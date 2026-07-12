"""Read-only verification of the separately rooted live holdout access state.

The verifier accepts metadata paths only.  It never accepts a corpus, container,
mount, media, or payload root, and it never resolves paths embedded in metadata.
An absent open-intent file is the valid preopen state established by
``mirmir_quality.holdout``; the containing anchor registry must still exist and
match its predeclared filesystem identity.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
from typing import Mapping

import jsonschema


CALIBRATION_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = CALIBRATION_ROOT.parents[1]
QUALITY_SCHEMA_ROOT = REPOSITORY_ROOT / "validation" / "quality" / "schemas"
CALIBRATION_SCHEMA_ROOT = CALIBRATION_ROOT / "schemas"

LIVE_LEDGER_SCHEMA = QUALITY_SCHEMA_ROOT / "holdout-access-ledger.schema.json"
LIVE_ANCHOR_SCHEMA = QUALITY_SCHEMA_ROOT / "holdout-access-anchor.schema.json"
SEALED_COPY_SCHEMA = (
    CALIBRATION_SCHEMA_ROOT
    / "sealed-evaluation-access-ledger-v1.schema.json"
)
SEAL_ATTESTATION_SCHEMA = (
    CALIBRATION_SCHEMA_ROOT
    / "holdout-seal-attestation-no-pixel-v1.schema.json"
)
VERIFICATION_SCHEMA = (
    CALIBRATION_SCHEMA_ROOT
    / "live-holdout-preopen-verification-v1.schema.json"
)
PREOPEN_RECEIPT_SCHEMA = (
    CALIBRATION_SCHEMA_ROOT
    / "live-holdout-preopen-receipt-v1.schema.json"
)

SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VERSION_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
LIVE_LEDGER_FILENAME = "holdout-access-ledger.json"
LIVE_ANCHOR_FILENAME = "holdout-open-intent.json"
PREOPEN_RECEIPT_PREFIX = "holdout-preopen-receipt."
PREOPEN_RECEIPT_SUFFIX = ".json"
MAX_METADATA_BYTES = 1024 * 1024
ZERO_SHA256 = "0" * 64
HOLDOUT_ACCESS_THREAT_BOUNDARY = (
    "cooperating-processes-v1; deliberate owner-or-administrator flag clearing, "
    "direct media access, code bypass, and filesystem rollback are outside scope"
)


class LiveHoldoutPreopenError(ValueError):
    """The live preopen state or one of its metadata bindings is invalid."""


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
        raise LiveHoldoutPreopenError(
            "metadata is not finite canonical JSON"
        ) from error


def _canonical_sha256(value: object) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _require_file_sha256(path: Path, expected: str, label: str) -> None:
    if _sha256(_read_regular_file(path, label)) != expected:
        raise LiveHoldoutPreopenError(f"{label} changed during verification")


def _normalized_absolute(path: Path, label: str) -> Path:
    if not isinstance(path, Path):
        raise TypeError(f"{label} must be a pathlib.Path")
    if not path.is_absolute():
        raise LiveHoldoutPreopenError(f"{label} must be absolute")
    normalized = Path(os.path.normpath(os.fspath(path)))
    if normalized != path:
        raise LiveHoldoutPreopenError(f"{label} must be lexically normalized")
    return normalized


def _path_components(path: Path) -> tuple[Path, ...]:
    current = Path(path.anchor)
    components = [current]
    for part in path.parts[1:]:
        current = current / part
        components.append(current)
    return tuple(components)


def _validate_existing_components(
    path: Path,
    *,
    label: str,
    leaf_kind: str,
) -> os.stat_result:
    path = _normalized_absolute(path, label)
    components = _path_components(path)
    leaf: os.stat_result | None = None
    for index, component in enumerate(components):
        try:
            metadata = os.lstat(component)
        except OSError as error:
            raise LiveHoldoutPreopenError(
                f"{label} is absent or inaccessible"
            ) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise LiveHoldoutPreopenError(
                f"{label} traverses or names a symbolic link"
            )
        is_leaf = index == len(components) - 1
        if not is_leaf and not stat.S_ISDIR(metadata.st_mode):
            raise LiveHoldoutPreopenError(
                f"{label} has a non-directory parent component"
            )
        if is_leaf:
            leaf = metadata
    if leaf is None:
        raise LiveHoldoutPreopenError(f"{label} has no filesystem identity")
    if leaf_kind == "directory" and not stat.S_ISDIR(leaf.st_mode):
        raise LiveHoldoutPreopenError(f"{label} is not a directory")
    if leaf_kind == "file" and not stat.S_ISREG(leaf.st_mode):
        raise LiveHoldoutPreopenError(f"{label} is not a regular file")
    return leaf


def _read_regular_file(path: Path, label: str) -> bytes:
    before = _validate_existing_components(path, label=label, leaf_kind="file")
    if before.st_size > MAX_METADATA_BYTES:
        raise LiveHoldoutPreopenError(f"{label} exceeds the metadata-only size limit")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise LiveHoldoutPreopenError(f"{label} could not be opened safely") from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise LiveHoldoutPreopenError(f"{label} is not a regular file")
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise LiveHoldoutPreopenError(f"{label} changed while opening")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1024))
            if not chunk:
                raise LiveHoldoutPreopenError(f"{label} was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise LiveHoldoutPreopenError(f"{label} grew while reading")
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or after.st_ctime_ns != before.st_ctime_ns
    ):
        raise LiveHoldoutPreopenError(f"{label} changed while reading")
    return b"".join(chunks)


def _reject_duplicate_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise LiveHoldoutPreopenError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _decode_json(payload: bytes, label: str) -> Mapping[str, object]:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                LiveHoldoutPreopenError(f"non-finite JSON number: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LiveHoldoutPreopenError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise LiveHoldoutPreopenError(f"{label} top level is not an object")
    return value


def _read_json(path: Path, label: str) -> tuple[bytes, Mapping[str, object]]:
    payload = _read_regular_file(path, label)
    return payload, _decode_json(payload, label)


def _pretty_json_bytes(value: Mapping[str, object]) -> bytes:
    try:
        return (
            json.dumps(
                value,
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise LiveHoldoutPreopenError(
            "metadata cannot be encoded as finite JSON"
        ) from error


def _fsync_directory(directory: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    descriptor = os.open(directory, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _publish_exclusive_atomic(
    path: Path,
    payload: bytes,
    *,
    label: str,
) -> None:
    """Publish a complete new inode without replacing any existing pathname."""

    _validate_existing_components(
        path.parent,
        label=f"{label} parent",
        leaf_kind="directory",
    )
    if len(payload) > MAX_METADATA_BYTES:
        raise LiveHoldoutPreopenError(f"{label} exceeds the metadata-only size limit")
    if os.path.lexists(path):
        raise FileExistsError(f"{label} already exists: {path}")
    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.{secrets.token_hex(12)}.partial"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    linked = False
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise LiveHoldoutPreopenError(
                    f"{label} could not be written completely"
                )
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.link(temporary, path, follow_symlinks=False)
        linked = True
        _fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        if linked:
            _fsync_directory(path.parent)


def _seal_user_immutable(path: Path, *, label: str) -> None:
    if not hasattr(stat, "UF_IMMUTABLE") or not hasattr(os, "chflags"):
        raise LiveHoldoutPreopenError(
            f"{label} requires macOS user-immutable filesystem support"
        )
    before = _validate_existing_components(path, label=label, leaf_kind="file")
    try:
        os.chflags(
            path,
            before.st_flags | stat.UF_IMMUTABLE,
            follow_symlinks=False,
        )
        after = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise LiveHoldoutPreopenError(
            f"{label} could not be made user immutable"
        ) from error
    if not stat.S_ISREG(after.st_mode) or not after.st_flags & stat.UF_IMMUTABLE:
        raise LiveHoldoutPreopenError(
            f"{label} did not retain the user-immutable flag"
        )


def _validate_schema(
    document: Mapping[str, object],
    schema_path: Path,
    label: str,
) -> None:
    _, schema = _read_json(schema_path, f"{label} schema")
    validator = jsonschema.Draft202012Validator(
        schema,
        format_checker=jsonschema.FormatChecker(),
    )
    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if errors:
        descriptions = []
        for error in errors:
            location = "/".join(str(part) for part in error.absolute_path) or "<root>"
            descriptions.append(f"{location}: {error.message}")
        raise LiveHoldoutPreopenError(
            f"{label} schema validation failed: " + "; ".join(descriptions)
        )


def _require_sha256(value: str, label: str) -> None:
    if not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value):
        raise LiveHoldoutPreopenError(f"{label} is not a lowercase SHA-256")


def filesystem_directory_identity_sha256(directory: Path) -> str:
    """Return the non-path-disclosing identity digest for one metadata directory."""

    directory = _normalized_absolute(directory, "metadata directory")
    metadata = _validate_existing_components(
        directory,
        label="metadata directory",
        leaf_kind="directory",
    )
    identity = {
        "identity_contract": "absolute-path-device-inode-owner-mode-v1",
        "absolute_path_sha256": _sha256(os.fsencode(directory)),
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "owner_uid": metadata.st_uid,
        "owner_gid": metadata.st_gid,
        "mode": stat.S_IMODE(metadata.st_mode),
    }
    return _canonical_sha256(identity)


def _require_independent_roots(ledger_root: Path, anchor_root: Path) -> None:
    try:
        ledger_root.relative_to(anchor_root)
        overlaps = True
    except ValueError:
        overlaps = False
    try:
        anchor_root.relative_to(ledger_root)
        overlaps = True
    except ValueError:
        pass
    if overlaps:
        raise LiveHoldoutPreopenError(
            "live ledger and open-intent anchor require independent storage roots"
        )


def _validate_live_ledger(document: Mapping[str, object]) -> tuple[str, int]:
    _validate_schema(document, LIVE_LEDGER_SCHEMA, "live access ledger")
    corpus_sha256 = document.get("corpus_manifest_sha256")
    if not isinstance(corpus_sha256, str):
        raise LiveHoldoutPreopenError("live access ledger corpus binding is absent")
    _require_sha256(corpus_sha256, "live access ledger corpus binding")
    events = document.get("events")
    if not isinstance(events, list):
        raise LiveHoldoutPreopenError("live access ledger events are absent")
    previous = ZERO_SHA256
    event_names: list[str] = []
    event_times: dict[str, str] = {}
    for sequence, event in enumerate(events):
        if not isinstance(event, dict):
            raise LiveHoldoutPreopenError(
                "live access ledger event is not an object"
            )
        if event.get("sequence") != sequence:
            raise LiveHoldoutPreopenError(
                "live access ledger sequence is discontinuous"
            )
        if event.get("previous_entry_sha256") != previous:
            raise LiveHoldoutPreopenError(
                "live access ledger hash chain is discontinuous"
            )
        unhashed = dict(event)
        declared = unhashed.pop("entry_sha256", None)
        actual = _canonical_sha256(unhashed)
        if declared != actual:
            raise LiveHoldoutPreopenError(
                "live access ledger event self-hash is invalid"
            )
        previous = actual
        event_name = event.get("event")
        if not isinstance(event_name, str):
            raise LiveHoldoutPreopenError("live access ledger event name is invalid")
        event_names.append(event_name)
        occurred = event.get("occurred_utc")
        if isinstance(occurred, str):
            event_times[event_name] = occurred
    valid_sequences = {
        "sealed": ["sealed"],
        "intent_recorded": ["sealed", "open_intent"],
        "opened": ["sealed", "open_intent", "opened"],
        "completed": ["sealed", "open_intent", "opened", "completed"],
        "failed": ["sealed", "open_intent", "opened", "failed_after_open"],
    }
    state = document.get("state")
    if state not in valid_sequences or event_names != valid_sequences[state]:
        raise LiveHoldoutPreopenError("live access ledger state transition is invalid")
    expected_times = {
        "open_intent_utc": event_times.get("open_intent"),
        "opened_utc": event_times.get("opened"),
        "completed_utc": event_times.get("completed")
        or event_times.get("failed_after_open"),
    }
    if any(document.get(field) != value for field, value in expected_times.items()):
        raise LiveHoldoutPreopenError(
            "live access ledger timestamps do not match its event chain"
        )
    first = events[0]
    if first.get("details") != {"corpus_manifest_sha256": corpus_sha256}:
        raise LiveHoldoutPreopenError(
            "live access ledger seal event does not bind the corpus"
        )
    access_count = sum(name == "opened" for name in event_names)
    if state != "sealed" or access_count != 0:
        raise LiveHoldoutPreopenError(
            "live access ledger records prior holdout access"
        )
    if any(
        document.get(field) is not None
        for field in ("open_intent_utc", "opened_utc", "completed_utc")
    ):
        raise LiveHoldoutPreopenError(
            "live access ledger contains a preopen timestamp"
        )
    return corpus_sha256, access_count


def _validate_open_intent_absent(
    anchor_path: Path,
    corpus_manifest_sha256: str,
) -> None:
    try:
        metadata = os.lstat(anchor_path)
    except FileNotFoundError:
        return
    except OSError as error:
        raise LiveHoldoutPreopenError(
            "live open-intent anchor cannot be inspected"
        ) from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise LiveHoldoutPreopenError(
            "live open-intent anchor is symbolic or not a regular file"
        )
    if not hasattr(stat, "UF_IMMUTABLE") or not hasattr(os, "chflags"):
        raise LiveHoldoutPreopenError(
            "live open-intent anchor cannot prove macOS user immutability"
        )
    if not metadata.st_flags & stat.UF_IMMUTABLE:
        raise LiveHoldoutPreopenError(
            "live open-intent anchor exists without the required user-immutable flag"
        )
    _, document = _read_json(anchor_path, "live open-intent anchor")
    _validate_schema(document, LIVE_ANCHOR_SCHEMA, "live open-intent anchor")
    if document.get("corpus_manifest_sha256") != corpus_manifest_sha256:
        raise LiveHoldoutPreopenError(
            "live open-intent anchor is bound to a different corpus"
        )
    raise LiveHoldoutPreopenError(
        "live open-intent anchor proves prior holdout access intent"
    )


def _validate_repository_preopen_evidence(
    sealed_copy: Mapping[str, object],
    attestation: Mapping[str, object],
    *,
    sealed_copy_sha256: str,
    live_corpus_manifest_sha256: str,
) -> None:
    _validate_schema(
        sealed_copy,
        SEALED_COPY_SCHEMA,
        "repository sealed ledger copy",
    )
    _validate_schema(
        attestation,
        SEAL_ATTESTATION_SCHEMA,
        "repository seal attestation",
    )
    if sealed_copy.get("status") != "unopened":
        raise LiveHoldoutPreopenError("repository sealed ledger copy is not unopened")
    if sealed_copy.get("evaluation_access_count") != 0:
        raise LiveHoldoutPreopenError(
            "repository sealed ledger copy has a nonzero access count"
        )
    if sealed_copy.get("entries") != []:
        raise LiveHoldoutPreopenError(
            "repository sealed ledger copy has access entries"
        )
    if any(
        sealed_copy.get(field) is not None
        for field in (
            "evaluation_opened_utc",
            "first_evaluation_access_utc",
            "last_evaluation_access_utc",
            "evaluation_run_id",
        )
    ):
        raise LiveHoldoutPreopenError(
            "repository sealed ledger copy has an access identity or timestamp"
        )
    if attestation.get("pixel_content_included") is not False:
        raise LiveHoldoutPreopenError(
            "repository seal attestation includes pixel content"
        )
    if sealed_copy.get("revision_id") != attestation.get("revision_id"):
        raise LiveHoldoutPreopenError(
            "repository preopen evidence revision binding differs"
        )
    outer_hashes = attestation.get("outer_record_hashes")
    if not isinstance(outer_hashes, dict) or outer_hashes.get(
        "evaluation_access_ledger_sealed_copy"
    ) != sealed_copy_sha256:
        raise LiveHoldoutPreopenError(
            "repository seal receipt does not bind the sealed ledger copy"
        )
    production_lock = attestation.get("production_corpus_lock")
    if not isinstance(production_lock, dict) or production_lock.get(
        "manifest_sha256"
    ) != live_corpus_manifest_sha256:
        raise LiveHoldoutPreopenError(
            "live access ledger and repository seal receipt bind different corpora"
        )
    if sealed_copy.get("prepared_for_seal_utc") != production_lock.get("created_utc"):
        raise LiveHoldoutPreopenError(
            "repository seal time does not bind the sealed corpus revision"
        )
    expected_access = {
        field: sealed_copy.get(field)
        for field in (
            "status",
            "evaluation_opened_utc",
            "first_evaluation_access_utc",
            "last_evaluation_access_utc",
            "evaluation_access_count",
            "evaluation_run_id",
        )
    }
    if attestation.get("evaluation_access") != expected_access:
        raise LiveHoldoutPreopenError(
            "repository seal receipt and sealed ledger access state differ"
        )
    container = attestation.get("container")
    inner_inventory = attestation.get("inner_inventory")
    keychain = attestation.get("keychain")
    if not isinstance(container, dict) or container.get("mounted") is not False:
        raise LiveHoldoutPreopenError(
            "repository seal receipt records a mounted container"
        )
    if not isinstance(inner_inventory, dict) or any(
        inner_inventory.get(field) is not False
        for field in (
            "preview_files_present",
            "scratch_files_present",
            "partial_files_present",
        )
    ):
        raise LiveHoldoutPreopenError(
            "repository seal receipt records unsealed auxiliary payloads"
        )
    if inner_inventory.get("verification_failures_before_seal") != 0:
        raise LiveHoldoutPreopenError(
            "repository seal receipt records pre-seal verification failures"
        )
    if (
        not isinstance(keychain, dict)
        or keychain.get("secret_in_attestation") is not False
    ):
        raise LiveHoldoutPreopenError("repository seal receipt contains a secret")


def _sealed_ledger_document(
    corpus_manifest_sha256: str,
    created_utc: str,
) -> Mapping[str, object]:
    event: dict[str, object] = {
        "sequence": 0,
        "event": "sealed",
        "occurred_utc": created_utc,
        "previous_entry_sha256": ZERO_SHA256,
        "details": {"corpus_manifest_sha256": corpus_manifest_sha256},
    }
    event["entry_sha256"] = _canonical_sha256(event)
    return {
        "schema_version": "1.0.0",
        "corpus_manifest_sha256": corpus_manifest_sha256,
        "state": "sealed",
        "open_intent_utc": None,
        "opened_utc": None,
        "completed_utc": None,
        "events": [event],
    }


def _validate_preopen_receipt(
    document: Mapping[str, object],
    *,
    expected_receipt_file_sha256: str,
    actual_receipt_file_sha256: str,
    live_ledger_sha256: str,
    live_ledger_root_identity_sha256: str,
    live_anchor_root_identity_sha256: str,
    repository_sealed_copy_sha256: str,
    repository_attestation_sha256: str,
    corpus_manifest_sha256: str,
) -> None:
    _validate_schema(document, PREOPEN_RECEIPT_SCHEMA, "live preopen receipt")
    if actual_receipt_file_sha256 != expected_receipt_file_sha256:
        raise LiveHoldoutPreopenError(
            "live preopen receipt differs from its expected file hash"
        )
    unhashed = dict(document)
    declared = unhashed.pop("receipt_sha256", None)
    if declared != _canonical_sha256(unhashed):
        raise LiveHoldoutPreopenError("live preopen receipt self-hash is invalid")
    expected_bindings = {
        "state": "sealed",
        "access_count": 0,
        "open_intent_anchor_present": False,
        "pixel_content_included": False,
        "corpus_manifest_sha256": corpus_manifest_sha256,
        "live_ledger_sha256": live_ledger_sha256,
        "live_ledger_root_identity_sha256": live_ledger_root_identity_sha256,
        "live_anchor_root_identity_sha256": live_anchor_root_identity_sha256,
        "repository_sealed_copy_sha256": repository_sealed_copy_sha256,
        "repository_attestation_sha256": repository_attestation_sha256,
        "persistence": "macos-user-immutable-v1",
        "threat_boundary": HOLDOUT_ACCESS_THREAT_BOUNDARY,
    }
    for field, expected in expected_bindings.items():
        if document.get(field) != expected:
            raise LiveHoldoutPreopenError(
                f"live preopen receipt binding differs: {field}"
            )


def initialize_live_holdout_preopen(
    *,
    version_id: str,
    created_utc: str,
    corpus_manifest_sha256: str,
    live_ledger_path: Path,
    live_anchor_path: Path,
    live_preopen_receipt_path: Path,
    repository_sealed_copy_path: Path,
    expected_repository_sealed_copy_sha256: str,
    repository_attestation_path: Path,
    expected_repository_attestation_sha256: str,
) -> Mapping[str, object]:
    """Create one new live guard ledger and immutable preopen receipt.

    Every path is caller supplied, every parent directory must already exist,
    and no existing destination is overwritten.  The ledger and receipt are
    atomically published per independent storage root; a cross-root failure is
    preserved and the same version cannot be retried over existing paths.
    """

    if not isinstance(version_id, str) or not VERSION_PATTERN.fullmatch(version_id):
        raise LiveHoldoutPreopenError("version_id is not a safe lowercase version")
    if not isinstance(created_utc, str) or not created_utc:
        raise LiveHoldoutPreopenError("created_utc is absent")
    for value, label in (
        (corpus_manifest_sha256, "corpus manifest hash"),
        (
            expected_repository_sealed_copy_sha256,
            "expected repository sealed copy hash",
        ),
        (
            expected_repository_attestation_sha256,
            "expected repository attestation hash",
        ),
    ):
        _require_sha256(value, label)

    live_ledger_path = _normalized_absolute(live_ledger_path, "live ledger path")
    live_anchor_path = _normalized_absolute(live_anchor_path, "live anchor path")
    live_preopen_receipt_path = _normalized_absolute(
        live_preopen_receipt_path,
        "live preopen receipt path",
    )
    repository_sealed_copy_path = _normalized_absolute(
        repository_sealed_copy_path,
        "repository sealed copy path",
    )
    repository_attestation_path = _normalized_absolute(
        repository_attestation_path,
        "repository attestation path",
    )
    if live_ledger_path.name != LIVE_LEDGER_FILENAME:
        raise LiveHoldoutPreopenError(
            f"live ledger path must end in {LIVE_LEDGER_FILENAME}"
        )
    if live_anchor_path.name != LIVE_ANCHOR_FILENAME:
        raise LiveHoldoutPreopenError(
            f"live anchor path must end in {LIVE_ANCHOR_FILENAME}"
        )
    expected_receipt_name = (
        f"{PREOPEN_RECEIPT_PREFIX}{version_id}{PREOPEN_RECEIPT_SUFFIX}"
    )
    if live_preopen_receipt_path.name != expected_receipt_name:
        raise LiveHoldoutPreopenError(
            f"live preopen receipt path must end in {expected_receipt_name}"
        )
    ledger_root = live_ledger_path.parent
    anchor_root = live_anchor_path.parent
    if live_preopen_receipt_path.parent != anchor_root:
        raise LiveHoldoutPreopenError(
            "live preopen receipt must be a sibling of the open-intent anchor"
        )
    _require_independent_roots(ledger_root, anchor_root)
    _validate_existing_components(
        ledger_root,
        label="live ledger root",
        leaf_kind="directory",
    )
    _validate_existing_components(
        anchor_root,
        label="live anchor root",
        leaf_kind="directory",
    )
    for destination, label in (
        (live_ledger_path, "live access ledger"),
        (live_anchor_path, "live open-intent anchor"),
        (live_preopen_receipt_path, "live preopen receipt"),
    ):
        if os.path.lexists(destination):
            raise FileExistsError(f"{label} already exists: {destination}")

    sealed_copy_payload, sealed_copy = _read_json(
        repository_sealed_copy_path,
        "repository sealed ledger copy",
    )
    sealed_copy_sha256 = _sha256(sealed_copy_payload)
    if sealed_copy_sha256 != expected_repository_sealed_copy_sha256:
        raise LiveHoldoutPreopenError(
            "repository sealed ledger copy differs from its expected hash"
        )
    attestation_payload, attestation = _read_json(
        repository_attestation_path,
        "repository seal attestation",
    )
    attestation_sha256 = _sha256(attestation_payload)
    if attestation_sha256 != expected_repository_attestation_sha256:
        raise LiveHoldoutPreopenError(
            "repository seal attestation differs from its expected hash"
        )
    _validate_repository_preopen_evidence(
        sealed_copy,
        attestation,
        sealed_copy_sha256=sealed_copy_sha256,
        live_corpus_manifest_sha256=corpus_manifest_sha256,
    )

    ledger_root_identity = filesystem_directory_identity_sha256(ledger_root)
    anchor_root_identity = filesystem_directory_identity_sha256(anchor_root)
    ledger = _sealed_ledger_document(corpus_manifest_sha256, created_utc)
    _validate_live_ledger(ledger)
    ledger_payload = _pretty_json_bytes(ledger)
    ledger_sha256 = _sha256(ledger_payload)
    receipt: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "live_holdout_preopen_receipt",
        "version_id": version_id,
        "created_utc": created_utc,
        "state": "sealed",
        "access_count": 0,
        "open_intent_anchor_present": False,
        "pixel_content_included": False,
        "corpus_manifest_sha256": corpus_manifest_sha256,
        "live_ledger_sha256": ledger_sha256,
        "live_ledger_root_identity_sha256": ledger_root_identity,
        "live_anchor_root_identity_sha256": anchor_root_identity,
        "repository_sealed_copy_sha256": sealed_copy_sha256,
        "repository_attestation_sha256": attestation_sha256,
        "persistence": "macos-user-immutable-v1",
        "threat_boundary": HOLDOUT_ACCESS_THREAT_BOUNDARY,
        "hash_scope": "canonical document excluding receipt_sha256",
    }
    receipt["receipt_sha256"] = _canonical_sha256(receipt)
    _validate_schema(receipt, PREOPEN_RECEIPT_SCHEMA, "live preopen receipt")
    receipt_payload = _pretty_json_bytes(receipt)
    receipt_file_sha256 = _sha256(receipt_payload)

    _publish_exclusive_atomic(
        live_ledger_path,
        ledger_payload,
        label="live access ledger",
    )
    _publish_exclusive_atomic(
        live_preopen_receipt_path,
        receipt_payload,
        label="live preopen receipt",
    )
    _seal_user_immutable(
        live_preopen_receipt_path,
        label="live preopen receipt",
    )
    reopened_payload, reopened = _read_json(
        live_preopen_receipt_path,
        "live preopen receipt",
    )
    reopened_metadata = os.stat(live_preopen_receipt_path, follow_symlinks=False)
    if not reopened_metadata.st_flags & stat.UF_IMMUTABLE:
        raise LiveHoldoutPreopenError(
            "live preopen receipt lost the user-immutable flag"
        )
    _validate_preopen_receipt(
        reopened,
        expected_receipt_file_sha256=receipt_file_sha256,
        actual_receipt_file_sha256=_sha256(reopened_payload),
        live_ledger_sha256=ledger_sha256,
        live_ledger_root_identity_sha256=ledger_root_identity,
        live_anchor_root_identity_sha256=anchor_root_identity,
        repository_sealed_copy_sha256=sealed_copy_sha256,
        repository_attestation_sha256=attestation_sha256,
        corpus_manifest_sha256=corpus_manifest_sha256,
    )
    _validate_open_intent_absent(live_anchor_path, corpus_manifest_sha256)
    verified = verify_live_holdout_preopen(
        live_ledger_path=live_ledger_path,
        live_anchor_path=live_anchor_path,
        live_preopen_receipt_path=live_preopen_receipt_path,
        expected_live_ledger_root_identity_sha256=ledger_root_identity,
        expected_live_anchor_root_identity_sha256=anchor_root_identity,
        expected_live_preopen_receipt_sha256=receipt_file_sha256,
        repository_sealed_copy_path=repository_sealed_copy_path,
        expected_repository_sealed_copy_sha256=sealed_copy_sha256,
        repository_attestation_path=repository_attestation_path,
        expected_repository_attestation_sha256=attestation_sha256,
    )
    initialized = {
        "schema_version": "1.0.0",
        "initialization_status": "pass",
    }
    initialized.update(
        {
            field: value
            for field, value in verified.items()
            if field
            not in {"schema_version", "artifact_kind", "verification_status"}
        }
    )
    return initialized


def verify_live_holdout_preopen(
    *,
    live_ledger_path: Path,
    live_anchor_path: Path,
    live_preopen_receipt_path: Path,
    expected_live_ledger_root_identity_sha256: str,
    expected_live_anchor_root_identity_sha256: str,
    expected_live_preopen_receipt_sha256: str,
    repository_sealed_copy_path: Path,
    expected_repository_sealed_copy_sha256: str,
    repository_attestation_path: Path,
    expected_repository_attestation_sha256: str,
) -> Mapping[str, object]:
    """Verify the live preopen state and return path/identifier-free evidence.

    The ledger root and anchor/receipt root must be independent.  The ledger and
    immutable preopen receipt are required, while the open-intent anchor file
    must be absent.  Embedded paths in either repository record are treated as
    inert strings and are never resolved or opened.
    """

    for value, label in (
        (
            expected_live_ledger_root_identity_sha256,
            "expected live ledger root identity",
        ),
        (
            expected_live_anchor_root_identity_sha256,
            "expected live anchor root identity",
        ),
        (
            expected_live_preopen_receipt_sha256,
            "expected live preopen receipt hash",
        ),
        (
            expected_repository_sealed_copy_sha256,
            "expected repository sealed copy hash",
        ),
        (
            expected_repository_attestation_sha256,
            "expected repository attestation hash",
        ),
    ):
        _require_sha256(value, label)

    live_ledger_path = _normalized_absolute(live_ledger_path, "live ledger path")
    live_anchor_path = _normalized_absolute(live_anchor_path, "live anchor path")
    live_preopen_receipt_path = _normalized_absolute(
        live_preopen_receipt_path,
        "live preopen receipt path",
    )
    repository_sealed_copy_path = _normalized_absolute(
        repository_sealed_copy_path,
        "repository sealed copy path",
    )
    repository_attestation_path = _normalized_absolute(
        repository_attestation_path,
        "repository attestation path",
    )
    if live_ledger_path.name != LIVE_LEDGER_FILENAME:
        raise LiveHoldoutPreopenError(
            f"live ledger path must end in {LIVE_LEDGER_FILENAME}"
        )
    if live_anchor_path.name != LIVE_ANCHOR_FILENAME:
        raise LiveHoldoutPreopenError(
            f"live anchor path must end in {LIVE_ANCHOR_FILENAME}"
        )
    receipt_name = live_preopen_receipt_path.name
    if not (
        receipt_name.startswith(PREOPEN_RECEIPT_PREFIX)
        and receipt_name.endswith(PREOPEN_RECEIPT_SUFFIX)
    ):
        raise LiveHoldoutPreopenError(
            "live preopen receipt path does not use the versioned filename contract"
        )
    receipt_version = receipt_name[
        len(PREOPEN_RECEIPT_PREFIX) : -len(PREOPEN_RECEIPT_SUFFIX)
    ]
    if not VERSION_PATTERN.fullmatch(receipt_version):
        raise LiveHoldoutPreopenError(
            "live preopen receipt filename has an invalid version"
        )

    ledger_root = live_ledger_path.parent
    anchor_root = live_anchor_path.parent
    if live_preopen_receipt_path.parent != anchor_root:
        raise LiveHoldoutPreopenError(
            "live preopen receipt must be a sibling of the open-intent anchor"
        )
    _require_independent_roots(ledger_root, anchor_root)
    actual_ledger_root_identity = filesystem_directory_identity_sha256(ledger_root)
    actual_anchor_root_identity = filesystem_directory_identity_sha256(anchor_root)
    if actual_ledger_root_identity != expected_live_ledger_root_identity_sha256:
        raise LiveHoldoutPreopenError("live ledger root identity differs from its lock")
    if actual_anchor_root_identity != expected_live_anchor_root_identity_sha256:
        raise LiveHoldoutPreopenError("live anchor root identity differs from its lock")

    live_ledger_payload, live_ledger = _read_json(
        live_ledger_path,
        "live access ledger",
    )
    live_corpus_sha256, access_count = _validate_live_ledger(live_ledger)
    _validate_open_intent_absent(live_anchor_path, live_corpus_sha256)

    sealed_copy_payload, sealed_copy = _read_json(
        repository_sealed_copy_path,
        "repository sealed ledger copy",
    )
    sealed_copy_sha256 = _sha256(sealed_copy_payload)
    if sealed_copy_sha256 != expected_repository_sealed_copy_sha256:
        raise LiveHoldoutPreopenError(
            "repository sealed ledger copy differs from its expected hash"
        )
    attestation_payload, attestation = _read_json(
        repository_attestation_path,
        "repository seal attestation",
    )
    attestation_sha256 = _sha256(attestation_payload)
    if attestation_sha256 != expected_repository_attestation_sha256:
        raise LiveHoldoutPreopenError(
            "repository seal attestation differs from its expected hash"
        )
    _validate_repository_preopen_evidence(
        sealed_copy,
        attestation,
        sealed_copy_sha256=sealed_copy_sha256,
        live_corpus_manifest_sha256=live_corpus_sha256,
    )

    receipt_metadata = _validate_existing_components(
        live_preopen_receipt_path,
        label="live preopen receipt",
        leaf_kind="file",
    )
    if not hasattr(stat, "UF_IMMUTABLE") or not hasattr(os, "chflags"):
        raise LiveHoldoutPreopenError(
            "live preopen receipt cannot prove macOS user immutability"
        )
    if not receipt_metadata.st_flags & stat.UF_IMMUTABLE:
        raise LiveHoldoutPreopenError(
            "live preopen receipt is not user immutable"
        )
    receipt_payload, receipt = _read_json(
        live_preopen_receipt_path,
        "live preopen receipt",
    )
    receipt_file_sha256 = _sha256(receipt_payload)
    _validate_preopen_receipt(
        receipt,
        expected_receipt_file_sha256=expected_live_preopen_receipt_sha256,
        actual_receipt_file_sha256=receipt_file_sha256,
        live_ledger_sha256=_sha256(live_ledger_payload),
        live_ledger_root_identity_sha256=actual_ledger_root_identity,
        live_anchor_root_identity_sha256=actual_anchor_root_identity,
        repository_sealed_copy_sha256=sealed_copy_sha256,
        repository_attestation_sha256=attestation_sha256,
        corpus_manifest_sha256=live_corpus_sha256,
    )
    if receipt.get("version_id") != receipt_version:
        raise LiveHoldoutPreopenError(
            "live preopen receipt version differs from its filename"
        )

    if filesystem_directory_identity_sha256(ledger_root) != actual_ledger_root_identity:
        raise LiveHoldoutPreopenError(
            "live ledger root identity changed during verification"
        )
    if filesystem_directory_identity_sha256(anchor_root) != actual_anchor_root_identity:
        raise LiveHoldoutPreopenError(
            "live anchor root identity changed during verification"
        )
    _validate_open_intent_absent(live_anchor_path, live_corpus_sha256)
    _require_file_sha256(
        live_ledger_path,
        _sha256(live_ledger_payload),
        "live access ledger",
    )
    _require_file_sha256(
        live_preopen_receipt_path,
        receipt_file_sha256,
        "live preopen receipt",
    )
    _require_file_sha256(
        repository_sealed_copy_path,
        sealed_copy_sha256,
        "repository sealed ledger copy",
    )
    _require_file_sha256(
        repository_attestation_path,
        attestation_sha256,
        "repository seal attestation",
    )

    record: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "live_holdout_preopen_verification",
        "verification_status": "pass",
        "access_status": "unopened",
        "access_count": access_count,
        "open_intent_anchor_present": False,
        "pixel_content_included": False,
        "live_ledger_sha256": _sha256(live_ledger_payload),
        "live_ledger_root_identity_sha256": actual_ledger_root_identity,
        "live_anchor_root_identity_sha256": actual_anchor_root_identity,
        "live_preopen_receipt_sha256": receipt_file_sha256,
        "repository_sealed_copy_sha256": sealed_copy_sha256,
        "repository_attestation_sha256": attestation_sha256,
        "corpus_binding_sha256": live_corpus_sha256,
    }
    record["verification_receipt_sha256"] = _canonical_sha256(record)
    _validate_schema(record, VERIFICATION_SCHEMA, "live preopen verification")
    return record
