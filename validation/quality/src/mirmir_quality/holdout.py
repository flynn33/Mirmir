"""Persistent holdout authorization that fails closed before any payload read."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
from typing import Callable, Dict, Mapping, TypeVar

from .harness_manifest import (
    QualityHarnessManifestError,
    validate_quality_harness_implementation_manifest,
)
from .json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
    read_json,
    validate_schema,
)


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_HASHES = (
    "mapping_sha256",
    "operator_bank_sha256",
    "quality_policy_sha256",
    "metric_policy_sha256",
    "metric_implementation_sha256",
    "metric_conformance_sha256",
    "degradation_policy_sha256",
    "actual_codec_fixture_sha256",
    "actual_codec_evidence_sha256",
    "quality_harness_implementation_manifest_sha256",
    "compiler_inputs_sha256",
    "route_luts_sha256",
    "corpus_manifest_sha256",
)
T = TypeVar("T")
HOLDOUT_ACCESS_THREAT_BOUNDARY = (
    "cooperating-processes-v1; deliberate owner-or-administrator flag clearing, "
    "direct media access, code bypass, and filesystem rollback are outside scope"
)
CONFIGURATION_LOCK_SCHEMA = (
    Path(__file__).resolve().parents[2]
    / "schemas"
    / "configuration-lock.schema.json"
)
CONFIGURATION_LOCK_V2_SCHEMA = (
    Path(__file__).resolve().parents[3]
    / "calibration_v2"
    / "schemas"
    / "p06-configuration-lock-v2.schema.json"
)
V3_CONFIGURATION_FILE_ORDER = (
    ("locked_mapping", "locked-mapping.json"),
    ("locked_operator_bank", "locked-operator-bank.json"),
    ("locked_quality_policy", "locked-quality-policy.json"),
    ("locked_metric_policy", "locked-metric-policy.json"),
    ("locked_compiler_input_v2", "locked-compiler-input-v2.json"),
    ("direct2x_lut", "direct2x.ashlut"),
    ("direct3over2_lut", "direct3over2.ashlut"),
    ("native_parity_manifest", "native-lut-parity-manifest-v3.json"),
    ("lut_manifest", "lut-manifest-v3.json"),
)
V3_CONFIGURATION_LOCK_FIELDS = {
    "schema_version",
    "artifact_kind",
    "status",
    "locked_utc",
    "configuration_id",
    "candidate_vector_sha256",
    "shared_bank_configuration_sha256",
    "calibration_selection",
    "selected_evaluation",
    "configuration_files",
    "candidate_bytes_rewritten_after_selection",
    "holdout_accessed",
    "manifest_sha256",
}


class HoldoutAccessError(PermissionError):
    pass


@dataclass(frozen=True)
class HashBinding:
    """Bind one configuration-lock hash to actual bytes or a canonical manifest hash."""

    path: Path
    root: Path
    digest_mode: str = "file_sha256"
    manifest_hash_field: str = "manifest_sha256"


def hash_binding_digest(field: str, binding: HashBinding) -> str:
    """Reopen one bound artifact using the holdout guard's exact digest mode."""

    if field not in REQUIRED_HASHES:
        raise HoldoutAccessError(f"unsupported configuration binding field: {field}")
    if not isinstance(binding, HashBinding):
        raise TypeError("configuration artifact binding must be HashBinding")
    root = Path(os.path.abspath(binding.root))
    path = Path(os.path.abspath(binding.path))
    if root.is_symlink() or not root.is_dir():
        raise HoldoutAccessError(f"bound artifact root {field} is absent or symbolic")
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise HoldoutAccessError(f"bound artifact {field} escapes its trusted root") from error
    if not relative.parts:
        raise HoldoutAccessError(f"bound artifact {field} does not name a file")
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise HoldoutAccessError(f"bound artifact {field} traverses a symbolic link")
    try:
        root_resolved = root.resolve(strict=True)
        resolved = path.resolve(strict=True)
        resolved.relative_to(root_resolved)
    except (FileNotFoundError, ValueError) as error:
        raise HoldoutAccessError(
            f"bound artifact {field} is absent or escapes its trusted root"
        ) from error
    if not resolved.is_file():
        raise HoldoutAccessError(f"bound artifact {field} is absent or not a regular file")
    if binding.digest_mode == "file_sha256":
        return _sha256_file(resolved)
    if binding.digest_mode == "manifest_sha256":
        value = read_json(resolved)
        if not isinstance(value, dict):
            raise HoldoutAccessError(f"bound manifest {field} is not an object")
        declared = value.get(binding.manifest_hash_field)
        actual = manifest_sha256(value, binding.manifest_hash_field)
        if declared != actual:
            raise HoldoutAccessError(f"bound manifest {field} has an invalid self-hash")
        return str(actual)
    if binding.digest_mode == "quality_harness_manifest":
        if field != "quality_harness_implementation_manifest_sha256":
            raise HoldoutAccessError(
                f"bound artifact {field} cannot use quality-harness validation"
            )
        try:
            value = read_json(resolved)
        except (OSError, json.JSONDecodeError) as error:
            raise HoldoutAccessError(
                "bound quality-harness implementation manifest cannot be read"
            ) from error
        if not isinstance(value, dict):
            raise HoldoutAccessError(
                "bound quality-harness implementation manifest is not an object"
            )
        try:
            return validate_quality_harness_implementation_manifest(
                value,
                root,
            )
        except QualityHarnessManifestError as error:
            raise HoldoutAccessError(
                "bound quality-harness implementation manifest is invalid: "
                f"{error}"
            ) from error
    raise HoldoutAccessError(f"bound artifact {field} has an unsupported digest mode")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _write_exclusive(path: Path, value: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        indent=2,
    ).encode("utf-8") + b"\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def _atomic_replace(path: Path, value: Mapping[str, object]) -> None:
    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.partial"
    )
    _write_exclusive(temporary, value)
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def _seal_access_anchor(path: Path) -> None:
    """Apply and verify the macOS user-immutable flag before any holdout read."""

    if not hasattr(os, "chflags") or not hasattr(stat, "UF_IMMUTABLE"):
        raise HoldoutAccessError(
            "persistent holdout anchor requires macOS user-immutable flags"
        )
    try:
        before = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or path.is_symlink():
            raise HoldoutAccessError(
                "persistent holdout anchor is not a regular nonsymbolic file"
            )
        os.chflags(
            path,
            before.st_flags | stat.UF_IMMUTABLE,
            follow_symlinks=False,
        )
        after = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise HoldoutAccessError(
            "persistent holdout anchor could not be made user-immutable"
        ) from error
    if not after.st_flags & stat.UF_IMMUTABLE:
        raise HoldoutAccessError(
            "persistent holdout anchor user-immutable flag was not retained"
        )


def _ledger_event(
    *,
    sequence: int,
    event: str,
    occurred_utc: str,
    previous_entry_sha256: str,
    details: Mapping[str, object],
) -> Dict[str, object]:
    record: Dict[str, object] = {
        "sequence": sequence,
        "event": event,
        "occurred_utc": occurred_utc,
        "previous_entry_sha256": previous_entry_sha256,
        "details": dict(details),
    }
    record["entry_sha256"] = canonical_sha256(record)
    return record


def initialize_holdout_access_ledger(
    path: Path,
    corpus_manifest_sha256: str,
    *,
    created_utc: str,
    anchor_path: Path,
) -> None:
    """Create sealed state only when the separately rooted access anchor is unused."""

    if not SHA256_PATTERN.fullmatch(corpus_manifest_sha256):
        raise ValueError("corpus manifest hash is invalid")
    _validate_anchor_location(path, anchor_path)
    if os.path.lexists(anchor_path):
        raise HoldoutAccessError("persistent holdout anchor records prior access")
    event = _ledger_event(
        sequence=0,
        event="sealed",
        occurred_utc=created_utc,
        previous_entry_sha256="0" * 64,
        details={"corpus_manifest_sha256": corpus_manifest_sha256},
    )
    ledger = {
        "schema_version": "1.0.0",
        "corpus_manifest_sha256": corpus_manifest_sha256,
        "state": "sealed",
        "open_intent_utc": None,
        "opened_utc": None,
        "completed_utc": None,
        "events": [event],
    }
    _write_exclusive(path, ledger)


def _validate_anchor_location(ledger_path: Path, anchor_path: Path) -> None:
    ledger_parent = ledger_path.parent.resolve(strict=False)
    anchor_parent = anchor_path.parent.resolve(strict=False)
    try:
        anchor_parent.relative_to(ledger_parent)
        overlaps = True
    except ValueError:
        overlaps = False
    try:
        ledger_parent.relative_to(anchor_parent)
        overlaps = True
    except ValueError:
        pass
    if overlaps:
        raise ValueError("holdout anchor must use an independent storage root")


class HoldoutAccessGuard:
    """Verify locked bytes and persist a user-immutable cooperating-process receipt."""

    def __init__(
        self,
        expected_corpus_manifest_sha256: str,
        *,
        ledger_path: Path,
        anchor_path: Path,
        hash_bindings: Mapping[str, HashBinding],
        clock: Callable[[], str] = _utc_now,
    ) -> None:
        if not SHA256_PATTERN.fullmatch(expected_corpus_manifest_sha256):
            raise ValueError("expected corpus hash is invalid")
        if set(hash_bindings) != set(REQUIRED_HASHES):
            raise ValueError("hash bindings must contain exactly the required artifacts")
        if any(not isinstance(value, HashBinding) for value in hash_bindings.values()):
            raise ValueError("every holdout hash binding must declare a trusted root")
        harness_binding = hash_bindings[
            "quality_harness_implementation_manifest_sha256"
        ]
        if harness_binding.digest_mode != "quality_harness_manifest":
            raise ValueError(
                "quality-harness implementation binding must use recursive validation"
            )
        _validate_anchor_location(ledger_path, anchor_path)
        self.expected_corpus_manifest_sha256 = expected_corpus_manifest_sha256
        self.ledger_path = ledger_path
        self.anchor_path = anchor_path
        self.intent_path = anchor_path
        self.hash_bindings = dict(hash_bindings)
        self.clock = clock

    def _binding_digest(self, field: str, binding: HashBinding) -> str:
        return hash_binding_digest(field, binding)

    def _validate_hash_bindings(self, configuration_lock: Mapping[str, object]) -> None:
        for field in REQUIRED_HASHES:
            value = configuration_lock.get(field)
            if not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value):
                raise HoldoutAccessError(f"configuration hash {field} is absent or invalid")
            actual = self._binding_digest(field, self.hash_bindings[field])
            if actual != value:
                raise HoldoutAccessError(f"bound artifact {field} does not match the lock")

    def _read_ledger(self) -> Dict[str, object]:
        try:
            ledger = read_json(self.ledger_path)
        except (FileNotFoundError, json.JSONDecodeError) as error:
            raise HoldoutAccessError("persistent holdout ledger is absent or invalid") from error
        if not isinstance(ledger, dict) or ledger.get("schema_version") != "1.0.0":
            raise HoldoutAccessError("persistent holdout ledger has an invalid schema version")
        if ledger.get("corpus_manifest_sha256") != self.expected_corpus_manifest_sha256:
            raise HoldoutAccessError("persistent holdout ledger is bound to a different corpus")
        events = ledger.get("events")
        if not isinstance(events, list) or not events:
            raise HoldoutAccessError("persistent holdout ledger has no hash-chain events")
        previous = "0" * 64
        event_names = []
        event_timestamps: Dict[str, str] = {}
        for sequence, event in enumerate(events):
            if not isinstance(event, dict):
                raise HoldoutAccessError("persistent holdout ledger event is invalid")
            if event.get("sequence") != sequence or event.get("previous_entry_sha256") != previous:
                raise HoldoutAccessError("persistent holdout ledger hash chain is discontinuous")
            expected = canonical_sha256(
                {key: value for key, value in event.items() if key != "entry_sha256"}
            )
            if event.get("entry_sha256") != expected:
                raise HoldoutAccessError("persistent holdout ledger event hash is invalid")
            previous = expected
            event_name = str(event.get("event", ""))
            event_names.append(event_name)
            event_timestamps[event_name] = str(event.get("occurred_utc", ""))
        state = ledger.get("state")
        valid_sequences = {
            "sealed": ["sealed"],
            "intent_recorded": ["sealed", "open_intent"],
            "opened": ["sealed", "open_intent", "opened"],
            "completed": ["sealed", "open_intent", "opened", "completed"],
            "failed": ["sealed", "open_intent", "opened", "failed_after_open"],
        }
        if state not in valid_sequences or event_names != valid_sequences[state]:
            raise HoldoutAccessError("persistent holdout ledger state transition is invalid")
        expected_timestamps = {
            "open_intent_utc": event_timestamps.get("open_intent"),
            "opened_utc": event_timestamps.get("opened"),
            "completed_utc": event_timestamps.get("completed")
            or event_timestamps.get("failed_after_open"),
        }
        for field, expected_timestamp in expected_timestamps.items():
            if ledger.get(field) != expected_timestamp:
                raise HoldoutAccessError("persistent holdout ledger timestamps do not match events")
        return ledger

    def _append_event(
        self,
        ledger: Dict[str, object],
        *,
        event: str,
        occurred_utc: str,
        state: str,
        details: Mapping[str, object],
    ) -> Dict[str, object]:
        events = list(ledger["events"])
        events.append(
            _ledger_event(
                sequence=len(events),
                event=event,
                occurred_utc=occurred_utc,
                previous_entry_sha256=str(events[-1]["entry_sha256"]),
                details=details,
            )
        )
        updated = dict(ledger)
        updated["events"] = events
        updated["state"] = state
        if event == "open_intent":
            updated["open_intent_utc"] = occurred_utc
        elif event == "opened":
            updated["opened_utc"] = occurred_utc
        elif event in {"completed", "failed_after_open"}:
            updated["completed_utc"] = occurred_utc
        _atomic_replace(self.ledger_path, updated)
        return updated

    def validate_lock(self, configuration_lock: Mapping[str, object]) -> None:
        try:
            validate_schema(
                dict(configuration_lock),
                CONFIGURATION_LOCK_SCHEMA,
            )
        except (OSError, ValueError) as error:
            raise HoldoutAccessError(
                "configuration lock schema validation failed"
            ) from error
        if configuration_lock.get("schema_version") != "1.0.0":
            raise HoldoutAccessError("configuration lock schema is incomplete")
        if configuration_lock.get("release_fields_complete") is not True:
            raise HoldoutAccessError("release fields are incomplete")
        if configuration_lock.get("configuration_files_modified_after_lock") is not False:
            raise HoldoutAccessError("configuration changed after lock")
        if not configuration_lock.get("locked_utc"):
            raise HoldoutAccessError("configuration lock timestamp is absent")
        self._validate_hash_bindings(configuration_lock)
        if configuration_lock["corpus_manifest_sha256"] != self.expected_corpus_manifest_sha256:
            raise HoldoutAccessError("holdout corpus hash does not match the configuration lock")
        if configuration_lock.get("holdout_opened_utc") is not None:
            raise HoldoutAccessError("holdout was already opened for this configuration")
        ledger = self._read_ledger()
        if os.path.lexists(self.anchor_path) or ledger.get("state") != "sealed":
            raise HoldoutAccessError("persistent holdout ledger already contains an open intent")
        if any(ledger.get(field) is not None for field in ("open_intent_utc", "opened_utc", "completed_utc")):
            raise HoldoutAccessError("persistent holdout ledger contains a prior open timestamp")

    def read_once(
        self,
        configuration_lock: Mapping[str, object],
        loader: Callable[[], T],
    ) -> T:
        locked_configuration = dict(configuration_lock)
        self.validate_lock(locked_configuration)
        intent_utc = self.clock()
        configuration_sha256 = canonical_sha256(locked_configuration)
        intent = {
            "schema_version": "1.0.0",
            "artifact_kind": "holdout_access_anchor",
            "corpus_manifest_sha256": self.expected_corpus_manifest_sha256,
            "configuration_sha256": configuration_sha256,
            "open_intent_utc": intent_utc,
            "persistence": "macos-user-immutable-v1",
            "threat_boundary": HOLDOUT_ACCESS_THREAT_BOUNDARY,
        }
        try:
            _write_exclusive(self.anchor_path, intent)
        except FileExistsError as error:
            raise HoldoutAccessError("persistent holdout open intent already exists") from error
        _seal_access_anchor(self.anchor_path)
        anchor_sha256 = _sha256_file(self.anchor_path)

        ledger = self._read_ledger()
        ledger = self._append_event(
            ledger,
            event="open_intent",
            occurred_utc=intent_utc,
            state="intent_recorded",
            details={
                "configuration_sha256": configuration_sha256,
                "external_anchor_sha256": anchor_sha256,
            },
        )
        opened_utc = self.clock()
        ledger = self._append_event(
            ledger,
            event="opened",
            occurred_utc=opened_utc,
            state="opened",
            details={"receipt": "persisted before loader delegation"},
        )
        try:
            result = loader()
            self._validate_hash_bindings(locked_configuration)
        except BaseException as error:
            self._append_event(
                ledger,
                event="failed_after_open",
                occurred_utc=self.clock(),
                state="failed",
                details={"failure_type": type(error).__name__},
            )
            raise
        self._append_event(
            ledger,
            event="completed",
            occurred_utc=self.clock(),
            state="completed",
            details={"post_loader_bindings_reverified": True},
        )
        return result


class P06V3HoldoutAccessGuard(HoldoutAccessGuard):
    """Authorize P07 only from the exact schema-3 P06 configuration bytes."""

    def __init__(
        self,
        expected_corpus_manifest_sha256: str,
        *,
        ledger_path: Path,
        anchor_path: Path,
        release_root: Path,
        clock: Callable[[], str] = _utc_now,
    ) -> None:
        if not SHA256_PATTERN.fullmatch(expected_corpus_manifest_sha256):
            raise ValueError("expected corpus hash is invalid")
        root = Path(os.path.abspath(release_root))
        if len(root.parts) >= 2 and root.parts[1] == "var":
            root = Path("/private/var").joinpath(*root.parts[2:])
        if root.is_symlink() or not root.is_dir():
            raise ValueError("P06 V3 release root must be one real directory")
        _validate_anchor_location(ledger_path, anchor_path)
        self.expected_corpus_manifest_sha256 = expected_corpus_manifest_sha256
        self.ledger_path = ledger_path
        self.anchor_path = anchor_path
        self.intent_path = anchor_path
        self.release_root = root
        self.hash_bindings = {
            identifier: HashBinding(path=root / filename, root=root)
            for identifier, filename in V3_CONFIGURATION_FILE_ORDER
        }
        self.clock = clock

    @staticmethod
    def _validate_release_binding(binding: object, label: str) -> Mapping[str, object]:
        if not isinstance(binding, dict) or set(binding) != {
            "path",
            "sha256",
            "size_bytes",
        }:
            raise HoldoutAccessError(f"{label} binding is not exact")
        if (
            not isinstance(binding.get("path"), str)
            or not binding["path"]
            or not SHA256_PATTERN.fullmatch(str(binding.get("sha256", "")))
            or not isinstance(binding.get("size_bytes"), int)
            or isinstance(binding.get("size_bytes"), bool)
            or int(binding["size_bytes"]) <= 0
        ):
            raise HoldoutAccessError(f"{label} binding is invalid")
        return binding

    def _validate_hash_bindings(self, configuration_lock: Mapping[str, object]) -> None:
        self._validate_release_lock_bytes(configuration_lock)
        rows = configuration_lock.get("configuration_files")
        if not isinstance(rows, list) or len(rows) != len(V3_CONFIGURATION_FILE_ORDER):
            raise HoldoutAccessError("P06 V3 configuration-file bindings are not exact")
        for row, (identifier, filename) in zip(rows, V3_CONFIGURATION_FILE_ORDER):
            if not isinstance(row, dict) or set(row) != {
                "id",
                "path",
                "sha256",
                "size_bytes",
            }:
                raise HoldoutAccessError(
                    f"P06 V3 configuration binding is not exact: {identifier}"
                )
            if row.get("id") != identifier or row.get("path") != filename:
                raise HoldoutAccessError(
                    f"P06 V3 configuration filename differs: {identifier}"
                )
            expected_sha256 = row.get("sha256")
            expected_size = row.get("size_bytes")
            if (
                not isinstance(expected_sha256, str)
                or not SHA256_PATTERN.fullmatch(expected_sha256)
                or not isinstance(expected_size, int)
                or isinstance(expected_size, bool)
                or expected_size <= 0
            ):
                raise HoldoutAccessError(
                    f"P06 V3 configuration binding is invalid: {identifier}"
                )
            binding = self.hash_bindings[identifier]
            actual_sha256 = hash_binding_digest_v3(identifier, binding)
            try:
                actual_size = os.stat(binding.path, follow_symlinks=False).st_size
            except OSError as error:
                raise HoldoutAccessError(
                    f"P06 V3 configuration file is absent: {identifier}"
                ) from error
            if actual_sha256 != expected_sha256 or actual_size != expected_size:
                raise HoldoutAccessError(
                    f"P06 V3 configuration bytes differ: {identifier}"
                )

    def _validate_release_lock_bytes(
        self,
        configuration_lock: Mapping[str, object],
    ) -> None:
        try:
            # Lazy import avoids the release_lock -> holdout module cycle while
            # retaining one authoritative descriptor-safe P06 validator.
            from validation.calibration_v2.release_lock import (
                validate_p06_configuration_lock_v2,
            )

            lock_path = self.release_root / "configuration-lock-v2.json"
            validated = validate_p06_configuration_lock_v2(
                release_root=self.release_root,
                expected_file_sha256=_sha256_file(lock_path),
            )
        except (OSError, ValueError) as error:
            raise HoldoutAccessError(
                "P06 V3 configuration lock release validation failed"
            ) from error
        if validated != configuration_lock:
            raise HoldoutAccessError(
                "supplied P06 V3 configuration lock differs from release"
            )

    def validate_lock(self, configuration_lock: Mapping[str, object]) -> None:
        try:
            validate_schema(
                dict(configuration_lock),
                CONFIGURATION_LOCK_V2_SCHEMA,
            )
        except (OSError, ValueError) as error:
            raise HoldoutAccessError(
                "P06 V3 configuration lock schema validation failed"
            ) from error
        if not isinstance(configuration_lock, dict) or set(configuration_lock) != (
            V3_CONFIGURATION_LOCK_FIELDS
        ):
            raise HoldoutAccessError("P06 V3 configuration lock fields are not exact")
        if (
            configuration_lock.get("schema_version") != "2.0.0"
            or configuration_lock.get("artifact_kind")
            != "p06_configuration_lock_v2"
            or configuration_lock.get("status") != "locked_before_p07"
            or not isinstance(configuration_lock.get("locked_utc"), str)
            or not configuration_lock.get("locked_utc")
            or not isinstance(configuration_lock.get("configuration_id"), str)
            or not configuration_lock.get("configuration_id")
            or not SHA256_PATTERN.fullmatch(
                str(configuration_lock.get("candidate_vector_sha256", ""))
            )
            or not SHA256_PATTERN.fullmatch(
                str(configuration_lock.get("shared_bank_configuration_sha256", ""))
            )
            or configuration_lock.get("candidate_bytes_rewritten_after_selection")
            is not False
            or configuration_lock.get("holdout_accessed") is not False
        ):
            raise HoldoutAccessError("P06 V3 configuration lock is incomplete")
        self._validate_release_binding(
            configuration_lock.get("calibration_selection"),
            "P06 V3 calibration selection",
        )
        self._validate_release_binding(
            configuration_lock.get("selected_evaluation"),
            "P06 V3 selected evaluation",
        )
        if configuration_lock.get("manifest_sha256") != manifest_sha256(
            dict(configuration_lock),
            "manifest_sha256",
        ):
            raise HoldoutAccessError("P06 V3 configuration lock self-hash differs")
        self._validate_hash_bindings(configuration_lock)
        ledger = self._read_ledger()
        if os.path.lexists(self.anchor_path) or ledger.get("state") != "sealed":
            raise HoldoutAccessError("persistent holdout ledger already contains an open intent")
        if any(
            ledger.get(field) is not None
            for field in ("open_intent_utc", "opened_utc", "completed_utc")
        ):
            raise HoldoutAccessError(
                "persistent holdout ledger contains a prior open timestamp"
            )


def hash_binding_digest_v3(identifier: str, binding: HashBinding) -> str:
    """Reopen one exact P06 V3 configuration file without legacy field aliases."""

    if identifier not in {row[0] for row in V3_CONFIGURATION_FILE_ORDER}:
        raise HoldoutAccessError(
            f"unsupported P06 V3 configuration binding: {identifier}"
        )
    if not isinstance(binding, HashBinding) or binding.digest_mode != "file_sha256":
        raise HoldoutAccessError(
            f"invalid P06 V3 configuration binding: {identifier}"
        )
    root = Path(os.path.abspath(binding.root))
    path = Path(os.path.abspath(binding.path))
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise HoldoutAccessError(
            f"P06 V3 configuration file escapes release root: {identifier}"
        ) from error
    if relative.as_posix() != dict(V3_CONFIGURATION_FILE_ORDER)[identifier]:
        raise HoldoutAccessError(
            f"P06 V3 configuration filename differs: {identifier}"
        )
    if root.is_symlink() or not root.is_dir() or path.is_symlink():
        raise HoldoutAccessError(
            f"P06 V3 configuration path is symbolic: {identifier}"
        )
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise HoldoutAccessError(
            f"P06 V3 configuration file is absent: {identifier}"
        ) from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise HoldoutAccessError(
            f"P06 V3 configuration file is not singular: {identifier}"
        )
    return _sha256_file(path)
