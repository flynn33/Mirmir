"""Fail-closed P07 holdout mount, extraction, and evaluation boundary.

Preflight is metadata-only.  The encrypted volume is mounted, inventoried,
sampled, evaluated, and detached only inside ``HoldoutAccessGuard.read_once``.
The P06 release and all six external support roots are rehashed both before
authorization and after evaluation.  Extracted NV12 crops remain temporary;
only JSON evidence is published.
"""

from __future__ import annotations

import ctypes
from contextlib import nullcontext
from dataclasses import dataclass, replace
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile
import traceback
from typing import Any, Callable, Mapping, Optional, Sequence
import uuid

import jsonschema

from validation.calibration_v2.macos_code_identity import (
    authorize_running_code,
    static_code_identity,
)
from validation.calibration_v2.native_adapter.factory import (
    authorized_process_environment,
    run_authorized_pipeline,
    run_authorized_process,
)
from validation.calibration_v2.release_lock import (
    P06_SUPPORT_EVIDENCE_ROOT_IDS,
    p06_release_bundle_sha256 as _versioned_p06_release_bundle_sha256,
    validate_p06_release_bundle_manifest,
)
from validation.calibration_v2.run_provenance_v2 import (
    INPUT_BUNDLE_SHA256 as P06_V2_INPUT_BUNDLE_SHA256,
    PLAN_FILE_SHA256 as P06_V2_PLAN_FILE_SHA256,
    authority_input_bindings_v2,
)
from validation.calibration_v2.runner import (
    LiveHoldoutPreopenBinding,
    bind_preregistered_inputs,
    corpus_lock_bundle_sha256,
)
from validation.calibration_v2.p07.contracts_v2 import (
    IDENTITY_FIELD,
    release_identity_v2,
    selected_evaluation_projection_v2,
    validate_identity_v2,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
from validation.quality.src.mirmir_quality.holdout import HoldoutAccessGuard


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = CALIBRATION_ROOT.parents[1]
SCHEMAS_ROOT = CALIBRATION_ROOT / "schemas"
PLAN_SCHEMA = SCHEMAS_ROOT / "holdout-sampling-plan-v1.schema.json"
ATTESTATION_SCHEMA = (
    SCHEMAS_ROOT / "holdout-seal-attestation-no-pixel-v1.schema.json"
)
INNER_INVENTORY_SCHEMA = SCHEMAS_ROOT / "p07-inner-inventory-v1.schema.json"
EXTRACTION_SCHEMA = SCHEMAS_ROOT / "p07-frame-extraction-v1.schema.json"
EXECUTION_RESULT_SCHEMA = SCHEMAS_ROOT / "p07-execution-result-v1.schema.json"
G07_PUBLICATION_SCHEMA = SCHEMAS_ROOT / "p07-g07-publication-v1.schema.json"
RUNTIME_EVIDENCE_SCHEMA = SCHEMAS_ROOT / "p07-runtime-evidence-v1.schema.json"
ARTIFACT_MANIFEST_SCHEMA = (
    SCHEMAS_ROOT / "p07-artifact-manifest-v1.schema.json"
)
FAILURE_LOG_SCHEMA = SCHEMAS_ROOT / "p07-failure-log-v1.schema.json"
TRANSACTION_INTENT_SCHEMA = (
    SCHEMAS_ROOT / "p07-transaction-intent-v1.schema.json"
)
AUTHORIZED_EXECUTION_BINDINGS_SCHEMA = (
    SCHEMAS_ROOT / "p07-authorized-execution-bindings-v1.schema.json"
)
PRODUCTION_EXECUTION_BINDING_FRAGMENT_SCHEMA = (
    SCHEMAS_ROOT
    / "p07-production-authorized-execution-binding-fragment-v1.schema.json"
)
EXECUTION_RESULT_V2_SCHEMA = SCHEMAS_ROOT / "p07-execution-result-v2.schema.json"
G07_PUBLICATION_V2_SCHEMA = SCHEMAS_ROOT / "p07-g07-publication-v2.schema.json"
RUNTIME_EVIDENCE_V2_SCHEMA = SCHEMAS_ROOT / "p07-runtime-evidence-v2.schema.json"
ARTIFACT_MANIFEST_V2_SCHEMA = SCHEMAS_ROOT / "p07-artifact-manifest-v2.schema.json"
FAILURE_LOG_V2_SCHEMA = SCHEMAS_ROOT / "p07-failure-log-v2.schema.json"
TRANSACTION_INTENT_V2_SCHEMA = SCHEMAS_ROOT / "p07-transaction-intent-v2.schema.json"
AUTHORIZED_EXECUTION_BINDINGS_V2_SCHEMA = (
    SCHEMAS_ROOT / "p07-authorized-execution-bindings-v2.schema.json"
)
PRODUCTION_EXECUTION_BINDING_FRAGMENT_V2_SCHEMA = (
    SCHEMAS_ROOT
    / "p07-production-authorized-execution-binding-fragment-v2.schema.json"
)
EXECUTION_FAILURE_V2_SCHEMA = (
    SCHEMAS_ROOT / "p07-execution-failure-v2.schema.json"
)
MAX_JSON_BYTES = 16 * 1024 * 1024
SHA256_LENGTH = 64
ARTIFACT_MANIFEST_NAME = "artifact-manifest.json"
FAILURE_LOG_NAME = "failure-log.json"
AUTHORIZED_EXECUTION_BINDINGS_NAME = "authorized-execution-bindings.json"
PUBLICATION_PRODUCER = "Mirmir P07 locked-holdout harness"
PUBLICATION_GATE_IDS = ("P07", "G07")
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
EXPECTED_WORKFLOW_PATHS = {
    "mount_script_path": "tools/mount-read-only.sh",
    "unmount_script_path": "tools/unmount-provisioning.sh",
    "key_helper_path": "tools/bin/key-access",
}
_TRUSTED_SCRIPT_INTERPRETERS = frozenset(
    {Path("/bin/sh"), Path("/bin/bash"), Path("/bin/zsh")}
)
_MOUNT_TABLE_EXECUTABLE = Path("/sbin/mount")
_HDIUTIL_EXECUTABLE = Path("/usr/bin/hdiutil")
_AUTHORIZED_SPAWN_POLICY_VERSION = (
    "p07-mandatory-suspended-runtime-identity-v1"
)
_DIRECT_MOUNT_TEMPLATE_DIGEST_CONTRACT = (
    "SHA-256 of b'mount\\0' + mount-script bytes + "
    "b'\\0unmount\\0' + unmount-script bytes"
)
SUPPORT_ROOT_IDS = P06_SUPPORT_EVIDENCE_ROOT_IDS


class P07ExecutionError(RuntimeError):
    """A P07 preflight, authorization, lifecycle, or evidence check failed."""


@dataclass(frozen=True)
class P07MediaContext:
    """Exact media/case location attached only when the producer knows it."""

    asset_id: Optional[str] = None
    case_id: Optional[str] = None
    frame_index: Optional[int] = None
    presentation_timestamp: Optional[Mapping[str, int]] = None

    def evidence(self) -> Mapping[str, object]:
        if self.asset_id is not None and not self.asset_id:
            raise P07ExecutionError("P07 media asset ID is empty")
        if self.case_id is not None and not self.case_id:
            raise P07ExecutionError("P07 media case ID is empty")
        if self.frame_index is not None and (
            not isinstance(self.frame_index, int)
            or isinstance(self.frame_index, bool)
            or self.frame_index < 0
        ):
            raise P07ExecutionError("P07 media frame index is invalid")
        timestamp: Optional[Mapping[str, int]] = None
        if self.presentation_timestamp is not None:
            value = self.presentation_timestamp.get("value")
            timescale = self.presentation_timestamp.get("timescale")
            if (
                not isinstance(value, int)
                or isinstance(value, bool)
                or not isinstance(timescale, int)
                or isinstance(timescale, bool)
                or timescale <= 0
            ):
                raise P07ExecutionError("P07 media presentation timestamp is invalid")
            timestamp = {"value": value, "timescale": timescale}
        return {
            "media_asset_id": self.asset_id,
            "media_case_id": self.case_id,
            "frame_index": self.frame_index,
            "presentation_timestamp": timestamp,
            "media_context_available": any(
                value is not None
                for value in (
                    self.asset_id,
                    self.case_id,
                    self.frame_index,
                    timestamp,
                )
            ),
        }


class P07ContextualError(P07ExecutionError):
    """Failure carrying an exact, producer-supplied P07 media context."""

    def __init__(self, message: str, *, media_context: P07MediaContext) -> None:
        super().__init__(message)
        self.media_context = media_context


class P07DualFailure(P07ExecutionError):
    """Preserve independent evaluation and cleanup failures without flattening."""

    def __init__(
        self,
        primary_error: BaseException,
        cleanup_error: BaseException,
    ) -> None:
        super().__init__(
            "P07 evaluation failed ({}) and cleanup failed ({})".format(
                type(primary_error).__name__,
                type(cleanup_error).__name__,
            )
        )
        self.primary_error = primary_error
        self.cleanup_error = cleanup_error


@dataclass(frozen=True)
class MountObservation:
    mounted: bool
    read_only: bool
    record: str

@dataclass(frozen=True)
class P07Preflight:
    plan: Mapping[str, object]
    plan_file_sha256: str
    attestation: Mapping[str, object]
    attestation_file_sha256: str
    corpus_lock: Mapping[str, object]
    corpus_lock_file_sha256: str
    degradation_policy: Mapping[str, object]
    analytic_fixture_manifest: Mapping[str, object]
    outer_wrapper: Mapping[str, object]
    outer_wrapper_file_sha256: str
    release_bundle: Mapping[str, object]
    workflow_paths: Mapping[str, Path]
    mount_root: Path
    loader_sha256: str
    p07_cache_tree_sha256: str
    input_bundle_sha256: str
    corpus_lock_bundle_sha256: str
    input_records: Sequence[Mapping[str, object]]
    candidate_vector_sha256: Optional[str] = None
    shared_bank_configuration_sha256: Optional[str] = None
    p06_v2_identity: Optional[Mapping[str, str]] = None
    authorized_execution_bindings: Optional[Mapping[str, object]] = None


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == SHA256_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )


def _require_sha256(value: object, label: str) -> str:
    if not _is_sha256(value):
        raise P07ExecutionError("{} is not a lowercase SHA-256".format(label))
    return str(value)


def p06_release_bundle_sha256(
    bundle: Mapping[str, object],
) -> str:
    """Return exact V2/V3 identity without allowing V3 legacy fallback.

    The executor retains the historical manifest field for injected V1 test
    fixtures and legacy P07 archives.  Any document declaring a release schema
    is dispatched only through the strict versioned release validator.
    """

    if "schema_version" in bundle or "bundle_id" in bundle:
        return _versioned_p06_release_bundle_sha256(bundle)
    return _require_sha256(
        bundle.get("manifest_sha256"),
        "legacy P06 release manifest",
    )


def _preflight_p06_v2_identity(
    preflight: P07Preflight,
) -> Optional[Mapping[str, str]]:
    bundle = preflight.release_bundle
    identity = preflight.p06_v2_identity
    is_v3 = (
        bundle.get("schema_version") == "3.0.1"
        and bundle.get("bundle_id")
        == "mirmir-p06-spatial-release-lock-v3"
    )
    if is_v3:
        if identity is None:
            raise P07ExecutionError(
                "P06 V3 preflight has no authenticated P07 V2 identity"
            )
        validated = validate_identity_v2(identity)
        if (
            validated["p06_release_bundle_artifact_sha256"]
            != _versioned_p06_release_bundle_sha256(bundle)
        ):
            raise P07ExecutionError("P06 V3 preflight identity differs")
        return validated
    if identity is not None:
        raise P07ExecutionError(
            "P07 V2 identity is attached to a non-V3 preflight"
        )
    return None


def _normalized_absolute(path: Path, label: str) -> Path:
    if not isinstance(path, Path) or not path.is_absolute():
        raise P07ExecutionError("{} must be an absolute pathlib.Path".format(label))
    normalized = Path(os.path.normpath(os.fspath(path)))
    if normalized != path:
        raise P07ExecutionError("{} must be lexically normalized".format(label))
    return path


def _components(path: Path) -> Sequence[Path]:
    cursor = Path(path.anchor)
    values = [cursor]
    for part in path.parts[1:]:
        cursor = cursor / part
        values.append(cursor)
    return values


def _validate_existing_path(path: Path, *, label: str, kind: str) -> os.stat_result:
    path = _normalized_absolute(path, label)
    leaf: Optional[os.stat_result] = None
    for index, component in enumerate(_components(path)):
        try:
            metadata = os.lstat(component)
        except OSError as error:
            raise P07ExecutionError("{} is absent or inaccessible".format(label)) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise P07ExecutionError("{} traverses a symbolic link".format(label))
        is_leaf = index == len(_components(path)) - 1
        if not is_leaf and not stat.S_ISDIR(metadata.st_mode):
            raise P07ExecutionError("{} has a non-directory parent".format(label))
        if is_leaf:
            leaf = metadata
    if leaf is None:
        raise P07ExecutionError("{} has no filesystem identity".format(label))
    if kind == "file" and not stat.S_ISREG(leaf.st_mode):
        raise P07ExecutionError("{} is not a regular file".format(label))
    if kind == "directory" and not stat.S_ISDIR(leaf.st_mode):
        raise P07ExecutionError("{} is not a directory".format(label))
    return leaf


def _read_regular_file(path: Path, label: str, *, maximum: Optional[int] = None) -> bytes:
    before = _validate_existing_path(path, label=label, kind="file")
    if maximum is not None and before.st_size > maximum:
        raise P07ExecutionError("{} exceeds its size limit".format(label))
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise P07ExecutionError("{} could not be opened safely".format(label)) from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise P07ExecutionError("{} changed while opening".format(label))
        chunks = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            if not chunk:
                raise P07ExecutionError("{} was truncated while reading".format(label))
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise P07ExecutionError("{} grew while reading".format(label))
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    final = os.lstat(path)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or (final.st_dev, final.st_ino) != (before.st_dev, before.st_ino)
        or after.st_size != before.st_size
        or final.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or final.st_mtime_ns != before.st_mtime_ns
        or after.st_ctime_ns != before.st_ctime_ns
        or final.st_ctime_ns != before.st_ctime_ns
    ):
        raise P07ExecutionError("{} changed while reading".format(label))
    return b"".join(chunks)


def _sha256_file(path: Path, label: str) -> str:
    return hashlib.sha256(_read_regular_file(path, label)).hexdigest()


def _reject_duplicate_pairs(pairs: Sequence[tuple[str, object]]) -> Mapping[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise P07ExecutionError("duplicate JSON key: {}".format(key))
        result[key] = value
    return result


def _decode_json(payload: bytes, label: str) -> Mapping[str, object]:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                P07ExecutionError("non-finite JSON number: {}".format(token))
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise P07ExecutionError("{} is not valid UTF-8 JSON".format(label)) from error
    if not isinstance(value, dict):
        raise P07ExecutionError("{} top level is not an object".format(label))
    return value


def _read_json(path: Path, label: str) -> tuple[bytes, Mapping[str, object]]:
    payload = _read_regular_file(path, label, maximum=MAX_JSON_BYTES)
    return payload, _decode_json(payload, label)


def _canonical_bytes(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise P07ExecutionError("evidence is not finite canonical JSON") from error


def _validate_schema(document: Mapping[str, object], schema_path: Path, label: str) -> None:
    _, schema = _read_json(schema_path, "{} schema".format(label))
    validator = jsonschema.Draft202012Validator(
        schema,
        format_checker=jsonschema.FormatChecker(),
    )
    errors = sorted(validator.iter_errors(document), key=lambda error: list(error.path))
    if errors:
        raise P07ExecutionError(
            "{} schema validation failed: {}".format(label, errors[0].message)
        )


def _safe_relative(value: object, label: str) -> PurePosixPath:
    if not isinstance(value, str):
        raise P07ExecutionError("{} must be a string".format(label))
    parsed = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or "\x00" in value
        or "//" in value
        or parsed.as_posix() != value
        or any(part in {"", ".", ".."} for part in parsed.parts)
    ):
        raise P07ExecutionError("{} is not a safe relative path".format(label))
    return parsed


def _path_under(root: Path, value: object, label: str) -> Path:
    relative = _safe_relative(value, label)
    return root.joinpath(*relative.parts)


def _manifest_hash(document: Mapping[str, object], field: str = "manifest_sha256") -> str:
    return canonical_sha256({key: value for key, value in document.items() if key != field})


def _write_new(path: Path, payload: bytes) -> None:
    _validate_existing_path(path.parent, label="output parent", kind="directory")
    if os.path.lexists(path):
        raise P07ExecutionError("output path already exists")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    complete = False
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise P07ExecutionError("output write made no progress")
            offset += written
        os.fsync(descriptor)
        complete = True
    finally:
        os.close(descriptor)
        if not complete:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def _write_json(path: Path, document: Mapping[str, object]) -> None:
    _write_new(path, _canonical_bytes(document) + b"\n")


def _unavailable_authorized_execution_bindings() -> Mapping[str, object]:
    document = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_authorized_execution_bindings",
        "status": "unavailable",
        "authorized_environment": authorized_process_environment(
            Path("/private/tmp")
        ),
        "authorized_spawn_policy_version": _AUTHORIZED_SPAWN_POLICY_VERSION,
        "direct_mount_template_sha256": None,
        "direct_mount_template_digest_contract": (
            _DIRECT_MOUNT_TEMPLATE_DIGEST_CONTRACT
        ),
        "unavailable_reason": (
            "authorized execution closure was not completed before "
            "pre-guard failure"
        ),
        "loader": None,
        "sampling_plan": None,
        "mount_script": None,
        "unmount_script": None,
        "key_helper": None,
        "mount_table": None,
        "hdiutil": None,
        "production_execution_binding_fragment": None,
    }
    document["manifest_sha256"] = _manifest_hash(document)
    return document


def _validate_authorized_execution_bindings(
    document: Mapping[str, object],
    *,
    require_bound: bool,
) -> None:
    is_v2 = document.get("schema_version") == "2.0.0"
    _validate_schema(
        document,
        (
            AUTHORIZED_EXECUTION_BINDINGS_V2_SCHEMA
            if is_v2
            else AUTHORIZED_EXECUTION_BINDINGS_SCHEMA
        ),
        "P07 authorized execution bindings",
    )
    identity = None
    if is_v2:
        try:
            identity = validate_identity_v2(document.get(IDENTITY_FIELD))
        except ValueError as error:
            raise P07ExecutionError(
                "P07 authorized execution V2 identity differs"
            ) from error
    if document.get("manifest_sha256") != _manifest_hash(document):
        raise P07ExecutionError(
            "P07 authorized execution bindings self-hash differs"
        )
    production_fragment = document.get(
        "production_execution_binding_fragment"
    )
    if document.get("status") == "bound":
        if not isinstance(production_fragment, dict):
            raise P07ExecutionError(
                "P07 production execution binding fragment is absent"
            )
        _validate_schema(
            production_fragment,
            (
                PRODUCTION_EXECUTION_BINDING_FRAGMENT_V2_SCHEMA
                if is_v2
                else PRODUCTION_EXECUTION_BINDING_FRAGMENT_SCHEMA
            ),
            "P07 production execution binding fragment",
        )
        if is_v2:
            try:
                validate_identity_v2(
                    production_fragment.get(IDENTITY_FIELD),
                    expected=identity,
                )
            except ValueError as error:
                raise P07ExecutionError(
                    "P07 production fragment V2 identity differs"
                ) from error
        if production_fragment.get("fragment_sha256") != _manifest_hash(
            production_fragment,
            field="fragment_sha256",
        ):
            raise P07ExecutionError(
                "P07 production execution binding fragment self-hash differs"
            )
    if require_bound and document.get("status") != "bound":
        raise P07ExecutionError(
            "P07 authorized execution bindings are unavailable"
        )


def _write_authorized_execution_bindings(
    directory: Path,
    document: Mapping[str, object],
    *,
    require_bound: bool,
) -> tuple[str, str]:
    _validate_authorized_execution_bindings(
        document,
        require_bound=require_bound,
    )
    path = directory / AUTHORIZED_EXECUTION_BINDINGS_NAME
    if os.path.lexists(path):
        payload, reopened = _read_json(
            path,
            "P07 authorized execution bindings",
        )
        if reopened != document:
            raise P07ExecutionError(
                "P07 authorized execution bindings differ after reopening"
            )
    else:
        _write_json(path, document)
        payload, reopened = _read_json(
            path,
            "P07 authorized execution bindings",
        )
    if payload != _canonical_bytes(reopened) + b"\n":
        raise P07ExecutionError(
            "P07 authorized execution bindings are not canonical JSON"
        )
    _validate_authorized_execution_bindings(
        reopened,
        require_bound=require_bound,
    )
    return (
        hashlib.sha256(payload).hexdigest(),
        str(reopened["manifest_sha256"]),
    )


def _read_authorized_execution_bindings(
    directory: Path,
    *,
    require_bound: bool,
) -> tuple[bytes, Mapping[str, object]]:
    payload, document = _read_json(
        directory / AUTHORIZED_EXECUTION_BINDINGS_NAME,
        "P07 authorized execution bindings",
    )
    if payload != _canonical_bytes(document) + b"\n":
        raise P07ExecutionError(
            "P07 authorized execution bindings are not canonical JSON"
        )
    _validate_authorized_execution_bindings(
        document,
        require_bound=require_bound,
    )
    return payload, document


def _authorized_execution_publication_document(
    value: object,
) -> Mapping[str, object]:
    if isinstance(value, dict):
        document = dict(value)
        _validate_authorized_execution_bindings(
            document,
            require_bound=True,
        )
        return document
    return _unavailable_authorized_execution_bindings()


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _open_directory_nofollow(path: Path, label: str) -> tuple[int, os.stat_result]:
    before = _validate_existing_path(path, label=label, kind="directory")
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise P07ExecutionError("{} cannot be opened safely".format(label)) from error
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
    ):
        os.close(descriptor)
        raise P07ExecutionError("{} changed while opening".format(label))
    return descriptor, opened


def _verify_directory_path_identity(
    path: Path,
    expected: os.stat_result,
    label: str,
) -> None:
    current = _validate_existing_path(path, label=label, kind="directory")
    if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
        raise P07ExecutionError("{} identity changed".format(label))


def _rename_directory_exclusive_at(
    source_parent_descriptor: int,
    source_name: str,
    destination_parent_descriptor: int,
    destination_name: str,
) -> None:
    if (
        not source_name
        or not destination_name
        or "/" in source_name
        or "/" in destination_name
        or source_name in {".", ".."}
        or destination_name in {".", ".."}
    ):
        raise P07ExecutionError("exclusive publication names are invalid")
    if _RENAMEATX_NP is None:
        raise P07ExecutionError(
            "exclusive descriptor-pinned directory publication is unavailable"
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
        raise FileExistsError(
            number,
            "exclusive P07 publication destination already exists",
            destination_name,
        )
    raise OSError(number, os.strerror(number), destination_name)


def _descriptor_entry_names(descriptor: int, label: str) -> tuple[str, ...]:
    try:
        names = tuple(sorted(os.listdir(descriptor)))
    except OSError as error:
        raise P07ExecutionError("{} cannot be enumerated".format(label)) from error
    if any(
        not name or name in {".", ".."} or "/" in name or "\x00" in name
        for name in names
    ):
        raise P07ExecutionError("{} contains an invalid child name".format(label))
    return names


def _open_child_descriptor(
    parent_descriptor: int,
    name: str,
    *,
    directory: bool,
    label: str,
) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY
    if directory and hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise P07ExecutionError("{} child cannot be pinned".format(label)) from error
    opened = os.fstat(descriptor)
    expected_kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not expected_kind(before.st_mode)
        or not expected_kind(opened.st_mode)
        or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
    ):
        os.close(descriptor)
        raise P07ExecutionError("{} child identity changed".format(label))
    return descriptor, opened


def _hash_regular_descriptor(
    descriptor: int,
    identity: os.stat_result,
    label: str,
) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    except OSError as error:
        raise P07ExecutionError("{} content cannot be read".format(label)) from error
    after = os.fstat(descriptor)
    if (
        (after.st_dev, after.st_ino) != (identity.st_dev, identity.st_ino)
        or after.st_size != identity.st_size
        or after.st_mtime_ns != identity.st_mtime_ns
        or size != identity.st_size
    ):
        raise P07ExecutionError("{} changed while being hashed".format(label))
    return digest.hexdigest(), size


@dataclass
class _RetainedAuthorizedFile:
    path: Path
    descriptor: int
    identity: os.stat_result
    sha256: str
    label: str

    @classmethod
    def open(
        cls,
        path: Path,
        *,
        expected_sha256: Optional[str],
        executable: bool,
        label: str,
    ) -> "_RetainedAuthorizedFile":
        metadata = _validate_existing_path(path, label=label, kind="file")
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            descriptor = os.open(path, flags)
        except OSError as error:
            raise P07ExecutionError(
                "{} cannot be retained".format(label)
            ) from error
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino)
                != (metadata.st_dev, metadata.st_ino)
                or opened.st_nlink != 1
                or (executable and stat.S_IMODE(opened.st_mode) & 0o111 == 0)
            ):
                raise P07ExecutionError(
                    "{} retained identity or mode differs".format(label)
                )
            digest, size = _hash_regular_descriptor(
                descriptor,
                opened,
                label,
            )
            if size != opened.st_size or (
                expected_sha256 is not None and digest != expected_sha256
            ):
                raise P07ExecutionError(
                    "{} retained hash differs".format(label)
                )
            retained = cls(
                path=path,
                descriptor=descriptor,
                identity=opened,
                sha256=digest,
                label=label,
            )
            retained.verify()
            return retained
        except BaseException:
            os.close(descriptor)
            raise

    def verify(self) -> None:
        opened = os.fstat(self.descriptor)
        current = _validate_existing_path(
            self.path,
            label=self.label,
            kind="file",
        )
        stable = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_nlink,
            stat.S_IMODE(value.st_mode),
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if (
            stable(opened) != stable(self.identity)
            or stable(current) != stable(self.identity)
        ):
            raise P07ExecutionError(
                "{} retained or named identity changed".format(self.label)
            )
        digest, size = _hash_regular_descriptor(
            self.descriptor,
            self.identity,
            self.label,
        )
        if digest != self.sha256 or size != self.identity.st_size:
            raise P07ExecutionError(
                "{} retained bytes changed".format(self.label)
            )

    def read_prefix(self, maximum: int) -> bytes:
        if maximum <= 0:
            raise P07ExecutionError(
                "{} prefix limit is invalid".format(self.label)
            )
        try:
            return os.pread(
                self.descriptor,
                min(maximum, self.identity.st_size),
                0,
            )
        except OSError as error:
            raise P07ExecutionError(
                "{} retained prefix cannot be read".format(self.label)
            ) from error

    def reset(self) -> None:
        try:
            os.lseek(self.descriptor, 0, os.SEEK_SET)
        except OSError as error:
            raise P07ExecutionError(
                "{} retained offset cannot be reset".format(self.label)
            ) from error

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


@dataclass
class _RetainedCodeBinding:
    file: _RetainedAuthorizedFile
    code_identity: Mapping[str, object]

    @classmethod
    def open(
        cls,
        path: Path,
        *,
        expected_sha256: Optional[str],
        label: str,
    ) -> "_RetainedCodeBinding":
        retained = _RetainedAuthorizedFile.open(
            path,
            expected_sha256=expected_sha256,
            executable=True,
            label=label,
        )
        try:
            identity = dict(static_code_identity(path))
            if identity.get("file_sha256") != retained.sha256:
                raise P07ExecutionError(
                    "{} code identity and retained bytes differ".format(label)
                )
            retained.verify()
            return cls(file=retained, code_identity=identity)
        except BaseException:
            retained.close()
            raise

    def verify(self) -> None:
        self.file.verify()
        if dict(static_code_identity(self.file.path)) != dict(
            self.code_identity
        ):
            raise P07ExecutionError(
                "{} static code identity changed".format(self.file.label)
            )
        self.file.verify()

    def binding(self) -> Mapping[str, object]:
        return {
            "path": os.fspath(self.file.path),
            "file_sha256": self.file.sha256,
            "code_identity": dict(self.code_identity),
        }


@dataclass
class _RetainedScriptBinding:
    script: _RetainedAuthorizedFile
    interpreter: _RetainedCodeBinding

    def binding(self) -> Mapping[str, object]:
        return {
            "path": os.fspath(self.script.path),
            "file_sha256": self.script.sha256,
            "interpreter": self.interpreter.binding(),
        }


@dataclass
class _AuthorizedExecutionContext:
    loader: _RetainedCodeBinding
    sampling_plan: _RetainedAuthorizedFile
    mount_script: _RetainedScriptBinding
    unmount_script: _RetainedScriptBinding
    key_helper: _RetainedCodeBinding
    mount_table: _RetainedCodeBinding
    hdiutil: _RetainedCodeBinding
    direct_mount_template_sha256: str
    production_execution_binding_fragment: Optional[
        Mapping[str, object]
    ]
    p06_v2_identity: Optional[Mapping[str, str]] = None

    def binding_document(self) -> Mapping[str, object]:
        identity = (
            validate_identity_v2(self.p06_v2_identity)
            if self.p06_v2_identity is not None
            else None
        )
        document = {
            "schema_version": "2.0.0" if identity is not None else "1.0.0",
            "artifact_kind": (
                "p07_authorized_execution_bindings_v2"
                if identity is not None
                else "p07_authorized_execution_bindings"
            ),
            **(
                {IDENTITY_FIELD: dict(identity)}
                if identity is not None
                else {}
            ),
            "status": "bound",
            "authorized_environment": authorized_process_environment(
                Path("/private/tmp")
            ),
            "authorized_spawn_policy_version": (
                _AUTHORIZED_SPAWN_POLICY_VERSION
            ),
            "direct_mount_template_sha256": (
                self.direct_mount_template_sha256
            ),
            "direct_mount_template_digest_contract": (
                _DIRECT_MOUNT_TEMPLATE_DIGEST_CONTRACT
            ),
            "unavailable_reason": None,
            "loader": self.loader.binding(),
            "sampling_plan": {
                "path": os.fspath(self.sampling_plan.path),
                "file_sha256": self.sampling_plan.sha256,
            },
            "mount_script": self.mount_script.binding(),
            "unmount_script": self.unmount_script.binding(),
            "key_helper": self.key_helper.binding(),
            "mount_table": self.mount_table.binding(),
            "hdiutil": self.hdiutil.binding(),
            "production_execution_binding_fragment": (
                dict(self.production_execution_binding_fragment)
                if self.production_execution_binding_fragment is not None
                else None
            ),
        }
        document["manifest_sha256"] = _manifest_hash(document)
        return document

    def verify(self) -> None:
        self.loader.verify()
        self.sampling_plan.verify()
        for script in (self.mount_script, self.unmount_script):
            script.script.verify()
            script.interpreter.verify()
        for executable in (
            self.key_helper,
            self.mount_table,
            self.hdiutil,
        ):
            executable.verify()
        if self.production_execution_binding_fragment is not None:
            is_v2 = self.p06_v2_identity is not None
            _validate_schema(
                self.production_execution_binding_fragment,
                (
                    PRODUCTION_EXECUTION_BINDING_FRAGMENT_V2_SCHEMA
                    if is_v2
                    else PRODUCTION_EXECUTION_BINDING_FRAGMENT_SCHEMA
                ),
                "P07 retained production execution binding fragment",
            )
            if is_v2:
                validate_identity_v2(
                    self.production_execution_binding_fragment.get(
                        IDENTITY_FIELD
                    ),
                    expected=validate_identity_v2(self.p06_v2_identity),
                )
            if self.production_execution_binding_fragment.get(
                "fragment_sha256"
            ) != _manifest_hash(
                self.production_execution_binding_fragment,
                field="fragment_sha256",
            ):
                raise P07ExecutionError(
                    "P07 retained production execution fragment hash differs"
                )

    def close(self) -> None:
        files = (
            self.loader.file,
            self.sampling_plan,
            self.mount_script.script,
            self.mount_script.interpreter.file,
            self.unmount_script.script,
            self.unmount_script.interpreter.file,
            self.key_helper.file,
            self.mount_table.file,
            self.hdiutil.file,
        )
        primary: Optional[BaseException] = None
        closed = set()
        for retained in files:
            if id(retained) in closed:
                continue
            closed.add(id(retained))
            try:
                retained.close()
            except BaseException as error:
                if primary is None:
                    primary = error
        if primary is not None:
            raise primary


def _retained_script_interpreter(
    script: _RetainedAuthorizedFile,
) -> Path:
    prefix = script.read_prefix(4096)
    line, separator, _ = prefix.partition(b"\n")
    if not separator:
        raise P07ExecutionError(
            "{} shebang line is absent".format(script.label)
        )
    try:
        shebang = line.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise P07ExecutionError(
            "{} shebang is not UTF-8".format(script.label)
        ) from error
    if not shebang.startswith("#!"):
        raise P07ExecutionError(
            "{} shebang is absent".format(script.label)
        )
    declaration = shebang[2:]
    if (
        not declaration
        or declaration != declaration.strip()
        or any(character.isspace() for character in declaration)
    ):
        raise P07ExecutionError(
            "{} shebang arguments are unsupported".format(script.label)
        )
    interpreter = Path(declaration)
    if interpreter not in _TRUSTED_SCRIPT_INTERPRETERS:
        raise P07ExecutionError(
            "{} interpreter is not explicitly trusted".format(script.label)
        )
    return interpreter


def _direct_mount_template_sha256(
    mount_script: _RetainedAuthorizedFile,
    unmount_script: _RetainedAuthorizedFile,
) -> str:
    if (
        mount_script.identity.st_size > 64 * 1024
        or unmount_script.identity.st_size > 64 * 1024
    ):
        raise P07ExecutionError("P07 direct-mount template exceeds its limit")
    payload = (
        b"mount\x00"
        + mount_script.read_prefix(64 * 1024)
        + b"\x00unmount\x00"
        + unmount_script.read_prefix(64 * 1024)
    )
    return hashlib.sha256(payload).hexdigest()


def _snapshot_descriptor_tree(
    root_descriptor: int,
    label: str,
) -> Mapping[str, object]:
    """Snapshot exact path, inode, mode, size, and bytes through pinned dirfds."""

    root_identity = os.fstat(root_descriptor)
    if not stat.S_ISDIR(root_identity.st_mode):
        raise P07ExecutionError("{} root is not a directory".format(label))
    rows: list[Mapping[str, object]] = []

    def visit(directory_descriptor: int, relative_directory: str) -> None:
        directory_before = os.fstat(directory_descriptor)
        names = _descriptor_entry_names(directory_descriptor, label)
        for name in names:
            relative = name if not relative_directory else "{}/{}".format(
                relative_directory,
                name,
            )
            try:
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise P07ExecutionError(
                    "{} child cannot be inspected".format(label)
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                raise P07ExecutionError("{} contains a symbolic link".format(label))
            if stat.S_ISDIR(metadata.st_mode):
                child_descriptor, opened = _open_child_descriptor(
                    directory_descriptor,
                    name,
                    directory=True,
                    label=label,
                )
                try:
                    rows.append(
                        {
                            "path": relative,
                            "kind": "directory",
                            "device": opened.st_dev,
                            "inode": opened.st_ino,
                            "mode": stat.S_IMODE(opened.st_mode),
                        }
                    )
                    visit(child_descriptor, relative)
                finally:
                    os.close(child_descriptor)
            elif stat.S_ISREG(metadata.st_mode):
                child_descriptor, opened = _open_child_descriptor(
                    directory_descriptor,
                    name,
                    directory=False,
                    label=label,
                )
                try:
                    digest, size = _hash_regular_descriptor(
                        child_descriptor,
                        opened,
                        label,
                    )
                    rows.append(
                        {
                            "path": relative,
                            "kind": "file",
                            "device": opened.st_dev,
                            "inode": opened.st_ino,
                            "mode": stat.S_IMODE(opened.st_mode),
                            "size_bytes": size,
                            "sha256": digest,
                        }
                    )
                finally:
                    os.close(child_descriptor)
            else:
                raise P07ExecutionError(
                    "{} contains a nonregular entry".format(label)
                )
        if _descriptor_entry_names(directory_descriptor, label) != names:
            raise P07ExecutionError("{} child set changed during snapshot".format(label))
        directory_after = os.fstat(directory_descriptor)
        if (
            (directory_after.st_dev, directory_after.st_ino)
            != (directory_before.st_dev, directory_before.st_ino)
        ):
            raise P07ExecutionError("{} directory identity changed".format(label))

    visit(root_descriptor, "")
    root_after = os.fstat(root_descriptor)
    if (root_after.st_dev, root_after.st_ino) != (
        root_identity.st_dev,
        root_identity.st_ino,
    ):
        raise P07ExecutionError("{} root identity changed".format(label))
    return {
        "root": {
            "device": root_identity.st_dev,
            "inode": root_identity.st_ino,
            "mode": stat.S_IMODE(root_identity.st_mode),
        },
        "entries": sorted(rows, key=lambda row: (str(row["path"]), str(row["kind"]))),
    }


def _sync_descriptor_tree_durable(root_descriptor: int, label: str) -> None:
    """Fsync every pinned regular file and directory bottom-up."""

    def visit(directory_descriptor: int) -> None:
        names = _descriptor_entry_names(directory_descriptor, label)
        for name in names:
            metadata = os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
            if stat.S_ISLNK(metadata.st_mode):
                raise P07ExecutionError("{} contains a symbolic link".format(label))
            if stat.S_ISDIR(metadata.st_mode):
                child_descriptor, _ = _open_child_descriptor(
                    directory_descriptor,
                    name,
                    directory=True,
                    label=label,
                )
                try:
                    visit(child_descriptor)
                finally:
                    os.close(child_descriptor)
            elif stat.S_ISREG(metadata.st_mode):
                child_descriptor, opened = _open_child_descriptor(
                    directory_descriptor,
                    name,
                    directory=False,
                    label=label,
                )
                try:
                    os.fsync(child_descriptor)
                    after = os.fstat(child_descriptor)
                    if (
                        (after.st_dev, after.st_ino)
                        != (opened.st_dev, opened.st_ino)
                        or after.st_size != opened.st_size
                        or after.st_mtime_ns != opened.st_mtime_ns
                    ):
                        raise P07ExecutionError(
                            "{} file changed during durability sync".format(label)
                        )
                finally:
                    os.close(child_descriptor)
            else:
                raise P07ExecutionError(
                    "{} contains a nonregular entry".format(label)
                )
        if _descriptor_entry_names(directory_descriptor, label) != names:
            raise P07ExecutionError("{} child set changed during sync".format(label))
        os.fsync(directory_descriptor)

    visit(root_descriptor)


def _write_new_at(
    directory_descriptor: int,
    name: str,
    payload: bytes,
    label: str,
) -> None:
    if not name or name in {".", ".."} or "/" in name or "\x00" in name:
        raise P07ExecutionError("{} name is invalid".format(label))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        descriptor = os.open(name, flags, 0o600, dir_fd=directory_descriptor)
    except OSError as error:
        raise P07ExecutionError("{} cannot be created".format(label)) from error
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise P07ExecutionError("{} write made no progress".format(label))
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _read_regular_at(
    directory_descriptor: int,
    name: str,
    label: str,
    *,
    maximum: int = MAX_JSON_BYTES,
) -> bytes:
    descriptor, identity = _open_child_descriptor(
        directory_descriptor,
        name,
        directory=False,
        label=label,
    )
    try:
        if identity.st_size > maximum:
            raise P07ExecutionError("{} exceeds its size limit".format(label))
        digest, size = _hash_regular_descriptor(descriptor, identity, label)
        del digest
        os.lseek(descriptor, 0, os.SEEK_SET)
        payload = b""
        while len(payload) < size:
            chunk = os.read(descriptor, min(size - len(payload), 1024 * 1024))
            if not chunk:
                raise P07ExecutionError("{} was truncated".format(label))
            payload += chunk
        if os.read(descriptor, 1):
            raise P07ExecutionError("{} grew while reading".format(label))
        return payload
    finally:
        os.close(descriptor)


def _transaction_directory_path(output_directory: Path) -> Path:
    digest = hashlib.sha256(
        os.fspath(output_directory).encode("utf-8", "strict")
    ).hexdigest()[:32]
    return output_directory.parent / ".p07-transaction-{}".format(digest)


def _pre_guard_failure_staging_path(output_directory: Path) -> Path:
    digest = hashlib.sha256(
        os.fspath(output_directory).encode("utf-8", "strict")
    ).hexdigest()[:32]
    return output_directory.parent / ".p07-pre-guard-failure-{}".format(digest)


def _transaction_intent_document(
    *,
    output_directory: Path,
    configuration_lock: Mapping[str, object],
    preflight: P07Preflight,
    live_binding: LiveHoldoutPreopenBinding,
    command: str,
    platform: str,
) -> Mapping[str, object]:
    workflow = preflight.attestation["read_only_provisioning_workflow"]
    identity = _preflight_p06_v2_identity(preflight)
    source_gate_semantics = None
    if identity is not None:
        bindings = preflight.authorized_execution_bindings
        fragment = (
            bindings.get("production_execution_binding_fragment")
            if isinstance(bindings, dict)
            else None
        )
        source_gate_semantics = (
            fragment.get("source_gate_semantics")
            if isinstance(fragment, dict)
            else None
        )
        if (
            not isinstance(source_gate_semantics, dict)
            or source_gate_semantics.get("artifact_kind")
            != "p06_current_source_gate_semantics_v2"
            or source_gate_semantics.get("status") != "pass"
            or source_gate_semantics.get("holdout_accessed") is not False
            or source_gate_semantics.get("manifest_sha256")
            != _manifest_hash(source_gate_semantics)
        ):
            raise P07ExecutionError(
                "P07 V2 transaction has no authenticated source-gate semantics"
            )
    document = {
        "schema_version": "2.0.0" if identity is not None else "1.0.0",
        "artifact_kind": (
            "p07_durable_transaction_intent_v2"
            if identity is not None
            else "p07_durable_transaction_intent"
        ),
        **(
            {IDENTITY_FIELD: dict(identity)}
            if identity is not None
            else {}
        ),
        **(
            {"source_gate_semantics": dict(source_gate_semantics)}
            if source_gate_semantics is not None
            else {}
        ),
        "transaction_id": str(uuid.uuid4()),
        "transaction_state": "pre_guard",
        "requested_output_directory": os.fspath(output_directory),
        "configuration_id": preflight.release_bundle["configuration_id"],
        "configuration_sha256": canonical_sha256(configuration_lock),
        "release_bundle_manifest_sha256": p06_release_bundle_sha256(
            preflight.release_bundle
        ),
        "input_bundle_sha256": preflight.input_bundle_sha256,
        "corpus_lock_bundle_sha256": preflight.corpus_lock_bundle_sha256,
        "corpus_manifest_sha256": preflight.corpus_lock["manifest_sha256"],
        "sampling_plan_file_sha256": preflight.plan_file_sha256,
        "sampling_plan_manifest_sha256": preflight.plan["manifest_sha256"],
        "no_pixel_attestation_file_sha256": preflight.attestation_file_sha256,
        "outer_wrapper_file_sha256": preflight.outer_wrapper_file_sha256,
        "outer_wrapper_manifest_sha256": preflight.outer_wrapper[
            "manifest_sha256"
        ],
        "loader_executable_sha256": preflight.loader_sha256,
        "authorized_execution_bindings": (
            dict(preflight.authorized_execution_bindings)
            if preflight.authorized_execution_bindings is not None
            else None
        ),
        "p07_preopen_cache_tree_sha256": preflight.p07_cache_tree_sha256,
        "inner_inventory_sha256": preflight.attestation["inner_inventory"][
            "sha256"
        ],
        "direct_input_bindings": [
            {
                "id": record["id"],
                "path": record["path"],
                "sha256": record["sha256"],
                "size_bytes": record["size_bytes"],
            }
            for record in preflight.input_records
        ],
        "unmount_script_path": os.fspath(
            preflight.workflow_paths["unmount_script_path"]
        ),
        "unmount_script_sha256": workflow["unmount_script_sha256"],
        "live_ledger_path": os.fspath(live_binding.live_ledger_path),
        "live_anchor_path": os.fspath(live_binding.live_anchor_path),
        "live_preopen_receipt_path": os.fspath(
            live_binding.live_preopen_receipt_path
        ),
        "expected_live_ledger_root_identity_sha256": (
            live_binding.expected_live_ledger_root_identity_sha256
        ),
        "expected_live_anchor_root_identity_sha256": (
            live_binding.expected_live_anchor_root_identity_sha256
        ),
        "expected_live_preopen_receipt_sha256": (
            live_binding.expected_live_preopen_receipt_sha256
        ),
        "command": command,
        "platform": platform,
    }
    document["manifest_sha256"] = _manifest_hash(document)
    _validate_schema(
        document,
        (
            TRANSACTION_INTENT_V2_SCHEMA
            if identity is not None
            else TRANSACTION_INTENT_SCHEMA
        ),
        "P07 durable transaction intent",
    )
    return document


def _read_transaction_intent_at(
    transaction_descriptor: int,
    *,
    output_directory: Path,
) -> Mapping[str, object]:
    payload = _read_regular_at(
        transaction_descriptor,
        "transaction-intent.json",
        "P07 durable transaction intent",
    )
    document = _decode_json(payload, "P07 durable transaction intent")
    is_v2 = document.get("schema_version") == "2.0.0"
    _validate_schema(
        document,
        TRANSACTION_INTENT_V2_SCHEMA if is_v2 else TRANSACTION_INTENT_SCHEMA,
        "P07 durable transaction intent",
    )
    if is_v2:
        try:
            validate_identity_v2(document.get(IDENTITY_FIELD))
        except ValueError as error:
            raise P07ExecutionError(
                "P07 durable transaction V2 identity differs"
            ) from error
    if (
        payload != _canonical_bytes(document) + b"\n"
        or document.get("manifest_sha256") != _manifest_hash(document)
        or document.get("requested_output_directory")
        != os.fspath(output_directory)
    ):
        raise P07ExecutionError(
            "P07 transaction directory is not a recognized owned transaction"
        )
    return document


def _clear_directory_descriptor(
    directory_descriptor: int,
    label: str,
) -> None:
    """Remove only pinned regular children and directories without link traversal."""

    for name in _descriptor_entry_names(directory_descriptor, label):
        metadata = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if stat.S_ISLNK(metadata.st_mode):
            raise P07ExecutionError("{} contains a symbolic link".format(label))
        if stat.S_ISDIR(metadata.st_mode):
            child_descriptor, _ = _open_child_descriptor(
                directory_descriptor,
                name,
                directory=True,
                label=label,
            )
            try:
                _clear_directory_descriptor(child_descriptor, label)
            finally:
                os.close(child_descriptor)
            os.rmdir(name, dir_fd=directory_descriptor)
        elif stat.S_ISREG(metadata.st_mode):
            os.unlink(name, dir_fd=directory_descriptor)
        else:
            raise P07ExecutionError("{} contains a nonregular entry".format(label))
    os.fsync(directory_descriptor)


@dataclass
class _P07TransactionWorkspace:
    path: Path
    parent_descriptor: int
    parent_identity: os.stat_result
    descriptor: int
    identity: os.stat_result
    intent: Mapping[str, object]

    @classmethod
    def open_existing(
        cls,
        *,
        output_directory: Path,
        parent_descriptor: int,
        parent_identity: os.stat_result,
    ) -> Optional["_P07TransactionWorkspace"]:
        path = _transaction_directory_path(output_directory)
        try:
            descriptor, identity = _open_child_descriptor(
                parent_descriptor,
                path.name,
                directory=True,
                label="P07 durable transaction workspace",
            )
        except P07ExecutionError:
            if not os.path.lexists(path):
                return None
            raise
        try:
            intent = _read_transaction_intent_at(
                descriptor,
                output_directory=output_directory,
            )
            workspace = cls(
                path=path,
                parent_descriptor=parent_descriptor,
                parent_identity=parent_identity,
                descriptor=descriptor,
                identity=identity,
                intent=intent,
            )
            workspace.verify()
            return workspace
        except BaseException:
            os.close(descriptor)
            raise

    @classmethod
    def open_or_create(
        cls,
        *,
        output_directory: Path,
        parent_descriptor: int,
        parent_identity: os.stat_result,
        intent: Mapping[str, object],
    ) -> tuple["_P07TransactionWorkspace", bool]:
        path = _transaction_directory_path(output_directory)
        created = False
        try:
            os.mkdir(path.name, 0o700, dir_fd=parent_descriptor)
            created = True
        except FileExistsError:
            pass
        descriptor, identity = _open_child_descriptor(
            parent_descriptor,
            path.name,
            directory=True,
            label="P07 durable transaction workspace",
        )
        try:
            if created:
                _write_new_at(
                    descriptor,
                    "transaction-intent.json",
                    _canonical_bytes(intent) + b"\n",
                    "P07 durable transaction intent",
                )
                for name in ("extraction", "publication"):
                    os.mkdir(name, 0o700, dir_fd=descriptor)
                os.fsync(descriptor)
                os.fsync(parent_descriptor)
            reopened = _read_transaction_intent_at(
                descriptor,
                output_directory=output_directory,
            )
            comparable_fields = set(intent) - {"transaction_id", "manifest_sha256"}
            if any(reopened.get(field) != intent.get(field) for field in comparable_fields):
                raise P07ExecutionError(
                    "existing P07 transaction intent differs from this invocation"
                )
            workspace = cls(
                path=path,
                parent_descriptor=parent_descriptor,
                parent_identity=parent_identity,
                descriptor=descriptor,
                identity=identity,
                intent=reopened,
            )
            workspace.verify()
            return workspace, created
        except BaseException:
            os.close(descriptor)
            raise

    def verify(self) -> None:
        opened = os.fstat(self.descriptor)
        if (
            (opened.st_dev, opened.st_ino)
            != (self.identity.st_dev, self.identity.st_ino)
            or not stat.S_ISDIR(opened.st_mode)
        ):
            raise P07ExecutionError("P07 transaction descriptor identity changed")
        _verify_directory_path_identity(
            self.path.parent,
            self.parent_identity,
            "P07 output parent",
        )
        current = os.stat(
            self.path.name,
            dir_fd=self.parent_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(current.st_mode)
            or (current.st_dev, current.st_ino)
            != (self.identity.st_dev, self.identity.st_ino)
        ):
            raise P07ExecutionError("P07 transaction workspace identity changed")
        allowed = {
            "transaction-intent.json",
            "extraction",
            "publication",
            "failure",
            "emergency",
        }
        names = set(
            _descriptor_entry_names(
                self.descriptor,
                "P07 durable transaction workspace",
            )
        )
        if not names <= allowed or "transaction-intent.json" not in names:
            raise P07ExecutionError(
                "P07 transaction workspace contains an unknown path"
            )
        _read_transaction_intent_at(
            self.descriptor,
            output_directory=Path(
                str(self.intent["requested_output_directory"])
            ),
        )

    def child_descriptor(
        self,
        name: str,
        *,
        required: bool = True,
    ) -> Optional[tuple[int, os.stat_result]]:
        self.verify()
        try:
            return _open_child_descriptor(
                self.descriptor,
                name,
                directory=True,
                label="P07 transaction {}".format(name),
            )
        except P07ExecutionError:
            if required:
                raise
            return None

    def ensure_empty_child(self, name: str) -> None:
        opened = self.child_descriptor(name)
        assert opened is not None
        descriptor, _ = opened
        try:
            if _descriptor_entry_names(
                descriptor,
                "P07 transaction {}".format(name),
            ):
                raise P07ExecutionError(
                    "P07 resumable transaction {} is not empty".format(name)
                )
        finally:
            os.close(descriptor)

    def remove_child(self, name: str) -> None:
        opened = self.child_descriptor(name, required=False)
        if opened is None:
            return
        descriptor, _ = opened
        try:
            _clear_directory_descriptor(
                descriptor,
                "P07 transaction {}".format(name),
            )
        finally:
            os.close(descriptor)
        os.rmdir(name, dir_fd=self.descriptor)
        os.fsync(self.descriptor)

    def close(self) -> None:
        os.close(self.descriptor)

    def destroy(self) -> None:
        self.verify()
        _clear_directory_descriptor(
            self.descriptor,
            "P07 durable transaction workspace",
        )
        os.close(self.descriptor)
        self.descriptor = -1
        os.rmdir(self.path.name, dir_fd=self.parent_descriptor)
        os.fsync(self.parent_descriptor)

    def prepare_empty_child(self, name: str) -> Path:
        self.verify()
        try:
            os.mkdir(name, 0o700, dir_fd=self.descriptor)
            os.fsync(self.descriptor)
        except FileExistsError:
            pass
        self.ensure_empty_child(name)
        return self.path / name

    def write_emergency_seed(self, document: Mapping[str, object]) -> None:
        self.verify()
        try:
            os.mkdir("emergency", 0o700, dir_fd=self.descriptor)
            os.fsync(self.descriptor)
        except FileExistsError:
            pass
        opened = self.child_descriptor("emergency")
        assert opened is not None
        descriptor, _ = opened
        try:
            if "failure-seed.json" in _descriptor_entry_names(
                descriptor,
                "P07 emergency failure seed",
            ):
                existing = _decode_json(
                    _read_regular_at(
                        descriptor,
                        "failure-seed.json",
                        "P07 emergency failure seed",
                    ),
                    "P07 emergency failure seed",
                )
                if existing != document:
                    raise P07ExecutionError(
                        "P07 emergency failure seed already records another failure"
                    )
                return
            _write_new_at(
                descriptor,
                "failure-seed.json",
                _canonical_bytes(document) + b"\n",
                "P07 emergency failure seed",
            )
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def read_emergency_seed(self) -> Optional[Mapping[str, object]]:
        opened = self.child_descriptor("emergency", required=False)
        if opened is None:
            return None
        descriptor, _ = opened
        try:
            names = _descriptor_entry_names(
                descriptor,
                "P07 emergency failure seed",
            )
            if not names:
                return None
            if not set(names) <= {
                "failure-seed.json",
                "archive-publication-failure.json",
            } or "failure-seed.json" not in names:
                raise P07ExecutionError(
                    "P07 emergency recovery contains an unknown path"
                )
            seed = _decode_json(
                _read_regular_at(
                    descriptor,
                    "failure-seed.json",
                    "P07 emergency failure seed",
                ),
                "P07 emergency failure seed",
            )
            is_v2 = seed.get("schema_version") == "2.0.0"
            if (
                seed.get("artifact_kind")
                != (
                    "p07_emergency_failure_seed_v2"
                    if is_v2
                    else "p07_emergency_failure_seed"
                )
                or seed.get("manifest_sha256") != _manifest_hash(seed)
            ):
                raise P07ExecutionError("P07 emergency failure seed is invalid")
            if is_v2:
                validate_identity_v2(seed.get(IDENTITY_FIELD))
            return seed
        finally:
            os.close(descriptor)

    def write_archive_publication_failure(
        self,
        document: Mapping[str, object],
    ) -> None:
        self.verify()
        try:
            os.mkdir("emergency", 0o700, dir_fd=self.descriptor)
            os.fsync(self.descriptor)
        except FileExistsError:
            pass
        opened = self.child_descriptor("emergency")
        assert opened is not None
        descriptor, _ = opened
        try:
            name = "archive-publication-failure.json"
            if name in _descriptor_entry_names(
                descriptor,
                "P07 archive-publication failure provenance",
            ):
                existing = _decode_json(
                    _read_regular_at(
                        descriptor,
                        name,
                        "P07 archive-publication failure provenance",
                    ),
                    "P07 archive-publication failure provenance",
                )
                if existing != document:
                    raise P07ExecutionError(
                        "P07 archive-publication failure provenance differs"
                    )
                return
            _write_new_at(
                descriptor,
                name,
                _canonical_bytes(document) + b"\n",
                "P07 archive-publication failure provenance",
            )
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def read_archive_publication_failure(
        self,
    ) -> Optional[Mapping[str, object]]:
        opened = self.child_descriptor("emergency", required=False)
        if opened is None:
            return None
        descriptor, _ = opened
        try:
            name = "archive-publication-failure.json"
            if name not in _descriptor_entry_names(
                descriptor,
                "P07 archive-publication failure provenance",
            ):
                return None
            document = _decode_json(
                _read_regular_at(
                    descriptor,
                    name,
                    "P07 archive-publication failure provenance",
                ),
                "P07 archive-publication failure provenance",
            )
            if (
                document.get("role") != "failure_evidence_publication"
                or document.get("manifest_sha256") != _manifest_hash(document)
            ):
                raise P07ExecutionError(
                    "P07 archive-publication failure provenance is invalid"
                )
            return {
                key: value
                for key, value in document.items()
                if key != "manifest_sha256"
            }
        finally:
            os.close(descriptor)


def _publish_directory_exclusive(
    source: Path,
    destination: Path,
    *,
    progress: Optional[dict[str, object]] = None,
    destination_parent_pin: Optional[tuple[int, os.stat_result]] = None,
) -> Mapping[str, object]:
    """Durably publish one direct-child directory without replacing a name."""

    source = _normalized_absolute(source, "P07 private publication directory")
    destination = _normalized_absolute(destination, "P07 output directory")
    source_parent = source.parent
    destination_parent = destination.parent
    source_parent_descriptor, source_parent_identity = _open_directory_nofollow(
        source_parent,
        "P07 private publication parent",
    )
    destination_parent_descriptor = -1
    try:
        if destination_parent_pin is not None:
            pinned_descriptor, pinned_identity = destination_parent_pin
            destination_parent_descriptor = os.dup(pinned_descriptor)
            destination_parent_identity = os.fstat(destination_parent_descriptor)
            if (
                (destination_parent_identity.st_dev, destination_parent_identity.st_ino)
                != (pinned_identity.st_dev, pinned_identity.st_ino)
            ):
                raise P07ExecutionError(
                    "pinned P07 final publication parent identity changed"
                )
        elif source_parent == destination_parent:
            destination_parent_descriptor = os.dup(source_parent_descriptor)
            destination_parent_identity = os.fstat(destination_parent_descriptor)
        else:
            destination_parent_descriptor, destination_parent_identity = (
                _open_directory_nofollow(
                    destination_parent,
                    "P07 final publication parent",
                )
            )
        source_descriptor, source_identity = _open_child_descriptor(
            source_parent_descriptor,
            source.name,
            directory=True,
            label="P07 private publication tree",
        )
        try:
            before_sync = _snapshot_descriptor_tree(
                source_descriptor,
                "P07 private publication tree",
            )
            _sync_descriptor_tree_durable(
                source_descriptor,
                "P07 private publication tree",
            )
            after_sync = _snapshot_descriptor_tree(
                source_descriptor,
                "P07 private publication tree",
            )
            if after_sync != before_sync:
                raise P07ExecutionError(
                    "P07 publication tree changed during durability sync"
                )
            _verify_directory_path_identity(
                source_parent,
                source_parent_identity,
                "P07 private publication parent",
            )
            _verify_directory_path_identity(
                destination_parent,
                destination_parent_identity,
                "P07 final publication parent",
            )
            _rename_directory_exclusive_at(
                source_parent_descriptor,
                source.name,
                destination_parent_descriptor,
                destination.name,
            )
            if progress is not None:
                progress["publication_renamed"] = True
            after_rename = _snapshot_descriptor_tree(
                source_descriptor,
                "P07 renamed publication tree",
            )
            if after_rename != before_sync:
                raise P07ExecutionError("P07 publication tree changed during rename")
            published_descriptor, published = _open_child_descriptor(
                destination_parent_descriptor,
                destination.name,
                directory=True,
                label="P07 published tree",
            )
            try:
                if (
                    not stat.S_ISDIR(published.st_mode)
                    or (published.st_dev, published.st_ino)
                    != (source_identity.st_dev, source_identity.st_ino)
                ):
                    raise P07ExecutionError(
                        "exclusive P07 publication directory identity changed"
                    )
                reopened = _snapshot_descriptor_tree(
                    published_descriptor,
                    "P07 published tree",
                )
                if reopened != before_sync:
                    raise P07ExecutionError(
                        "P07 published tree differs after descriptor reopen"
                    )
                os.fsync(published_descriptor)
                os.fsync(source_parent_descriptor)
                os.fsync(destination_parent_descriptor)
                if progress is not None:
                    progress["parent_directory_synced"] = True
                after_parent_sync = _snapshot_descriptor_tree(
                    published_descriptor,
                    "P07 durable published tree",
                )
                source_after_parent_sync = _snapshot_descriptor_tree(
                    source_descriptor,
                    "P07 durable renamed source tree",
                )
                if (
                    after_parent_sync != before_sync
                    or source_after_parent_sync != before_sync
                ):
                    raise P07ExecutionError(
                        "P07 published tree changed after parent durability sync"
                    )
            finally:
                os.close(published_descriptor)
            _verify_directory_path_identity(
                source_parent,
                source_parent_identity,
                "P07 private publication parent",
            )
            _verify_directory_path_identity(
                destination_parent,
                destination_parent_identity,
                "P07 final publication parent",
            )
            return before_sync
        finally:
            os.close(source_descriptor)
    finally:
        if destination_parent_descriptor >= 0:
            os.close(destination_parent_descriptor)
        os.close(source_parent_descriptor)


def _write_artifact_manifest(
    directory: Path,
    *,
    status: str,
    publication_kind: str,
    configuration_id: Optional[str],
    configuration_sha256: str,
    release_bundle_manifest_sha256: Optional[str],
    sampling_plan_manifest_sha256: Optional[str],
    holdout_accessed: bool,
    holdout_access_consumed: Optional[bool],
    command: str,
    platform: str,
    p06_v2_identity: Optional[Mapping[str, str]] = None,
) -> Mapping[str, object]:
    if status not in {"complete", "failed"}:
        raise P07ExecutionError("P07 artifact-manifest status is invalid")
    if publication_kind not in {"g07_evidence", "execution_failure"}:
        raise P07ExecutionError("P07 artifact-manifest publication kind is invalid")
    if not command or not platform:
        raise P07ExecutionError("P07 artifact-manifest provenance is incomplete")
    manifest_path = directory / ARTIFACT_MANIFEST_NAME
    if os.path.lexists(manifest_path):
        raise P07ExecutionError("P07 artifact manifest already exists")
    artifacts = []
    for child in sorted(directory.iterdir(), key=lambda value: value.name):
        metadata = os.lstat(child)
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or child.suffix != ".json"
        ):
            raise P07ExecutionError(
                "P07 artifact manifest encountered an unsafe publication entry"
            )
        payload = _read_regular_file(
            child,
            "P07 artifact-manifest input",
            maximum=MAX_JSON_BYTES,
        )
        artifacts.append(
            {
                "path": child.name,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
                "producer": PUBLICATION_PRODUCER,
                "command": command,
                "platform": platform,
                "gate_ids": list(PUBLICATION_GATE_IDS),
            }
        )
    if not artifacts:
        raise P07ExecutionError("P07 artifact manifest has no evidence files")
    identity = (
        validate_identity_v2(p06_v2_identity)
        if p06_v2_identity is not None
        else None
    )
    document = {
        "schema_version": "2.0.0" if identity is not None else "1.0.0",
        "artifact_kind": (
            "p07_artifact_manifest_v2"
            if identity is not None
            else "p07_artifact_manifest"
        ),
        **(
            {IDENTITY_FIELD: dict(identity)}
            if identity is not None
            else {}
        ),
        "status": status,
        "publication_kind": publication_kind,
        "configuration_id": configuration_id,
        "configuration_sha256": _require_sha256(
            configuration_sha256,
            "P07 manifest configuration hash",
        ),
        "release_bundle_manifest_sha256": (
            None
            if release_bundle_manifest_sha256 is None
            else _require_sha256(
                release_bundle_manifest_sha256,
                "P07 manifest release hash",
            )
        ),
        "sampling_plan_manifest_sha256": (
            None
            if sampling_plan_manifest_sha256 is None
            else _require_sha256(
                sampling_plan_manifest_sha256,
                "P07 manifest sampling-plan hash",
            )
        ),
        "holdout_accessed": holdout_accessed,
        "holdout_access_consumed": holdout_access_consumed,
        "producer": PUBLICATION_PRODUCER,
        "command": command,
        "platform": platform,
        "gate_ids": list(PUBLICATION_GATE_IDS),
        "artifacts": artifacts,
        "exact_file_names": sorted(
            [record["path"] for record in artifacts]
            + [ARTIFACT_MANIFEST_NAME]
        ),
        "self_reference_boundary": (
            "artifact-manifest.json is excluded from its own artifacts list "
            "and bound by manifest_sha256 over this document without that field"
        ),
    }
    document["manifest_sha256"] = _manifest_hash(document)
    _validate_schema(
        document,
        (
            ARTIFACT_MANIFEST_V2_SCHEMA
            if identity is not None
            else ARTIFACT_MANIFEST_SCHEMA
        ),
        "P07 artifact manifest",
    )
    _write_json(manifest_path, document)
    return document


def _validate_artifact_manifest(
    directory: Path,
    *,
    expected_status: str,
    expected_publication_kind: str,
) -> Mapping[str, str]:
    payload, manifest = _read_json(
        directory / ARTIFACT_MANIFEST_NAME,
        "P07 artifact manifest",
    )
    if payload != _canonical_bytes(manifest) + b"\n":
        raise P07ExecutionError("P07 artifact manifest is not canonical JSON")
    is_v2 = manifest.get("schema_version") == "2.0.0"
    _validate_schema(
        manifest,
        ARTIFACT_MANIFEST_V2_SCHEMA if is_v2 else ARTIFACT_MANIFEST_SCHEMA,
        "P07 artifact manifest",
    )
    if is_v2:
        validate_identity_v2(manifest.get(IDENTITY_FIELD))
    children = sorted(child.name for child in directory.iterdir())
    artifacts = manifest.get("artifacts")
    if (
        manifest.get("manifest_sha256") != _manifest_hash(manifest)
        or manifest.get("status") != expected_status
        or manifest.get("publication_kind") != expected_publication_kind
        or manifest.get("exact_file_names") != children
        or not isinstance(artifacts, list)
        or [record.get("path") for record in artifacts]
        != [name for name in children if name != ARTIFACT_MANIFEST_NAME]
    ):
        raise P07ExecutionError(
            "P07 artifact manifest identity or exact file set differs"
        )
    bindings = {ARTIFACT_MANIFEST_NAME: hashlib.sha256(payload).hexdigest()}
    for record in artifacts:
        if not isinstance(record, dict):
            raise P07ExecutionError("P07 artifact-manifest record is invalid")
        name = str(record["path"])
        artifact_payload = _read_regular_file(
            directory / name,
            "P07 artifact-manifest evidence",
            maximum=MAX_JSON_BYTES,
        )
        if (
            record.get("sha256") != hashlib.sha256(artifact_payload).hexdigest()
            or record.get("size_bytes") != len(artifact_payload)
            or record.get("producer") != manifest.get("producer")
            or record.get("command") != manifest.get("command")
            or record.get("platform") != manifest.get("platform")
            or record.get("gate_ids") != manifest.get("gate_ids")
        ):
            raise P07ExecutionError(
                "P07 artifact-manifest file binding or provenance differs"
            )
        bindings[name] = str(record["sha256"])
    return bindings


def _artifact_manifest_top_level(directory: Path) -> Mapping[str, object]:
    _, manifest = _read_json(
        directory / ARTIFACT_MANIFEST_NAME,
        "P07 artifact manifest top-level binding",
    )
    return {
        field: manifest.get(field)
        for field in (
            "schema_version",
            IDENTITY_FIELD,
            "configuration_id",
            "configuration_sha256",
            "release_bundle_manifest_sha256",
            "sampling_plan_manifest_sha256",
            "holdout_accessed",
            "holdout_access_consumed",
            "manifest_sha256",
        )
    }


def _validate_failure_publication(directory: Path) -> Mapping[str, str]:
    bindings = _validate_artifact_manifest(
        directory,
        expected_status="failed",
        expected_publication_kind="execution_failure",
    )
    expected = {
        ARTIFACT_MANIFEST_NAME,
        FAILURE_LOG_NAME,
        "failed-version-archive.json",
        AUTHORIZED_EXECUTION_BINDINGS_NAME,
    }
    if set(bindings) != expected:
        raise P07ExecutionError("P07 failure publication file set differs")
    log_payload, failure_log = _read_json(
        directory / FAILURE_LOG_NAME,
        "P07 failure log",
    )
    archive_payload, archive = _read_json(
        directory / "failed-version-archive.json",
        "P07 execution failure archive",
    )
    is_v2 = archive.get("schema_version") == "2.0.0"
    identity = (
        validate_identity_v2(archive.get(IDENTITY_FIELD))
        if is_v2
        else None
    )
    _validate_schema(
        failure_log,
        FAILURE_LOG_V2_SCHEMA if is_v2 else FAILURE_LOG_SCHEMA,
        "P07 failure log",
    )
    _validate_schema(
        archive,
        (
            EXECUTION_FAILURE_V2_SCHEMA
            if is_v2
            else SCHEMAS_ROOT / "p07-execution-failure-v1.schema.json"
        ),
        "P07 execution failure archive",
    )
    if is_v2:
        validate_identity_v2(
            failure_log.get(IDENTITY_FIELD),
            expected=identity,
        )
    authorized_payload, authorized_execution = (
        _read_authorized_execution_bindings(
            directory,
            require_bound=(
                archive.get("failure_stage") != "pre_guard_validation"
            ),
        )
    )
    failure_production_fragment = authorized_execution.get(
        "production_execution_binding_fragment"
    )
    manifest_top_level = _artifact_manifest_top_level(directory)
    if is_v2:
        validate_identity_v2(
            manifest_top_level.get(IDENTITY_FIELD),
            expected=identity,
        )
        validate_identity_v2(
            authorized_execution.get(IDENTITY_FIELD),
            expected=identity,
        )
    expected_holdout_accessed = (
        archive.get("holdout_access_consumed") is True
        or archive.get("holdout_access_state")
        in {"anchor_only", "opened", "completed", "failed"}
        or archive.get("transaction_state", {}).get("guard_returned") is True
        or archive.get("cleanup_result", {}).get("mount_invoked") is True
    )
    shared_fields = (
        "failure_type",
        "failure_message",
        "failure_message_sha256",
        "failure_traceback",
        "failure_traceback_sha256",
        "secondary_failure",
        "archive_publication_failure",
        "failure_stage",
        "transaction_state",
        "cleanup_result",
        "media_asset_id",
        "media_case_id",
        "frame_index",
        "presentation_timestamp",
        "media_context_available",
        "requested_output_directory",
        "temporary_run_path",
        "command",
        "platform",
        "holdout_access_consumed",
    )
    if (
        failure_log.get("manifest_sha256") != _manifest_hash(failure_log)
        or archive.get("manifest_sha256") != _manifest_hash(archive)
        or archive.get("failure_log_file_sha256")
        != hashlib.sha256(log_payload).hexdigest()
        or archive.get("authorized_execution_bindings_file_sha256")
        != hashlib.sha256(authorized_payload).hexdigest()
        or archive.get(
            "authorized_execution_bindings_manifest_sha256"
        )
        != authorized_execution.get("manifest_sha256")
        or bindings.get(AUTHORIZED_EXECUTION_BINDINGS_NAME)
        != hashlib.sha256(authorized_payload).hexdigest()
        or (
            isinstance(failure_production_fragment, dict)
            and (
                failure_production_fragment.get(
                    "p06_release_bundle_manifest_sha256"
                )
                != archive.get("release_bundle_manifest_sha256")
                or failure_production_fragment.get(
                    "production_writer",
                    {},
                ).get("executable_sha256")
                != failure_production_fragment.get(
                    "macos_code_identities",
                    {},
                ).get("production_writer_executable", {}).get(
                    "file_sha256"
                )
                or failure_production_fragment.get(
                    "spawn_policy",
                    {},
                ).get("environment")
                != authorized_execution.get("authorized_environment")
            )
        )
        or hashlib.sha256(archive_payload).hexdigest()
        != bindings["failed-version-archive.json"]
        or manifest_top_level.get("configuration_id")
        != archive.get("configuration_id")
        or manifest_top_level.get("configuration_sha256")
        != archive.get("configuration_sha256")
        or manifest_top_level.get("release_bundle_manifest_sha256")
        != archive.get("release_bundle_manifest_sha256")
        or manifest_top_level.get("sampling_plan_manifest_sha256")
        != archive.get("sampling_plan_manifest_sha256")
        or manifest_top_level.get("holdout_accessed")
        is not expected_holdout_accessed
        or manifest_top_level.get("holdout_access_consumed")
        is not archive.get("holdout_access_consumed")
        or any(archive.get(field) != failure_log.get(field) for field in shared_fields)
        or hashlib.sha256(
            str(archive.get("failure_message")).encode("utf-8", "strict")
        ).hexdigest()
        != archive.get("failure_message_sha256")
        or hashlib.sha256(
            str(archive.get("failure_traceback")).encode("utf-8", "strict")
        ).hexdigest()
        != archive.get("failure_traceback_sha256")
        or (
            isinstance(archive.get("secondary_failure"), dict)
            and (
                hashlib.sha256(
                    str(
                        archive["secondary_failure"].get("failure_message")
                    ).encode("utf-8", "strict")
                ).hexdigest()
                != archive["secondary_failure"].get("failure_message_sha256")
                or hashlib.sha256(
                    str(
                        archive["secondary_failure"].get("failure_traceback")
                    ).encode("utf-8", "strict")
                ).hexdigest()
                != archive["secondary_failure"].get(
                    "failure_traceback_sha256"
                )
            )
        )
        or (
            isinstance(archive.get("archive_publication_failure"), dict)
            and (
                hashlib.sha256(
                    str(
                        archive["archive_publication_failure"].get(
                            "failure_message"
                        )
                    ).encode("utf-8", "strict")
                ).hexdigest()
                != archive["archive_publication_failure"].get(
                    "failure_message_sha256"
                )
                or hashlib.sha256(
                    str(
                        archive["archive_publication_failure"].get(
                            "failure_traceback"
                        )
                    ).encode("utf-8", "strict")
                ).hexdigest()
                != archive["archive_publication_failure"].get(
                    "failure_traceback_sha256"
                )
            )
        )
    ):
        raise P07ExecutionError("P07 failure publication cross-binding differs")
    return bindings


def _paths_overlap(left: Path, right: Path) -> bool:
    left_resolved = left.resolve(strict=True)
    right_resolved = right.resolve(strict=True)
    try:
        left_resolved.relative_to(right_resolved)
        return True
    except ValueError:
        pass
    try:
        right_resolved.relative_to(left_resolved)
        return True
    except ValueError:
        return False


def _existing_and_future_paths_overlap(existing: Path, future: Path) -> bool:
    existing_resolved = existing.resolve(strict=True)
    future_resolved = future.resolve(strict=False)
    try:
        existing_resolved.relative_to(future_resolved)
        return True
    except ValueError:
        pass
    try:
        future_resolved.relative_to(existing_resolved)
        return True
    except ValueError:
        return False


def _directory_tree_sha256(root: Path, label: str) -> str:
    """Hash exact regular-file bytes, paths, directory paths, and permission bits."""

    _validate_existing_path(root, label=label, kind="directory")
    rows = []
    pending = [(root, "")]
    while pending:
        directory, relative_directory = pending.pop()
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as error:
            raise P07ExecutionError("{} cannot be enumerated".format(label)) from error
        for child in children:
            relative = (
                child.name
                if not relative_directory
                else "{}/{}".format(relative_directory, child.name)
            )
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError as error:
                raise P07ExecutionError(
                    "{} entry cannot be inspected".format(label)
                ) from error
            mode = stat.S_IMODE(metadata.st_mode)
            path = Path(child.path)
            if stat.S_ISLNK(metadata.st_mode):
                raise P07ExecutionError("{} contains a symbolic link".format(label))
            if stat.S_ISDIR(metadata.st_mode):
                rows.append({"path": relative, "kind": "directory", "mode": mode})
                pending.append((path, relative))
            elif stat.S_ISREG(metadata.st_mode):
                rows.append(
                    {
                        "path": relative,
                        "kind": "file",
                        "mode": mode,
                        "size_bytes": metadata.st_size,
                        "sha256": _sha256_file(path, "{} entry".format(label)),
                    }
                )
            else:
                raise P07ExecutionError(
                    "{} contains a non-regular entry".format(label)
                )
    rows.sort(key=lambda row: (str(row["path"]), str(row["kind"])))
    return canonical_sha256(
        {
            "contract": "p07-preopen-cache-tree-v1",
            "entries": rows,
        }
    )


def _directory_file_snapshot(root: Path, label: str) -> Mapping[str, object]:
    """Return the exact ordered regular-file snapshot used by runtime evidence."""

    _validate_existing_path(root, label=label, kind="directory")
    rows = []
    for current_name, directory_names, file_names in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        directory_names.sort()
        file_names.sort()
        current = Path(current_name)
        for name in directory_names:
            candidate = current / name
            metadata = os.lstat(candidate)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise P07ExecutionError("{} contains an unsafe directory".format(label))
        for name in file_names:
            candidate = current / name
            metadata = os.lstat(candidate)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise P07ExecutionError("{} contains a nonregular file".format(label))
            rows.append(
                {
                    "path": candidate.relative_to(root).as_posix(),
                    "sha256": _sha256_file(candidate, "{} file".format(label)),
                    "size_bytes": metadata.st_size,
                }
            )
    rows.sort(key=lambda row: str(row["path"]))
    return {
        "file_count": len(rows),
        "size_bytes": sum(int(row["size_bytes"]) for row in rows),
        "tree_sha256": canonical_sha256(rows),
        "files": rows,
    }


def _measurement_core_sha256(measurement: Mapping[str, object]) -> str:
    return canonical_sha256(
        {
            key: value
            for key, value in measurement.items()
            if key not in {
                "measurement_sha256",
                "runtime_evidence_manifest_sha256",
            }
        }
    )


def _normalize_macho_uuid(path: Path) -> str:
    """Replace one arm64 Mach-O LC_UUID with a deterministic content UUID."""

    payload = bytearray(_read_regular_file(path, "P07 unsigned loader executable"))
    if len(payload) < 32 or payload[0:4] != bytes.fromhex("cffaedfe"):
        raise P07ExecutionError("P07 loader is not a thin little-endian Mach-O 64 binary")
    command_count = int.from_bytes(payload[16:20], "little")
    command_bytes = int.from_bytes(payload[20:24], "little")
    offset = 32
    limit = offset + command_bytes
    if command_count <= 0 or limit > len(payload):
        raise P07ExecutionError("P07 loader Mach-O command table is invalid")
    uuid_offsets = []
    for _ in range(command_count):
        if offset + 8 > limit:
            raise P07ExecutionError("P07 loader Mach-O command is truncated")
        command = int.from_bytes(payload[offset : offset + 4], "little")
        size = int.from_bytes(payload[offset + 4 : offset + 8], "little")
        if size < 8 or offset + size > limit:
            raise P07ExecutionError("P07 loader Mach-O command size is invalid")
        if command == 0x1B:
            if size != 24:
                raise P07ExecutionError("P07 loader LC_UUID size differs")
            uuid_offsets.append(offset + 8)
        offset += size
    if offset != limit or len(uuid_offsets) != 1:
        raise P07ExecutionError("P07 loader requires exactly one LC_UUID command")
    uuid_offset = uuid_offsets[0]
    payload[uuid_offset : uuid_offset + 16] = b"\0" * 16
    uuid_bytes = bytearray(hashlib.sha256(payload).digest()[:16])
    uuid_bytes[6] = (uuid_bytes[6] & 0x0F) | 0x30
    uuid_bytes[8] = (uuid_bytes[8] & 0x3F) | 0x80
    flags = os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        written = os.pwrite(descriptor, uuid_bytes, uuid_offset)
        if written != len(uuid_bytes):
            raise P07ExecutionError("P07 loader UUID normalization write is incomplete")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    reopened = _read_regular_file(path, "P07 UUID-normalized loader executable")
    if reopened[uuid_offset : uuid_offset + 16] != uuid_bytes:
        raise P07ExecutionError("P07 loader UUID normalization did not persist")
    return bytes(uuid_bytes).hex()


def _validate_declared_tree_snapshot(snapshot: object) -> None:
    if not isinstance(snapshot, dict) or set(snapshot) != {
        "file_count",
        "size_bytes",
        "tree_sha256",
        "files",
    }:
        raise P07ExecutionError("P07 declared cache snapshot shape differs")
    files = snapshot["files"]
    if not isinstance(files, list) or not files:
        raise P07ExecutionError("P07 declared cache snapshot files are absent")
    paths = []
    total = 0
    for row in files:
        if not isinstance(row, dict) or set(row) != {
            "path",
            "sha256",
            "size_bytes",
        }:
            raise P07ExecutionError("P07 declared cache file binding differs")
        relative = _safe_relative(row["path"], "P07 declared cache file")
        _require_sha256(row["sha256"], "P07 declared cache file")
        size = row["size_bytes"]
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
            raise P07ExecutionError("P07 declared cache file size is invalid")
        paths.append(relative.as_posix())
        total += size
    if (
        paths != sorted(paths)
        or len(paths) != len(set(paths))
        or snapshot["file_count"] != len(files)
        or snapshot["size_bytes"] != total
        or snapshot["tree_sha256"] != canonical_sha256(files)
    ):
        raise P07ExecutionError("P07 declared cache tree binding differs")


def _validate_runtime_case_records(
    runtime_evidence: Mapping[str, object],
    measurement: Mapping[str, object],
) -> None:
    analytic = runtime_evidence.get("analytic_preopen_evidence")
    analytic_cases = analytic.get("case_evidence") if isinstance(analytic, dict) else None
    corpus_cases = runtime_evidence.get("corpus_case_evidence")
    if not isinstance(analytic_cases, list) or not isinstance(corpus_cases, list):
        raise P07ExecutionError("P07 runtime case evidence is absent")
    if len(analytic_cases) != 14 or len(corpus_cases) != 9:
        raise P07ExecutionError("P07 runtime case evidence count differs")
    measurement_analytic = measurement.get("analytic_fixture_rows")
    measurement_corpus = measurement.get("corpus_rows")
    if not isinstance(measurement_analytic, list) or not isinstance(
        measurement_corpus,
        list,
    ):
        raise P07ExecutionError("P07 measurement rows are absent")
    analytic_order = [
        row.get("fixture_id")
        for row in measurement_analytic
        if isinstance(row, dict) and row.get("comparison_domain") == "engine_raw"
    ]
    runtime_analytic_order = [
        case.get("case_evidence", {}).get("fixture_id")
        if isinstance(case, dict)
        and isinstance(case.get("case_evidence"), dict)
        else None
        for case in analytic_cases
    ]
    corpus_order = [
        (row.get("source_asset_id"), row.get("degradation_kind"))
        for row in measurement_corpus
        if isinstance(row, dict) and row.get("comparison_domain") == "engine_raw"
    ]
    runtime_corpus_order = [
        (
            case.get("case_evidence", {}).get("source_asset_id"),
            case.get("case_evidence", {}).get("degradation_kind"),
        )
        if isinstance(case, dict)
        and isinstance(case.get("case_evidence"), dict)
        else (None, None)
        for case in corpus_cases
    ]
    if (
        runtime_analytic_order != analytic_order
        or runtime_corpus_order != corpus_order
    ):
        raise P07ExecutionError("P07 runtime case order differs from measurements")

    for runtime_case, analytic_case in (
        *((case, True) for case in analytic_cases),
        *((case, False) for case in corpus_cases),
    ):
        if not isinstance(runtime_case, dict) or set(runtime_case) != {
            "case_evidence_sha256",
            "case_evidence",
            "native_records_by_control",
            "writer_evidence_by_control",
        }:
            raise P07ExecutionError("P07 runtime case wrapper differs")
        case_evidence = runtime_case["case_evidence"]
        native_records = runtime_case["native_records_by_control"]
        writer_records = runtime_case["writer_evidence_by_control"]
        if (
            not isinstance(case_evidence, dict)
            or runtime_case["case_evidence_sha256"]
            != canonical_sha256(case_evidence)
            or not isinstance(native_records, dict)
            or not isinstance(writer_records, dict)
        ):
            raise P07ExecutionError("P07 runtime case content address differs")
        expected_native_hashes = case_evidence.get(
            "native_record_sha256_by_control"
        )
        expected_writer_hashes = case_evidence.get(
            "writer_evidence_sha256_by_control"
        )
        if (
            not isinstance(expected_native_hashes, dict)
            or not isinstance(expected_writer_hashes, dict)
            or set(native_records) != set(expected_native_hashes)
            or set(writer_records) != set(expected_writer_hashes)
        ):
            raise P07ExecutionError("P07 runtime record coverage differs")
        for control, record in native_records.items():
            if (
                not isinstance(record, dict)
                or record.get("record_sha256") != expected_native_hashes[control]
                or record.get("record_sha256")
                != canonical_sha256(
                    {
                        key: value
                        for key, value in record.items()
                        if key != "record_sha256"
                    }
                )
            ):
                raise P07ExecutionError("P07 native runtime record hash differs")
        for control, record in writer_records.items():
            expected = expected_writer_hashes[control]
            if expected is None:
                if record is not None:
                    raise P07ExecutionError(
                        "P07 runtime writer record exists without a hash"
                    )
            elif (
                not isinstance(record, dict)
                or expected != canonical_sha256(record)
            ):
                raise P07ExecutionError("P07 writer runtime record hash differs")

        if analytic_case:
            identity_fields = (
                "fixture_id",
                "fixture_kind",
                "fixture_definition_sha256",
                "target_route",
            )
            rows = measurement_analytic
        else:
            identity_fields = (
                "source_asset_id",
                "source_family_id",
                "categories",
                "target_route",
                "degradation_kind",
                "degradation_profile_id",
                "degradation_profile_sha256",
                "source_crop_nv12_sha256",
                "degraded_input_frame_sha256",
            )
            rows = measurement_corpus
        matches = [
            row
            for row in rows
            if isinstance(row, dict)
            and all(row.get(field) == case_evidence.get(field) for field in identity_fields)
        ]
        if len(matches) != 2:
            raise P07ExecutionError("P07 runtime case does not bind both domains")
        for row in matches:
            domain = row.get("comparison_domain")
            expected_outputs = case_evidence.get(
                "{}_output_sha256_by_control".format(domain)
            )
            expected_writers = (
                {key: None for key in expected_writer_hashes}
                if domain == "engine_raw"
                else expected_writer_hashes
            )
            if (
                domain not in {"engine_raw", "container_decoded"}
                or row.get("configuration_sha256_by_control")
                != case_evidence.get("control_configuration_sha256_by_control")
                or row.get("output_sha256_by_control") != expected_outputs
                or row.get("writer_evidence_sha256_by_control")
                != expected_writers
            ):
                raise P07ExecutionError(
                    "P07 runtime case hashes differ from measurement rows"
                )


def build_p07_frame_loader(
    *,
    source_path: Path,
    output_path: Path,
    repository_root: Path = REPOSITORY_ROOT,
) -> Mapping[str, object]:
    """Compile the standalone loader and return byte-bound build evidence."""

    _validate_existing_path(repository_root, label="repository root", kind="directory")
    source_bytes = _read_regular_file(source_path, "P07 Swift loader source")
    _normalized_absolute(output_path, "P07 Swift loader output")
    _validate_existing_path(output_path.parent, label="loader output parent", kind="directory")
    if os.path.lexists(output_path):
        raise P07ExecutionError("P07 Swift loader output already exists")
    command = [
        "xcrun",
        "swiftc",
        "-parse-as-library",
        "-O",
        "-whole-module-optimization",
        "-module-name",
        "P07HoldoutFrameLoader",
        "-Xlinker",
        "-no_adhoc_codesign",
        os.fspath(source_path),
        "-o",
        os.fspath(output_path),
    ]
    completed = subprocess.run(
        command,
        cwd=repository_root,
        check=False,
        capture_output=True,
        timeout=300,
    )
    if completed.returncode != 0:
        raise P07ExecutionError(
            "P07 Swift loader compilation failed: {}".format(
                completed.stderr.decode("utf-8", "replace").strip()
            )
        )
    normalized_uuid = _normalize_macho_uuid(output_path)
    signing_identifier = "local.mirmir.p07-holdout-frame-loader"
    signing = subprocess.run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--identifier",
            signing_identifier,
            "--timestamp=none",
            os.fspath(output_path),
        ],
        cwd=repository_root,
        check=False,
        capture_output=True,
        timeout=30,
    )
    if signing.returncode != 0:
        raise P07ExecutionError(
            "P07 deterministic ad-hoc code signing failed: {}".format(
                signing.stderr.decode("utf-8", "replace").strip()
            )
        )
    version = subprocess.run(
        ["xcrun", "swiftc", "--version"],
        cwd=repository_root,
        check=False,
        capture_output=True,
        timeout=30,
    )
    if version.returncode != 0:
        raise P07ExecutionError("Swift compiler version could not be recorded")
    executable_sha256 = _sha256_file(output_path, "P07 Swift loader executable")
    document = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_holdout_frame_loader_build",
        "status": "pass",
        "source_path": source_path.resolve(strict=True).relative_to(
            repository_root.resolve(strict=True)
        ).as_posix(),
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "executable_sha256": executable_sha256,
        "compiler_version": version.stdout.decode("utf-8", "strict").strip(),
        "command": command[:-1] + ["<output>"],
        "mach_o_uuid": normalized_uuid,
        "mach_o_uuid_contract": (
            "sha256_first_128_bits_after_zeroing_lc_uuid_rfc4122_v3_variant"
        ),
        "code_signing": "deterministic_ad_hoc_fixed_identifier_no_timestamp",
        "code_signing_identifier": signing_identifier,
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = canonical_sha256(document)
    return document


class P07HoldoutExecutor:
    """Execute one locked holdout evaluation without exposing mount operations."""

    def __init__(
        self,
        *,
        repository_root: Path,
        holdout_root: Path,
        sampling_plan_path: Path,
        expected_sampling_plan_sha256: str,
        no_pixel_attestation_path: Path,
        expected_no_pixel_attestation_sha256: str,
        loader_executable: Path,
        expected_loader_sha256: str,
        p06_release_root: Path,
        p06_release_manifest_path: Path,
        support_evidence_roots: Mapping[str, Path],
        p07_cache_root: Path,
        live_holdout_preopen_binding: LiveHoldoutPreopenBinding,
        release_validator: Callable[..., Mapping[str, object]] = (
            validate_p06_release_bundle_manifest
        ),
        input_binder: Callable[..., object] = bind_preregistered_inputs,
        publication_command: str = "direct P07HoldoutExecutor.execute_once invocation",
        publication_platform: Optional[str] = None,
    ) -> None:
        self.repository_root = _normalized_absolute(
            repository_root, "repository root"
        )
        self.holdout_root = _normalized_absolute(holdout_root, "holdout root")
        self.sampling_plan_path = _normalized_absolute(
            sampling_plan_path, "sampling plan path"
        )
        self.expected_sampling_plan_sha256 = _require_sha256(
            expected_sampling_plan_sha256, "expected sampling-plan hash"
        )
        self.no_pixel_attestation_path = _normalized_absolute(
            no_pixel_attestation_path, "no-pixel attestation path"
        )
        self.expected_no_pixel_attestation_sha256 = _require_sha256(
            expected_no_pixel_attestation_sha256,
            "expected no-pixel attestation hash",
        )
        self.loader_executable = _normalized_absolute(
            loader_executable, "loader executable"
        )
        self.expected_loader_sha256 = _require_sha256(
            expected_loader_sha256, "expected loader hash"
        )
        self.p06_release_root = _normalized_absolute(
            p06_release_root, "P06 release root"
        )
        self.p06_release_manifest_path = _normalized_absolute(
            p06_release_manifest_path, "P06 release manifest"
        )
        if set(support_evidence_roots) != SUPPORT_ROOT_IDS:
            raise P07ExecutionError("P06 support evidence roots are not exact")
        self.support_evidence_roots = dict(support_evidence_roots)
        self.p07_cache_root = _normalized_absolute(p07_cache_root, "P07 cache root")
        self.live_holdout_preopen_binding = live_holdout_preopen_binding
        self.release_validator = release_validator
        self.input_binder = input_binder
        if not publication_command:
            raise P07ExecutionError("P07 publication command is empty")
        self.publication_command = publication_command
        machine = os.uname()
        self.publication_platform = publication_platform or "{} {} {}".format(
            machine.sysname,
            machine.release,
            machine.machine,
        )
        if not self.publication_platform:
            raise P07ExecutionError("P07 publication platform is empty")
        self._transaction_context: dict[str, object] = {}
        self._authorized_execution_context: Optional[
            _AuthorizedExecutionContext
        ] = None

    def _set_media_context(self, context: Optional[P07MediaContext]) -> None:
        evidence = (
            P07MediaContext().evidence()
            if context is None
            else context.evidence()
        )
        self._transaction_context.update(evidence)

    def _capture_error_media_context(self, error: BaseException) -> None:
        cursor: Optional[BaseException] = error
        seen: set[int] = set()
        while cursor is not None and id(cursor) not in seen:
            seen.add(id(cursor))
            context = getattr(cursor, "media_context", None)
            if isinstance(context, P07MediaContext):
                self._set_media_context(context)
                return
            cursor = cursor.__cause__ or cursor.__context__

    def _open_retained_script_binding(
        self,
        path: Path,
        *,
        expected_sha256: str,
        label: str,
    ) -> _RetainedScriptBinding:
        script = _RetainedAuthorizedFile.open(
            path,
            expected_sha256=expected_sha256,
            executable=False,
            label=label,
        )
        try:
            interpreter_path = _retained_script_interpreter(script)
            interpreter = _RetainedCodeBinding.open(
                interpreter_path,
                expected_sha256=None,
                label="{} interpreter".format(label),
            )
            return _RetainedScriptBinding(
                script=script,
                interpreter=interpreter,
            )
        except BaseException:
            script.close()
            raise

    def _validate_direct_mount_script_contract(
        self,
        *,
        preflight: P07Preflight,
        mount_script: _RetainedScriptBinding,
        unmount_script: _RetainedScriptBinding,
    ) -> str:
        container = preflight.attestation.get("container")
        if not isinstance(container, dict):
            raise P07ExecutionError("P07 holdout container binding is absent")
        relative = _safe_relative(
            container.get("relative_path"),
            "P07 holdout container",
        ).as_posix()
        if (
            preflight.mount_root != self.holdout_root / "mount-v2"
            or preflight.workflow_paths.get("key_helper_path")
            != self.holdout_root / "tools/bin/key-access"
        ):
            raise P07ExecutionError(
                "P07 direct mount paths differ from the attested layout"
            )
        mount_interpreter = os.fspath(
            mount_script.interpreter.file.path
        )
        unmount_interpreter = os.fspath(
            unmount_script.interpreter.file.path
        )
        mount_expected = """#!{interpreter}
set -euo pipefail

root=${{0:A:h:h}}
container="$root/{container}"
mount_point="$root/mount-v2"
key_helper="$root/tools/bin/key-access"

[[ -d "$container" ]]
[[ -x "$key_helper" ]]
if /sbin/mount | /usr/bin/grep -Fq " on $mount_point "; then
  print -u2 'holdout volume is already mounted'
  exit 1
fi
/bin/mkdir -p "$mount_point"
"$key_helper" emit-v2 | /usr/bin/hdiutil attach \\
  "$container" \\
  -stdinpass \\
  -readonly \\
  -nobrowse \\
  -mountpoint "$mount_point"
/sbin/mount | /usr/bin/grep -F " on $mount_point "
""".format(
            interpreter=mount_interpreter,
            container=relative,
        ).encode("utf-8")
        unmount_expected = """#!{interpreter}
set -euo pipefail

root=${{0:A:h:h}}
mount_point="$root/mount-v2"
device=$(/sbin/mount | /usr/bin/awk -v target="$mount_point" '$0 ~ " on " target " " {{print $1}}')
[[ -n "$device" ]]
/usr/bin/hdiutil detach "$device"
if /sbin/mount | /usr/bin/grep -Fq " on $mount_point "; then
  print -u2 'holdout volume remains mounted'
  exit 1
fi
""".format(interpreter=unmount_interpreter).encode("utf-8")
        for binding, expected in (
            (mount_script, mount_expected),
            (unmount_script, unmount_expected),
        ):
            if binding.script.identity.st_size > 64 * 1024:
                raise P07ExecutionError(
                    "{} exceeds its direct-mount contract limit".format(
                        binding.script.label
                    )
                )
            payload = binding.script.read_prefix(64 * 1024)
            if payload != expected:
                raise P07ExecutionError(
                    "{} differs from the supported direct-mount contract".format(
                        binding.script.label
                    )
                )
        return _direct_mount_template_sha256(
            mount_script.script,
            unmount_script.script,
        )

    def _prepare_authorized_execution(
        self,
        preflight: P07Preflight,
    ) -> P07Preflight:
        existing = getattr(self, "_authorized_execution_context", None)
        if isinstance(existing, _AuthorizedExecutionContext):
            existing.verify()
            return replace(
                preflight,
                authorized_execution_bindings=(
                    existing.binding_document()
                ),
            )
        workflow = preflight.attestation.get(
            "read_only_provisioning_workflow"
        )
        if not isinstance(workflow, dict):
            raise P07ExecutionError(
                "P07 authorized workflow binding is absent"
            )
        opened: list[object] = []
        try:
            loader = _RetainedCodeBinding.open(
                self.loader_executable,
                expected_sha256=preflight.loader_sha256,
                label="P07 authorized loader",
            )
            opened.append(loader.file)
            sampling_plan = _RetainedAuthorizedFile.open(
                self.sampling_plan_path,
                expected_sha256=preflight.plan_file_sha256,
                executable=False,
                label="P07 retained sampling plan",
            )
            opened.append(sampling_plan)
            mount_script = self._open_retained_script_binding(
                preflight.workflow_paths["mount_script_path"],
                expected_sha256=str(workflow["mount_script_sha256"]),
                label="P07 retained mount script",
            )
            opened.extend(
                [mount_script.script, mount_script.interpreter.file]
            )
            unmount_script = self._open_retained_script_binding(
                preflight.workflow_paths["unmount_script_path"],
                expected_sha256=str(workflow["unmount_script_sha256"]),
                label="P07 retained unmount script",
            )
            opened.extend(
                [unmount_script.script, unmount_script.interpreter.file]
            )
            key_helper = _RetainedCodeBinding.open(
                preflight.workflow_paths["key_helper_path"],
                expected_sha256=str(workflow["key_helper_sha256"]),
                label="P07 authorized key helper",
            )
            opened.append(key_helper.file)
            mount_table = _RetainedCodeBinding.open(
                _MOUNT_TABLE_EXECUTABLE,
                expected_sha256=None,
                label="P07 authorized mount-table executable",
            )
            opened.append(mount_table.file)
            hdiutil = _RetainedCodeBinding.open(
                _HDIUTIL_EXECUTABLE,
                expected_sha256=None,
                label="P07 authorized hdiutil executable",
            )
            opened.append(hdiutil.file)
            direct_mount_template_sha256 = (
                self._validate_direct_mount_script_contract(
                    preflight=preflight,
                    mount_script=mount_script,
                    unmount_script=unmount_script,
                )
            )
            context = _AuthorizedExecutionContext(
                loader=loader,
                sampling_plan=sampling_plan,
                mount_script=mount_script,
                unmount_script=unmount_script,
                key_helper=key_helper,
                mount_table=mount_table,
                hdiutil=hdiutil,
                direct_mount_template_sha256=(
                    direct_mount_template_sha256
                ),
                production_execution_binding_fragment=None,
                p06_v2_identity=_preflight_p06_v2_identity(preflight),
            )
            context.verify()
            self._authorized_execution_context = context
            return replace(
                preflight,
                authorized_execution_bindings=context.binding_document(),
            )
        except BaseException:
            closed = set()
            for value in reversed(opened):
                if not isinstance(value, _RetainedAuthorizedFile):
                    continue
                if id(value) in closed:
                    continue
                closed.add(id(value))
                try:
                    value.close()
                except OSError:
                    pass
            raise

    def _validated_production_execution_binding_fragment(
        self,
        evaluator: object,
    ) -> Mapping[str, object]:
        try:
            value = getattr(
                evaluator,
                "authorized_execution_binding_fragment",
            )
        except BaseException as error:
            raise P07ExecutionError(
                "P07 production execution binding fragment cannot be read"
            ) from error
        if not isinstance(value, dict):
            raise P07ExecutionError(
                "P07 production execution binding fragment is absent"
            )
        is_v2 = value.get("schema_version") == "2.0.0"
        _validate_schema(
            value,
            (
                PRODUCTION_EXECUTION_BINDING_FRAGMENT_V2_SCHEMA
                if is_v2
                else PRODUCTION_EXECUTION_BINDING_FRAGMENT_SCHEMA
            ),
            "P07 production execution binding fragment",
        )
        if value.get("fragment_sha256") != _manifest_hash(
            value,
            field="fragment_sha256",
        ):
            raise P07ExecutionError(
                "P07 production execution binding fragment self-hash differs"
            )
        copied = json.loads(
            _canonical_bytes(value).decode("utf-8", "strict")
        )
        if not isinstance(copied, dict):
            raise P07ExecutionError(
                "P07 production execution binding fragment copy differs"
            )
        return copied

    def _bind_production_execution_fragment(
        self,
        *,
        preflight: P07Preflight,
        evaluator: object,
    ) -> P07Preflight:
        context = self._required_authorized_execution_context()
        fragment = self._validated_production_execution_binding_fragment(
            evaluator
        )
        if fragment.get("p06_release_bundle_manifest_sha256") != (
            p06_release_bundle_sha256(preflight.release_bundle)
        ):
            raise P07ExecutionError(
                "P07 production fragment uses another P06 release"
            )
        preflight_identity = _preflight_p06_v2_identity(preflight)
        if preflight_identity is not None:
            try:
                validate_identity_v2(
                    fragment.get(IDENTITY_FIELD),
                    expected=preflight_identity,
                )
            except ValueError as error:
                raise P07ExecutionError(
                    "P07 production fragment uses another V2 identity"
                ) from error
        if (
            context.production_execution_binding_fragment is not None
            and context.production_execution_binding_fragment != fragment
        ):
            raise P07ExecutionError(
                "P07 production execution fragment changed"
            )
        context.production_execution_binding_fragment = fragment
        context.verify()
        self._persisted_production_execution_binding_fragment = fragment
        document = context.binding_document()
        _validate_authorized_execution_bindings(
            document,
            require_bound=True,
        )
        return replace(
            preflight,
            authorized_execution_bindings=document,
        )

    def _current_production_execution_fragment(
        self,
    ) -> Mapping[str, object]:
        self._validate_cache_isolation()
        identity = getattr(self, "_p07_cache_identity", None)
        if not isinstance(identity, os.stat_result):
            raise P07ExecutionError(
                "P07 pinned cache-root identity is unavailable"
            )
        release_bundle = self._support_aware_release_validation()
        try:
            from validation.calibration_v2.p07.production import (
                derive_production_authorized_execution_binding_fragment,
            )

            fragment = (
                derive_production_authorized_execution_binding_fragment(
                    release_root=self.p06_release_root,
                    release_bundle=release_bundle,
                    production_writer_support_root=(
                        self.support_evidence_roots["production_writer"]
                    ),
                    repository_root=self.repository_root,
                    p07_cache_root=self.p07_cache_root,
                    expected_cache_root_identity=(
                        identity.st_dev,
                        identity.st_ino,
                    ),
                )
            )
        except P07ExecutionError:
            raise
        except BaseException as error:
            raise P07ExecutionError(
                "P07 current production execution fragment cannot be reconstructed"
            ) from error
        _validate_schema(
            fragment,
            (
                PRODUCTION_EXECUTION_BINDING_FRAGMENT_V2_SCHEMA
                if fragment.get("schema_version") == "2.0.0"
                else PRODUCTION_EXECUTION_BINDING_FRAGMENT_SCHEMA
            ),
            "P07 reconstructed production execution binding fragment",
        )
        return fragment

    def _open_declared_code_binding(
        self,
        value: object,
        *,
        label: str,
    ) -> _RetainedCodeBinding:
        if not isinstance(value, dict) or set(value) != {
            "path",
            "file_sha256",
            "code_identity",
        }:
            raise P07ExecutionError(
                "{} persisted binding is invalid".format(label)
            )
        path = Path(str(value["path"]))
        retained = _RetainedCodeBinding.open(
            path,
            expected_sha256=_require_sha256(
                value["file_sha256"],
                "{} persisted file hash".format(label),
            ),
            label=label,
        )
        if not isinstance(value["code_identity"], dict) or dict(
            retained.code_identity
        ) != value["code_identity"]:
            retained.file.close()
            raise P07ExecutionError(
                "{} persisted code identity differs".format(label)
            )
        return retained

    def _open_declared_script_binding(
        self,
        value: object,
        *,
        label: str,
    ) -> _RetainedScriptBinding:
        if not isinstance(value, dict) or set(value) != {
            "path",
            "file_sha256",
            "interpreter",
        }:
            raise P07ExecutionError(
                "{} persisted script binding is invalid".format(label)
            )
        script = _RetainedAuthorizedFile.open(
            Path(str(value["path"])),
            expected_sha256=_require_sha256(
                value["file_sha256"],
                "{} persisted script hash".format(label),
            ),
            executable=False,
            label=label,
        )
        interpreter: Optional[_RetainedCodeBinding] = None
        try:
            interpreter = self._open_declared_code_binding(
                value["interpreter"],
                label="{} interpreter".format(label),
            )
            if interpreter.file.path != _retained_script_interpreter(script):
                raise P07ExecutionError(
                    "{} persisted shebang differs".format(label)
                )
            return _RetainedScriptBinding(
                script=script,
                interpreter=interpreter,
            )
        except BaseException:
            if interpreter is not None:
                interpreter.file.close()
            script.close()
            raise

    def _prepare_authorized_execution_from_intent(
        self,
        intent: Mapping[str, object],
    ) -> None:
        existing = getattr(self, "_authorized_execution_context", None)
        declared = intent.get("authorized_execution_bindings")
        if not isinstance(declared, dict) or (
            declared.get("manifest_sha256") != _manifest_hash(declared)
        ):
            raise P07ExecutionError(
                "P07 persisted authorized execution bindings are absent or invalid"
            )
        _validate_authorized_execution_bindings(
            declared,
            require_bound=True,
        )
        if isinstance(existing, _AuthorizedExecutionContext):
            existing.verify()
            if existing.binding_document() != declared:
                raise P07ExecutionError(
                    "P07 persisted authorized execution bindings differ"
                )
            self._persisted_production_execution_binding_fragment = dict(
                existing.production_execution_binding_fragment
            )
            return
        opened: list[_RetainedAuthorizedFile] = []
        try:
            loader = self._open_declared_code_binding(
                declared.get("loader"),
                label="P07 recovered loader",
            )
            opened.append(loader.file)
            sampling = declared.get("sampling_plan")
            if not isinstance(sampling, dict) or set(sampling) != {
                "path",
                "file_sha256",
            }:
                raise P07ExecutionError(
                    "P07 recovered sampling-plan binding is invalid"
                )
            sampling_plan = _RetainedAuthorizedFile.open(
                Path(str(sampling["path"])),
                expected_sha256=_require_sha256(
                    sampling["file_sha256"],
                    "P07 recovered sampling-plan hash",
                ),
                executable=False,
                label="P07 recovered sampling plan",
            )
            opened.append(sampling_plan)
            mount_script = self._open_declared_script_binding(
                declared.get("mount_script"),
                label="P07 recovered mount script",
            )
            opened.extend(
                [mount_script.script, mount_script.interpreter.file]
            )
            unmount_script = self._open_declared_script_binding(
                declared.get("unmount_script"),
                label="P07 recovered unmount script",
            )
            opened.extend(
                [unmount_script.script, unmount_script.interpreter.file]
            )
            key_helper = self._open_declared_code_binding(
                declared.get("key_helper"),
                label="P07 recovered key helper",
            )
            opened.append(key_helper.file)
            mount_table = self._open_declared_code_binding(
                declared.get("mount_table"),
                label="P07 recovered mount-table executable",
            )
            opened.append(mount_table.file)
            hdiutil = self._open_declared_code_binding(
                declared.get("hdiutil"),
                label="P07 recovered hdiutil executable",
            )
            opened.append(hdiutil.file)
            context = _AuthorizedExecutionContext(
                loader=loader,
                sampling_plan=sampling_plan,
                mount_script=mount_script,
                unmount_script=unmount_script,
                key_helper=key_helper,
                mount_table=mount_table,
                hdiutil=hdiutil,
                direct_mount_template_sha256=(
                    _direct_mount_template_sha256(
                        mount_script.script,
                        unmount_script.script,
                    )
                ),
                production_execution_binding_fragment=dict(
                    declared["production_execution_binding_fragment"]
                ),
                p06_v2_identity=(
                    validate_identity_v2(declared.get(IDENTITY_FIELD))
                    if declared.get("schema_version") == "2.0.0"
                    else None
                ),
            )
            context.verify()
            if context.binding_document() != declared:
                raise P07ExecutionError(
                    "P07 recovered authorized execution closure differs"
                )
            self._authorized_execution_context = context
            self._persisted_production_execution_binding_fragment = dict(
                context.production_execution_binding_fragment
            )
        except BaseException:
            closed = set()
            for retained in reversed(opened):
                if id(retained) in closed:
                    continue
                closed.add(id(retained))
                try:
                    retained.close()
                except OSError:
                    pass
            raise

    def _close_authorized_execution(self) -> None:
        context = getattr(self, "_authorized_execution_context", None)
        self._authorized_execution_context = None
        if isinstance(context, _AuthorizedExecutionContext):
            context.close()

    def _required_authorized_execution_context(
        self,
    ) -> _AuthorizedExecutionContext:
        context = getattr(self, "_authorized_execution_context", None)
        if not isinstance(context, _AuthorizedExecutionContext):
            raise P07ExecutionError(
                "P07 authorized execution context is absent"
            )
        return context

    def _run_authorized_binding(
        self,
        binding: _RetainedCodeBinding,
        arguments: Sequence[str],
        *,
        cwd: Optional[Path] = None,
        cwd_descriptor: Optional[int] = None,
        additional_files: Sequence[_RetainedAuthorizedFile] = (),
        additional_descriptors: Sequence[int] = (),
        timeout_seconds: float,
        input_payload: Optional[bytes] = None,
    ) -> subprocess.CompletedProcess[bytes]:
        if (cwd is None) == (cwd_descriptor is None):
            raise P07ExecutionError(
                "P07 authorized command requires exactly one cwd binding"
            )
        files = (binding.file, *additional_files)
        descriptor_identities = {}
        for descriptor in additional_descriptors:
            if (
                not isinstance(descriptor, int)
                or isinstance(descriptor, bool)
                or descriptor < 0
            ):
                raise P07ExecutionError(
                    "P07 additional authorized descriptor is invalid"
                )
            metadata = os.fstat(descriptor)
            descriptor_identities[descriptor] = (
                metadata.st_dev,
                metadata.st_ino,
                stat.S_IFMT(metadata.st_mode),
            )
        for retained in files:
            retained.verify()
            retained.reset()
        primary_error: Optional[BaseException] = None
        result: Optional[subprocess.CompletedProcess[bytes]] = None
        try:
            result = run_authorized_process(
                [os.fspath(binding.file.path), *arguments],
                cwd=cwd,
                cwd_descriptor=cwd_descriptor,
                pass_fds=(
                    tuple(file.descriptor for file in files)
                    + tuple(additional_descriptors)
                ),
                execution_authorizer=lambda pid: authorize_running_code(
                    pid,
                    binding.code_identity,
                ),
                authorized_environment=authorized_process_environment(
                    Path("/private/tmp")
                ),
                timeout_seconds=timeout_seconds,
                input_payload=input_payload,
            )
        except BaseException as error:
            primary_error = error
        cleanup_error: Optional[BaseException] = None
        try:
            for retained in files:
                retained.verify()
            for descriptor, expected in descriptor_identities.items():
                metadata = os.fstat(descriptor)
                if (
                    metadata.st_dev,
                    metadata.st_ino,
                    stat.S_IFMT(metadata.st_mode),
                ) != expected:
                    raise P07ExecutionError(
                        "P07 additional authorized descriptor changed"
                    )
        except BaseException as error:
            cleanup_error = error
        if cleanup_error is not None:
            if primary_error is not None:
                raise P07DualFailure(
                    primary_error,
                    cleanup_error,
                ) from primary_error
            raise cleanup_error
        if primary_error is not None:
            raise primary_error.with_traceback(primary_error.__traceback__)
        assert result is not None
        return result

    @staticmethod
    def _mount_observation_from_output(
        mount_root: Path,
        payload: bytes,
    ) -> MountObservation:
        if len(payload) > 4 * 1024 * 1024:
            raise P07ExecutionError("mount table output exceeds its limit")
        try:
            lines = payload.decode("utf-8", "strict").splitlines()
        except UnicodeDecodeError as error:
            raise P07ExecutionError("mount table output is not UTF-8") from error
        marker = " on {} (".format(mount_root)
        records = [line for line in lines if marker in line]
        if len(records) > 1:
            raise P07ExecutionError("mount point has multiple mount records")
        if not records:
            return MountObservation(False, False, "")
        record = records[0]
        device, separator, suffix = record.partition(marker)
        if (
            not separator
            or not device.startswith("/dev/")
            or any(character.isspace() for character in device)
            or not suffix.endswith(")")
            or "(" in suffix
        ):
            raise P07ExecutionError("mount point record is ambiguous")
        fields = {
            field.strip()
            for field in suffix[:-1].split(",")
            if field.strip()
        }
        if not fields:
            raise P07ExecutionError("mount point options are absent")
        return MountObservation(
            True,
            "read-only" in fields or "rdonly" in fields,
            record,
        )

    def _authorized_observe_mount(
        self,
        mount_root: Path,
    ) -> MountObservation:
        context = self._required_authorized_execution_context()
        result = self._run_authorized_binding(
            context.mount_table,
            (),
            cwd=self.holdout_root,
            timeout_seconds=30.0,
        )
        if result.returncode != 0 or result.stderr:
            raise P07ExecutionError("authorized mount table query failed")
        return self._mount_observation_from_output(
            mount_root,
            result.stdout,
        )

    def _authorized_mount(self, preflight: P07Preflight) -> None:
        context = self._required_authorized_execution_context()
        container = preflight.attestation.get("container")
        if not isinstance(container, dict):
            raise P07ExecutionError("P07 holdout container binding is absent")
        container_path = _path_under(
            self.holdout_root,
            container.get("relative_path"),
            "P07 authorized encrypted container",
        )
        _validate_existing_path(
            container_path,
            label="P07 authorized encrypted container",
            kind="directory",
        )
        _validate_existing_path(
            preflight.mount_root,
            label="P07 authorized mount root",
            kind="directory",
        )
        context.verify()
        primary_error: Optional[BaseException] = None
        result = None
        try:
            environment = authorized_process_environment(Path("/private/tmp"))
            result = run_authorized_pipeline(
                [os.fspath(context.key_helper.file.path), "emit-v2"],
                [
                    os.fspath(context.hdiutil.file.path),
                    "attach",
                    os.fspath(container_path),
                    "-stdinpass",
                    "-readonly",
                    "-nobrowse",
                    "-mountpoint",
                    os.fspath(preflight.mount_root),
                ],
                producer_cwd=self.holdout_root,
                consumer_cwd=self.holdout_root,
                producer_pass_fds=(context.key_helper.file.descriptor,),
                consumer_pass_fds=(context.hdiutil.file.descriptor,),
                producer_execution_authorizer=lambda pid: authorize_running_code(
                    pid,
                    context.key_helper.code_identity,
                ),
                consumer_execution_authorizer=lambda pid: authorize_running_code(
                    pid,
                    context.hdiutil.code_identity,
                ),
                producer_authorized_environment=environment,
                consumer_authorized_environment=environment,
                timeout_seconds=300.0,
                max_output_bytes=1024 * 1024,
            )
            if (
                result.producer_returncode != 0
                or result.consumer_returncode != 0
                or result.producer_stderr
            ):
                raise P07ExecutionError(
                    "authorized holdout key-to-mount pipeline failed"
                )
        except BaseException as error:
            primary_error = error
        cleanup_error: Optional[BaseException] = None
        try:
            context.verify()
            if (
                _direct_mount_template_sha256(
                    context.mount_script.script,
                    context.unmount_script.script,
                )
                != context.direct_mount_template_sha256
            ):
                raise P07ExecutionError(
                    "P07 direct-mount template binding changed"
                )
        except BaseException as error:
            cleanup_error = error
        if cleanup_error is not None:
            if primary_error is not None:
                raise P07DualFailure(
                    primary_error,
                    cleanup_error,
                ) from primary_error
            raise cleanup_error
        if primary_error is not None:
            raise primary_error.with_traceback(primary_error.__traceback__)
        if result is None:
            raise P07ExecutionError(
                "authorized holdout key-to-mount pipeline returned no status"
            )

    def _authorized_unmount(
        self,
        mount_root: Path,
    ) -> None:
        context = self._required_authorized_execution_context()
        observation = self._authorized_observe_mount(mount_root)
        if not observation.mounted:
            return
        device = observation.record.split(" on ", 1)[0]
        result = self._run_authorized_binding(
            context.hdiutil,
            ("detach", device),
            cwd=self.holdout_root,
            timeout_seconds=300.0,
        )
        if result.returncode != 0:
            raise P07ExecutionError("authorized holdout detach failed")

    def _validate_guard_binding(
        self,
        guard: object,
        *,
        corpus_manifest_sha256: str,
    ) -> None:
        if not isinstance(guard, HoldoutAccessGuard):
            raise P07ExecutionError(
                "P07 guard is not the required HoldoutAccessGuard implementation"
            )
        expected = self.live_holdout_preopen_binding
        if (
            guard.ledger_path != expected.live_ledger_path
            or guard.anchor_path != expected.live_anchor_path
            or guard.intent_path != expected.live_anchor_path
            or guard.expected_corpus_manifest_sha256
            != corpus_manifest_sha256
            or not callable(getattr(guard, "read_once", None))
            or not callable(getattr(guard, "validate_lock", None))
        ):
            raise P07ExecutionError(
                "P07 guard paths, corpus, or protocol differ from preregistration"
            )

    def _validate_direct_input_bindings(
        self,
        bindings: object,
    ) -> Optional[str]:
        if not isinstance(bindings, list) or not bindings:
            raise P07ExecutionError(
                "terminal P07 direct-input bindings are absent"
            )
        identifiers: set[str] = set()
        corpus_manifest_sha256: Optional[str] = None
        for record in bindings:
            if not isinstance(record, dict):
                raise P07ExecutionError(
                    "terminal P07 direct-input binding is invalid"
                )
            identifier = record.get("id")
            if (
                not isinstance(identifier, str)
                or not identifier
                or identifier in identifiers
            ):
                raise P07ExecutionError(
                    "terminal P07 direct-input identifiers differ"
                )
            identifiers.add(identifier)
            path = _path_under(
                self.repository_root,
                record.get("path"),
                "terminal P07 direct input",
            )
            metadata = _validate_existing_path(
                path,
                label="terminal P07 direct input",
                kind="file",
            )
            if (
                metadata.st_size != record.get("size_bytes")
                or _sha256_file(path, "terminal P07 direct input")
                != record.get("sha256")
            ):
                raise P07ExecutionError(
                    "terminal P07 direct input changed"
                )
            if identifier == "corpus_lock":
                _, corpus = _read_json(path, "terminal P07 corpus lock")
                if corpus.get("manifest_sha256") != _manifest_hash(corpus):
                    raise P07ExecutionError(
                        "terminal P07 corpus lock self-hash differs"
                    )
                corpus_manifest_sha256 = str(corpus["manifest_sha256"])
        return corpus_manifest_sha256

    def _validate_terminal_authorized_execution_closure(
        self,
        *,
        authorized_document: Mapping[str, object],
        terminal_document: Mapping[str, object],
    ) -> None:
        context = self._required_authorized_execution_context()
        published_production_fragment = authorized_document.get(
            "production_execution_binding_fragment"
        )
        current_production_fragment = (
            self._current_production_execution_fragment()
        )
        if (
            not isinstance(published_production_fragment, dict)
            or published_production_fragment
            != current_production_fragment
            or published_production_fragment.get(
                "p06_release_bundle_manifest_sha256"
            )
            != terminal_document.get(
                "release_bundle_manifest_sha256"
            )
        ):
            raise P07ExecutionError(
                "terminal P07 production execution fragment differs"
            )
        _, attestation = _read_json(
            self.no_pixel_attestation_path,
            "terminal P07 no-pixel attestation closure",
        )
        workflow = attestation.get("read_only_provisioning_workflow")
        if not isinstance(workflow, dict):
            raise P07ExecutionError(
                "terminal P07 authorized workflow binding is absent"
            )
        expected_paths = {
            "loader": self.loader_executable,
            "sampling_plan": self.sampling_plan_path,
            "mount_script": self.holdout_root
            / EXPECTED_WORKFLOW_PATHS["mount_script_path"],
            "unmount_script": self.holdout_root
            / EXPECTED_WORKFLOW_PATHS["unmount_script_path"],
            "key_helper": self.holdout_root
            / EXPECTED_WORKFLOW_PATHS["key_helper_path"],
            "mount_table": _MOUNT_TABLE_EXECUTABLE,
            "hdiutil": _HDIUTIL_EXECUTABLE,
        }
        for name, path in expected_paths.items():
            binding = authorized_document.get(name)
            if not isinstance(binding, dict) or binding.get("path") != os.fspath(
                path
            ):
                raise P07ExecutionError(
                    "terminal P07 authorized {} path differs".format(name)
                )
        expected_hashes = {
            "loader": terminal_document.get("loader_executable_sha256"),
            "sampling_plan": terminal_document.get(
                "sampling_plan_file_sha256"
            ),
            "mount_script": workflow.get("mount_script_sha256"),
            "unmount_script": workflow.get("unmount_script_sha256"),
            "key_helper": workflow.get("key_helper_sha256"),
        }
        if any(
            not _is_sha256(expected)
            or authorized_document[name].get("file_sha256") != expected
            for name, expected in expected_hashes.items()
        ):
            raise P07ExecutionError(
                "terminal P07 authorized execution file hashes differ"
            )
        for name in ("mount_script", "unmount_script"):
            binding = authorized_document[name]
            interpreter = binding.get("interpreter")
            if (
                not isinstance(interpreter, dict)
                or Path(str(interpreter.get("path")))
                not in _TRUSTED_SCRIPT_INTERPRETERS
            ):
                raise P07ExecutionError(
                    "terminal P07 authorized script interpreter differs"
                )
        context.verify()
        if (
            authorized_document
            != context.binding_document()
            or _direct_mount_template_sha256(
                context.mount_script.script,
                context.unmount_script.script,
            )
            != context.direct_mount_template_sha256
        ):
            raise P07ExecutionError(
                "terminal P07 authorized execution closure changed"
            )

    @staticmethod
    def _terminal_document_for_workspace_crosscheck(
        output_directory: Path,
    ) -> tuple[Optional[Path], Optional[Mapping[str, object]]]:
        candidates = (
            output_directory,
            output_directory.with_name(output_directory.name + ".failed"),
        )
        for directory in candidates:
            if not directory.is_dir():
                continue
            for name, label in (
                (
                    "p07-execution-result.json",
                    "P07 workspace-crosscheck success",
                ),
                (
                    "failed-version-archive.json",
                    "P07 workspace-crosscheck failure",
                ),
            ):
                path = directory / name
                if os.path.lexists(path):
                    _, document = _read_json(path, label)
                    return directory, document
        return None, None

    def _validate_workspace_intent_for_invocation(
        self,
        *,
        workspace: _P07TransactionWorkspace,
        output_directory: Path,
        configuration_lock: Mapping[str, object],
        guard: object,
    ) -> None:
        intent = workspace.intent
        configuration_sha256 = canonical_sha256(configuration_lock)
        if (
            intent.get("requested_output_directory")
            != os.fspath(output_directory)
            or intent.get("configuration_sha256")
            != configuration_sha256
        ):
            raise P07ExecutionError(
                "P07 workspace intent differs from the current invocation"
            )
        _, release = _read_json(
            self.p06_release_manifest_path,
            "P07 workspace current release manifest",
        )
        _, sampling_plan = _read_json(
            self.sampling_plan_path,
            "P07 workspace current sampling plan",
        )
        try:
            release_sha256 = p06_release_bundle_sha256(release)
        except ValueError as error:
            raise P07ExecutionError(
                "P07 workspace current release self-hash differs"
            ) from error
        if (
            release_sha256
            != intent.get("release_bundle_manifest_sha256")
            or release.get("configuration_id")
            != intent.get("configuration_id")
            or release.get("input_bundle_sha256")
            != intent.get("input_bundle_sha256")
            or release.get("corpus_lock_bundle_sha256")
            != intent.get("corpus_lock_bundle_sha256")
            or _sha256_file(
                self.sampling_plan_path,
                "P07 workspace sampling-plan file",
            )
            != intent.get("sampling_plan_file_sha256")
            or sampling_plan.get("manifest_sha256")
            != _manifest_hash(sampling_plan)
            or sampling_plan.get("manifest_sha256")
            != intent.get("sampling_plan_manifest_sha256")
            or sampling_plan.get("corpus_manifest_sha256")
            != intent.get("corpus_manifest_sha256")
            or _sha256_file(
                self.no_pixel_attestation_path,
                "P07 workspace no-pixel attestation",
            )
            != intent.get("no_pixel_attestation_file_sha256")
            or _sha256_file(
                self.loader_executable,
                "P07 workspace loader executable",
            )
            != intent.get("loader_executable_sha256")
        ):
            raise P07ExecutionError(
                "P07 workspace intent differs from current release inputs"
            )
        unmount_path = Path(str(intent.get("unmount_script_path")))
        if (
            not unmount_path.is_absolute()
            or _sha256_file(
                unmount_path,
                "P07 workspace unmount script",
            )
            != intent.get("unmount_script_sha256")
        ):
            raise P07ExecutionError(
                "P07 workspace unmount binding differs"
            )
        live = self.live_holdout_preopen_binding
        live_fields = {
            "live_ledger_path": live.live_ledger_path,
            "live_anchor_path": live.live_anchor_path,
            "live_preopen_receipt_path": live.live_preopen_receipt_path,
            "expected_live_ledger_root_identity_sha256": (
                live.expected_live_ledger_root_identity_sha256
            ),
            "expected_live_anchor_root_identity_sha256": (
                live.expected_live_anchor_root_identity_sha256
            ),
            "expected_live_preopen_receipt_sha256": (
                live.expected_live_preopen_receipt_sha256
            ),
        }
        if any(
            intent.get(field)
            != (os.fspath(expected) if isinstance(expected, Path) else expected)
            for field, expected in live_fields.items()
        ):
            raise P07ExecutionError(
                "P07 workspace live-guard binding differs"
            )
        corpus_manifest_sha256 = self._validate_direct_input_bindings(
            intent.get("direct_input_bindings")
        )
        if (
            corpus_manifest_sha256 is None
            or corpus_manifest_sha256
            != intent.get("corpus_manifest_sha256")
        ):
            raise P07ExecutionError(
                "P07 workspace corpus binding differs"
            )
        self._validate_guard_binding(
            guard,
            corpus_manifest_sha256=str(
                intent["corpus_manifest_sha256"]
            ),
        )
        authorized = intent.get("authorized_execution_bindings")
        if not isinstance(authorized, dict):
            raise P07ExecutionError(
                "P07 workspace authorized execution binding is absent"
            )
        _validate_authorized_execution_bindings(
            authorized,
            require_bound=True,
        )
        authorized_loader = authorized.get("loader")
        authorized_sampling_plan = authorized.get("sampling_plan")
        authorized_unmount = authorized.get("unmount_script")
        if (
            not isinstance(authorized_loader, dict)
            or authorized_loader.get("path")
            != os.fspath(self.loader_executable)
            or authorized_loader.get("file_sha256")
            != intent.get("loader_executable_sha256")
            or not isinstance(authorized_sampling_plan, dict)
            or authorized_sampling_plan.get("path")
            != os.fspath(self.sampling_plan_path)
            or authorized_sampling_plan.get("file_sha256")
            != intent.get("sampling_plan_file_sha256")
            or not isinstance(authorized_unmount, dict)
            or authorized_unmount.get("path")
            != intent.get("unmount_script_path")
            or authorized_unmount.get("file_sha256")
            != intent.get("unmount_script_sha256")
        ):
            raise P07ExecutionError(
                "P07 workspace authorized input cross-links differ"
            )
        workspace_production_fragment = authorized.get(
            "production_execution_binding_fragment"
        )
        current_production_fragment = (
            self._current_production_execution_fragment()
        )
        if (
            not isinstance(workspace_production_fragment, dict)
            or workspace_production_fragment != current_production_fragment
            or workspace_production_fragment.get("fragment_sha256")
            != current_production_fragment.get("fragment_sha256")
            or workspace_production_fragment.get(
                "p06_release_bundle_manifest_sha256"
            )
            != intent.get("release_bundle_manifest_sha256")
        ):
            raise P07ExecutionError(
                "P07 workspace production execution fragment differs"
            )
        terminal_directory, terminal = (
            self._terminal_document_for_workspace_crosscheck(
                output_directory
            )
        )
        if terminal is None or terminal_directory is None:
            return
        shared_fields = (
            "configuration_id",
            "configuration_sha256",
            "release_bundle_manifest_sha256",
            "input_bundle_sha256",
            "direct_input_bindings",
            "corpus_lock_bundle_sha256",
            "sampling_plan_file_sha256",
            "sampling_plan_manifest_sha256",
            "no_pixel_attestation_file_sha256",
            "loader_executable_sha256",
            "p07_preopen_cache_tree_sha256",
        )
        if any(
            terminal.get(field) != intent.get(field)
            for field in shared_fields
        ):
            raise P07ExecutionError(
                "P07 terminal publication and workspace intent differ"
            )
        authorized_payload, terminal_authorized = (
            _read_authorized_execution_bindings(
                terminal_directory,
                require_bound=True,
            )
        )
        if (
            terminal_authorized != authorized
            or terminal.get(
                "authorized_execution_bindings_file_sha256"
            )
            != hashlib.sha256(authorized_payload).hexdigest()
            or terminal.get(
                "authorized_execution_bindings_manifest_sha256"
            )
            != terminal_authorized.get("manifest_sha256")
        ):
            raise P07ExecutionError(
                "P07 terminal and workspace execution closures differ"
            )

    def _validate_terminal_invocation_binding(
        self,
        *,
        directory: Path,
        configuration_lock: Mapping[str, object],
        guard: object,
    ) -> None:
        success_path = directory / "p07-execution-result.json"
        failure_path = directory / "failed-version-archive.json"
        if os.path.lexists(success_path):
            _, document = _read_json(
                success_path,
                "terminal P07 execution identity",
            )
        elif os.path.lexists(failure_path):
            _, document = _read_json(
                failure_path,
                "terminal P07 failure identity",
            )
        else:
            raise P07ExecutionError("terminal P07 identity document is absent")
        configuration_sha256 = canonical_sha256(configuration_lock)
        if document.get("configuration_sha256") != configuration_sha256:
            raise P07ExecutionError(
                "terminal P07 publication uses another configuration"
            )
        require_bound = (
            document.get("failure_stage") != "pre_guard_validation"
        )
        authorized_payload, authorized_document = (
            _read_authorized_execution_bindings(
                directory,
                require_bound=require_bound,
            )
        )
        if (
            document.get("authorized_execution_bindings_file_sha256")
            != hashlib.sha256(authorized_payload).hexdigest()
            or document.get(
                "authorized_execution_bindings_manifest_sha256"
            )
            != authorized_document.get("manifest_sha256")
        ):
            raise P07ExecutionError(
                "terminal P07 authorized execution binding differs"
            )
        if authorized_document.get("status") == "bound":
            self._prepare_authorized_execution_from_intent(
                {"authorized_execution_bindings": authorized_document}
            )
        if document.get("failure_stage") == "pre_guard_validation":
            expected_fields = (
                (
                    "sampling_plan_file_sha256",
                    "expected_sampling_plan_sha256",
                ),
                (
                    "no_pixel_attestation_file_sha256",
                    "expected_no_pixel_attestation_sha256",
                ),
                (
                    "loader_executable_sha256",
                    "expected_loader_sha256",
                ),
            )
            if any(
                document.get(document_field)
                != getattr(self, executor_field, None)
                for document_field, executor_field in expected_fields
            ):
                raise P07ExecutionError(
                    "terminal P07 pre-guard publication uses another "
                    "expected input identity"
                )
            release_manifest = document.get(
                "release_bundle_manifest_sha256"
            )
            expected_release_manifest = getattr(
                self,
                "expected_release_manifest_sha256",
                release_manifest,
            )
            if release_manifest not in {None, expected_release_manifest}:
                raise P07ExecutionError(
                    "terminal P07 pre-guard publication uses another release"
                )
            expected_corpus = getattr(
                guard,
                "expected_corpus_manifest_sha256",
                None,
            )
            if not _is_sha256(expected_corpus):
                raise P07ExecutionError(
                    "terminal P07 pre-guard guard corpus identity is unavailable"
                )
            self._validate_guard_binding(
                guard,
                corpus_manifest_sha256=str(expected_corpus),
            )
            return
        release_manifest = document.get("release_bundle_manifest_sha256")
        if release_manifest is not None:
            _, release = _read_json(
                self.p06_release_manifest_path,
                "terminal P07 release manifest",
            )
            try:
                current_release_sha256 = p06_release_bundle_sha256(release)
            except ValueError as error:
                raise P07ExecutionError(
                    "terminal P07 release self-hash differs"
                ) from error
            if current_release_sha256 != release_manifest:
                raise P07ExecutionError(
                    "terminal P07 publication uses another release"
                )
        sampling_file_sha256 = document.get("sampling_plan_file_sha256")
        if sampling_file_sha256 is not None and (
            _sha256_file(self.sampling_plan_path, "terminal P07 sampling plan")
            != sampling_file_sha256
        ):
            raise P07ExecutionError(
                "terminal P07 publication uses another sampling-plan file"
            )
        sampling_manifest_sha256 = document.get(
            "sampling_plan_manifest_sha256"
        )
        if sampling_manifest_sha256 is not None:
            _, plan = _read_json(
                self.sampling_plan_path,
                "terminal P07 sampling plan",
            )
            if (
                plan.get("manifest_sha256") != _manifest_hash(plan)
                or plan.get("manifest_sha256") != sampling_manifest_sha256
            ):
                raise P07ExecutionError(
                    "terminal P07 publication uses another sampling plan"
                )
        no_pixel_sha256 = document.get("no_pixel_attestation_file_sha256")
        if no_pixel_sha256 is not None and (
            _sha256_file(
                self.no_pixel_attestation_path,
                "terminal P07 no-pixel attestation",
            )
            != no_pixel_sha256
        ):
            raise P07ExecutionError(
                "terminal P07 publication uses another no-pixel attestation"
            )
        loader_sha256 = document.get("loader_executable_sha256")
        if loader_sha256 is not None and (
            _sha256_file(self.loader_executable, "terminal P07 loader")
            != loader_sha256
        ):
            raise P07ExecutionError(
                "terminal P07 publication uses another loader"
            )
        if authorized_document.get("status") == "bound":
            self._validate_terminal_authorized_execution_closure(
                authorized_document=authorized_document,
                terminal_document=document,
            )
        direct_bindings = document.get("direct_input_bindings")
        corpus_manifest_sha256: Optional[str] = None
        if direct_bindings is not None:
            corpus_manifest_sha256 = self._validate_direct_input_bindings(
                direct_bindings
            )
        if corpus_manifest_sha256 is None:
            expected_corpus = getattr(
                guard,
                "expected_corpus_manifest_sha256",
                None,
            )
            if not _is_sha256(expected_corpus):
                raise P07ExecutionError(
                    "terminal P07 guard corpus identity is unavailable"
                )
            corpus_manifest_sha256 = str(expected_corpus)
        self._validate_guard_binding(
            guard,
            corpus_manifest_sha256=corpus_manifest_sha256,
        )

    def _recover_mount_from_intent(
        self,
        intent: Mapping[str, object],
    ) -> None:
        mount_root = self.holdout_root / "mount-v2"
        self._prepare_authorized_execution_from_intent(intent)
        observation = self._authorized_observe_mount(mount_root)
        if observation.mounted:
            self._authorized_unmount(mount_root)
        if self._authorized_observe_mount(mount_root).mounted:
            raise P07ExecutionError("P07 recovery left the holdout mounted")
        self._support_aware_release_validation()
        self._validate_cache_isolation()
        rows = intent.get("direct_input_bindings")
        if not isinstance(rows, list):
            raise P07ExecutionError(
                "P07 recovery direct-input bindings are absent"
            )
        for record in rows:
            if not isinstance(record, dict):
                raise P07ExecutionError(
                    "P07 recovery direct-input binding is invalid"
                )
            path = _path_under(
                self.repository_root,
                record.get("path"),
                "P07 recovery direct input",
            )
            metadata = _validate_existing_path(
                path,
                label="P07 recovery direct input",
                kind="file",
            )
            if (
                metadata.st_size != record.get("size_bytes")
                or _sha256_file(path, "P07 recovery direct input")
                != record.get("sha256")
            ):
                raise P07ExecutionError(
                    "P07 recovery direct input changed"
                )
        self._transaction_context["cleanup_result"] = {
            "status": "passed",
            "mount_invoked": observation.mounted,
            "mount_detached": True,
            "support_revalidation": "passed",
        }

    def _recover_staged_failure(
        self,
        *,
        workspace: _P07TransactionWorkspace,
        output_directory: Path,
        configuration_lock: Mapping[str, object],
        guard: object,
    ) -> Optional[Path]:
        archive_publication_failure = (
            workspace.read_archive_publication_failure()
        )
        opened = workspace.child_descriptor("failure", required=False)
        if opened is None:
            seed = workspace.read_emergency_seed()
            if seed is None:
                return None
            self._materialize_emergency_failure(
                workspace=workspace,
                seed=seed,
                archive_publication_failure=archive_publication_failure,
            )
            opened = workspace.child_descriptor("failure")
            assert opened is not None
        descriptor, _ = opened
        try:
            if not _descriptor_entry_names(
                descriptor,
                "P07 staged failure publication",
            ):
                seed = workspace.read_emergency_seed()
                if seed is None:
                    return None
                _clear_directory_descriptor(
                    descriptor,
                    "P07 empty failure publication",
                )
                os.close(descriptor)
                descriptor = -1
                self._materialize_emergency_failure(
                    workspace=workspace,
                    seed=seed,
                    archive_publication_failure=(
                        archive_publication_failure
                    ),
                )
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        staged = workspace.path / "failure"
        if archive_publication_failure is not None:
            seed = workspace.read_emergency_seed()
            if seed is None:
                raise P07ExecutionError(
                    "P07 archive-publication failure provenance has no "
                    "emergency seed"
                )
            self._materialize_emergency_failure(
                workspace=workspace,
                seed=seed,
                archive_publication_failure=archive_publication_failure,
            )
        else:
            try:
                _validate_failure_publication(staged)
            except P07ExecutionError:
                seed = workspace.read_emergency_seed()
                if seed is None:
                    raise
                self._materialize_emergency_failure(
                    workspace=workspace,
                    seed=seed,
                    archive_publication_failure=None,
                )
        _validate_failure_publication(staged)
        self._validate_terminal_invocation_binding(
            directory=staged,
            configuration_lock=configuration_lock,
            guard=guard,
        )
        preferred = (
            output_directory
            if not os.path.lexists(output_directory)
            else output_directory.with_name(output_directory.name + ".failed")
        )
        _publish_directory_exclusive(
            staged,
            preferred,
            destination_parent_pin=(
                workspace.parent_descriptor,
                workspace.parent_identity,
            ),
        )
        _validate_failure_publication(preferred)
        workspace.remove_child("extraction")
        workspace.destroy()
        return preferred

    def _materialize_emergency_failure(
        self,
        *,
        workspace: _P07TransactionWorkspace,
        seed: Mapping[str, object],
        archive_publication_failure: Optional[Mapping[str, object]],
    ) -> None:
        is_v2 = seed.get("schema_version") == "2.0.0"
        identity = (
            validate_identity_v2(seed.get(IDENTITY_FIELD))
            if is_v2
            else None
        )
        failure_log_value = seed.get("failure_log")
        access_evidence = seed.get("access_evidence")
        if not isinstance(failure_log_value, dict) or not isinstance(
            access_evidence,
            dict,
        ):
            raise P07ExecutionError("P07 emergency failure seed is incomplete")
        failure_log = dict(failure_log_value)
        failure_log["archive_publication_failure"] = (
            dict(archive_publication_failure)
            if archive_publication_failure is not None
            else None
        )
        failure_log["manifest_sha256"] = _manifest_hash(failure_log)
        _validate_schema(
            failure_log,
            FAILURE_LOG_V2_SCHEMA if is_v2 else FAILURE_LOG_SCHEMA,
            "P07 failure log",
        )
        if is_v2:
            validate_identity_v2(
                failure_log.get(IDENTITY_FIELD),
                expected=identity,
            )
        if failure_log.get("manifest_sha256") != _manifest_hash(failure_log):
            raise P07ExecutionError("P07 emergency failure log hash differs")
        opened = workspace.child_descriptor("failure", required=False)
        if opened is None:
            staged = workspace.prepare_empty_child("failure")
        else:
            descriptor, _ = opened
            try:
                _clear_directory_descriptor(
                    descriptor,
                    "P07 partial failure publication",
                )
            finally:
                os.close(descriptor)
            staged = workspace.path / "failure"
        _write_json(staged / FAILURE_LOG_NAME, failure_log)
        log_payload = _read_regular_file(
            staged / FAILURE_LOG_NAME,
            "P07 recovered failure log",
        )
        (
            authorized_execution_file_sha256,
            authorized_execution_manifest_sha256,
        ) = _write_authorized_execution_bindings(
            staged,
            _authorized_execution_publication_document(
                seed.get("authorized_execution_bindings")
            ),
            require_bound=(
                failure_log.get("failure_stage")
                != "pre_guard_validation"
            ),
        )
        document = {
            "schema_version": "2.0.0" if is_v2 else "1.1.0",
            "artifact_kind": (
                "p07_execution_failure_archive_v2"
                if is_v2
                else "p07_execution_failure_archive"
            ),
            **(
                {IDENTITY_FIELD: dict(identity)}
                if identity is not None
                else {}
            ),
            "status": "failed",
            **{
                field: seed[field]
                for field in (
                    "configuration_id",
                    "configuration_sha256",
                    "release_bundle_manifest_sha256",
                    "input_bundle_sha256",
                    "direct_input_bindings",
                    "corpus_lock_bundle_sha256",
                    "sampling_plan_file_sha256",
                    "sampling_plan_manifest_sha256",
                    "no_pixel_attestation_file_sha256",
                    "outer_wrapper_file_sha256",
                    "outer_wrapper_manifest_sha256",
                    "loader_executable_sha256",
                    "p07_preopen_cache_tree_sha256",
                )
            },
            "authorized_execution_bindings_file_sha256": (
                authorized_execution_file_sha256
            ),
            "authorized_execution_bindings_manifest_sha256": (
                authorized_execution_manifest_sha256
            ),
            **{
                field: failure_log[field]
                for field in (
                    "failure_type",
                    "failure_message",
                    "failure_message_sha256",
                    "failure_traceback",
                    "failure_traceback_sha256",
                    "secondary_failure",
                    "archive_publication_failure",
                    "failure_stage",
                    "transaction_state",
                    "cleanup_result",
                    "media_asset_id",
                    "media_case_id",
                    "frame_index",
                    "presentation_timestamp",
                    "media_context_available",
                    "requested_output_directory",
                    "temporary_run_path",
                    "command",
                    "platform",
                )
            },
            "failure_log_file_sha256": hashlib.sha256(log_payload).hexdigest(),
            **dict(access_evidence),
            "result_reusable_for_same_version": False,
        }
        document["manifest_sha256"] = _manifest_hash(document)
        _validate_schema(
            document,
            (
                EXECUTION_FAILURE_V2_SCHEMA
                if is_v2
                else SCHEMAS_ROOT / "p07-execution-failure-v1.schema.json"
            ),
            "P07 recovered failure archive",
        )
        _write_json(staged / "failed-version-archive.json", document)
        holdout_accessed = (
            access_evidence.get("holdout_access_consumed") is True
            or access_evidence.get("holdout_access_state")
            in {"anchor_only", "opened", "completed", "failed"}
            or failure_log.get("transaction_state", {}).get("guard_returned")
            is True
            or failure_log.get("cleanup_result", {}).get("mount_invoked") is True
        )
        _write_artifact_manifest(
            staged,
            status="failed",
            publication_kind="execution_failure",
            configuration_id=str(seed["configuration_id"]),
            configuration_sha256=str(seed["configuration_sha256"]),
            release_bundle_manifest_sha256=str(
                seed["release_bundle_manifest_sha256"]
            ),
            sampling_plan_manifest_sha256=str(
                seed["sampling_plan_manifest_sha256"]
            ),
            holdout_accessed=holdout_accessed,
            holdout_access_consumed=access_evidence.get(
                "holdout_access_consumed"
            ),
            command=str(failure_log["command"]),
            platform=str(failure_log["platform"]),
            p06_v2_identity=identity,
        )

    def _artifact_path(
        self,
        bundle: Mapping[str, object],
        identifier: str,
    ) -> Path:
        rows = bundle.get("artifacts")
        if not isinstance(rows, list):
            raise P07ExecutionError("P06 release artifacts are absent")
        matches = [row for row in rows if isinstance(row, dict) and row.get("id") == identifier]
        if len(matches) != 1:
            raise P07ExecutionError("P06 release artifact is absent: {}".format(identifier))
        return _path_under(
            self.p06_release_root,
            matches[0].get("path"),
            "P06 {} path".format(identifier),
        )

    def _artifact_binding(
        self,
        bundle: Mapping[str, object],
        identifier: str,
    ) -> Mapping[str, object]:
        rows = bundle.get("artifacts")
        if not isinstance(rows, list):
            raise P07ExecutionError("P06 release artifacts are absent")
        matches = [row for row in rows if isinstance(row, dict) and row.get("id") == identifier]
        if len(matches) != 1:
            raise P07ExecutionError("P06 release artifact is absent: {}".format(identifier))
        return matches[0]

    def _validate_cache_isolation(self) -> None:
        _validate_existing_path(
            self.p07_cache_root,
            label="P07 cache root",
            kind="directory",
        )
        descriptor = getattr(self, "_p07_cache_descriptor", None)
        identity = getattr(self, "_p07_cache_identity", None)
        if not isinstance(descriptor, int) or not isinstance(identity, os.stat_result):
            descriptor, identity = _open_directory_nofollow(
                self.p07_cache_root,
                "P07 cache root",
            )
            self._p07_cache_descriptor = descriptor
            self._p07_cache_identity = identity
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or (opened.st_dev, opened.st_ino)
            != (identity.st_dev, identity.st_ino)
        ):
            raise P07ExecutionError("pinned P07 cache root identity changed")
        _verify_directory_path_identity(
            self.p07_cache_root,
            identity,
            "P07 cache root",
        )
        _snapshot_descriptor_tree(descriptor, "P07 cache root")

        protected = [
            self.repository_root,
            self.p06_release_root,
            self.holdout_root,
            self.holdout_root / "mount-v2",
            self.sampling_plan_path.parent,
            self.no_pixel_attestation_path.parent,
            self.live_holdout_preopen_binding.live_ledger_path.parent,
            self.live_holdout_preopen_binding.live_anchor_path.parent,
            self.live_holdout_preopen_binding.live_preopen_receipt_path.parent,
        ]
        for field in ("repository_sealed_copy_path", "repository_attestation_path"):
            path = getattr(self.live_holdout_preopen_binding, field, None)
            if isinstance(path, Path):
                protected.append(path.parent)
        try:
            loader_inside_cache = self.loader_executable.relative_to(
                self.p07_cache_root
            )
        except ValueError:
            loader_inside_cache = None
        if loader_inside_cache is None:
            protected.append(self.loader_executable.parent)
        for identifier, root in self.support_evidence_roots.items():
            _validate_existing_path(root, label="{} support root".format(identifier), kind="directory")
            protected.append(root)
        if any(_paths_overlap(self.p07_cache_root, path) for path in protected):
            raise P07ExecutionError("P07 cache overlaps a protected P07 root")

    def _validate_output_isolation(self, output_directory: Path) -> None:
        protected = [
            self.p07_cache_root,
            self.p06_release_root,
            self.holdout_root,
            self.holdout_root / "mount-v2",
            *self.support_evidence_roots.values(),
            self.live_holdout_preopen_binding.live_ledger_path.parent,
            self.live_holdout_preopen_binding.live_anchor_path.parent,
            self.live_holdout_preopen_binding.live_preopen_receipt_path.parent,
        ]
        for root in protected:
            _validate_existing_path(root, label="P07 protected output root", kind="directory")
        if any(
            _existing_and_future_paths_overlap(root, output_directory)
            for root in protected
        ):
            raise P07ExecutionError(
                "P07 output directory overlaps protected evidence"
            )
        parent_resolved = output_directory.parent.resolve(strict=True)
        for root in protected:
            try:
                parent_resolved.relative_to(root.resolve(strict=True))
                raise P07ExecutionError(
                    "P07 output parent is inside protected evidence"
                )
            except ValueError:
                pass

    def _validate_release_and_inputs(self) -> tuple[Mapping[str, object], object]:
        try:
            bundle = self.release_validator(
                release_root=self.p06_release_root,
                manifest_path=self.p06_release_manifest_path,
                support_evidence_roots=self.support_evidence_roots,
            )
        except Exception as error:
            raise P07ExecutionError("support-aware P06 release validation failed") from error
        try:
            bound = self.input_binder(
                self.repository_root,
                live_holdout_preopen_binding=self.live_holdout_preopen_binding,
            )
            bound.verify_unchanged()
            rebound_corpus_bundle_sha256 = corpus_lock_bundle_sha256(bound)
        except Exception as error:
            raise P07ExecutionError("direct P06 preregistered inputs changed") from error

        ledger_path = self._artifact_path(bundle, "calibration_run_ledger")
        _, ledger = _read_json(ledger_path, "P06 calibration-run ledger")
        selection_path = self._artifact_path(bundle, "calibration_selection")
        _, selection = _read_json(selection_path, "P06 calibration selection")
        is_v3 = (
            bundle.get("schema_version") == "3.0.1"
            and bundle.get("bundle_id")
            == "mirmir-p06-spatial-release-lock-v3"
        )
        compiler_id = (
            "locked_compiler_input_v2" if is_v3 else "locked_compiler_input"
        )
        compiler_path = self._artifact_path(bundle, compiler_id)
        _, compiler = _read_json(compiler_path, "P06 locked compiler input")
        live_path = self._artifact_path(bundle, "live_holdout_preopen_verification")
        _, live = _read_json(live_path, "P06 live holdout verification")

        input_bundle_sha256 = getattr(bound, "bundle_sha256", None)
        records = getattr(bound, "records", None)
        live_verification = getattr(bound, "live_holdout_preopen_verification", None)
        compiler_bindings = compiler.get("hash_bindings")
        calibration_plan_record = None
        if isinstance(records, tuple):
            matches = [record for record in records if record.get("id") == "calibration_plan"]
            if len(matches) == 1:
                calibration_plan_record = matches[0]
        if is_v3:
            exact_v2_inputs = list(authority_input_bindings_v2())
            selected = selection.get("selected")
            if (
                ledger.get("schema_version") != "2.0.1"
                or selection.get("schema_version") != "2.0.2"
                or not isinstance(selected, dict)
                or not _is_sha256(selected.get("candidate_vector_sha256"))
                or ledger.get("input_bindings") != exact_v2_inputs
                or ledger.get("input_bundle_sha256")
                != P06_V2_INPUT_BUNDLE_SHA256
                or selection.get("input_bundle_sha256")
                != P06_V2_INPUT_BUNDLE_SHA256
                or bundle.get("input_bundle_sha256")
                != P06_V2_INPUT_BUNDLE_SHA256
                or bundle.get("shared_bank_configuration_sha256")
                != selection.get("shared_bank_configuration_sha256")
                or bundle.get("corpus_lock_bundle_sha256")
                != rebound_corpus_bundle_sha256
                or live != live_verification
                or not isinstance(compiler_bindings, dict)
                or compiler_bindings.get("corpus_lock_bundle_sha256")
                != rebound_corpus_bundle_sha256
                or compiler_bindings.get("calibration_plan_sha256")
                != P06_V2_PLAN_FILE_SHA256
            ):
                raise P07ExecutionError(
                    "reopened P06 V3 inputs do not match the exact schema-2 "
                    "authority, selected identity, live verification, and compiler"
                )
            return bundle, bound

        if (
            not _is_sha256(input_bundle_sha256)
            or not isinstance(records, tuple)
            or not isinstance(live_verification, dict)
            or ledger.get("input_bindings") != list(records)
            or ledger.get("input_bundle_sha256") != input_bundle_sha256
            or ledger.get("live_holdout_preopen_verification") != live_verification
            or selection.get("input_bundle_sha256") != input_bundle_sha256
            or selection.get("corpus_lock_bundle_sha256")
            != rebound_corpus_bundle_sha256
            or selection.get("live_holdout_preopen_verification") != live_verification
            or bundle.get("input_bundle_sha256") != input_bundle_sha256
            or bundle.get("corpus_lock_bundle_sha256")
            != rebound_corpus_bundle_sha256
            or live != live_verification
            or not isinstance(compiler_bindings, dict)
            or compiler_bindings.get("corpus_lock_bundle_sha256")
            != rebound_corpus_bundle_sha256
            or calibration_plan_record is None
            or compiler_bindings.get("calibration_plan_sha256")
            != calibration_plan_record.get("sha256")
        ):
            raise P07ExecutionError(
                "reopened P06 inputs do not match ledger, live verification, selection, and compiler"
            )
        return bundle, bound

    def _validate_sampling_plan(
        self,
        plan: Mapping[str, object],
        corpus: Mapping[str, object],
        attestation: Mapping[str, object],
    ) -> None:
        _validate_schema(plan, PLAN_SCHEMA, "P07 sampling plan")
        if (
            plan.get("manifest_sha256") != _manifest_hash(plan)
            or plan.get("corpus_manifest_sha256") != corpus.get("manifest_sha256")
            or plan.get("target_pixel_hashes_known_before_p07") is not False
            or plan.get("holdout_accessed") is not False
        ):
            raise P07ExecutionError("P07 sampling plan hash or unopened binding differs")
        corpus_assets = corpus.get("assets")
        plan_assets = plan.get("assets")
        if not isinstance(corpus_assets, list) or not isinstance(plan_assets, list):
            raise P07ExecutionError("P07 sampling assets are absent")
        holdout = [
            asset
            for asset in corpus_assets
            if isinstance(asset, dict) and asset.get("split") == "holdout"
        ]
        if len(holdout) != 3:
            raise P07ExecutionError("locked corpus does not contain exactly three holdout assets")
        expected_by_id = {str(asset["asset_id"]): asset for asset in holdout}
        if len(expected_by_id) != 3:
            raise P07ExecutionError("locked holdout asset IDs are duplicated")
        for ordinal, item in enumerate(plan_assets):
            if not isinstance(item, dict) or item.get("ordinal") != ordinal:
                raise P07ExecutionError("sampling plan asset order differs")
            source = expected_by_id.get(str(item.get("asset_id")))
            if source is None:
                raise P07ExecutionError("sampling plan substitutes a holdout asset")
            dimensions = item.get("presentation_dimensions")
            expected_metadata = item.get("expected_metadata")
            if (
                source.get("orientation") != "identity"
                or item.get("source_asset_id") != source.get("source_asset_id")
                or item.get("source_family_id") != source.get("source_family_id")
                or item.get("source_sha256") != source.get("sha256")
                or item.get("source_size_bytes") != source.get("size_bytes")
                or item.get("frame_count") != source.get("frame_count")
                or item.get("frame_range") != source.get("frame_range")
                or not isinstance(dimensions, dict)
                or [dimensions.get("width"), dimensions.get("height")]
                != source.get("presentation_dimensions")
                or [item.get("target_route")] != source.get("target_routes")
                or not isinstance(expected_metadata, dict)
                or expected_metadata
                != {
                    "pixel_format": source.get("pixel_format"),
                    "range": source.get("range"),
                    "color_primaries": source.get("color_primaries"),
                    "transfer_function": source.get("transfer_function"),
                    "ycbcr_matrix": source.get("ycbcr_matrix"),
                    "chroma_location": source.get("chroma_location"),
                }
            ):
                raise P07ExecutionError("sampling plan metadata differs from the corpus lock")
        attested_payloads = attestation.get("canonical_payload_hashes")
        expected_payloads = [
            {
                "asset_id": item["asset_id"],
                "bytes": item["source_size_bytes"],
                "sha256": item["source_sha256"],
            }
            for item in plan_assets
        ]
        if attested_payloads != expected_payloads:
            raise P07ExecutionError("sampling plan differs from attested canonical payloads")

    def _validate_outer_attestation(
        self,
        attestation: Mapping[str, object],
    ) -> Mapping[str, Path]:
        _validate_schema(attestation, ATTESTATION_SCHEMA, "holdout no-pixel attestation")
        evaluation_access = attestation.get("evaluation_access")
        container = attestation.get("container")
        workflow = attestation.get("read_only_provisioning_workflow")
        if (
            attestation.get("pixel_content_included") is not False
            or not isinstance(evaluation_access, dict)
            or evaluation_access
            != {
                "status": "unopened",
                "evaluation_opened_utc": None,
                "first_evaluation_access_utc": None,
                "last_evaluation_access_utc": None,
                "evaluation_access_count": 0,
                "evaluation_run_id": None,
            }
            or not isinstance(container, dict)
            or container.get("mounted") is not False
            or not isinstance(workflow, dict)
        ):
            raise P07ExecutionError("outer attestation no longer proves unopened state")
        paths = {}
        for path_field, expected_relative in EXPECTED_WORKFLOW_PATHS.items():
            if workflow.get(path_field) != expected_relative:
                raise P07ExecutionError("holdout workflow path differs: {}".format(path_field))
            path = _path_under(self.holdout_root, expected_relative, path_field)
            _validate_existing_path(path, label=path_field, kind="file")
            hash_field = path_field.replace("_path", "_sha256")
            if _sha256_file(path, path_field) != workflow.get(hash_field):
                raise P07ExecutionError("holdout workflow bytes changed: {}".format(path_field))
            if not os.access(path, os.X_OK):
                raise P07ExecutionError("holdout workflow is not executable: {}".format(path_field))
            paths[path_field] = path
        container_path = _path_under(
            self.holdout_root,
            container.get("relative_path"),
            "encrypted container path",
        )
        _validate_existing_path(container_path, label="encrypted container", kind="directory")
        hashes_path = _path_under(
            self.holdout_root,
            container.get("container_file_hashes_path"),
            "container hash inventory path",
        )
        if _sha256_file(hashes_path, "container hash inventory") != container.get(
            "container_file_hashes_sha256"
        ):
            raise P07ExecutionError("container hash inventory changed")
        return paths

    def preflight(self) -> P07Preflight:
        """Reopen every P06 and no-pixel input without touching holdout media."""

        _validate_existing_path(self.repository_root, label="repository root", kind="directory")
        _validate_existing_path(self.holdout_root, label="holdout root", kind="directory")
        _validate_existing_path(self.p06_release_root, label="P06 release root", kind="directory")
        self._validate_cache_isolation()
        bundle, bound = self._validate_release_and_inputs()

        plan_payload, plan = _read_json(self.sampling_plan_path, "P07 sampling plan")
        plan_file_sha256 = hashlib.sha256(plan_payload).hexdigest()
        if plan_file_sha256 != self.expected_sampling_plan_sha256:
            raise P07ExecutionError("P07 sampling-plan file hash changed")
        attestation_payload, attestation = _read_json(
            self.no_pixel_attestation_path,
            "holdout no-pixel attestation",
        )
        attestation_file_sha256 = hashlib.sha256(attestation_payload).hexdigest()
        if attestation_file_sha256 != self.expected_no_pixel_attestation_sha256:
            raise P07ExecutionError("holdout no-pixel attestation file hash changed")

        records = getattr(bound, "records")
        plan_records = [record for record in records if record.get("id") == "holdout_sampling_plan"]
        attestation_records = [
            record for record in records if record.get("id") == "holdout_preopen_anchor"
        ]
        corpus_records = [record for record in records if record.get("id") == "corpus_lock"]
        if (
            len(plan_records) != 1
            or len(attestation_records) != 1
            or len(corpus_records) != 1
            or plan_records[0].get("sha256") != plan_file_sha256
            or attestation_records[0].get("sha256") != attestation_file_sha256
        ):
            raise P07ExecutionError("P07 plan or attestation is not the direct P06 input")
        corpus_path = _path_under(
            self.repository_root,
            corpus_records[0].get("path"),
            "corpus lock path",
        )
        corpus_payload, corpus = _read_json(corpus_path, "locked corpus manifest")
        corpus_file_sha256 = hashlib.sha256(corpus_payload).hexdigest()
        if corpus_file_sha256 != corpus_records[0].get("sha256"):
            raise P07ExecutionError("locked corpus bytes changed after direct binding")

        workflow_paths = self._validate_outer_attestation(attestation)
        sealed_corpus = attestation.get("production_corpus_lock")
        if (
            not isinstance(sealed_corpus, dict)
            or sealed_corpus.get("file_sha256") != corpus_file_sha256
            or sealed_corpus.get("manifest_sha256") != corpus.get("manifest_sha256")
            or corpus.get("manifest_sha256") != _manifest_hash(corpus)
            or plan.get("corpus_manifest_sha256") != corpus.get("manifest_sha256")
        ):
            raise P07ExecutionError("corpus, plan, and no-pixel attestation hashes differ")
        self._validate_sampling_plan(plan, corpus, attestation)

        wrapper_binding = attestation.get("holdout_wrapper")
        if not isinstance(wrapper_binding, dict):
            raise P07ExecutionError("outer holdout wrapper binding is absent")
        wrapper_path = _path_under(
            self.holdout_root,
            wrapper_binding.get("path"),
            "outer holdout wrapper path",
        )
        wrapper_payload, wrapper = _read_json(wrapper_path, "outer holdout wrapper")
        wrapper_file_sha256 = hashlib.sha256(wrapper_payload).hexdigest()
        if (
            wrapper_file_sha256 != wrapper_binding.get("file_sha256")
            or wrapper.get("manifest_sha256") != wrapper_binding.get("manifest_sha256")
            or wrapper.get("manifest_sha256") != _manifest_hash(wrapper)
        ):
            raise P07ExecutionError("outer holdout wrapper changed")

        loader_sha256 = _sha256_file(self.loader_executable, "P07 loader executable")
        if loader_sha256 != self.expected_loader_sha256:
            raise P07ExecutionError("P07 loader executable changed")
        if not os.access(self.loader_executable, os.X_OK):
            raise P07ExecutionError("P07 loader executable is not executable")
        mount_root = self.holdout_root / "mount-v2"
        _validate_existing_path(mount_root, label="holdout mount root", kind="directory")
        candidate_vector_sha256: Optional[str] = None
        shared_bank_configuration_sha256: Optional[str] = None
        p06_v2_identity: Optional[Mapping[str, str]] = None
        preflight_input_bundle_sha256 = str(getattr(bound, "bundle_sha256"))
        if (
            bundle.get("schema_version") == "3.0.1"
            and bundle.get("bundle_id")
            == "mirmir-p06-spatial-release-lock-v3"
        ):
            selection_path = self._artifact_path(
                bundle,
                "calibration_selection",
            )
            _, selected_release = _read_json(
                selection_path,
                "P06 V3 calibration selection",
            )
            selected = selected_release.get("selected")
            if not isinstance(selected, dict):
                raise P07ExecutionError(
                    "P06 V3 selected candidate identity is absent"
                )
            candidate_vector_sha256 = _require_sha256(
                selected.get("candidate_vector_sha256"),
                "P06 V3 candidate-vector identity",
            )
            shared_bank_configuration_sha256 = _require_sha256(
                bundle.get("shared_bank_configuration_sha256"),
                "P06 V3 shared-bank identity",
            )
            preflight_input_bundle_sha256 = _require_sha256(
                bundle.get("input_bundle_sha256"),
                "P06 V3 input-bundle identity",
            )
            _, selected_evaluation = _read_json(
                self._artifact_path(bundle, "selected_evaluation"),
                "P06 V3 selected evaluation",
            )
            _, compiler_input = _read_json(
                self._artifact_path(bundle, "locked_compiler_input_v2"),
                "P06 V3 locked compiler input",
            )
            try:
                p06_v2_identity = release_identity_v2(
                    bundle=bundle,
                    selection=selected_release,
                    evaluation=selected_evaluation,
                    compiler_input=compiler_input,
                )
            except ValueError as error:
                raise P07ExecutionError(
                    "P06 V3 identity projection differs"
                ) from error
        return P07Preflight(
            plan=plan,
            plan_file_sha256=plan_file_sha256,
            attestation=attestation,
            attestation_file_sha256=attestation_file_sha256,
            corpus_lock=corpus,
            corpus_lock_file_sha256=corpus_file_sha256,
            degradation_policy=getattr(bound, "documents")["degradation_policy"],
            analytic_fixture_manifest=getattr(bound, "documents")[
                "analytic_fixture_manifest"
            ],
            outer_wrapper=wrapper,
            outer_wrapper_file_sha256=wrapper_file_sha256,
            release_bundle=bundle,
            workflow_paths=workflow_paths,
            mount_root=mount_root,
            loader_sha256=loader_sha256,
            p07_cache_tree_sha256=_directory_tree_sha256(
                self.p07_cache_root,
                "P07 pre-open cache tree",
            ),
            input_bundle_sha256=preflight_input_bundle_sha256,
            corpus_lock_bundle_sha256=corpus_lock_bundle_sha256(bound),
            input_records=tuple(records),
            candidate_vector_sha256=candidate_vector_sha256,
            shared_bank_configuration_sha256=(
                shared_bank_configuration_sha256
            ),
            p06_v2_identity=p06_v2_identity,
        )

    def _verify_preflight_files(self, preflight: P07Preflight) -> None:
        self._validate_cache_isolation()
        if (
            _sha256_file(self.sampling_plan_path, "P07 sampling plan")
            != preflight.plan_file_sha256
            or _sha256_file(self.no_pixel_attestation_path, "no-pixel attestation")
            != preflight.attestation_file_sha256
            or _sha256_file(self.loader_executable, "P07 loader executable")
            != preflight.loader_sha256
            or _directory_tree_sha256(
                self.p07_cache_root,
                "P07 pre-open cache tree",
            )
            != preflight.p07_cache_tree_sha256
        ):
            raise P07ExecutionError("P07 preflight bytes changed")
        workflow = preflight.attestation["read_only_provisioning_workflow"]
        for path_field, path in preflight.workflow_paths.items():
            hash_field = path_field.replace("_path", "_sha256")
            if _sha256_file(path, path_field) != workflow[hash_field]:
                raise P07ExecutionError("holdout workflow changed after preflight")

    def _verify_direct_input_files(self, preflight: P07Preflight) -> None:
        for record in preflight.input_records:
            path = _path_under(
                self.repository_root,
                record.get("path"),
                "direct P06 input path",
            )
            metadata = _validate_existing_path(path, label="direct P06 input", kind="file")
            if (
                metadata.st_size != record.get("size_bytes")
                or _sha256_file(path, "direct P06 input") != record.get("sha256")
            ):
                raise P07ExecutionError("a direct P06 input changed during P07")

    def _validate_inner_inventory(
        self,
        preflight: P07Preflight,
    ) -> Mapping[str, object]:
        binding = preflight.attestation.get("inner_inventory")
        if not isinstance(binding, dict):
            raise P07ExecutionError("inner inventory binding is absent")
        inventory_path = _path_under(
            preflight.mount_root,
            binding.get("container_relative_path"),
            "inner inventory path",
        )
        payload, inventory = _read_json(inventory_path, "mounted inner inventory")
        if hashlib.sha256(payload).hexdigest() != binding.get("sha256"):
            raise P07ExecutionError("mounted inner inventory hash changed")
        _validate_schema(inventory, INNER_INVENTORY_SCHEMA, "mounted inner inventory")
        entries = inventory.get("entries")
        if not isinstance(entries, list):
            raise P07ExecutionError("mounted inner inventory entries are absent")
        relative_paths = [entry.get("relative_path") for entry in entries if isinstance(entry, dict)]
        if (
            len(relative_paths) != len(entries)
            or relative_paths != sorted(relative_paths)
            or len(relative_paths) != len(set(relative_paths))
            or inventory.get("entry_count") != len(entries)
            or inventory.get("entry_count") != binding.get("entry_count")
            or inventory.get("payload_file_count")
            != binding.get("canonical_payload_file_count")
            or inventory.get("payload_bytes") != binding.get("canonical_payload_bytes")
            or inventory.get("rejected_payload_file_count")
            != binding.get("rejected_payload_file_count")
            or inventory.get("rejected_payload_bytes")
            != binding.get("rejected_payload_bytes")
            or inventory.get("revision_id") != preflight.attestation.get("revision_id")
        ):
            raise P07ExecutionError("mounted inner inventory metadata differs")
        for entry in entries:
            if not isinstance(entry, dict):
                raise P07ExecutionError("mounted inner inventory entry is not an object")
            path = _path_under(
                preflight.mount_root,
                entry.get("relative_path"),
                "inner inventory entry path",
            )
            metadata = _validate_existing_path(path, label="inner inventory entry", kind="file")
            if metadata.st_size != entry.get("size_bytes"):
                raise P07ExecutionError("mounted inner inventory entry size changed")

        payload_entries = [
            entry
            for entry in entries
            if isinstance(entry.get("relative_path"), str)
            and str(entry["relative_path"]).startswith("payloads/")
        ]
        expected_payload_entries = [
            {
                "sha256": item["source_sha256"],
                "size_bytes": item["source_size_bytes"],
                "relative_path": "payloads/{}.mp4".format(item["asset_id"]),
            }
            for item in preflight.plan["assets"]
        ]
        if payload_entries != expected_payload_entries:
            raise P07ExecutionError("mounted canonical payload inventory differs from the plan")

        wrapper_binding = preflight.attestation["holdout_wrapper"]
        mounted_wrapper_path = _path_under(
            preflight.mount_root,
            wrapper_binding["path"],
            "mounted holdout wrapper path",
        )
        mounted_wrapper_payload, mounted_wrapper = _read_json(
            mounted_wrapper_path,
            "mounted holdout wrapper",
        )
        if (
            hashlib.sha256(mounted_wrapper_payload).hexdigest()
            != preflight.outer_wrapper_file_sha256
            or mounted_wrapper != preflight.outer_wrapper
        ):
            raise P07ExecutionError("mounted holdout wrapper differs from the sealed outer copy")
        return inventory

    def _validate_extraction(
        self,
        *,
        preflight: P07Preflight,
        output_descriptor: int,
        stdout: bytes,
    ) -> Mapping[str, object]:
        stdout_document = _decode_json(stdout, "P07 loader stdout")
        extraction_payload = _read_regular_at(
            output_descriptor,
            "frame-extraction.json",
            "P07 frame extraction",
        )
        extraction = _decode_json(extraction_payload, "P07 frame extraction")
        if stdout_document != extraction:
            raise P07ExecutionError("P07 loader stdout differs from persisted extraction")
        _validate_schema(extraction, EXTRACTION_SCHEMA, "P07 frame extraction")
        if (
            extraction.get("manifest_sha256") != _manifest_hash(extraction)
            or extraction.get("sampling_plan_file_sha256")
            != preflight.plan_file_sha256
            or extraction.get("sampling_plan_manifest_sha256")
            != preflight.plan.get("manifest_sha256")
            or extraction.get("corpus_manifest_sha256")
            != preflight.corpus_lock.get("manifest_sha256")
        ):
            raise P07ExecutionError("P07 extraction is stale or has an invalid self-hash")
        rows = extraction.get("assets")
        plan_rows = preflight.plan.get("assets")
        if not isinstance(rows, list) or not isinstance(plan_rows, list):
            raise P07ExecutionError("P07 extraction rows are absent")
        expected_files = {"frame-extraction.json"}
        for row, plan in zip(rows, plan_rows):
            expected_name = "{:02d}-{}.nv12".format(plan["ordinal"], plan["asset_id"])
            expected_files.add(expected_name)
            selected = row.get("selected_presentation_time")
            asset_id = plan.get("asset_id")
            exact_timestamp = (
                selected
                if isinstance(selected, dict)
                and isinstance(selected.get("value"), int)
                and not isinstance(selected.get("value"), bool)
                and isinstance(selected.get("timescale"), int)
                and not isinstance(selected.get("timescale"), bool)
                and selected.get("timescale") > 0
                else None
            )
            self._set_media_context(
                P07MediaContext(
                    asset_id=str(asset_id) if isinstance(asset_id, str) else None,
                    case_id="loader_extraction_validation",
                    presentation_timestamp=exact_timestamp,
                )
            )
            frame_range = plan.get("frame_range")
            if not isinstance(selected, dict) or not isinstance(frame_range, dict):
                raise P07ExecutionError("P07 selected frame timing is absent")
            pts_value = selected.get("value")
            pts_scale = selected.get("timescale")
            plan_scale = frame_range.get("timescale")
            start = frame_range.get("start")
            duration = frame_range.get("duration")
            if not all(isinstance(value, int) and not isinstance(value, bool) for value in (
                pts_value, pts_scale, plan_scale, start, duration
            )):
                raise P07ExecutionError("P07 selected frame timing is not integral")
            midpoint_left = 2 * (pts_value * plan_scale - start * pts_scale)
            midpoint_right = duration * pts_scale
            end_left = pts_value * plan_scale
            end_right = (start + duration) * pts_scale
            transform = row.get("preferred_transform")
            if (
                row.get("ordinal") != plan.get("ordinal")
                or row.get("asset_id") != plan.get("asset_id")
                or row.get("source_asset_id") != plan.get("source_asset_id")
                or row.get("source_family_id") != plan.get("source_family_id")
                or row.get("target_route") != plan.get("target_route")
                or row.get("source_sha256") != plan.get("source_sha256")
                or row.get("source_size_bytes") != plan.get("source_size_bytes")
                or row.get("presentation_dimensions")
                != plan.get("presentation_dimensions")
                or row.get("frame_range") != frame_range
                or row.get("crop") != plan.get("crop")
                or row.get("crop_nv12_filename") != expected_name
                or transform != {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0}
                or pts_scale <= 0
                or midpoint_left < midpoint_right
                or end_left > end_right
            ):
                raise P07ExecutionError("P07 extraction differs from its preregistered sample")
            crop_descriptor, crop_metadata = _open_child_descriptor(
                output_descriptor,
                expected_name,
                directory=False,
                label="P07 extracted crop",
            )
            try:
                crop_sha256, crop_size = _hash_regular_descriptor(
                    crop_descriptor,
                    crop_metadata,
                    "P07 extracted crop",
                )
            finally:
                os.close(crop_descriptor)
            if (
                crop_size != row.get("crop_nv12_size_bytes")
                or crop_sha256 != row.get("crop_nv12_sha256")
            ):
                raise P07ExecutionError("P07 extracted crop bytes changed")
        observed_files = set(
            _descriptor_entry_names(
                output_descriptor,
                "P07 extraction directory",
            )
        )
        for name in observed_files:
            metadata = os.stat(
                name,
                dir_fd=output_descriptor,
                follow_symlinks=False,
            )
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(
                metadata.st_mode
            ):
                raise P07ExecutionError(
                    "P07 extraction directory contains a nonregular entry"
                )
        if observed_files != expected_files:
            raise P07ExecutionError("P07 extraction directory contents differ")
        if extraction_payload != _canonical_bytes(extraction) + b"\n":
            raise P07ExecutionError("P07 extraction is not canonical JSON")
        self._set_media_context(None)
        return extraction

    def _run_extraction(
        self,
        *,
        preflight: P07Preflight,
        output_descriptor: int,
        mount_descriptor: int,
    ) -> Mapping[str, object]:
        context = self._required_authorized_execution_context()
        result = self._run_authorized_binding(
            context.loader,
            (
                "extract",
                "--plan-fd",
                str(context.sampling_plan.descriptor),
                "--plan-sha256",
                preflight.plan_file_sha256,
                "--mount-root",
                ".",
                "--output-directory-fd",
                str(output_descriptor),
            ),
            cwd_descriptor=mount_descriptor,
            additional_files=(context.sampling_plan,),
            additional_descriptors=(output_descriptor,),
            timeout_seconds=1800.0,
        )
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", "replace").strip()
            matches = [
                str(row.get("asset_id"))
                for row in preflight.plan.get("assets", [])
                if isinstance(row, dict)
                and isinstance(row.get("asset_id"), str)
                and str(row.get("asset_id")) in stderr
            ]
            if len(matches) == 1:
                raise P07ContextualError(
                    "P07 frame extraction failed: {}".format(stderr),
                    media_context=P07MediaContext(
                        asset_id=matches[0],
                        case_id="loader_extraction",
                    ),
                )
            raise P07ExecutionError(
                "P07 frame extraction failed: {}".format(stderr)
            )
        return self._validate_extraction(
            preflight=preflight,
            output_descriptor=output_descriptor,
            stdout=result.stdout,
        )

    def _validate_measurement_input_bindings(
        self,
        *,
        preflight: P07Preflight,
        extraction: Mapping[str, object],
        measurement: Mapping[str, object],
    ) -> None:
        kind_order = (
            "lowpass_decimate",
            "camera_blur_decimate",
            "codec_quantized_proxy",
        )
        route_order = ("direct-2x", "direct-3over2")
        if (
            measurement.get("frame_extraction_manifest_sha256")
            != extraction.get("manifest_sha256")
            or measurement.get("analytic_fixture_manifest_sha256")
            != preflight.analytic_fixture_manifest.get("manifest_sha256")
        ):
            raise P07ExecutionError("P07 measurements are not bound to extraction/fixtures")
        plan_assets = preflight.plan.get("assets")
        extraction_assets = extraction.get("assets")
        corpus_assets = preflight.corpus_lock.get("assets")
        if not all(isinstance(value, list) for value in (
            plan_assets, extraction_assets, corpus_assets
        )):
            raise P07ExecutionError("P07 source binding metadata is absent")
        holdout_by_source = {
            str(asset["source_asset_id"]): asset
            for asset in corpus_assets
            if isinstance(asset, dict) and asset.get("split") == "holdout"
        }
        source_order = [str(item["source_asset_id"]) for item in plan_assets]
        if measurement.get("source_order") != source_order:
            raise P07ExecutionError("P07 measurement source order differs from sampling plan")
        crop_hashes = {
            str(plan["source_asset_id"]): extracted["crop_nv12_sha256"]
            for plan, extracted in zip(plan_assets, extraction_assets)
        }
        profiles = preflight.degradation_policy.get("profiles")
        if not isinstance(profiles, list):
            raise P07ExecutionError("locked degradation profiles are absent")
        expected_profiles = []
        for route in route_order:
            for kind in kind_order:
                matches = [
                    profile
                    for profile in profiles
                    if isinstance(profile, dict)
                    and profile.get("target_route") == route
                    and profile.get("kind") == kind
                ]
                if len(matches) != 1:
                    raise P07ExecutionError("route-specific degradation profile is ambiguous")
                expected_profiles.append(
                    {
                        "target_route": route,
                        "kind": kind,
                        "profile_id": matches[0]["id"],
                        "profile_sha256": canonical_sha256(matches[0]),
                    }
                )
        if measurement.get("locked_degradation_profiles") != expected_profiles:
            raise P07ExecutionError("P07 measurements substitute degradation profiles")
        profile_by_route_kind = {
            (row["target_route"], row["kind"]): row for row in expected_profiles
        }
        rows = measurement.get("corpus_rows")
        if not isinstance(rows, list):
            raise P07ExecutionError("P07 measurement corpus rows are absent")
        for row in rows:
            if not isinstance(row, dict):
                raise P07ExecutionError("P07 measurement corpus row is invalid")
            source = str(row.get("source_asset_id"))
            asset = holdout_by_source.get(source)
            profile = profile_by_route_kind.get(
                (row.get("target_route"), row.get("degradation_kind"))
            )
            if (
                asset is None
                or row.get("source_family_id") != asset.get("source_family_id")
                or row.get("categories") != asset.get("categories")
                or [row.get("target_route")] != asset.get("target_routes")
                or row.get("source_crop_nv12_sha256") != crop_hashes.get(source)
                or profile is None
                or row.get("degradation_profile_id") != profile["profile_id"]
                or row.get("degradation_profile_sha256") != profile["profile_sha256"]
            ):
                raise P07ExecutionError("P07 row substitutes source, crop, route, or profile")

        fixture_definitions = preflight.analytic_fixture_manifest.get("fixtures")
        if not isinstance(fixture_definitions, list) or len(fixture_definitions) != 14:
            raise P07ExecutionError("locked analytic fixture manifest is incomplete")
        expected_fixtures = [
            {
                "fixture_id": definition["fixture_id"],
                "fixture_kind": definition["fixture_kind"],
                "target_route": definition["target_route"],
                "fixture_definition_sha256": canonical_sha256(definition),
            }
            for definition in fixture_definitions
        ]
        if measurement.get("locked_analytic_fixtures") != expected_fixtures:
            raise P07ExecutionError("P07 measurements substitute analytic fixtures")

    def _support_aware_release_validation(self) -> Mapping[str, object]:
        try:
            return self.release_validator(
                release_root=self.p06_release_root,
                manifest_path=self.p06_release_manifest_path,
                support_evidence_roots=self.support_evidence_roots,
            )
        except Exception as error:
            raise P07ExecutionError("P06 release or support evidence changed during P07") from error

    def _authorized_evaluation(
        self,
        *,
        preflight: P07Preflight,
        extraction_directory: Path,
        extraction_descriptor: int,
        publication_directory: Path,
        evaluator: Callable[[
            Mapping[str, object], Path, Path
        ], Mapping[str, object]],
    ) -> Mapping[str, object]:
        primary_error: Optional[BaseException] = None
        result: Optional[Mapping[str, object]] = None
        mount_invoked = False
        context = getattr(self, "_transaction_context", {})
        self._transaction_context = context
        context.update(
            {
                "phase": "authorized_evaluation",
                "cleanup_result": {
                    "status": "not_started",
                    "mount_invoked": False,
                    "mount_detached": None,
                    "support_revalidation": "not_run",
                },
                "frame_index": None,
                "presentation_timestamp": None,
                "media_asset_id": None,
                "media_case_id": None,
                "media_context_available": False,
            }
        )
        try:
            before = self._authorized_observe_mount(preflight.mount_root)
            if before.mounted:
                raise P07ExecutionError("holdout became mounted before authorized mount")
            self._verify_preflight_files(preflight)
            mount_invoked = True
            context["cleanup_result"] = {
                "status": "not_started",
                "mount_invoked": True,
                "mount_detached": None,
                "support_revalidation": "not_run",
            }
            context["phase"] = "mounting_holdout"
            self._authorized_mount(preflight)
            mounted = self._authorized_observe_mount(preflight.mount_root)
            if not mounted.mounted or not mounted.read_only:
                raise P07ExecutionError("holdout mount is absent or not read-only")
            context["phase"] = "extracting_holdout_frames"
            self._validate_inner_inventory(preflight)
            mount_descriptor, _ = _open_directory_nofollow(
                preflight.mount_root,
                "P07 mounted holdout root",
            )
            try:
                extraction = self._run_extraction(
                    preflight=preflight,
                    output_descriptor=extraction_descriptor,
                    mount_descriptor=mount_descriptor,
                )
            finally:
                os.close(mount_descriptor)
            envelope = evaluator(
                extraction,
                extraction_directory,
                self.p07_cache_root,
            )
            context["phase"] = "validating_holdout_measurements"
            if not isinstance(envelope, dict) or set(envelope) != {
                "measurements",
                "runtime_evidence",
            }:
                raise P07ExecutionError(
                    "P07 evaluator did not return the exact evidence envelope"
                )
            evaluation = envelope.get("measurements")
            runtime_evidence = envelope.get("runtime_evidence")
            if not isinstance(evaluation, dict) or not isinstance(
                runtime_evidence,
                dict,
            ):
                raise P07ExecutionError("P07 evaluator evidence envelope is invalid")
            p06_identity = _preflight_p06_v2_identity(preflight)
            is_v2 = p06_identity is not None
            _validate_schema(
                runtime_evidence,
                (
                    RUNTIME_EVIDENCE_V2_SCHEMA
                    if is_v2
                    else RUNTIME_EVIDENCE_SCHEMA
                ),
                "P07 runtime evidence",
            )
            if is_v2:
                try:
                    validate_identity_v2(
                        runtime_evidence.get(IDENTITY_FIELD),
                        expected=p06_identity,
                    )
                    validate_identity_v2(
                        evaluation.get(IDENTITY_FIELD),
                        expected=p06_identity,
                    )
                except ValueError as error:
                    raise P07ExecutionError(
                        "P07 evaluator V2 identity differs"
                    ) from error
            runtime_manifest_sha256 = runtime_evidence.get("manifest_sha256")
            if (
                runtime_manifest_sha256 != _manifest_hash(runtime_evidence)
                or evaluation.get("runtime_evidence_manifest_sha256")
                != runtime_manifest_sha256
                or runtime_evidence.get("measurement_core_sha256")
                != _measurement_core_sha256(evaluation)
                or runtime_evidence.get("configuration_sha256")
                != canonical_sha256(
                    _read_json(
                        self._artifact_path(
                            preflight.release_bundle,
                            "configuration_lock",
                        ),
                        "P07 released configuration lock",
                    )[1]
                )
                or runtime_evidence.get("p06_release_bundle_manifest_sha256")
                != p06_release_bundle_sha256(preflight.release_bundle)
                or runtime_evidence.get("sampling_plan_manifest_sha256")
                != preflight.plan.get("manifest_sha256")
                or runtime_evidence.get("frame_extraction_manifest_sha256")
                != extraction.get("manifest_sha256")
            ):
                raise P07ExecutionError(
                    "P07 runtime evidence identity or measurement cross-link differs"
                )
            cache_snapshot = _directory_file_snapshot(
                self.p07_cache_root,
                "P07 pre-open runtime cache snapshot",
            )
            _validate_declared_tree_snapshot(
                runtime_evidence.get("preopen_cache_snapshot_before")
            )
            _validate_declared_tree_snapshot(
                runtime_evidence.get("preopen_cache_snapshot_after")
            )
            if (
                runtime_evidence.get("preopen_cache_snapshot_before")
                != cache_snapshot
                or runtime_evidence.get("preopen_cache_snapshot_after")
                != cache_snapshot
                or runtime_evidence.get("preopen_cache_unchanged") is not True
            ):
                raise P07ExecutionError(
                    "P07 runtime evidence cache snapshots differ from the pre-open tree"
                )
            loader_verification = runtime_evidence.get(
                "loader_preopen_verification"
            )
            if not isinstance(loader_verification, dict):
                raise P07ExecutionError("P07 loader verification is absent")
            loader_build = loader_verification.get("build")
            reproducibility_build = loader_verification.get(
                "reproducibility_build"
            )
            self_tests = loader_verification.get("self_tests")
            if (
                not isinstance(loader_build, dict)
                or loader_build.get("manifest_sha256")
                != _manifest_hash(loader_build)
                or loader_build.get("executable_sha256")
                != preflight.loader_sha256
                or not isinstance(reproducibility_build, dict)
                or reproducibility_build != loader_build
                or loader_verification.get("builds_byte_identical") is not True
                or not isinstance(self_tests, list)
                or len(self_tests) != 2
                or self_tests[0] != self_tests[1]
                or any(
                    not isinstance(document, dict)
                    or document.get("manifest_sha256")
                    != _manifest_hash(document)
                    for document in self_tests
                )
            ):
                raise P07ExecutionError(
                    "P07 loader build or two-run self-test evidence differs"
                )
            _validate_runtime_case_records(runtime_evidence, evaluation)
            if (
                evaluation.get("artifact_kind")
                != (
                    "p07_spatial_holdout_measurements_v2"
                    if is_v2
                    else "p07_spatial_holdout_measurements"
                )
                or
                evaluation.get("holdout_accessed") is not True
                or evaluation.get("configuration_files_modified_after_holdout") is not False
                or evaluation.get("sampling_plan_manifest_sha256")
                != preflight.plan.get("manifest_sha256")
            ):
                raise P07ExecutionError("P07 evaluator omitted its holdout/configuration status")
            configuration_path = self._artifact_path(
                preflight.release_bundle,
                "configuration_lock",
            )
            _, configuration_lock = _read_json(
                configuration_path,
                "P07 released configuration lock",
            )
            if evaluation.get("configuration_sha256") != canonical_sha256(
                configuration_lock
            ):
                raise P07ExecutionError("P07 measurements use a different configuration lock")
            selected_binding = self._artifact_binding(
                preflight.release_bundle,
                "selected_evaluation",
            )
            selected_path = self._artifact_path(
                preflight.release_bundle,
                "selected_evaluation",
            )
            _, selected_evaluation = _read_json(
                selected_path,
                "P07 selected P06 evaluation",
            )
            if is_v2:
                expected_projection = selected_evaluation_projection_v2(
                    selected_evaluation,
                    identity=p06_identity,
                )
                if evaluation.get(
                    "selected_p06_evidence_projection"
                ) != expected_projection:
                    raise P07ExecutionError(
                        "P07 measurements differ from selected P06 V2 evidence"
                    )
            else:
                performance = selected_evaluation.get("performance")
                if not isinstance(performance, dict):
                    raise P07ExecutionError(
                        "selected P06 performance evidence is absent"
                    )
                expected_performance = {
                    "selected_evaluation_sha256": selected_binding.get("sha256"),
                    "full_frames_per_second": performance.get(
                        "preregistered_production_estimate_frames_per_second"
                    ),
                    "h07_control_frames_per_second": performance.get(
                        "h07_control_estimate_frames_per_second"
                    ),
                    "full_dispatch_cost": performance.get(
                        "preregistered_production_estimate_dispatch_cost"
                    ),
                    "h07_control_dispatch_cost": performance.get(
                        "h07_control_estimate_dispatch_cost"
                    ),
                    "no_worse_frames_per_second": (
                        performance.get(
                            "preregistered_production_estimate_frames_per_second"
                        )
                        >= performance.get(
                            "h07_control_estimate_frames_per_second"
                        )
                        if isinstance(
                            performance.get(
                                "preregistered_production_estimate_frames_per_second"
                            ),
                            (int, float),
                        )
                        and isinstance(
                            performance.get(
                                "h07_control_estimate_frames_per_second"
                            ),
                            (int, float),
                        )
                        else False
                    ),
                    "no_worse_dispatch_cost": (
                        performance.get(
                            "preregistered_production_estimate_dispatch_cost"
                        )
                        <= performance.get(
                            "h07_control_estimate_dispatch_cost"
                        )
                        if isinstance(
                            performance.get(
                                "preregistered_production_estimate_dispatch_cost"
                            ),
                            (int, float),
                        )
                        and isinstance(
                            performance.get(
                                "h07_control_estimate_dispatch_cost"
                            ),
                            (int, float),
                        )
                        else False
                    ),
                }
                if (
                    evaluation.get("locked_p06_performance_evidence")
                    != expected_performance
                ):
                    raise P07ExecutionError(
                        "P07 measurements differ from locked P06 performance"
                    )
            self._validate_measurement_input_bindings(
                preflight=preflight,
                extraction=extraction,
                measurement=evaluation,
            )
            metric_policy_path = self._artifact_path(
                preflight.release_bundle,
                "locked_metric_policy",
            )
            _, metric_policy = _read_json(
                metric_policy_path,
                "P07 locked metric policy",
            )
            from validation.calibration_v2.p07.gate import publish_g07_artifacts

            _write_json(
                publication_directory / "spatial-holdout-measurements.json",
                evaluation,
            )
            _write_json(
                publication_directory / "p07-runtime-evidence.json",
                runtime_evidence,
            )
            gate_publication = publish_g07_artifacts(
                output_directory=publication_directory,
                measurements=evaluation,
                locked_metric_policy=metric_policy,
            )
            _write_json(
                publication_directory / "evaluation-result.json",
                gate_publication,
            )
            _write_new(
                publication_directory / "frame-extraction.json",
                _read_regular_file(
                    extraction_directory / "frame-extraction.json",
                    "P07 frame extraction publication source",
                ),
            )
            result = {
                "inventory_sha256": preflight.attestation["inner_inventory"]["sha256"],
                "frame_extraction_manifest_sha256": extraction["manifest_sha256"],
                "evaluation_sha256": evaluation["measurement_sha256"],
                "runtime_evidence_manifest_sha256": runtime_manifest_sha256,
                "gate_pass": gate_publication["gate_pass"],
            }
            context["phase"] = "authorized_evaluation_complete"
        except BaseException as error:
            self._capture_error_media_context(error)
            primary_error = error

        cleanup_error: Optional[BaseException] = None
        support_revalidation = "not_run"
        mount_detached: Optional[bool] = None
        try:
            context["phase"] = "mount_cleanup_and_revalidation"
            observation = self._authorized_observe_mount(preflight.mount_root)
            if observation.mounted:
                self._authorized_unmount(preflight.mount_root)
            after = self._authorized_observe_mount(preflight.mount_root)
            mount_detached = not after.mounted
            if after.mounted:
                raise P07ExecutionError("holdout remains mounted after evaluation")
            if mount_invoked:
                try:
                    self._verify_preflight_files(preflight)
                    self._verify_direct_input_files(preflight)
                    self._support_aware_release_validation()
                    support_revalidation = "passed"
                except BaseException:
                    support_revalidation = "failed"
                    raise
        except BaseException as error:
            cleanup_error = error
        context["cleanup_result"] = {
            "status": "failed" if cleanup_error is not None else "passed",
            "mount_invoked": mount_invoked,
            "mount_detached": mount_detached,
            "support_revalidation": support_revalidation,
        }

        if cleanup_error is not None:
            if primary_error is not None:
                raise P07DualFailure(primary_error, cleanup_error) from primary_error
            raise cleanup_error
        if primary_error is not None:
            raise primary_error.with_traceback(primary_error.__traceback__)
        if result is None:
            raise P07ExecutionError("P07 authorized evaluation returned no evidence")
        return result

    def _validate_publication(self, directory: Path) -> Mapping[str, str]:
        children = sorted(directory.iterdir(), key=lambda path: path.name)
        if not children:
            raise P07ExecutionError("P07 publication is empty")
        documents = {}
        bindings = {}
        for child in children:
            metadata = os.lstat(child)
            if (
                stat.S_ISLNK(metadata.st_mode)
                or not stat.S_ISREG(metadata.st_mode)
                or child.suffix != ".json"
                or metadata.st_size > MAX_JSON_BYTES
            ):
                raise P07ExecutionError("P07 publication contains unsafe or non-JSON evidence")
            payload, document = _read_json(child, "P07 publication evidence")
            if payload != _canonical_bytes(document) + b"\n":
                raise P07ExecutionError("P07 publication evidence is not canonical JSON")
            documents[child.name] = document
            bindings[child.name] = hashlib.sha256(payload).hexdigest()

        manifest_bindings = _validate_artifact_manifest(
            directory,
            expected_status="complete",
            expected_publication_kind="g07_evidence",
        )
        if bindings != manifest_bindings:
            raise P07ExecutionError(
                "P07 artifact manifest does not bind the reopened publication"
            )

        required_base = {
            ARTIFACT_MANIFEST_NAME,
            "spatial-holdout-measurements.json",
            "spatial-holdout-results.json",
            "paired-bootstrap-results.json",
            "ablation-results.json",
            "g07-decision.json",
            "evaluation-result.json",
            "frame-extraction.json",
            "p07-runtime-evidence.json",
            "p07-execution-result.json",
            AUTHORIZED_EXECUTION_BINDINGS_NAME,
        }
        publication = documents.get("evaluation-result.json")
        if not isinstance(publication, dict):
            raise P07ExecutionError("P07 G07 publication summary is absent")
        is_v2 = publication.get("schema_version") == "2.0.0"
        identity = (
            validate_identity_v2(publication.get(IDENTITY_FIELD))
            if is_v2
            else None
        )
        _validate_schema(
            publication,
            G07_PUBLICATION_V2_SCHEMA if is_v2 else G07_PUBLICATION_SCHEMA,
            "P07 G07 publication summary",
        )
        publication_hash = publication.get("manifest_sha256")
        gate_pass = publication.get("gate_pass")
        gate_bindings = publication.get("artifact_file_sha256")
        if (
            publication.get("artifact_kind")
            != (
                "p07_g07_publication_v2"
                if is_v2
                else "p07_g07_publication"
            )
            or publication_hash != _manifest_hash(publication)
            or not isinstance(gate_pass, bool)
            or publication.get("status") != ("pass" if gate_pass else "fail")
            or not isinstance(gate_bindings, dict)
        ):
            raise P07ExecutionError("P07 G07 publication summary is invalid")
        expected_gate_files = {
            "spatial-holdout-results.json",
            "paired-bootstrap-results.json",
            "ablation-results.json",
            "g07-decision.json",
        }
        if not gate_pass:
            expected_gate_files.add("failed-version-archive.json")
        expected_files = required_base | ({"failed-version-archive.json"} if not gate_pass else set())
        if set(documents) != expected_files or set(gate_bindings) != expected_gate_files:
            raise P07ExecutionError("P07 publication file set differs from the G07 result")
        if any(bindings[name] != digest for name, digest in gate_bindings.items()):
            raise P07ExecutionError("P07 gate artifact file hash changed")

        measurement = documents["spatial-holdout-measurements.json"]
        _validate_schema(
            measurement,
            SCHEMAS_ROOT
            / (
                "p07-spatial-holdout-measurements-v2.schema.json"
                if is_v2
                else "p07-spatial-holdout-measurements-v1.schema.json"
            ),
            "P07 published measurements",
        )
        if is_v2:
            validate_identity_v2(
                measurement.get(IDENTITY_FIELD),
                expected=identity,
            )
        if measurement.get("measurement_sha256") != canonical_sha256(
            {key: value for key, value in measurement.items() if key != "measurement_sha256"}
        ):
            raise P07ExecutionError("P07 published measurement self-hash differs")
        for name in expected_gate_files:
            document = documents[name]
            _validate_schema(
                document,
                SCHEMAS_ROOT
                / (
                    "p07-gate-evidence-v2.schema.json"
                    if is_v2
                    else "p07-gate-evidence-v1.schema.json"
                ),
                "P07 gate artifact",
            )
            if is_v2:
                validate_identity_v2(
                    document.get(IDENTITY_FIELD),
                    expected=identity,
                )
            if document.get("manifest_sha256") != _manifest_hash(document):
                raise P07ExecutionError("P07 gate artifact self-hash differs")
            if document.get("measurement_sha256") != measurement["measurement_sha256"]:
                raise P07ExecutionError("P07 gate artifact measurement binding differs")
        decision = documents["g07-decision.json"]
        if decision.get("evidence", {}).get("pass") is not gate_pass:
            raise P07ExecutionError("P07 decision and publication pass status differ")

        extraction = documents["frame-extraction.json"]
        _validate_schema(extraction, EXTRACTION_SCHEMA, "published P07 frame extraction")
        if extraction.get("manifest_sha256") != _manifest_hash(extraction):
            raise P07ExecutionError("published P07 frame extraction self-hash differs")
        execution = documents["p07-execution-result.json"]
        _validate_schema(
            execution,
            EXECUTION_RESULT_V2_SCHEMA if is_v2 else EXECUTION_RESULT_SCHEMA,
            "published P07 execution result",
        )
        if is_v2:
            validate_identity_v2(
                execution.get(IDENTITY_FIELD),
                expected=identity,
            )
        authorized_payload, authorized_execution = (
            _read_authorized_execution_bindings(
                directory,
                require_bound=True,
            )
        )
        production_fragment = authorized_execution[
            "production_execution_binding_fragment"
        ]
        manifest_top_level = _artifact_manifest_top_level(directory)
        if is_v2:
            validate_identity_v2(
                manifest_top_level.get(IDENTITY_FIELD),
                expected=identity,
            )
            validate_identity_v2(
                authorized_execution.get(IDENTITY_FIELD),
                expected=identity,
            )
            validate_identity_v2(
                production_fragment.get(IDENTITY_FIELD),
                expected=identity,
            )
        if (
            execution.get("artifact_kind")
            != (
                "p07_locked_holdout_execution_v2"
                if is_v2
                else "p07_locked_holdout_execution"
            )
            or execution.get("manifest_sha256") != _manifest_hash(execution)
            or execution.get(
                "authorized_execution_bindings_file_sha256"
            )
            != hashlib.sha256(authorized_payload).hexdigest()
            or execution.get(
                "authorized_execution_bindings_manifest_sha256"
            )
            != authorized_execution.get("manifest_sha256")
            or bindings.get(AUTHORIZED_EXECUTION_BINDINGS_NAME)
            != hashlib.sha256(authorized_payload).hexdigest()
            or production_fragment.get(
                "p06_release_bundle_manifest_sha256"
            )
            != execution.get("release_bundle_manifest_sha256")
            or production_fragment.get("production_writer", {}).get(
                "executable_sha256"
            )
            != production_fragment.get("macos_code_identities", {}).get(
                "production_writer_executable",
                {},
            ).get("file_sha256")
            or production_fragment.get("spawn_policy", {}).get(
                "environment"
            )
            != authorized_execution.get("authorized_environment")
            or manifest_top_level.get("configuration_id")
            != execution.get("configuration_id")
            or manifest_top_level.get("configuration_sha256")
            != execution.get("configuration_sha256")
            or manifest_top_level.get("release_bundle_manifest_sha256")
            != execution.get("release_bundle_manifest_sha256")
            or manifest_top_level.get("sampling_plan_manifest_sha256")
            != execution.get("sampling_plan_manifest_sha256")
            or manifest_top_level.get("sampling_plan_manifest_sha256")
            != extraction.get("sampling_plan_manifest_sha256")
            or manifest_top_level.get("holdout_accessed") is not True
            or manifest_top_level.get("holdout_access_consumed") is not True
            or execution.get("evaluation_sha256") != measurement["measurement_sha256"]
            or execution.get("g07_gate_pass") is not gate_pass
            or execution.get("holdout_access_consumed") is not True
            or execution.get("holdout_access_state") != "completed"
            or execution.get("holdout_access_evidence_source")
            != "live_guard_ledger"
            or execution.get("holdout_access_ledger_event_order")
            != ["sealed", "open_intent", "opened", "completed"]
            or execution.get("holdout_access_ledger_event_count") != 4
            or execution.get("holdout_access_configuration_sha256")
            != execution.get("configuration_sha256")
            or execution.get("holdout_access_open_intent_linked") is not True
            or execution.get("holdout_access_ledger_verification_error_sha256")
            is not None
            or not _is_sha256(
                execution.get("holdout_access_ledger_file_sha256")
            )
            or not _is_sha256(
                execution.get("holdout_access_ledger_tip_sha256")
            )
            or not _is_sha256(
                execution.get("holdout_access_immutable_anchor_file_sha256")
            )
        ):
            raise P07ExecutionError("P07 execution result is invalid or stale")
        runtime_evidence = documents["p07-runtime-evidence.json"]
        _validate_schema(
            runtime_evidence,
            RUNTIME_EVIDENCE_V2_SCHEMA if is_v2 else RUNTIME_EVIDENCE_SCHEMA,
            "published P07 runtime evidence",
        )
        if is_v2:
            validate_identity_v2(
                runtime_evidence.get(IDENTITY_FIELD),
                expected=identity,
            )
        if (
            runtime_evidence.get("manifest_sha256")
            != _manifest_hash(runtime_evidence)
            or measurement.get("runtime_evidence_manifest_sha256")
            != runtime_evidence.get("manifest_sha256")
            or execution.get("runtime_evidence_manifest_sha256")
            != runtime_evidence.get("manifest_sha256")
            or runtime_evidence.get("measurement_core_sha256")
            != _measurement_core_sha256(measurement)
            or runtime_evidence.get("configuration_sha256")
            != measurement.get("configuration_sha256")
            or runtime_evidence.get("configuration_sha256")
            != execution.get("configuration_sha256")
            or runtime_evidence.get("p06_release_bundle_manifest_sha256")
            != execution.get("release_bundle_manifest_sha256")
            or runtime_evidence.get("sampling_plan_manifest_sha256")
            != extraction.get("sampling_plan_manifest_sha256")
            or runtime_evidence.get("frame_extraction_manifest_sha256")
            != extraction.get("manifest_sha256")
            or runtime_evidence.get("preopen_cache_snapshot_before")
            != runtime_evidence.get("preopen_cache_snapshot_after")
            or runtime_evidence.get("preopen_cache_unchanged") is not True
            or runtime_evidence.get("loader_preopen_verification", {})
            .get("build", {})
            .get("executable_sha256")
            != execution.get("loader_executable_sha256")
        ):
            raise P07ExecutionError(
                "P07 runtime evidence is stale, substituted, or cross-link invalid"
            )
        published_loader = runtime_evidence.get("loader_preopen_verification")
        if not isinstance(published_loader, dict) or (
            published_loader.get("reproducibility_build")
            != published_loader.get("build")
            or published_loader.get("builds_byte_identical") is not True
            or published_loader.get("self_tests_byte_identical") is not True
            or not isinstance(published_loader.get("self_tests"), list)
            or len(published_loader["self_tests"]) != 2
            or published_loader["self_tests"][0]
            != published_loader["self_tests"][1]
        ):
            raise P07ExecutionError(
                "P07 loader reproducibility evidence differs after publication"
            )
        _validate_declared_tree_snapshot(
            runtime_evidence.get("preopen_cache_snapshot_before")
        )
        _validate_declared_tree_snapshot(
            runtime_evidence.get("preopen_cache_snapshot_after")
        )
        _validate_runtime_case_records(runtime_evidence, measurement)
        return bindings

    def _finalize_success_transaction(
        self,
        *,
        workspace: _P07TransactionWorkspace,
        output_directory: Path,
        guard: object,
        guard_evidence: Mapping[str, object],
        result: Optional[Mapping[str, object]],
        configuration_lock: Mapping[str, object],
    ) -> Mapping[str, object]:
        intent = workspace.intent
        configuration_sha256 = str(intent["configuration_sha256"])
        if (
            guard_evidence.get("holdout_access_consumed") is not True
            or guard_evidence.get("holdout_access_state") != "completed"
            or guard_evidence.get("holdout_access_evidence_source")
            != "live_guard_ledger"
            or guard_evidence.get("holdout_access_ledger_event_order")
            != ["sealed", "open_intent", "opened", "completed"]
            or guard_evidence.get("holdout_access_ledger_event_count") != 4
            or guard_evidence.get("holdout_access_configuration_sha256")
            != configuration_sha256
            or guard_evidence.get("holdout_access_open_intent_linked") is not True
            or guard_evidence.get(
                "holdout_access_ledger_verification_error_sha256"
            )
            is not None
            or not _is_sha256(
                guard_evidence.get("holdout_access_ledger_file_sha256")
            )
            or not _is_sha256(
                guard_evidence.get("holdout_access_ledger_tip_sha256")
            )
            or not _is_sha256(
                guard_evidence.get(
                    "holdout_access_immutable_anchor_file_sha256"
                )
            )
        ):
            raise P07ExecutionError(
                "completed guard ledger or immutable anchor evidence is invalid"
            )
        workspace.verify()
        publication_directory = workspace.path / "publication"
        publication_opened = workspace.child_descriptor("publication")
        assert publication_opened is not None
        publication_descriptor, publication_identity = publication_opened
        os.close(publication_descriptor)
        if result is None:
            _, extraction = _read_json(
                publication_directory / "frame-extraction.json",
                "recoverable P07 frame extraction",
            )
            _, measurement = _read_json(
                publication_directory / "spatial-holdout-measurements.json",
                "recoverable P07 measurement",
            )
            _, runtime = _read_json(
                publication_directory / "p07-runtime-evidence.json",
                "recoverable P07 runtime evidence",
            )
            _, gate = _read_json(
                publication_directory / "evaluation-result.json",
                "recoverable P07 gate publication",
            )
            result = {
                "inventory_sha256": intent["inner_inventory_sha256"],
                "frame_extraction_manifest_sha256": extraction.get(
                    "manifest_sha256"
                ),
                "evaluation_sha256": measurement.get("measurement_sha256"),
                "runtime_evidence_manifest_sha256": runtime.get(
                    "manifest_sha256"
                ),
                "gate_pass": gate.get("gate_pass"),
            }
        authorized_execution_document = (
            _authorized_execution_publication_document(
                intent.get("authorized_execution_bindings")
            )
        )
        (
            authorized_execution_file_sha256,
            authorized_execution_manifest_sha256,
        ) = _write_authorized_execution_bindings(
            publication_directory,
            authorized_execution_document,
            require_bound=True,
        )
        is_v2 = intent.get("schema_version") == "2.0.0"
        identity = (
            validate_identity_v2(intent.get(IDENTITY_FIELD))
            if is_v2
            else None
        )
        execution = {
            "schema_version": "2.0.0" if is_v2 else "1.0.0",
            "artifact_kind": (
                "p07_locked_holdout_execution_v2"
                if is_v2
                else "p07_locked_holdout_execution"
            ),
            **(
                {IDENTITY_FIELD: dict(identity)}
                if identity is not None
                else {}
            ),
            "status": "complete",
            "configuration_sha256": configuration_sha256,
            "configuration_id": intent["configuration_id"],
            "release_bundle_manifest_sha256": intent[
                "release_bundle_manifest_sha256"
            ],
            "input_bundle_sha256": intent["input_bundle_sha256"],
            "direct_input_bindings": list(intent["direct_input_bindings"]),
            "corpus_lock_bundle_sha256": intent["corpus_lock_bundle_sha256"],
            "sampling_plan_file_sha256": intent[
                "sampling_plan_file_sha256"
            ],
            "sampling_plan_manifest_sha256": intent[
                "sampling_plan_manifest_sha256"
            ],
            "no_pixel_attestation_file_sha256": intent[
                "no_pixel_attestation_file_sha256"
            ],
            "loader_executable_sha256": intent["loader_executable_sha256"],
            "authorized_execution_bindings_file_sha256": (
                authorized_execution_file_sha256
            ),
            "authorized_execution_bindings_manifest_sha256": (
                authorized_execution_manifest_sha256
            ),
            "p07_preopen_cache_tree_sha256": intent[
                "p07_preopen_cache_tree_sha256"
            ],
            "inner_inventory_sha256": result.get("inventory_sha256"),
            "frame_extraction_manifest_sha256": result.get(
                "frame_extraction_manifest_sha256"
            ),
            "evaluation_sha256": result.get("evaluation_sha256"),
            "runtime_evidence_manifest_sha256": result.get(
                "runtime_evidence_manifest_sha256"
            ),
            "g07_gate_pass": result.get("gate_pass"),
            "support_evidence_revalidated_after_evaluation": True,
            "direct_p06_inputs_revalidated_after_evaluation": True,
            "mount_detached_before_publication": True,
            "temporary_nv12_crops_published": False,
            "holdout_accessed": True,
            "configuration_files_modified_after_holdout": False,
            **dict(guard_evidence),
        }
        execution["manifest_sha256"] = canonical_sha256(execution)
        _validate_schema(
            execution,
            EXECUTION_RESULT_V2_SCHEMA if is_v2 else EXECUTION_RESULT_SCHEMA,
            "P07 execution result",
        )
        execution_path = publication_directory / "p07-execution-result.json"
        if os.path.lexists(execution_path):
            _, existing_execution = _read_json(
                execution_path,
                "recoverable P07 execution result",
            )
            if existing_execution != execution:
                raise P07ExecutionError(
                    "recoverable P07 execution result differs"
                )
        else:
            _write_json(execution_path, execution)
        manifest_path = publication_directory / ARTIFACT_MANIFEST_NAME
        if not os.path.lexists(manifest_path):
            _write_artifact_manifest(
                publication_directory,
                status="complete",
                publication_kind="g07_evidence",
                configuration_id=str(intent["configuration_id"]),
                configuration_sha256=configuration_sha256,
                release_bundle_manifest_sha256=str(
                    intent["release_bundle_manifest_sha256"]
                ),
                sampling_plan_manifest_sha256=str(
                    intent["sampling_plan_manifest_sha256"]
                ),
                holdout_accessed=True,
                holdout_access_consumed=True,
                command=str(intent["command"]),
                platform=str(intent["platform"]),
                p06_v2_identity=identity,
            )
        evidence_bindings = self._validate_publication(publication_directory)
        self._validate_terminal_invocation_binding(
            directory=publication_directory,
            configuration_lock=configuration_lock,
            guard=guard,
        )
        workspace.remove_child("extraction")
        self._transaction_context["raw_workspace_cleaned"] = True
        workspace.verify()
        final_guard_evidence = self._guard_access_evidence(
            guard,
            known_consumed=True,
            configuration_sha256=configuration_sha256,
        )
        if final_guard_evidence != guard_evidence:
            raise P07ExecutionError(
                "completed guard ledger or immutable anchor changed before publication"
            )
        self._transaction_context["publication_validated"] = True
        self._transaction_context["phase"] = "exclusive_publication"
        if os.path.lexists(output_directory):
            published_bindings = self._validate_publication(output_directory)
            if published_bindings != evidence_bindings:
                raise P07ExecutionError(
                    "existing terminal P07 publication differs from transaction"
                )
        else:
            try:
                _publish_directory_exclusive(
                    publication_directory,
                    output_directory,
                    progress=self._transaction_context,
                    destination_parent_pin=(
                        workspace.parent_descriptor,
                        workspace.parent_identity,
                    ),
                )
            except FileExistsError as publication_error:
                raise P07ExecutionError(
                    "exclusive P07 publication destination already exists"
                ) from publication_error
            published_bindings = self._validate_publication(output_directory)
            if published_bindings != evidence_bindings:
                raise P07ExecutionError(
                    "published P07 evidence bindings changed after parent sync"
                )
        manifest_top_level = _artifact_manifest_top_level(output_directory)
        self._transaction_context["phase"] = "publication_complete"
        workspace.destroy()
        return {
            **execution,
            "published_evidence_file_sha256": published_bindings,
            "artifact_manifest_sha256": manifest_top_level[
                "manifest_sha256"
            ],
            "artifact_manifest_top_level": manifest_top_level,
            "output_directory": os.fspath(output_directory),
        }

    def _publish_pre_guard_failure(
        self,
        *,
        output_directory: Path,
        output_parent_pin: tuple[int, os.stat_result],
        configuration_lock: Mapping[str, object],
        error: BaseException,
    ) -> Path:
        message = str(error)
        traceback_text = "".join(
            traceback.TracebackException.from_exception(error).format(chain=True)
        )
        machine = os.uname()
        command = str(
            getattr(
                self,
                "publication_command",
                "direct P07HoldoutExecutor.execute_once invocation",
            )
        )
        platform = str(
            getattr(
                self,
                "publication_platform",
                "{} {} {}".format(
                    machine.sysname,
                    machine.release,
                    machine.machine,
                ),
            )
        )
        release_manifest: Optional[str] = None
        configuration_id: Optional[str] = None
        try:
            _, release = _read_json(
                self.p06_release_manifest_path,
                "P07 pre-guard release manifest",
            )
            release_manifest = p06_release_bundle_sha256(release)
            raw_id = release.get("configuration_id")
            if isinstance(raw_id, str) and raw_id:
                configuration_id = raw_id
        except BaseException:
            pass
        sampling_manifest: Optional[str] = None
        try:
            _, plan = _read_json(
                self.sampling_plan_path,
                "P07 pre-guard sampling plan",
            )
            if plan.get("manifest_sha256") == _manifest_hash(plan):
                sampling_manifest = str(plan["manifest_sha256"])
        except BaseException:
            pass
        cache_hash: Optional[str] = None
        try:
            self._validate_cache_isolation()
            cache_hash = _directory_tree_sha256(
                self.p07_cache_root,
                "P07 pre-guard cache tree",
            )
        except BaseException:
            pass
        access_evidence = {
            "holdout_access_consumed": False,
            "holdout_access_state": "sealed",
            "holdout_access_evidence_source": "pre_guard_validation",
            "holdout_access_ledger_file_sha256": None,
            "holdout_access_ledger_tip_sha256": None,
            "holdout_access_ledger_event_count": None,
            "holdout_access_ledger_event_order": None,
            "holdout_access_configuration_sha256": None,
            "holdout_access_immutable_anchor_file_sha256": None,
            "holdout_access_open_intent_linked": None,
            "holdout_access_ledger_verification_error_sha256": None,
        }
        transaction_state = {
            "phase": "pre_guard_validation",
            "guard_returned": False,
            "publication_validated": False,
            "publication_renamed": False,
            "parent_directory_synced": False,
        }
        cleanup = {
            "status": "not_started",
            "mount_invoked": False,
            "mount_detached": None,
            "support_revalidation": "not_run",
        }
        failure_log = {
            "schema_version": "1.0.0",
            "artifact_kind": "p07_failure_log",
            "status": "failed",
            "failure_type": type(error).__name__,
            "failure_message": message,
            "failure_message_sha256": hashlib.sha256(
                message.encode("utf-8", "strict")
            ).hexdigest(),
            "failure_traceback": traceback_text,
            "failure_traceback_sha256": hashlib.sha256(
                traceback_text.encode("utf-8", "strict")
            ).hexdigest(),
            "secondary_failure": None,
            "archive_publication_failure": None,
            "failure_stage": "pre_guard_validation",
            "transaction_state": transaction_state,
            "cleanup_result": cleanup,
            "media_asset_id": None,
            "media_case_id": None,
            "frame_index": None,
            "presentation_timestamp": None,
            "media_context_available": False,
            "requested_output_directory": os.fspath(output_directory),
            "temporary_run_path": None,
            "holdout_access_consumed": False,
            "command": command,
            "platform": platform,
        }
        failure_log["manifest_sha256"] = _manifest_hash(failure_log)
        _validate_schema(failure_log, FAILURE_LOG_SCHEMA, "P07 failure log")
        staging = _pre_guard_failure_staging_path(output_directory)
        if os.path.lexists(staging):
            _validate_failure_publication(staging)
        else:
            os.mkdir(staging, 0o700)
            _write_json(staging / FAILURE_LOG_NAME, failure_log)
            log_payload = _read_regular_file(
                staging / FAILURE_LOG_NAME,
                "P07 pre-guard failure log",
            )
            authorized_context = getattr(
                self,
                "_authorized_execution_context",
                None,
            )
            authorized_value = (
                authorized_context.binding_document()
                if isinstance(
                    authorized_context,
                    _AuthorizedExecutionContext,
                )
                and authorized_context.production_execution_binding_fragment
                is not None
                else None
            )
            (
                authorized_execution_file_sha256,
                authorized_execution_manifest_sha256,
            ) = _write_authorized_execution_bindings(
                staging,
                _authorized_execution_publication_document(
                    authorized_value
                ),
                require_bound=False,
            )
            archive = {
                "schema_version": "1.1.0",
                "artifact_kind": "p07_execution_failure_archive",
                "status": "failed",
                "configuration_id": configuration_id,
                "configuration_sha256": canonical_sha256(configuration_lock),
                "release_bundle_manifest_sha256": release_manifest,
                "input_bundle_sha256": None,
                "direct_input_bindings": None,
                "corpus_lock_bundle_sha256": None,
                "sampling_plan_file_sha256": self.expected_sampling_plan_sha256,
                "sampling_plan_manifest_sha256": sampling_manifest,
                "no_pixel_attestation_file_sha256": (
                    self.expected_no_pixel_attestation_sha256
                ),
                "outer_wrapper_file_sha256": None,
                "outer_wrapper_manifest_sha256": None,
                "loader_executable_sha256": self.expected_loader_sha256,
                "authorized_execution_bindings_file_sha256": (
                    authorized_execution_file_sha256
                ),
                "authorized_execution_bindings_manifest_sha256": (
                    authorized_execution_manifest_sha256
                ),
                "p07_preopen_cache_tree_sha256": cache_hash,
                **{
                    field: failure_log[field]
                    for field in (
                        "failure_type",
                        "failure_message",
                        "failure_message_sha256",
                        "failure_traceback",
                        "failure_traceback_sha256",
                        "secondary_failure",
                        "archive_publication_failure",
                        "failure_stage",
                        "transaction_state",
                        "cleanup_result",
                        "media_asset_id",
                        "media_case_id",
                        "frame_index",
                        "presentation_timestamp",
                        "media_context_available",
                        "requested_output_directory",
                        "temporary_run_path",
                        "command",
                        "platform",
                    )
                },
                "failure_log_file_sha256": hashlib.sha256(log_payload).hexdigest(),
                **access_evidence,
                "result_reusable_for_same_version": False,
            }
            archive["manifest_sha256"] = _manifest_hash(archive)
            _validate_schema(
                archive,
                SCHEMAS_ROOT / "p07-execution-failure-v1.schema.json",
                "P07 pre-guard failure archive",
            )
            _write_json(staging / "failed-version-archive.json", archive)
            _write_artifact_manifest(
                staging,
                status="failed",
                publication_kind="execution_failure",
                configuration_id=configuration_id,
                configuration_sha256=canonical_sha256(configuration_lock),
                release_bundle_manifest_sha256=release_manifest,
                sampling_plan_manifest_sha256=sampling_manifest,
                holdout_accessed=False,
                holdout_access_consumed=False,
                command=command,
                platform=platform,
            )
            _validate_failure_publication(staging)
        preferred = (
            output_directory
            if not os.path.lexists(output_directory)
            else output_directory.with_name(output_directory.name + ".failed")
        )
        _publish_directory_exclusive(
            staging,
            preferred,
            destination_parent_pin=output_parent_pin,
        )
        _validate_failure_publication(preferred)
        return preferred

    def _publish_failure(
        self,
        *,
        output_directory: Path,
        preflight: P07Preflight,
        configuration_lock: Mapping[str, object],
        error: BaseException,
        failure_stage: str,
        access_evidence: Mapping[str, object],
    ) -> Path:
        identity = _preflight_p06_v2_identity(preflight)
        is_v2 = identity is not None
        command = str(
            getattr(
                self,
                "publication_command",
                "direct P07HoldoutExecutor.execute_once invocation",
            )
        )
        machine = os.uname()
        platform = str(
            getattr(
                self,
                "publication_platform",
                "{} {} {}".format(
                    machine.sysname,
                    machine.release,
                    machine.machine,
                ),
            )
        )
        raw_context = getattr(self, "_transaction_context", {})
        if not isinstance(raw_context, dict):
            raw_context = {}
        transaction_state = {
            "phase": str(raw_context.get("phase", failure_stage)),
            "guard_returned": raw_context.get("guard_returned") is True,
            "publication_validated": (
                raw_context.get("publication_validated") is True
            ),
            "publication_renamed": raw_context.get("publication_renamed") is True,
            "parent_directory_synced": (
                raw_context.get("parent_directory_synced") is True
            ),
        }
        cleanup = raw_context.get("cleanup_result")
        if not isinstance(cleanup, dict) or set(cleanup) != {
            "status",
            "mount_invoked",
            "mount_detached",
            "support_revalidation",
        }:
            cleanup = {
                "status": "unknown",
                "mount_invoked": False,
                "mount_detached": None,
                "support_revalidation": "unknown",
            }
        frame_index = raw_context.get("frame_index")
        if not isinstance(frame_index, int) or isinstance(frame_index, bool):
            frame_index = None
        timestamp = raw_context.get("presentation_timestamp")
        if not isinstance(timestamp, dict):
            timestamp = None
        media_asset_id = raw_context.get("media_asset_id")
        if not isinstance(media_asset_id, str) or not media_asset_id:
            media_asset_id = None
        media_case_id = raw_context.get("media_case_id")
        if not isinstance(media_case_id, str) or not media_case_id:
            media_case_id = None
        media_context_available = any(
            value is not None
            for value in (
                media_asset_id,
                media_case_id,
                frame_index,
                timestamp,
            )
        )
        temporary_run_path = raw_context.get("temporary_run_path")
        if not isinstance(temporary_run_path, str) or not temporary_run_path.startswith(
            "/"
        ):
            temporary_run_path = None
        evidence_error = (
            error.primary_error
            if isinstance(error, P07DualFailure)
            else error
        )
        message = str(evidence_error)
        message_sha256 = hashlib.sha256(
            message.encode("utf-8", "strict")
        ).hexdigest()
        traceback_text = "".join(
            traceback.TracebackException.from_exception(evidence_error).format(
                chain=True
            )
        )
        traceback_sha256 = hashlib.sha256(
            traceback_text.encode("utf-8", "strict")
        ).hexdigest()
        secondary_failure: Optional[Mapping[str, object]] = None
        if isinstance(error, P07DualFailure):
            secondary_message = str(error.cleanup_error)
            secondary_traceback = "".join(
                traceback.TracebackException.from_exception(
                    error.cleanup_error
                ).format(chain=True)
            )
            secondary_failure = {
                "role": "mount_cleanup_and_revalidation",
                "failure_type": type(error.cleanup_error).__name__,
                "failure_message": secondary_message,
                "failure_message_sha256": hashlib.sha256(
                    secondary_message.encode("utf-8", "strict")
                ).hexdigest(),
                "failure_traceback": secondary_traceback,
                "failure_traceback_sha256": hashlib.sha256(
                    secondary_traceback.encode("utf-8", "strict")
                ).hexdigest(),
            }
        failure_log = {
            "schema_version": "2.0.0" if is_v2 else "1.0.0",
            "artifact_kind": (
                "p07_failure_log_v2" if is_v2 else "p07_failure_log"
            ),
            **(
                {IDENTITY_FIELD: dict(identity)}
                if identity is not None
                else {}
            ),
            "status": "failed",
            "failure_type": type(evidence_error).__name__,
            "failure_message": message,
            "failure_message_sha256": message_sha256,
            "failure_traceback": traceback_text,
            "failure_traceback_sha256": traceback_sha256,
            "secondary_failure": secondary_failure,
            "archive_publication_failure": None,
            "failure_stage": failure_stage,
            "transaction_state": transaction_state,
            "cleanup_result": dict(cleanup),
            "media_asset_id": media_asset_id,
            "media_case_id": media_case_id,
            "frame_index": frame_index,
            "presentation_timestamp": timestamp,
            "media_context_available": media_context_available,
            "requested_output_directory": os.fspath(output_directory),
            "temporary_run_path": temporary_run_path,
            "holdout_access_consumed": access_evidence.get(
                "holdout_access_consumed"
            ),
            "command": command,
            "platform": platform,
        }
        failure_log["manifest_sha256"] = _manifest_hash(failure_log)
        _validate_schema(
            failure_log,
            FAILURE_LOG_V2_SCHEMA if is_v2 else FAILURE_LOG_SCHEMA,
            "P07 failure log",
        )

        workspace = getattr(self, "_active_workspace", None)
        if isinstance(workspace, _P07TransactionWorkspace):
            seed = {
                "schema_version": "2.0.0" if is_v2 else "1.0.0",
                "artifact_kind": (
                    "p07_emergency_failure_seed_v2"
                    if is_v2
                    else "p07_emergency_failure_seed"
                ),
                **(
                    {IDENTITY_FIELD: dict(identity)}
                    if identity is not None
                    else {}
                ),
                "failure_log": failure_log,
                "access_evidence": dict(access_evidence),
                "configuration_id": preflight.release_bundle[
                    "configuration_id"
                ],
                "configuration_sha256": canonical_sha256(configuration_lock),
                "release_bundle_manifest_sha256": p06_release_bundle_sha256(
                    preflight.release_bundle
                ),
                "input_bundle_sha256": preflight.input_bundle_sha256,
                "direct_input_bindings": [
                    {
                        "id": record["id"],
                        "path": record["path"],
                        "sha256": record["sha256"],
                        "size_bytes": record["size_bytes"],
                    }
                    for record in preflight.input_records
                ],
                "corpus_lock_bundle_sha256": preflight.corpus_lock_bundle_sha256,
                "sampling_plan_file_sha256": preflight.plan_file_sha256,
                "sampling_plan_manifest_sha256": preflight.plan[
                    "manifest_sha256"
                ],
                "no_pixel_attestation_file_sha256": (
                    preflight.attestation_file_sha256
                ),
                "outer_wrapper_file_sha256": preflight.outer_wrapper_file_sha256,
                "outer_wrapper_manifest_sha256": preflight.outer_wrapper[
                    "manifest_sha256"
                ],
                "loader_executable_sha256": preflight.loader_sha256,
                "p07_preopen_cache_tree_sha256": (
                    preflight.p07_cache_tree_sha256
                ),
                "authorized_execution_bindings": (
                    _authorized_execution_publication_document(
                        preflight.authorized_execution_bindings
                    )
                ),
            }
            seed["manifest_sha256"] = _manifest_hash(seed)
            workspace.write_emergency_seed(seed)

        parent = output_directory.parent
        _validate_existing_path(parent, label="P07 output parent", kind="directory")
        staging = (
            nullcontext(os.fspath(workspace.prepare_empty_child("failure")))
            if isinstance(workspace, _P07TransactionWorkspace)
            else tempfile.TemporaryDirectory(
                prefix=".p07-failure-publication-",
                dir=parent,
            )
        )
        with staging as temporary_name:
            private = Path(temporary_name)
            _write_json(private / FAILURE_LOG_NAME, failure_log)
            failure_log_file_sha256 = hashlib.sha256(
                _read_regular_file(private / FAILURE_LOG_NAME, "P07 failure log")
            ).hexdigest()
            (
                authorized_execution_file_sha256,
                authorized_execution_manifest_sha256,
            ) = _write_authorized_execution_bindings(
                private,
                _authorized_execution_publication_document(
                    preflight.authorized_execution_bindings
                ),
                require_bound=(failure_stage != "pre_guard_validation"),
            )
            document = {
                "schema_version": "2.0.0" if is_v2 else "1.1.0",
                "artifact_kind": (
                    "p07_execution_failure_archive_v2"
                    if is_v2
                    else "p07_execution_failure_archive"
                ),
                **(
                    {IDENTITY_FIELD: dict(identity)}
                    if identity is not None
                    else {}
                ),
                "status": "failed",
                "configuration_id": preflight.release_bundle["configuration_id"],
                "configuration_sha256": canonical_sha256(configuration_lock),
                "release_bundle_manifest_sha256": p06_release_bundle_sha256(
                    preflight.release_bundle
                ),
                "input_bundle_sha256": preflight.input_bundle_sha256,
                "direct_input_bindings": [
                    {
                        "id": record["id"],
                        "path": record["path"],
                        "sha256": record["sha256"],
                        "size_bytes": record["size_bytes"],
                    }
                    for record in preflight.input_records
                ],
                "corpus_lock_bundle_sha256": preflight.corpus_lock_bundle_sha256,
                "sampling_plan_file_sha256": preflight.plan_file_sha256,
                "sampling_plan_manifest_sha256": preflight.plan["manifest_sha256"],
                "no_pixel_attestation_file_sha256": (
                    preflight.attestation_file_sha256
                ),
                "outer_wrapper_file_sha256": preflight.outer_wrapper_file_sha256,
                "outer_wrapper_manifest_sha256": preflight.outer_wrapper[
                    "manifest_sha256"
                ],
                "loader_executable_sha256": preflight.loader_sha256,
                "authorized_execution_bindings_file_sha256": (
                    authorized_execution_file_sha256
                ),
                "authorized_execution_bindings_manifest_sha256": (
                    authorized_execution_manifest_sha256
                ),
                "p07_preopen_cache_tree_sha256": preflight.p07_cache_tree_sha256,
                "failure_type": type(evidence_error).__name__,
                "failure_message": message,
                "failure_message_sha256": message_sha256,
                "failure_traceback": traceback_text,
                "failure_traceback_sha256": traceback_sha256,
                "secondary_failure": secondary_failure,
                "archive_publication_failure": None,
                "failure_log_file_sha256": failure_log_file_sha256,
                "failure_stage": failure_stage,
                "transaction_state": transaction_state,
                "cleanup_result": dict(cleanup),
                "media_asset_id": media_asset_id,
                "media_case_id": media_case_id,
                "frame_index": frame_index,
                "presentation_timestamp": timestamp,
                "media_context_available": media_context_available,
                "requested_output_directory": os.fspath(output_directory),
                "temporary_run_path": temporary_run_path,
                "command": command,
                "platform": platform,
                **dict(access_evidence),
                "result_reusable_for_same_version": False,
            }
            document["manifest_sha256"] = _manifest_hash(document)
            _validate_schema(
                document,
                (
                    EXECUTION_FAILURE_V2_SCHEMA
                    if is_v2
                    else SCHEMAS_ROOT
                    / "p07-execution-failure-v1.schema.json"
                ),
                "P07 execution failure archive",
            )
            _write_json(private / "failed-version-archive.json", document)
            holdout_accessed = (
                access_evidence.get("holdout_access_consumed") is True
                or access_evidence.get("holdout_access_state")
                in {"anchor_only", "opened", "completed", "failed"}
                or transaction_state["guard_returned"] is True
                or cleanup.get("mount_invoked") is True
            )
            _write_artifact_manifest(
                private,
                status="failed",
                publication_kind="execution_failure",
                configuration_id=str(preflight.release_bundle["configuration_id"]),
                configuration_sha256=canonical_sha256(configuration_lock),
                release_bundle_manifest_sha256=p06_release_bundle_sha256(
                    preflight.release_bundle
                ),
                sampling_plan_manifest_sha256=str(
                    preflight.plan["manifest_sha256"]
                ),
                holdout_accessed=holdout_accessed,
                holdout_access_consumed=access_evidence.get(
                    "holdout_access_consumed"
                ),
                command=command,
                platform=platform,
                p06_v2_identity=identity,
            )
            _validate_failure_publication(private)
            if isinstance(workspace, _P07TransactionWorkspace):
                workspace.remove_child("extraction")
                self._transaction_context["raw_workspace_cleaned"] = True
            preferred = (
                output_directory
                if not os.path.lexists(output_directory)
                else output_directory.with_name(output_directory.name + ".failed")
            )
            destination_pin = (
                (workspace.parent_descriptor, workspace.parent_identity)
                if isinstance(workspace, _P07TransactionWorkspace)
                else None
            )
            try:
                _publish_directory_exclusive(
                    private,
                    preferred,
                    destination_parent_pin=destination_pin,
                )
            except FileExistsError:
                if preferred != output_directory:
                    raise P07ExecutionError(
                        "exclusive P07 failure destination already exists"
                    )
                preferred = output_directory.with_name(
                    output_directory.name + ".failed"
                )
                try:
                    _publish_directory_exclusive(
                        private,
                        preferred,
                        destination_parent_pin=destination_pin,
                    )
                except FileExistsError as publication_error:
                    raise P07ExecutionError(
                        "exclusive P07 failure destination already exists"
                    ) from publication_error
            _validate_failure_publication(preferred)
            return preferred

    def _guard_access_evidence(
        self,
        guard: object,
        *,
        known_consumed: Optional[bool],
        configuration_sha256: str,
    ) -> Mapping[str, object]:
        """Return exact authoritative live-ledger state when readable, else a bound fallback."""

        unavailable = {
            "holdout_access_consumed": known_consumed,
            "holdout_access_state": "unavailable",
            "holdout_access_evidence_source": (
                "guard_return" if known_consumed is not None else "unavailable"
            ),
            "holdout_access_ledger_file_sha256": None,
            "holdout_access_ledger_tip_sha256": None,
            "holdout_access_ledger_event_count": None,
            "holdout_access_ledger_event_order": None,
            "holdout_access_configuration_sha256": None,
            "holdout_access_immutable_anchor_file_sha256": None,
            "holdout_access_open_intent_linked": None,
            "holdout_access_ledger_verification_error_sha256": None,
        }
        ledger_path = getattr(guard, "ledger_path", None)
        if not isinstance(ledger_path, Path) or not ledger_path.is_absolute():
            return unavailable
        try:
            payload, ledger = _read_json(
                ledger_path,
                "P07 authoritative live guard ledger",
            )
            state = ledger.get("state")
            expected_sequences = {
                "sealed": ["sealed"],
                "intent_recorded": ["sealed", "open_intent"],
                "opened": ["sealed", "open_intent", "opened"],
                "completed": ["sealed", "open_intent", "opened", "completed"],
                "failed": [
                    "sealed",
                    "open_intent",
                    "opened",
                    "failed_after_open",
                ],
            }
            events = ledger.get("events")
            if state not in expected_sequences or not isinstance(events, list):
                raise P07ExecutionError("guard ledger state or events are invalid")
            previous = "0" * SHA256_LENGTH
            names = []
            for index, event in enumerate(events):
                if not isinstance(event, dict):
                    raise P07ExecutionError("guard ledger event is not an object")
                expected = canonical_sha256(
                    {
                        key: value
                        for key, value in event.items()
                        if key != "entry_sha256"
                    }
                )
                if (
                    event.get("sequence") != index
                    or event.get("previous_entry_sha256") != previous
                    or event.get("entry_sha256") != expected
                ):
                    raise P07ExecutionError("guard ledger hash chain is invalid")
                previous = expected
                names.append(event.get("event"))
            if names != expected_sequences[state]:
                raise P07ExecutionError("guard ledger transition sequence is invalid")
            anchor_path = getattr(guard, "anchor_path", None)
            anchor_exists = (
                isinstance(anchor_path, Path)
                and anchor_path.is_absolute()
                and os.path.lexists(anchor_path)
            )
            if state == "sealed" and anchor_exists:
                unavailable.update(
                    {
                        "holdout_access_consumed": True,
                        "holdout_access_state": "anchor_only",
                        "holdout_access_evidence_source": (
                            "anchor_only_guard_evidence"
                        ),
                        "holdout_access_ledger_file_sha256": hashlib.sha256(
                            payload
                        ).hexdigest(),
                        "holdout_access_ledger_tip_sha256": previous,
                        "holdout_access_ledger_event_count": len(events),
                        "holdout_access_ledger_event_order": names,
                    }
                )
                anchor_payload, anchor = _read_json(
                    anchor_path,
                    "P07 anchor-only guard evidence",
                )
                linked_configuration_sha256 = _require_sha256(
                    anchor.get("configuration_sha256"),
                    "anchor-only guard configuration",
                )
                if (
                    linked_configuration_sha256 != configuration_sha256
                    or anchor.get("corpus_manifest_sha256")
                    != ledger.get("corpus_manifest_sha256")
                ):
                    raise P07ExecutionError(
                        "anchor-only guard evidence uses another invocation"
                    )
                anchor_metadata = os.stat(anchor_path, follow_symlinks=False)
                immutable_flag = getattr(stat, "UF_IMMUTABLE", None)
                if (
                    stat.S_ISLNK(anchor_metadata.st_mode)
                    or not stat.S_ISREG(anchor_metadata.st_mode)
                    or not isinstance(immutable_flag, int)
                    or immutable_flag == 0
                    or getattr(anchor_metadata, "st_flags", 0)
                    & immutable_flag
                    == 0
                ):
                    raise P07ExecutionError(
                        "anchor-only guard evidence is not user-immutable"
                    )
                unavailable.update(
                    {
                        "holdout_access_configuration_sha256": (
                            linked_configuration_sha256
                        ),
                        "holdout_access_immutable_anchor_file_sha256": (
                            hashlib.sha256(anchor_payload).hexdigest()
                        ),
                        "holdout_access_open_intent_linked": False,
                        "holdout_access_ledger_verification_error_sha256": None,
                    }
                )
                return unavailable
            linked_configuration_sha256: Optional[str] = None
            anchor_sha256: Optional[str] = None
            open_intent_linked: Optional[bool] = None
            if state != "sealed":
                open_event = events[1]
                details = open_event.get("details")
                if not isinstance(details, dict):
                    raise P07ExecutionError("guard open-intent details are invalid")
                linked_configuration_sha256 = _require_sha256(
                    details.get("configuration_sha256"),
                    "guard open-intent configuration",
                )
                if linked_configuration_sha256 != configuration_sha256:
                    raise P07ExecutionError(
                        "guard open intent uses a different configuration"
                    )
                if not isinstance(anchor_path, Path) or not anchor_path.is_absolute():
                    raise P07ExecutionError("guard immutable anchor path is unavailable")
                try:
                    anchor_metadata = os.stat(anchor_path, follow_symlinks=False)
                except OSError as error:
                    raise P07ExecutionError(
                        "guard immutable anchor cannot be inspected"
                    ) from error
                immutable_flag = getattr(stat, "UF_IMMUTABLE", None)
                if (
                    stat.S_ISLNK(anchor_metadata.st_mode)
                    or not stat.S_ISREG(anchor_metadata.st_mode)
                    or not isinstance(immutable_flag, int)
                    or immutable_flag == 0
                    or getattr(anchor_metadata, "st_flags", 0) & immutable_flag == 0
                ):
                    raise P07ExecutionError(
                        "guard external anchor is not a user-immutable regular file"
                    )
                anchor_payload, anchor = _read_json(
                    anchor_path,
                    "P07 immutable guard anchor",
                )
                anchor_sha256 = hashlib.sha256(anchor_payload).hexdigest()
                if (
                    details.get("external_anchor_sha256") != anchor_sha256
                    or anchor.get("configuration_sha256") != configuration_sha256
                    or anchor.get("corpus_manifest_sha256")
                    != ledger.get("corpus_manifest_sha256")
                    or anchor.get("open_intent_utc")
                    != open_event.get("occurred_utc")
                ):
                    raise P07ExecutionError(
                        "guard ledger and immutable anchor linkage differs"
                    )
                open_intent_linked = True
            # Any persisted open intent makes this version non-replayable, even if
            # the loader was not reached; the exact state remains separately bound.
            consumed = state != "sealed"
            if known_consumed is not None and consumed != known_consumed:
                raise P07ExecutionError(
                    "guard return and immutable ledger consumption state disagree"
                )
            return {
                "holdout_access_consumed": consumed,
                "holdout_access_state": state,
                "holdout_access_evidence_source": "live_guard_ledger",
                "holdout_access_ledger_file_sha256": hashlib.sha256(payload).hexdigest(),
                "holdout_access_ledger_tip_sha256": previous,
                "holdout_access_ledger_event_count": len(events),
                "holdout_access_ledger_event_order": names,
                "holdout_access_configuration_sha256": (
                    linked_configuration_sha256
                ),
                "holdout_access_immutable_anchor_file_sha256": anchor_sha256,
                "holdout_access_open_intent_linked": open_intent_linked,
                "holdout_access_ledger_verification_error_sha256": None,
            }
        except BaseException as error:
            evidence = dict(unavailable)
            evidence["holdout_access_ledger_verification_error_sha256"] = (
                hashlib.sha256(
                    "{}:{}".format(type(error).__name__, error).encode(
                        "utf-8", "strict"
                    )
                ).hexdigest()
            )
            return evidence

    def _publish_primary_failure_or_raise_archive_error(
        self,
        *,
        output_directory: Path,
        preflight: P07Preflight,
        configuration_lock: Mapping[str, object],
        guard: object,
        primary_error: BaseException,
        failure_stage: str,
        known_consumed: Optional[bool],
    ) -> None:
        try:
            self._publish_failure(
                output_directory=output_directory,
                preflight=preflight,
                configuration_lock=configuration_lock,
                error=primary_error,
                failure_stage=failure_stage,
                access_evidence=self._guard_access_evidence(
                    guard,
                    known_consumed=known_consumed,
                    configuration_sha256=canonical_sha256(configuration_lock),
                ),
            )
        except BaseException as archive_error:
            workspace = getattr(self, "_active_workspace", None)
            if isinstance(workspace, _P07TransactionWorkspace):
                archive_message = str(archive_error)
                archive_traceback = "".join(
                    traceback.TracebackException.from_exception(
                        archive_error
                    ).format(chain=True)
                )
                archive_failure = {
                    "role": "failure_evidence_publication",
                    "failure_type": type(archive_error).__name__,
                    "failure_message": archive_message,
                    "failure_message_sha256": hashlib.sha256(
                        archive_message.encode("utf-8", "strict")
                    ).hexdigest(),
                    "failure_traceback": archive_traceback,
                    "failure_traceback_sha256": hashlib.sha256(
                        archive_traceback.encode("utf-8", "strict")
                    ).hexdigest(),
                }
                durable = dict(archive_failure)
                durable["manifest_sha256"] = _manifest_hash(durable)
                workspace.write_archive_publication_failure(durable)
            raise P07ExecutionError(
                "P07 {} primary failure ({}) and failure archive publication "
                "also failed ({}): {}".format(
                    failure_stage,
                    type(primary_error).__name__,
                    type(archive_error).__name__,
                    archive_error,
                )
            ) from archive_error

    def _validated_pre_guard_preflight(
        self,
        *,
        configuration_lock: Mapping[str, object],
        guard: object,
    ) -> P07Preflight:
        preflight = self.preflight()
        configuration_path = self._artifact_path(
            preflight.release_bundle,
            "configuration_lock",
        )
        _, released_configuration = _read_json(
            configuration_path,
            "released configuration lock",
        )
        if configuration_lock != released_configuration:
            raise P07ExecutionError(
                "supplied configuration lock differs from P06 release"
            )
        self._validate_guard_binding(
            guard,
            corpus_manifest_sha256=str(
                preflight.corpus_lock["manifest_sha256"]
            ),
        )
        self._verify_preflight_files(preflight)
        self._verify_direct_input_files(preflight)
        final_bundle, final_bound = self._validate_release_and_inputs()
        if (
            final_bundle != preflight.release_bundle
            or getattr(final_bound, "bundle_sha256", None)
            != preflight.input_bundle_sha256
            or corpus_lock_bundle_sha256(final_bound)
            != preflight.corpus_lock_bundle_sha256
            or tuple(getattr(final_bound, "records", ()))
            != tuple(preflight.input_records)
        ):
            raise P07ExecutionError(
                "P06 release or direct inputs changed before guard intent"
            )
        prepared = self._prepare_authorized_execution(preflight)
        observation = self._authorized_observe_mount(prepared.mount_root)
        if observation.mounted:
            raise P07ExecutionError(
                "holdout is already mounted before authorization"
            )
        return prepared

    def execute_once(
        self,
        *,
        configuration_lock: Mapping[str, object],
        guard: object,
        evaluator: Callable[[
            Mapping[str, object], Path, Path
        ], Mapping[str, object]],
        output_directory: Path,
    ) -> Mapping[str, object]:
        """Authorize, mount, evaluate, detach, and atomically publish one run."""
        output_directory = _normalized_absolute(
            output_directory,
            "P07 output directory",
        )
        if not isinstance(configuration_lock, dict):
            raise P07ExecutionError("configuration lock must be a JSON object")
        output_parent_descriptor, output_parent_identity = _open_directory_nofollow(
            output_directory.parent,
            "P07 output parent",
        )
        workspace: Optional[_P07TransactionWorkspace] = None
        primary_error: Optional[BaseException] = None
        self._active_workspace = None
        self._active_evaluator = evaluator
        self._persisted_production_execution_binding_fragment = None
        self._transaction_context = {
            "phase": "pre_guard_validation",
            "guard_returned": False,
            "publication_validated": False,
            "publication_renamed": False,
            "parent_directory_synced": False,
            "raw_workspace_cleaned": False,
            "cleanup_result": {
                "status": "not_started",
                "mount_invoked": False,
                "mount_detached": None,
                "support_revalidation": "not_run",
            },
            "frame_index": None,
            "presentation_timestamp": None,
            "media_asset_id": None,
            "media_case_id": None,
            "media_context_available": False,
            "temporary_run_path": None,
        }
        try:
            required_isolation_attributes = (
                "p07_cache_root",
                "p06_release_root",
                "holdout_root",
                "support_evidence_roots",
                "live_holdout_preopen_binding",
            )
            if all(
                hasattr(self, name) for name in required_isolation_attributes
            ):
                self._validate_output_isolation(output_directory)
            workspace = _P07TransactionWorkspace.open_existing(
                output_directory=output_directory,
                parent_descriptor=output_parent_descriptor,
                parent_identity=output_parent_identity,
            )
            self._active_workspace = workspace
            if workspace is not None:
                self._validate_workspace_intent_for_invocation(
                    workspace=workspace,
                    output_directory=output_directory,
                    configuration_lock=configuration_lock,
                    guard=guard,
                )

            if os.path.lexists(output_directory):
                if (
                    workspace is not None
                    and workspace.read_archive_publication_failure()
                    is not None
                ):
                    self._recover_mount_from_intent(workspace.intent)
                    recovered_failure = self._recover_staged_failure(
                        workspace=workspace,
                        output_directory=output_directory,
                        configuration_lock=configuration_lock,
                        guard=guard,
                    )
                    if recovered_failure is None:
                        raise P07ExecutionError(
                            "P07 archive-publication failure provenance "
                            "cannot be recovered"
                        )
                    workspace = None
                    self._active_workspace = None
                    raise P07ExecutionError(
                        "P07 recovered and validated an archive-publication "
                        "failure beside the existing output"
                    )
                try:
                    bindings = self._validate_publication(output_directory)
                except P07ExecutionError as success_error:
                    try:
                        _validate_failure_publication(output_directory)
                    except P07ExecutionError as failure_error:
                        raise P07ExecutionError(
                            "existing P07 output is neither a recognized success "
                            "nor failure publication"
                        ) from failure_error
                    self._validate_terminal_invocation_binding(
                        directory=output_directory,
                        configuration_lock=configuration_lock,
                        guard=guard,
                    )
                    if workspace is not None:
                        try:
                            self._recover_mount_from_intent(workspace.intent)
                        finally:
                            workspace.remove_child("extraction")
                        workspace.destroy()
                        workspace = None
                        self._active_workspace = None
                    raise P07ExecutionError(
                        "P07 transaction already has a validated terminal failure"
                    ) from success_error
                self._validate_terminal_invocation_binding(
                    directory=output_directory,
                    configuration_lock=configuration_lock,
                    guard=guard,
                )
                _, execution = _read_json(
                    output_directory / "p07-execution-result.json",
                    "terminal P07 execution result",
                )
                if workspace is not None:
                    try:
                        self._recover_mount_from_intent(workspace.intent)
                    finally:
                        workspace.remove_child("extraction")
                    workspace.destroy()
                    workspace = None
                    self._active_workspace = None
                manifest = _artifact_manifest_top_level(output_directory)
                return {
                    **execution,
                    "published_evidence_file_sha256": bindings,
                    "artifact_manifest_sha256": manifest[
                        "manifest_sha256"
                    ],
                    "artifact_manifest_top_level": manifest,
                    "output_directory": os.fspath(output_directory),
                }

            failure_output = output_directory.with_name(
                output_directory.name + ".failed"
            )
            if os.path.lexists(failure_output):
                _validate_failure_publication(failure_output)
                self._validate_terminal_invocation_binding(
                    directory=failure_output,
                    configuration_lock=configuration_lock,
                    guard=guard,
                )
                if workspace is not None:
                    try:
                        self._recover_mount_from_intent(workspace.intent)
                    finally:
                        workspace.remove_child("extraction")
                    workspace.destroy()
                    workspace = None
                    self._active_workspace = None
                raise P07ExecutionError(
                    "P07 transaction already has a validated terminal failure"
                )

            pre_guard_staging = _pre_guard_failure_staging_path(output_directory)
            if os.path.lexists(pre_guard_staging):
                _validate_failure_publication(pre_guard_staging)
                self._validate_terminal_invocation_binding(
                    directory=pre_guard_staging,
                    configuration_lock=configuration_lock,
                    guard=guard,
                )
                _publish_directory_exclusive(
                    pre_guard_staging,
                    output_directory,
                    destination_parent_pin=(
                        output_parent_descriptor,
                        output_parent_identity,
                    ),
                )
                _validate_failure_publication(output_directory)
                raise P07ExecutionError(
                    "P07 recovered a terminal pre-guard failure publication"
                )

            configuration_sha256 = canonical_sha256(configuration_lock)
            if workspace is not None:
                intent = workspace.intent
                if intent.get("configuration_sha256") != configuration_sha256:
                    raise P07ExecutionError(
                        "existing P07 transaction uses another configuration"
                    )
                try:
                    self._recover_mount_from_intent(intent)
                except BaseException:
                    workspace.remove_child("extraction")
                    self._transaction_context["raw_workspace_cleaned"] = True
                    raise
                recovered_failure = self._recover_staged_failure(
                    workspace=workspace,
                    output_directory=output_directory,
                    configuration_lock=configuration_lock,
                    guard=guard,
                )
                if recovered_failure is not None:
                    workspace = None
                    self._active_workspace = None
                    raise P07ExecutionError(
                        "P07 recovered and validated a terminal failure publication"
                    )
                self._validate_guard_binding(
                    guard,
                    corpus_manifest_sha256=str(
                        intent["corpus_manifest_sha256"]
                    ),
                )
                recovery_evidence = self._guard_access_evidence(
                    guard,
                    known_consumed=None,
                    configuration_sha256=configuration_sha256,
                )
                recovery_state = recovery_evidence.get("holdout_access_state")
                if recovery_state == "completed":
                    self._transaction_context["guard_returned"] = True
                    self._transaction_context["phase"] = (
                        "restart_completed_guard_recovery"
                    )
                    return self._finalize_success_transaction(
                        workspace=workspace,
                        output_directory=output_directory,
                        guard=guard,
                        guard_evidence=recovery_evidence,
                        result=None,
                        configuration_lock=configuration_lock,
                    )
                if recovery_state != "sealed":
                    self._transaction_context["phase"] = (
                        "restart_interrupted_guard_recovery"
                    )
                    interrupted = P07ExecutionError(
                        "P07 process ended after the one-use guard entered state {}"
                        .format(recovery_state)
                    )
                    recovery_preflight = P07Preflight(
                        plan={
                            "manifest_sha256": intent[
                                "sampling_plan_manifest_sha256"
                            ]
                        },
                        plan_file_sha256=str(
                            intent["sampling_plan_file_sha256"]
                        ),
                        attestation={
                            "inner_inventory": {
                                "sha256": intent["inner_inventory_sha256"]
                            }
                        },
                        attestation_file_sha256=str(
                            intent["no_pixel_attestation_file_sha256"]
                        ),
                        corpus_lock={
                            "manifest_sha256": intent[
                                "corpus_manifest_sha256"
                            ]
                        },
                        corpus_lock_file_sha256=str(
                            intent["corpus_manifest_sha256"]
                        ),
                        degradation_policy={},
                        analytic_fixture_manifest={},
                        outer_wrapper={
                            "manifest_sha256": intent[
                                "outer_wrapper_manifest_sha256"
                            ]
                        },
                        outer_wrapper_file_sha256=str(
                            intent["outer_wrapper_file_sha256"]
                        ),
                        release_bundle={
                            "configuration_id": intent["configuration_id"],
                            "manifest_sha256": intent[
                                "release_bundle_manifest_sha256"
                            ],
                        },
                        workflow_paths={},
                        mount_root=self.holdout_root / "mount-v2",
                        loader_sha256=str(intent["loader_executable_sha256"]),
                        p07_cache_tree_sha256=str(
                            intent["p07_preopen_cache_tree_sha256"]
                        ),
                        input_bundle_sha256=str(intent["input_bundle_sha256"]),
                        corpus_lock_bundle_sha256=str(
                            intent["corpus_lock_bundle_sha256"]
                        ),
                        input_records=tuple(intent["direct_input_bindings"]),
                        authorized_execution_bindings=intent.get(
                            "authorized_execution_bindings"
                        ),
                    )
                    self._publish_failure(
                        output_directory=output_directory,
                        preflight=recovery_preflight,
                        configuration_lock=configuration_lock,
                        error=interrupted,
                        failure_stage="restart_recovery",
                        access_evidence=recovery_evidence,
                    )
                    raise interrupted

            try:
                preflight = self._validated_pre_guard_preflight(
                    configuration_lock=configuration_lock,
                    guard=guard,
                )
                preflight = self._bind_production_execution_fragment(
                    preflight=preflight,
                    evaluator=evaluator,
                )
            except BaseException as error:
                self._transaction_context["phase"] = "pre_guard_validation"
                self._publish_pre_guard_failure(
                    output_directory=output_directory,
                    output_parent_pin=(
                        output_parent_descriptor,
                        output_parent_identity,
                    ),
                    configuration_lock=configuration_lock,
                    error=error,
                )
                raise
            machine = os.uname()
            command = str(
                getattr(
                    self,
                    "publication_command",
                    "direct P07HoldoutExecutor.execute_once invocation",
                )
            )
            platform = str(
                getattr(
                    self,
                    "publication_platform",
                    "{} {} {}".format(
                        machine.sysname,
                        machine.release,
                        machine.machine,
                    ),
                )
            )
            proposed_intent = _transaction_intent_document(
                output_directory=output_directory,
                configuration_lock=configuration_lock,
                preflight=preflight,
                live_binding=self.live_holdout_preopen_binding,
                command=command,
                platform=platform,
            )
            workspace, created = _P07TransactionWorkspace.open_or_create(
                output_directory=output_directory,
                parent_descriptor=output_parent_descriptor,
                parent_identity=output_parent_identity,
                intent=proposed_intent,
            )
            self._active_workspace = workspace
            self._transaction_context["temporary_run_path"] = os.fspath(
                workspace.path
            )
            self._transaction_context["phase"] = "durable_pre_guard_intent"
            if not created:
                workspace.ensure_empty_child("extraction")
                workspace.ensure_empty_child("publication")
            extraction_directory = workspace.path / "extraction"
            publication_directory = workspace.path / "publication"
            extraction_pin = workspace.child_descriptor("extraction")
            publication_pin = workspace.child_descriptor("publication")
            assert extraction_pin is not None and publication_pin is not None
            extraction_descriptor, extraction_identity = extraction_pin
            publication_descriptor, publication_identity = publication_pin

            def authorized_loader() -> Mapping[str, object]:
                workspace.verify()
                for name, expected in (
                    ("extraction", extraction_identity),
                    ("publication", publication_identity),
                ):
                    current = os.stat(
                        name,
                        dir_fd=workspace.descriptor,
                        follow_symlinks=False,
                    )
                    if (current.st_dev, current.st_ino) != (
                        expected.st_dev,
                        expected.st_ino,
                    ):
                        raise P07ExecutionError(
                            "P07 raw workspace child identity changed"
                        )
                loaded = self._authorized_evaluation(
                    preflight=preflight,
                    extraction_directory=extraction_directory,
                    extraction_descriptor=extraction_descriptor,
                    publication_directory=publication_directory,
                    evaluator=evaluator,
                )
                workspace.verify()
                for name, expected in (
                    ("extraction", extraction_identity),
                    ("publication", publication_identity),
                ):
                    current = os.stat(
                        name,
                        dir_fd=workspace.descriptor,
                        follow_symlinks=False,
                    )
                    if (current.st_dev, current.st_ino) != (
                        expected.st_dev,
                        expected.st_ino,
                    ):
                        raise P07ExecutionError(
                            "P07 raw workspace child identity changed"
                        )
                return loaded

            try:
                read_once = getattr(guard, "read_once")
                result = read_once(dict(configuration_lock), authorized_loader)
                self._transaction_context["guard_returned"] = True
                self._transaction_context["phase"] = "guard_completed"
            except BaseException as error:
                self._capture_error_media_context(error)
                self._publish_primary_failure_or_raise_archive_error(
                    output_directory=output_directory,
                    preflight=preflight,
                    configuration_lock=configuration_lock,
                    guard=guard,
                    primary_error=error,
                    failure_stage="guard_or_authorized_execution",
                    known_consumed=None,
                )
                raise
            finally:
                os.close(extraction_descriptor)
                os.close(publication_descriptor)
            try:
                if not isinstance(result, dict):
                    raise P07ExecutionError(
                        "holdout guard returned invalid P07 evidence"
                    )
                guard_evidence = self._guard_access_evidence(
                    guard,
                    known_consumed=True,
                    configuration_sha256=configuration_sha256,
                )
                return self._finalize_success_transaction(
                    workspace=workspace,
                    output_directory=output_directory,
                    guard=guard,
                    guard_evidence=guard_evidence,
                    result=result,
                    configuration_lock=configuration_lock,
                )
            except BaseException as error:
                self._publish_primary_failure_or_raise_archive_error(
                    output_directory=output_directory,
                    preflight=preflight,
                    configuration_lock=configuration_lock,
                    guard=guard,
                    primary_error=error,
                    failure_stage="post_guard_publication",
                    known_consumed=True,
                )
                raise
        except BaseException as error:
            primary_error = error
            raise
        finally:
            self._active_workspace = None
            self._active_evaluator = None
            self._persisted_production_execution_binding_fragment = None
            cleanup_error: Optional[BaseException] = None
            for closer in (
                self._close_authorized_execution,
                (
                    workspace.close
                    if workspace is not None and workspace.descriptor >= 0
                    else None
                ),
                lambda: os.close(output_parent_descriptor),
            ):
                if closer is None:
                    continue
                try:
                    closer()
                except BaseException as error:
                    if cleanup_error is None:
                        cleanup_error = error
            if cleanup_error is not None:
                if primary_error is not None:
                    raise P07DualFailure(
                        primary_error,
                        cleanup_error,
                    ) from primary_error
                raise cleanup_error
