"""Cycle-free P07 production authority projected before a P06 V3 release lock."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
from typing import Mapping, Sequence

from validation.calibration_v2.current_source_gate_closure_v2 import (
    CurrentSourceGateClosureV2Error,
    staged_current_source_gate_receipt_projection_v2,
)
from validation.calibration_v2.macos_code_identity import static_code_identity
from validation.calibration_v2.release_evidence import evidence_binding
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = (
    CALIBRATION_ROOT
    / "schemas"
    / "p07-production-execution-authority-v2.schema.json"
)
FILENAME = "p07-production-execution-authority-v2.json"
SUPPORT_BINDING_ORDER = (
    ("open_split_tree", "open_split"),
    ("calibration_evidence_tree", "calibration_evidence"),
    ("native_cache_tree", "native_cache"),
    ("production_writer_tree", "production_writer"),
    ("dispatch_measurement_tree", "dispatch_measurement"),
    ("complete_calibration_run_tree", "calibration_run"),
)
RELEASE_FILE_ORDER = (
    "candidate_runtime_manifest_v2",
    "production_swift_executable",
    "production_swift_source_manifest",
)
EXTERNAL_FILE_ORDER = (
    "production_writer_executable",
    "p00_native_executable",
    "product_settings_source",
)
CODE_IDENTITY_ORDER = (
    "production_swift_executable",
    "production_writer_executable",
    "p00_native_executable",
)


class P07ExecutionAuthorityV2Error(ValueError):
    """A P07 V2 authority projection is incomplete, mutable, or inconsistent."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and value != "0" * 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _require_sha256(value: object, label: str) -> str:
    if not _is_sha256(value):
        raise P07ExecutionAuthorityV2Error(f"{label} is not a lowercase SHA-256")
    return str(value)


def _strict_root(path: Path, label: str) -> Path:
    if not isinstance(path, Path) or not path.is_absolute():
        raise P07ExecutionAuthorityV2Error(f"{label} is not an absolute pathlib.Path")
    if len(path.parts) >= 2 and path.parts[1] == "var":
        path = Path("/private/var").joinpath(*path.parts[2:])
    normalized = Path(os.path.normpath(os.fspath(path)))
    if normalized != path:
        raise P07ExecutionAuthorityV2Error(f"{label} is not lexically normalized")
    cursor = Path(path.anchor)
    for part in path.parts[1:]:
        cursor /= part
        try:
            metadata = os.lstat(cursor)
        except OSError as error:
            raise P07ExecutionAuthorityV2Error(f"{label} is absent") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise P07ExecutionAuthorityV2Error(
                f"{label} traverses a symlink or non-directory"
            )
    return path


def _strict_file(path: Path, label: str, *, executable: bool) -> Path:
    if not isinstance(path, Path) or not path.is_absolute():
        raise P07ExecutionAuthorityV2Error(f"{label} is not an absolute pathlib.Path")
    if len(path.parts) >= 2 and path.parts[1] == "var":
        path = Path("/private/var").joinpath(*path.parts[2:])
    normalized = Path(os.path.normpath(os.fspath(path)))
    if normalized != path:
        raise P07ExecutionAuthorityV2Error(f"{label} is not lexically normalized")
    _strict_root(path.parent, f"{label} parent")
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise P07ExecutionAuthorityV2Error(f"{label} is absent") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or (executable and stat.S_IMODE(metadata.st_mode) & 0o111 == 0)
    ):
        raise P07ExecutionAuthorityV2Error(f"{label} is not a singular regular file")
    return path


def _binding(
    *,
    identifier: str,
    root_id: str,
    path: Path,
    root: Path,
) -> Mapping[str, object]:
    try:
        return evidence_binding(
            identifier=identifier,
            root_id=root_id,
            path=path,
            root=root,
        )
    except (OSError, ValueError) as error:
        raise P07ExecutionAuthorityV2Error(
            f"P07 execution authority binding cannot be derived: {identifier}"
        ) from error


def _validate_document(document: Mapping[str, object]) -> None:
    try:
        validate_schema(document, SCHEMA_PATH)
    except ValueError as error:
        raise P07ExecutionAuthorityV2Error(
            "P07 production execution authority violates schema"
        ) from error
    if document.get("artifact_sha256") != canonical_sha256(
        {key: value for key, value in document.items() if key != "artifact_sha256"}
    ):
        raise P07ExecutionAuthorityV2Error(
            "P07 production execution authority self-hash differs"
        )
    identities = document.get("macos_code_identities")
    release_files = document.get("release_files")
    external_files = document.get("external_files")
    if not isinstance(identities, dict) or not isinstance(release_files, list) \
            or not isinstance(external_files, list):
        raise P07ExecutionAuthorityV2Error(
            "P07 production execution authority identity bindings are absent"
        )
    files = {
        str(row["id"]): row
        for row in (*release_files, *external_files)
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }
    for identifier in CODE_IDENTITY_ORDER:
        identity = identities.get(identifier)
        binding = files.get(identifier)
        if (
            not isinstance(identity, dict)
            or not isinstance(binding, dict)
            or identity.get("file_sha256") != binding.get("sha256")
            or len(identity.get("all_cdhashes", []))
            != len(identity.get("digest_algorithms", []))
            or identity.get("unique_cdhash") not in identity.get("all_cdhashes", [])
        ):
            raise P07ExecutionAuthorityV2Error(
                f"P07 code identity differs from its file binding: {identifier}"
            )


def build_document(
    *,
    configuration_id: str,
    candidate_vector_sha256: str,
    shared_bank_configuration_sha256: str,
    calibration_plan_v2_file_sha256: str,
    input_bundle_sha256: str,
    corpus_lock_bundle_sha256: str,
    raw_output_contract_sha256: str,
    release_root: Path,
    repository_root: Path,
    candidate_runtime_manifest_path: Path,
    native_executable_path: Path,
    native_source_manifest_path: Path,
    production_writer_executable_path: Path,
    p00_executable_path: Path,
    product_settings_source_path: Path,
    support_evidence_roots: Mapping[str, Path],
    support_evidence_paths: Mapping[str, Path],
) -> Mapping[str, object]:
    """Derive one immutable projection without referring to the cyclic final release hash."""

    release_root = _strict_root(release_root, "P06 V3 release root")
    repository_root = _strict_root(repository_root, "repository root")
    expected_root_ids = {root_id for _, root_id in SUPPORT_BINDING_ORDER}
    if set(support_evidence_roots) != expected_root_ids \
            or set(support_evidence_paths) != expected_root_ids:
        raise P07ExecutionAuthorityV2Error("P07 support evidence roots are not exact")
    roots = {
        root_id: _strict_root(root, f"{root_id} support root")
        for root_id, root in support_evidence_roots.items()
    }
    release_files = (
        _binding(
            identifier="candidate_runtime_manifest_v2",
            root_id="release",
            path=_strict_file(
                candidate_runtime_manifest_path,
                "candidate runtime manifest V2",
                executable=False,
            ),
            root=release_root,
        ),
        _binding(
            identifier="production_swift_executable",
            root_id="release",
            path=_strict_file(
                native_executable_path,
                "production Swift executable",
                executable=True,
            ),
            root=release_root,
        ),
        _binding(
            identifier="production_swift_source_manifest",
            root_id="release",
            path=_strict_file(
                native_source_manifest_path,
                "production Swift source manifest",
                executable=False,
            ),
            root=release_root,
        ),
    )
    external_files = (
        _binding(
            identifier="production_writer_executable",
            root_id="production_writer",
            path=_strict_file(
                production_writer_executable_path,
                "production writer executable",
                executable=True,
            ),
            root=roots["production_writer"],
        ),
        _binding(
            identifier="p00_native_executable",
            root_id="native_cache",
            path=_strict_file(
                p00_executable_path,
                "P00 native executable",
                executable=True,
            ),
            root=roots["native_cache"],
        ),
        _binding(
            identifier="product_settings_source",
            root_id="repository",
            path=_strict_file(
                product_settings_source_path,
                "product settings source",
                executable=False,
            ),
            root=repository_root,
        ),
    )
    support_bindings = tuple(
        _binding(
            identifier=identifier,
            root_id=root_id,
            path=_strict_root(
                support_evidence_paths[root_id],
                f"{root_id} bound support tree",
            ),
            root=roots[root_id],
        )
        for identifier, root_id in SUPPORT_BINDING_ORDER
    )
    code_paths = {
        "production_swift_executable": native_executable_path,
        "production_writer_executable": production_writer_executable_path,
        "p00_native_executable": p00_executable_path,
    }
    try:
        code_identities = {
            identifier: dict(static_code_identity(code_paths[identifier]))
            for identifier in CODE_IDENTITY_ORDER
        }
    except (OSError, ValueError, RuntimeError) as error:
        raise P07ExecutionAuthorityV2Error(
            "P07 production executable identity cannot be derived"
        ) from error
    try:
        source_gate_semantics = staged_current_source_gate_receipt_projection_v2(
            repository_root=repository_root,
            release_root=release_root,
        )
    except (OSError, CurrentSourceGateClosureV2Error) as error:
        raise P07ExecutionAuthorityV2Error(
            "P07 current-source gate semantics cannot be derived"
        ) from error
    core = {
        "schema_version": "2.0.0",
        "artifact_kind": "p07_production_execution_authority_v2",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "candidate_vector_sha256": _require_sha256(
            candidate_vector_sha256,
            "candidate vector",
        ),
        "shared_bank_configuration_sha256": _require_sha256(
            shared_bank_configuration_sha256,
            "shared-bank configuration",
        ),
        "calibration_plan_v2_file_sha256": _require_sha256(
            calibration_plan_v2_file_sha256,
            "calibration plan V2 file",
        ),
        "input_bundle_sha256": _require_sha256(input_bundle_sha256, "input bundle"),
        "corpus_lock_bundle_sha256": _require_sha256(
            corpus_lock_bundle_sha256,
            "corpus lock bundle",
        ),
        "raw_output_contract_sha256": _require_sha256(
            raw_output_contract_sha256,
            "raw output contract",
        ),
        "release_files": list(release_files),
        "external_files": list(external_files),
        "support_evidence_trees": list(support_bindings),
        "source_gate_semantics": dict(source_gate_semantics),
        "macos_code_identities": code_identities,
    }
    document = {**core, "artifact_sha256": canonical_sha256(core)}
    _validate_document(document)
    return document


def canonical_file_bytes(document: Mapping[str, object]) -> bytes:
    """Return the only permitted serialized projection bytes."""

    _validate_document(document)
    return canonical_json_bytes(document) + b"\n"


def publish_new(path: Path, document: Mapping[str, object]) -> Mapping[str, object]:
    """Publish once with O_EXCL and return the binding used by the P06 V3 bundle."""

    payload = canonical_file_bytes(document)
    if path.name != FILENAME:
        raise P07ExecutionAuthorityV2Error("P07 execution authority filename differs")
    parent = _strict_root(path.parent, "P07 execution authority parent")
    parent_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        descriptor = os.open(
            path.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o444,
            dir_fd=parent_descriptor,
        )
    finally:
        os.close(parent_descriptor)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise P07ExecutionAuthorityV2Error(
                    "P07 execution authority write made no progress"
                )
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    reopened = path.read_bytes()
    if reopened != payload:
        raise P07ExecutionAuthorityV2Error(
            "P07 execution authority differs after publication"
        )
    return {
        "path": FILENAME,
        "sha256": _sha256(reopened),
        "size_bytes": len(reopened),
    }


def verify(
    *,
    release_root: Path,
    repository_root: Path,
    expected_file_sha256: str,
    expected_configuration_id: str,
    expected_shared_bank_configuration_sha256: str,
    expected_input_bundle_sha256: str,
    expected_corpus_lock_bundle_sha256: str,
    support_evidence_roots: Mapping[str, Path],
) -> Mapping[str, object]:
    """Reopen and rederive every authority binding before any P07 execution."""

    release_root = _strict_root(release_root, "P06 V3 release root")
    repository_root = _strict_root(repository_root, "repository root")
    path = _strict_file(
        release_root / FILENAME,
        "P07 production execution authority",
        executable=False,
    )
    payload = path.read_bytes()
    if _sha256(payload) != _require_sha256(
        expected_file_sha256,
        "expected P07 execution authority file",
    ):
        raise P07ExecutionAuthorityV2Error(
            "P07 execution authority file hash differs from P06 V3"
        )
    try:
        import json

        document = json.loads(payload)
    except (UnicodeDecodeError, ValueError) as error:
        raise P07ExecutionAuthorityV2Error(
            "P07 execution authority is not JSON"
        ) from error
    if not isinstance(document, dict) or payload != canonical_file_bytes(document):
        raise P07ExecutionAuthorityV2Error(
            "P07 execution authority is not canonical JSON"
        )
    if (
        document.get("configuration_id") != expected_configuration_id
        or document.get("shared_bank_configuration_sha256")
        != _require_sha256(
            expected_shared_bank_configuration_sha256,
            "expected shared-bank configuration",
        )
        or document.get("input_bundle_sha256")
        != _require_sha256(expected_input_bundle_sha256, "expected input bundle")
        or document.get("corpus_lock_bundle_sha256")
        != _require_sha256(
            expected_corpus_lock_bundle_sha256,
            "expected corpus lock bundle",
        )
    ):
        raise P07ExecutionAuthorityV2Error(
            "P07 execution authority differs from the P06 V3 release identity"
        )
    expected_root_ids = {root_id for _, root_id in SUPPORT_BINDING_ORDER}
    if set(support_evidence_roots) != expected_root_ids:
        raise P07ExecutionAuthorityV2Error("P07 support evidence roots are not exact")
    roots = {
        root_id: _strict_root(root, f"{root_id} support root")
        for root_id, root in support_evidence_roots.items()
    }
    root_by_id = {"release": release_root, "repository": repository_root, **roots}
    rows = (
        list(document["release_files"])
        + list(document["external_files"])
        + list(document["support_evidence_trees"])
    )
    for row in rows:
        if not isinstance(row, dict):
            raise P07ExecutionAuthorityV2Error("P07 authority binding is invalid")
        root_id = str(row["root_id"])
        root = root_by_id[root_id]
        rebound = _binding(
            identifier=str(row["id"]),
            root_id=root_id,
            path=root.joinpath(*str(row["path"]).split("/")),
            root=root,
        )
        if rebound != row:
            raise P07ExecutionAuthorityV2Error(
                f"P07 authority bytes changed: {row['id']}"
            )
    files = {
        str(row["id"]): row
        for row in (*document["release_files"], *document["external_files"])
    }
    identities = document["macos_code_identities"]
    for identifier in CODE_IDENTITY_ORDER:
        binding = files[identifier]
        root = root_by_id[str(binding["root_id"])]
        executable = root.joinpath(*str(binding["path"]).split("/"))
        if dict(static_code_identity(executable)) != identities[identifier]:
            raise P07ExecutionAuthorityV2Error(
                f"P07 static code identity changed: {identifier}"
            )
    try:
        source_gate_semantics = staged_current_source_gate_receipt_projection_v2(
            repository_root=repository_root,
            release_root=release_root,
        )
    except (OSError, CurrentSourceGateClosureV2Error) as error:
        raise P07ExecutionAuthorityV2Error(
            "P07 current-source gate semantics cannot be reopened"
        ) from error
    if source_gate_semantics != document.get("source_gate_semantics"):
        raise P07ExecutionAuthorityV2Error(
            "P07 current-source gate semantics changed"
        )
    return document


__all__ = [
    "FILENAME",
    "P07ExecutionAuthorityV2Error",
    "SUPPORT_BINDING_ORDER",
    "build_document",
    "canonical_file_bytes",
    "publish_new",
    "verify",
]
