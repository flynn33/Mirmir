"""Transitive source, test, failure, and configuration evidence for P06."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
from typing import Mapping, Sequence

from validation.quality.src.mirmir_quality.holdout import (
    HashBinding,
    REQUIRED_HASHES,
    hash_binding_digest,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
    validate_schema,
)


SCHEMA = (
    Path(__file__).resolve().parent
    / "schemas"
    / "p06-evidence-closure-v1.schema.json"
)
IMPLEMENTATION_IDS = (
    "production_swift_executable",
    "production_swift_source_manifest",
    "independent_python_source_manifest",
    "release_orchestrator_source",
    "production_calibration_cli_source",
)
SELECTED_CONTROL_IDS = (
    "best_fixed",
    "conventional",
    "non_ash_selector",
)
SUPPORT_TREE_IDS = (
    "open_split_tree",
    "calibration_evidence_tree",
    "native_cache_tree",
    "production_writer_tree",
    "dispatch_measurement_tree",
)
TEST_EVIDENCE_IDS = (
    "python_calibration_full_suite",
    "xcode_native_integration",
    "xcode_release_runtime",
    "swiftlint",
    "release_lock_unit_suite",
)
PYTHON_TEST_RUNNER_IDS = ("unittest_discovery", "pytest")
NATIVE_INTEGRATION_TEST_IDS = (
    "ASHAnalysisGridV2Tests",
    "ASHLUTBinaryFormatV2Tests",
    "ASHLUTCompilerV2Tests",
    "ASHLUTLockedConfigurationJSONV2Tests",
    "ASHLockedAffineRuntimeV2Tests",
    "ASHLockedGeometryRuntimeV2Tests",
    "ASHLockedLUTManifestV2Tests",
    "ASHLockedReferencePipelineV2Tests",
)
RELEASE_RUNTIME_TEST_IDS = (
    "ASHAnalysisGridV2Tests",
    "ASHLockedAffineRuntimeV2Tests",
    "ASHLockedGeometryRuntimeV2Tests",
    "ASHLockedLUTManifestV2Tests",
    "ASHLockedReferencePipelineV2Tests",
    "ASHSpatialRuntimeConfigurationV2Tests",
)
RELEASE_LOCK_TEST_MODULES = (
    "validation.calibration_v2.tests.test_release_lock",
    "validation.calibration_v2.tests.test_release_orchestrator",
    "validation.calibration_v2.tests.test_g06_release_evidence_handoff",
    "validation.calibration_v2.tests.test_production_calibration_cli",
)
P00_FAILURE_ID = "p00_pinned_lanczos_postcommit_handler"


_ACTIONABLE_DIAGNOSTIC = re.compile(
    r"(?im)^(?:(?:[^\n]+?):[0-9]+(?::[0-9]+)?:\s+|"
    r"(?:xcodebuild|clang|swiftc|ld):\s+)?(?P<level>warning|error):"
)


class P06EvidenceClosureError(ValueError):
    """A transitive P06 evidence artifact is absent, unsafe, or changed."""


def actionable_diagnostic_counts(text: str) -> Mapping[str, int]:
    """Count build diagnostics, excluding timestamped runtime/tool status logs."""

    counts = {"warning_count": 0, "error_count": 0}
    for match in _ACTIONABLE_DIAGNOSTIC.finditer(text):
        counts[f"{match.group('level').lower()}_count"] += 1
    return counts


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _relative(path: Path, root: Path) -> str:
    absolute_root = root.resolve(strict=True)
    absolute_path = path.resolve(strict=True)
    try:
        relative = absolute_path.relative_to(absolute_root)
    except ValueError as error:
        raise P06EvidenceClosureError("evidence path escapes its declared root") from error
    value = relative.as_posix()
    parsed = PurePosixPath(value)
    if (
        not value
        or value == "."
        or parsed.as_posix() != value
        or any(part in {"", ".", ".."} for part in parsed.parts)
    ):
        raise P06EvidenceClosureError("evidence path is not a safe relative path")
    return value


def _read_file(path: Path) -> bytes:
    before = os.stat(path, follow_symlinks=False)
    if path.is_symlink() or not stat.S_ISREG(before.st_mode):
        raise P06EvidenceClosureError("evidence file is not regular")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise P06EvidenceClosureError("evidence file changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
    ):
        raise P06EvidenceClosureError("evidence file changed while reading")
    return b"".join(chunks)


def _directory_tree(path: Path) -> tuple[int, int, str]:
    root = path.resolve(strict=True)
    if path.is_symlink() or not root.is_dir():
        raise P06EvidenceClosureError("evidence tree is not a directory")
    rows = []
    total = 0
    for current_name, directory_names, file_names in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            if (current / name).is_symlink():
                raise P06EvidenceClosureError("evidence tree contains a symbolic link")
        for name in file_names:
            candidate = current / name
            payload = _read_file(candidate)
            relative = candidate.relative_to(root).as_posix()
            rows.append(
                {
                    "path": relative,
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
            total += len(payload)
    if not rows or total < 1:
        raise P06EvidenceClosureError("evidence tree is empty")
    return len(rows), total, _sha256(canonical_json_bytes(rows))


def evidence_binding(
    *,
    identifier: str,
    root_id: str,
    path: Path,
    root: Path,
) -> Mapping[str, object]:
    """Derive one file or deterministic directory-tree binding."""

    relative = _relative(path, root)
    if path.is_dir() and not path.is_symlink():
        count, size, digest = _directory_tree(path)
        return {
            "id": identifier,
            "root_id": root_id,
            "path": relative,
            "kind": "directory_tree",
            "sha256": digest,
            "size_bytes": size,
            "file_count": count,
        }
    payload = _read_file(path)
    if not payload:
        raise P06EvidenceClosureError("evidence file is empty")
    return {
        "id": identifier,
        "root_id": root_id,
        "path": relative,
        "kind": "file",
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
        "file_count": 1,
    }


def _configuration_row(
    *,
    field: str,
    binding: HashBinding,
    roots: Mapping[str, Path],
) -> Mapping[str, object]:
    matching = [
        root_id
        for root_id, root in roots.items()
        if binding.root.resolve(strict=True) == root.resolve(strict=True)
    ]
    if len(matching) != 1:
        raise P06EvidenceClosureError(
            f"configuration binding root is not uniquely declared: {field}"
        )
    payload = _read_file(binding.path)
    return {
        "id": field,
        "root_id": matching[0],
        "path": _relative(binding.path, binding.root),
        "file_sha256": _sha256(payload),
        "size_bytes": len(payload),
        "digest_mode": binding.digest_mode,
        "manifest_hash_field": (
            binding.manifest_hash_field
            if binding.digest_mode == "manifest_sha256"
            else None
        ),
        "digest_sha256": hash_binding_digest(field, binding),
    }


def p06_evidence_closure_document(
    *,
    configuration_id: str,
    input_bundle_sha256: str,
    corpus_lock_bundle_sha256: str,
    configuration_bindings: Mapping[str, HashBinding],
    configuration_roots: Mapping[str, Path],
    implementation_artifacts: Mapping[str, tuple[str, Path, Path]],
    macos_code_identities: Mapping[str, Mapping[str, object]],
    selected_control_artifacts: Mapping[str, tuple[str, Path, Path]],
    support_evidence_trees: Mapping[str, tuple[str, Path, Path]],
    test_evidence: Mapping[str, tuple[str, Path, Path]],
    preserved_failures: Mapping[str, tuple[str, Path, Path]],
    calibration_run_path: Path,
    calibration_run_root: Path,
) -> Mapping[str, object]:
    """Build a closure only from reopened bytes and deterministic tree hashes."""

    if tuple(configuration_bindings) != tuple(REQUIRED_HASHES):
        raise P06EvidenceClosureError("configuration binding order or set differs")
    if tuple(implementation_artifacts) != IMPLEMENTATION_IDS:
        raise P06EvidenceClosureError("implementation evidence set or order differs")
    if tuple(macos_code_identities) != (
        "production_swift_executable",
        "production_writer_executable",
        "p00_native_executable",
    ):
        raise P06EvidenceClosureError("macOS code identity set or order differs")
    for identity in macos_code_identities.values():
        if (
            not isinstance(identity, dict)
            or identity.get("schema_version") != "1.0.0"
            or identity.get("artifact_kind") != "macos_code_identity_v1"
        ):
            raise P06EvidenceClosureError("macOS code identity record is invalid")
    if tuple(selected_control_artifacts) != SELECTED_CONTROL_IDS:
        raise P06EvidenceClosureError("selected control evidence set or order differs")
    if tuple(support_evidence_trees) != SUPPORT_TREE_IDS:
        raise P06EvidenceClosureError("support evidence tree set or order differs")
    if tuple(test_evidence) != TEST_EVIDENCE_IDS:
        raise P06EvidenceClosureError("test evidence set or order differs")
    if P00_FAILURE_ID not in preserved_failures:
        raise P06EvidenceClosureError("pinned P00 failure evidence is absent")

    def rows(
        entries: Mapping[str, tuple[str, Path, Path]],
    ) -> list[Mapping[str, object]]:
        return [
            evidence_binding(
                identifier=identifier,
                root_id=root_id,
                path=path,
                root=root,
            )
            for identifier, (root_id, path, root) in entries.items()
        ]

    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_release_evidence_closure",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "input_bundle_sha256": input_bundle_sha256,
        "corpus_lock_bundle_sha256": corpus_lock_bundle_sha256,
        "configuration_bindings": [
            _configuration_row(
                field=field,
                binding=configuration_bindings[field],
                roots=configuration_roots,
            )
            for field in REQUIRED_HASHES
        ],
        "implementation_artifacts": rows(implementation_artifacts),
        "macos_code_identities": {
            key: dict(value) for key, value in macos_code_identities.items()
        },
        "selected_control_artifacts": rows(selected_control_artifacts),
        "support_evidence_trees": rows(support_evidence_trees),
        "test_evidence": rows(test_evidence),
        "preserved_failures": rows(preserved_failures),
        "calibration_run_tree": evidence_binding(
            identifier="complete_calibration_run_tree",
            root_id="calibration_run",
            path=calibration_run_path,
            root=calibration_run_root,
        ),
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = manifest_sha256(document)
    validate_schema(document, SCHEMA)
    return document


def publish_p06_evidence_closure(
    *,
    output_path: Path,
    **arguments: object,
) -> Mapping[str, object]:
    """Publish a new closure and verify its exact canonical bytes."""

    document = p06_evidence_closure_document(**arguments)
    payload = canonical_json_bytes(document) + b"\n"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(output_path, flags, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("evidence closure publication made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if _read_file(output_path) != payload:
        raise P06EvidenceClosureError("published evidence closure changed")
    return document


__all__ = [
    "IMPLEMENTATION_IDS",
    "NATIVE_INTEGRATION_TEST_IDS",
    "P00_FAILURE_ID",
    "P06EvidenceClosureError",
    "PYTHON_TEST_RUNNER_IDS",
    "RELEASE_LOCK_TEST_MODULES",
    "RELEASE_RUNTIME_TEST_IDS",
    "SELECTED_CONTROL_IDS",
    "SUPPORT_TREE_IDS",
    "TEST_EVIDENCE_IDS",
    "actionable_diagnostic_counts",
    "evidence_binding",
    "p06_evidence_closure_document",
    "publish_p06_evidence_closure",
]
