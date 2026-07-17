#!/usr/bin/env python3
"""Assess and immutably publish one current-source, synthetic-only G05 run.

The caller stages the non-P05 command evidence in the unique hidden sibling
``.<final-name>.partial``.  This command executes and records the three P05
producers itself.  It never accepts a media, corpus, or payload path.  Its holdout
arguments are limited to the metadata-only live-preopen verifier contract.
"""

from __future__ import annotations

import argparse
import ast
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import traceback
from typing import Any, Mapping, Optional, Sequence
import uuid


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.g05.gate import (  # noqa: E402
    G05GateError,
    build_g04_closure_attestation,
    build_g05_documents,
    build_g05_receipt,
    document_bytes,
    pinned_wrapper_root,
    validate_g05_evidence,
    validate_g05_receipt,
    validate_g05_upstream_bindings,
)
from validation.calibration_v2.live_holdout_preopen import (  # noqa: E402
    LiveHoldoutPreopenError,
    verify_live_holdout_preopen,
)
from validation.calibration_v2.reference.spatial_policy_admissibility_v2 import (  # noqa: E402
    SpatialPolicyContractError,
    build_spatial_policy_admissibility_manifest,
    validate_spatial_policy_admissibility_manifest_file,
)
from validation.calibration_v2.tools.finalize_evidence_wrapper import (  # noqa: E402
    EvidenceWrapperError,
    _quarantine_owned_root,
    _remove_owned_record,
    _rename_exclusive_at,
    _snapshot_tree as _snapshot_evidence_tree,
    finalize_evidence_wrapper,
)
from validation.quality.src.mirmir_quality.harness_manifest import (  # noqa: E402
    QualityHarnessManifestError,
    create_quality_harness_implementation_manifest,
    validate_quality_harness_implementation_manifest,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
RUN_NAMES = ("run-a", "run-b", "independent-run")
RUN_ROUTE = "direct-both"
RUN_MODE = "synthetic-p05-current-source"
INSTRUCTION_PACKAGE_ROOT_TOKEN = "{instruction-package-root}"
CANONICAL_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
UTC_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$"
)
COMMAND_IDS = (
    "run-a",
    "run-b",
    "independent-run",
    "quality-lock-a",
    "quality-lock-b",
    "swiftlint",
    "attribution",
    "instruction-package",
    "diff-check",
)
P05_OUTPUT_NAMES = (
    "development-mapping.json",
    "state-fixtures.json",
    "operator-discrimination.json",
    "operator-distinctness.json",
    "coordinate-comparison.json",
    "state-causality-results.json",
    "cpu-reference-results.json",
    "cpu-reference-vectors.json",
)
COMMAND_PLAN_SCHEMA = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/g05-command-plan-v1.schema.json"
)
RUN_IDENTITY_SCHEMA = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/g05-run-identity-v1.schema.json"
)
EVIDENCE_WRAPPER_MANIFEST_SCHEMA = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/evidence-wrapper-artifact-manifest-v2.schema.json"
)
G03_CANONICAL_FILES = (
    "conformance/g03-gate-assessment.json",
    "conformance/canonical-vectors.json",
    "conformance/p03-g03-canonical-core-evidence.json",
    "conformance/ash-core-v1.contract.json",
)
G04_CANONICAL_FILES = (
    "analysis/g04-gate-assessment.json",
    "test-results.json",
)
QUALITY_MANIFEST_RELATIVE = Path(
    "validation/quality/locks/quality-harness-implementation-manifest.json"
)
SPATIAL_PREREGISTRATION_RELATIVE = Path(
    "validation/calibration_v2/contracts/spatial-semantics-preregistration-v2.json"
)
SPATIAL_LOCK_RELATIVE = Path(
    "validation/calibration_v2/locks/spatial-policy-admissibility-manifest.json"
)
RESERVED_PARTIAL_FILES = {
    "artifact-manifest.json",
    "publication-transaction.json",
    ".evidence-wrapper-transaction.json",
}
P00_BASELINE_RECORDS = (
    "audit-result.json",
    "local-work-plan.md",
    "validation/calibration_v2/production_evaluator.py",
    "validation/calibration_v2/native_adapter/factory.py",
)
SUPPLEMENTAL_SCAN_RELATIVE = "outputs/supplemental-content-scan.json"
COMMAND_AGGREGATE_RELATIVE = "inputs/command-execution-aggregate.json"
SEMANTIC_BINDINGS_RELATIVE = "inputs/pre-finalization-semantic-bindings.json"
INSTRUCTION_PACKAGE_PRODUCTS = (
    (
        "package_manifest.json",
        "inputs/instruction-package/package_manifest.json",
    ),
    (
        "SHA256SUMS.txt",
        "inputs/instruction-package/SHA256SUMS.txt",
    ),
)


class G05CurrentSourceError(RuntimeError):
    """A well-formed G05 assessment input fails a mandatory gate assertion."""


class G05SetupError(RuntimeError):
    """The requested assessment transaction cannot be started safely."""


class G05PostFinalReopenError(RuntimeError):
    """A published success wrapper failed strict reopen and was quarantined."""

    def __init__(self, message: str, failure_root: Path) -> None:
        super().__init__(message)
        self.failure_root = failure_root


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise G05CurrentSourceError(message)


def _require_setup(condition: bool, message: str) -> None:
    if not condition:
        raise G05SetupError(message)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _require_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise G05SetupError(f"{label} is not a lowercase SHA-256")
    return value


def _require_commit(value: object) -> str:
    if not isinstance(value, str) or COMMIT_PATTERN.fullmatch(value) is None:
        raise G05SetupError(
            "expected source commit is not a lowercase 40-character Git object ID"
        )
    return value


def _require_uuid(value: object) -> str:
    if not isinstance(value, str):
        raise G05SetupError("run ID is not a canonical lowercase UUID")
    try:
        parsed = uuid.UUID(value)
    except (AttributeError, ValueError) as error:
        raise G05SetupError("run ID is not a canonical lowercase UUID") from error
    if str(parsed) != value:
        raise G05SetupError("run ID is not a canonical lowercase UUID")
    return value


def _parse_utc(value: object, label: str) -> datetime:
    if not isinstance(value, str) or UTC_PATTERN.fullmatch(value) is None:
        raise G05SetupError(f"{label} is not a canonical UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise G05SetupError(f"{label} is not a canonical UTC timestamp") from error
    if parsed.tzinfo != timezone.utc:
        raise G05SetupError(f"{label} is not UTC")
    return parsed


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00",
        "Z",
    )


def _validate_schema_document(
    document: Mapping[str, Any], schema_path: Path, label: str
) -> None:
    try:
        validate_schema(document, schema_path)
    except ValueError as error:
        raise G05CurrentSourceError(f"{label} schema validation failed: {error}") from error


def _canonical_command_environment(
    repository_root: Path,
    *,
    python: bool,
) -> Mapping[str, str]:
    environment = {
        "HOME": os.environ.get("HOME", ""),
        "PATH": CANONICAL_PATH,
        "LANG": "C",
        "LC_ALL": "C",
    }
    if python:
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONPATH"] = os.fspath(repository_root)
    return environment


def _version_tool(
    executable: str,
    arguments: Sequence[str],
    *,
    label: str,
) -> Mapping[str, Any]:
    result = subprocess.run(
        (executable, *arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        env={
            "HOME": os.environ.get("HOME", ""),
            "PATH": CANONICAL_PATH,
            "LANG": "C",
            "LC_ALL": "C",
        },
    )
    _require(
        result.returncode == 0 and bool(result.stdout.strip()),
        f"{label} version identity command failed",
    )
    try:
        output = result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError as error:
        raise G05CurrentSourceError(f"{label} version identity is not UTF-8") from error
    return {
        "executable": executable,
        "version": output,
        "version_sha256": _sha256(result.stdout),
    }


def _toolchain_identity() -> Mapping[str, Any]:
    python_executable = os.fspath(Path(sys.executable).resolve(strict=True))
    swiftlint = shutil.which("swiftlint", path=CANONICAL_PATH)
    _require(swiftlint is not None, "SwiftLint executable is absent")
    swiftlint_executable = os.fspath(Path(swiftlint).resolve(strict=True))
    python_output = platform.python_version().encode("utf-8") + b"\n"
    return {
        "python": {
            "executable": python_executable,
            "version": platform.python_version(),
            "version_sha256": _sha256(python_output),
        },
        "xcode": _version_tool(
            "/usr/bin/xcodebuild", ("-version",), label="Xcode"
        ),
        "swift": _version_tool(
            "/usr/bin/xcrun", ("swiftc", "--version"), label="Swift"
        ),
        "macos_sdk": _version_tool(
            "/usr/bin/xcrun",
            ("--sdk", "macosx", "--show-sdk-version"),
            label="macOS SDK",
        ),
        "swiftlint": _version_tool(
            swiftlint_executable, ("version",), label="SwiftLint"
        ),
        "metal_device": {
            "applicable": False,
            "reason": "not_used_by_g05_synthetic_cpu_reference",
        },
    }


def _lexical_absolute(path: Path, label: str) -> Path:
    _require_setup(path.is_absolute(), f"{label} must be absolute")
    normalized = Path(os.path.normpath(os.fspath(path)))
    _require_setup(normalized == path, f"{label} must be lexically normalized")
    return path


def _canonical_directory(path: Path, label: str) -> Path:
    absolute = _lexical_absolute(path, label)
    try:
        metadata = os.lstat(absolute)
    except OSError as error:
        raise G05SetupError(f"{label} is absent or inaccessible") from error
    _require_setup(
        stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
        f"{label} is linked or not a directory",
    )
    try:
        resolved = absolute.resolve(strict=True)
    except OSError as error:
        raise G05SetupError(f"{label} cannot be resolved") from error
    _require_setup(resolved == absolute, f"{label} is not canonical")
    return absolute


def _canonical_regular(path: Path, label: str) -> Path:
    absolute = _lexical_absolute(path, label)
    try:
        metadata = os.lstat(absolute)
    except OSError as error:
        raise G05SetupError(f"{label} is absent or inaccessible") from error
    _require_setup(
        stat.S_ISREG(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and metadata.st_nlink == 1,
        f"{label} is not a single-link regular file",
    )
    _require_setup(
        absolute.resolve(strict=True) == absolute,
        f"{label} is not canonical",
    )
    return absolute


def _canonical_absent_leaf(path: Path, label: str) -> Path:
    absolute = _lexical_absolute(path, label)
    _canonical_directory(absolute.parent, f"{label} parent")
    _require_setup(not os.path.lexists(absolute), f"{label} must be absent")
    return absolute


def _read_regular(path: Path, label: str) -> bytes:
    try:
        before = os.lstat(path)
    except OSError as error:
        raise G05CurrentSourceError(f"{label} is absent or inaccessible") from error
    _require(
        stat.S_ISREG(before.st_mode)
        and not stat.S_ISLNK(before.st_mode)
        and before.st_nlink == 1,
        f"{label} is not a single-link regular file",
    )
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise G05CurrentSourceError(f"{label} cannot be opened safely") from error
    try:
        opened = os.fstat(descriptor)
        _require(
            (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"{label} changed while opening",
        )
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        current = os.lstat(path)
    except OSError as error:
        raise G05CurrentSourceError(f"{label} changed after reading") from error
    _require(
        (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        == (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ),
        f"{label} changed while reading",
    )
    _require(
        (
            current.st_dev,
            current.st_ino,
            stat.S_IFMT(current.st_mode),
            current.st_nlink,
            current.st_size,
            current.st_mtime_ns,
            current.st_ctime_ns,
        )
        == (
            before.st_dev,
            before.st_ino,
            stat.S_IFMT(before.st_mode),
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ),
        f"{label} path identity changed after reading",
    )
    return b"".join(chunks)


def _duplicate_rejector(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise G05CurrentSourceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _json_object(payload: bytes, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_duplicate_rejector,
            parse_constant=lambda token: (_ for _ in ()).throw(
                G05CurrentSourceError(f"non-finite JSON number in {label}: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise G05CurrentSourceError(f"{label} is not valid UTF-8 JSON") from error
    _require(isinstance(value, dict), f"{label} top level is not an object")
    return value


def _build_run_identity(
    *,
    arguments: argparse.Namespace,
    repository_root: Path,
    partial_root: Path,
    instruction_package_root: Path,
    source_commit: str,
    dirty_state_sha256: str,
    toolchain: Mapping[str, Any],
    p00_baseline_binding: Mapping[str, Any],
    ended_utc: str,
    outcome: str,
    closure: Optional[Mapping[str, Any]],
    holdout_access_status: str = "proven_unopened",
) -> Mapping[str, Any]:
    started = _parse_utc(arguments.started_utc, "run start")
    ended = _parse_utc(ended_utc, "run end")
    _require(ended >= started, "run end precedes run start")
    _require(
        holdout_access_status
        in {"proven_unopened", "unknown_not_proven_unopened"},
        "run identity holdout-access status is invalid",
    )
    configuration_sha256 = _require_sha256(
        arguments.configuration_sha256,
        "G05 configuration",
    )
    synthetic_input_sha256 = _require_sha256(
        arguments.synthetic_input_sha256,
        "G05 synthetic input",
    )
    synthetic_target_sha256 = _require_sha256(
        arguments.synthetic_target_sha256,
        "G05 synthetic target",
    )
    baseline_unhashed = dict(p00_baseline_binding)
    baseline_claimed = baseline_unhashed.pop("binding_sha256", None)
    _require(
        p00_baseline_binding.get("status") == "pass"
        and p00_baseline_binding.get("baseline_commit")
        == _require_commit(arguments.p00_baseline_commit)
        and p00_baseline_binding.get("source_commit") == source_commit
        and baseline_claimed == canonical_sha256(baseline_unhashed),
        "P00 baseline binding differs from the run identity",
    )
    mapping_path = repository_root / "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json"
    operator_path = repository_root / "Mirmir/Resources/ASH/operator_bank_v2.seed.json"
    metric_path = repository_root / "validation/quality/policies/metric-policy.json"
    media_path = instruction_package_root / "config/geometry_color_audio_policy.json"
    component_hashes = {
        "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json": _sha256(
            _read_regular(mapping_path, "ASH video mapping seed")
        ),
        "Mirmir/Resources/ASH/operator_bank_v2.seed.json": _sha256(
            _read_regular(operator_path, "ASH operator-bank seed")
        ),
    }
    upstream_path = partial_root / "inputs/upstream-bindings.json"
    if os.path.lexists(upstream_path):
        upstream_context: Mapping[str, Any] = {
            "status": "bound_in_wrapper",
            "sha256": _sha256(
                _read_regular(upstream_path, "G05 upstream bindings")
            ),
        }
    else:
        upstream_context = {
            "status": "not_available_gate_failed_before_binding",
            "sha256": None,
        }
    if closure is not None:
        provenance = closure.get("provenance_manifest_sha256")
        _require(
            isinstance(provenance, Mapping)
            and provenance.get("configuration") == configuration_sha256,
            "run identity configuration hash differs from P05 evidence",
        )
        _require(
            provenance.get("harness") == synthetic_input_sha256,
            "run identity synthetic-input hash differs from P05 evidence",
        )
        _require(
            closure.get("run_sha256") == synthetic_target_sha256,
            "run identity synthetic-target hash differs from P05 evidence",
        )
        documents = closure.get("documents")
        _require(
            isinstance(documents, Mapping) and bool(documents),
            "run identity P05 document closure is absent",
        )
        first_document = next(iter(documents.values()))
        _require(
            isinstance(first_document, Mapping)
            and isinstance(first_document.get("provenance"), Mapping),
            "run identity P05 provenance is absent",
        )
        configuration_files = first_document["provenance"].get(
            "configuration_files"
        )
        observed_components = {
            row.get("path"): row.get("sha256")
            for row in configuration_files
            if isinstance(row, Mapping)
        } if isinstance(configuration_files, list) else {}
        _require(
            observed_components == component_hashes,
            "run identity mapping/operator hashes differ from P05 provenance",
        )
    if outcome == "pass":
        package_manifest_path = (
            partial_root / "inputs/instruction-package/package_manifest.json"
        )
        checksum_index_path = (
            partial_root / "inputs/instruction-package/SHA256SUMS.txt"
        )
    else:
        package_manifest_path = instruction_package_root / "package_manifest.json"
        checksum_index_path = instruction_package_root / "SHA256SUMS.txt"
    package_manifest = _read_regular(
        package_manifest_path,
        "instruction package manifest",
    )
    checksum_index = _read_regular(
        checksum_index_path,
        "instruction package checksum index",
    )
    if outcome == "pass":
        _require(
            package_manifest
            == _read_regular(
                instruction_package_root / "package_manifest.json",
                "live instruction package manifest",
            )
            and checksum_index
            == _read_regular(
                instruction_package_root / "SHA256SUMS.txt",
                "live instruction package checksum index",
            ),
            "sealed instruction-package products differ from their live sources",
        )
    document: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_current_source_run_identity",
        "run_id": _require_uuid(arguments.run_id),
        "started_utc": arguments.started_utc,
        "ended_utc": ended_utc,
        "outcome": outcome,
        "source_commit": source_commit,
        "p00_baseline": dict(p00_baseline_binding),
        "working_tree": {
            "clean": True,
            "dirty_state_sha256": dirty_state_sha256,
        },
        "route": RUN_ROUTE,
        "routes_exercised": ["direct_2x", "direct_3_over_2"],
        "mode": RUN_MODE,
        "configuration_sha256": configuration_sha256,
        "configuration_components": {
            "mapping": {
                "kind": "ash_video_mapping_v2_seed",
                "sha256": component_hashes[
                    "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json"
                ],
            },
            "operator_bank": {
                "kind": "operator_bank_v2_seed",
                "sha256": component_hashes[
                    "Mirmir/Resources/ASH/operator_bank_v2.seed.json"
                ],
            },
            "branch_lut": {
                "status": "not_applicable_pre_g06",
                "sha256": None,
            },
            "metric_policy": {
                "kind": "development_metric_policy",
                "sha256": _sha256(
                    _read_regular(metric_path, "development metric policy")
                ),
            },
            "media_policy": {
                "kind": "instruction_geometry_color_audio_policy",
                "sha256": _sha256(
                    _read_regular(media_path, "instruction media policy")
                ),
            },
        },
        "coordinate_policies": [
            "half_pixel_center",
            "source_aligned_rational",
        ],
        "analysis_granularity": "synthetic_fixture_cell",
        "temporal_mode": (
            "spatial_reference_with_state_causality_controls_no_temporal_reconstruction"
        ),
        "comparison_domain": (
            "raw_engine_synthetic_cpu_reference_no_container_decode"
        ),
        "evidence_context": {
            "quality_harness_manifest": {
                "kind": "quality_harness_implementation_manifest",
                "sha256": _sha256(
                    _read_regular(
                        repository_root / QUALITY_MANIFEST_RELATIVE,
                        "quality-harness implementation manifest",
                    )
                ),
            },
            "spatial_preregistration": {
                "kind": "p05_spatial_semantics_preregistration",
                "sha256": _sha256(
                    _read_regular(
                        repository_root / SPATIAL_PREREGISTRATION_RELATIVE,
                        "spatial-semantics preregistration",
                    )
                ),
            },
            "upstream_bindings": upstream_context,
        },
        "synthetic_input": {
            "kind": "p05_synthetic_harness_manifest",
            "sha256": synthetic_input_sha256,
        },
        "synthetic_target": {
            "kind": "p05_reference_evidence_closure",
            "sha256": synthetic_target_sha256,
        },
        "instruction_package": {
            "root": INSTRUCTION_PACKAGE_ROOT_TOKEN,
            "package_manifest_sha256": _sha256(package_manifest),
            "checksum_index_sha256": _sha256(checksum_index),
            "p00_baseline_commit": _require_commit(
                arguments.p00_baseline_commit
            ),
        },
        "toolchain": toolchain,
        "platform": {
            "os": platform.system() or "unknown",
            "release": platform.release() or "unknown",
            "machine": platform.machine() or "unknown",
            "node": platform.node() or "unknown",
        },
        "holdout_accessed": (
            False if holdout_access_status == "proven_unopened" else None
        ),
        "holdout_access_status": holdout_access_status,
        "assessor_pixel_accessed": False,
    }
    document["identity_sha256"] = canonical_sha256(document)
    _validate_schema_document(document, RUN_IDENTITY_SCHEMA, "G05 run identity")
    return document


def _run_git(repository_root: Path, arguments: Sequence[str]) -> bytes:
    result = subprocess.run(
        ("/usr/bin/git", "-C", os.fspath(repository_root), *arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env={
            "PATH": CANONICAL_PATH,
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        },
    )
    if result.returncode != 0:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()
        raise G05SetupError(
            f"Git command failed ({' '.join(arguments)}): {diagnostic}"
        )
    return result.stdout


def _validate_repository_state(repository_root: Path, expected_commit: str) -> str:
    top = _run_git(repository_root, ("rev-parse", "--show-toplevel")).rstrip(b"\n")
    try:
        top_path = Path(top.decode("utf-8", errors="strict"))
    except UnicodeDecodeError as error:
        raise G05SetupError("repository top-level path is not UTF-8") from error
    _require_setup(top_path == repository_root, "repository root is not the Git top level")
    head = _run_git(repository_root, ("rev-parse", "--verify", "HEAD")).decode(
        "ascii", errors="strict"
    ).strip()
    _require_setup(head == expected_commit, "repository HEAD differs from expected source commit")
    status = _run_git(
        repository_root,
        ("status", "--porcelain=v1", "-z", "--untracked-files=all"),
    )
    _require_setup(status == b"", "repository working tree is not clean")
    return _sha256(status)


def _python_string_assignment(
    payload: bytes,
    name: str,
    label: str,
) -> str:
    try:
        tree = ast.parse(payload, filename=label)
    except (SyntaxError, ValueError) as error:
        raise G05SetupError(f"{label} cannot be parsed for its P00 binding") from error
    values: list[str] = []
    for statement in tree.body:
        if not isinstance(statement, (ast.Assign, ast.AnnAssign)):
            continue
        targets = (
            statement.targets
            if isinstance(statement, ast.Assign)
            else [statement.target]
        )
        if not any(isinstance(target, ast.Name) and target.id == name for target in targets):
            continue
        value = statement.value
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            values.append(value.value)
    _require_setup(
        len(values) == 1 and COMMIT_PATTERN.fullmatch(values[0]) is not None,
        f"{label} does not contain one exact P00 commit binding",
    )
    return values[0]


def _validate_baseline_commit(
    repository_root: Path,
    baseline_commit: str,
    source_commit: str,
) -> Mapping[str, Any]:
    payloads: dict[str, bytes] = {}
    for relative in P00_BASELINE_RECORDS:
        _run_git(repository_root, ("ls-files", "--error-unmatch", "--", relative))
        payloads[relative] = _read_regular(
            repository_root / relative,
            f"tracked P00 baseline record {relative}",
        )
    audit = _json_object(payloads["audit-result.json"], "tracked audit result")
    attribution_scan = audit.get("attribution_scan")
    _require_setup(
        isinstance(attribution_scan, Mapping),
        "tracked audit result lacks its P00 scan binding",
    )
    audit_commit = attribution_scan.get("base")
    try:
        work_plan = payloads["local-work-plan.md"].decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise G05SetupError("tracked local work plan is not UTF-8") from error
    plan_matches = re.findall(
        r"^Baseline commit: `([0-9a-f]{40})`$",
        work_plan,
        flags=re.MULTILINE,
    )
    evaluator_commit = _python_string_assignment(
        payloads["validation/calibration_v2/production_evaluator.py"],
        "P00_COMMIT",
        "tracked production evaluator",
    )
    adapter_commit = _python_string_assignment(
        payloads["validation/calibration_v2/native_adapter/factory.py"],
        "_P00_COMMIT",
        "tracked native adapter factory",
    )
    observed = (audit_commit, *plan_matches, evaluator_commit, adapter_commit)
    _require_setup(
        len(plan_matches) == 1
        and all(value == baseline_commit for value in observed),
        "supplied P00 baseline differs from current tracked baseline records",
    )
    _run_git(repository_root, ("cat-file", "-e", f"{baseline_commit}^{{commit}}"))
    _run_git(
        repository_root,
        ("merge-base", "--is-ancestor", baseline_commit, source_commit),
    )
    body: dict[str, Any] = {
        "schema_version": "1.0.0",
        "status": "pass",
        "baseline_commit": baseline_commit,
        "source_commit": source_commit,
        "ancestry": "baseline_is_ancestor_of_source",
        "tracked_records": [
            {
                "path": relative,
                "sha256": _sha256(payloads[relative]),
                "size_bytes": len(payloads[relative]),
            }
            for relative in P00_BASELINE_RECORDS
        ],
    }
    return {**body, "binding_sha256": canonical_sha256(body)}


def _safe_relative(value: object, label: str) -> PurePosixPath:
    _require(isinstance(value, str) and bool(value), f"{label} path is empty")
    parsed = PurePosixPath(value)
    _require(
        not parsed.is_absolute()
        and parsed.as_posix() == value
        and "\\" not in value
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"{label} path is unsafe",
    )
    return parsed


def _write_new(path: Path, payload: bytes, label: str) -> None:
    _canonical_directory(path.parent, f"{label} parent")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o644)
    except OSError as error:
        raise G05CurrentSourceError(f"{label} cannot be created exclusively") from error
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise G05CurrentSourceError(f"{label} write made no progress")
            offset += written
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    _require(
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_nlink == 1
        and metadata.st_size == len(payload),
        f"{label} publication metadata differs",
    )
    _require(_read_regular(path, label) == payload, f"{label} reopen bytes differ")


def _write_json_new(path: Path, document: Mapping[str, Any], label: str) -> None:
    _write_new(path, document_bytes(document), label)


def _copy_new(
    source: Path,
    destination: Path,
    label: str,
    *,
    binding_root: Optional[Path] = None,
) -> Mapping[str, Any]:
    payload = _read_regular(source, f"{label} source")
    _write_new(destination, payload, f"{label} copy")
    binding_path = (
        destination.name
        if binding_root is None
        else destination.relative_to(binding_root).as_posix()
    )
    return {
        "path": binding_path,
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _manifest_rows(document: Mapping[str, Any], label: str) -> Mapping[str, Mapping[str, Any]]:
    rows = document.get("artifacts")
    _require(isinstance(rows, list), f"{label} artifact rows are absent")
    result: dict[str, Mapping[str, Any]] = {}
    for index, row in enumerate(rows):
        _require(isinstance(row, dict), f"{label} artifact row {index} is invalid")
        relative = row.get("path")
        _safe_relative(relative, f"{label} artifact row {index}")
        _require(relative not in result, f"{label} artifact paths are ambiguous")
        result[str(relative)] = row
    return result


def _manifest_bound_file(
    root: Path,
    rows: Mapping[str, Mapping[str, Any]],
    relative: str,
    label: str,
) -> tuple[Path, bytes, Mapping[str, Any]]:
    parsed = _safe_relative(relative, label)
    path = root.joinpath(*parsed.parts)
    _require_frozen(path, label)
    payload = _read_regular(path, label)
    row = rows.get(relative)
    _require(
        isinstance(row, Mapping)
        and row.get("sha256") == _sha256(payload)
        and row.get("size_bytes") == len(payload),
        f"{label} differs from its finalized artifact-manifest binding",
    )
    return path, payload, row


def _require_frozen(path: Path, label: str) -> None:
    metadata = os.lstat(path)
    immutable = getattr(stat, "UF_IMMUTABLE", 0)
    _require(
        immutable != 0 and bool(getattr(metadata, "st_flags", 0) & immutable),
        f"{label} is not macOS user immutable",
    )


def _g04_snapshot_root(snapshot: object) -> object:
    directories = getattr(snapshot, "directories", ())
    roots = [item for item in directories if getattr(item, "path", None) == ""]
    _require(len(roots) == 1, "G04 finalized snapshot has no unique root directory")
    return roots[0]


def _validate_g04_snapshot_closure(
    *,
    manifest: Mapping[str, Any],
    manifest_payload: bytes,
    snapshot: object,
) -> None:
    rows = _manifest_rows(manifest, "G04 finalized artifact manifest")
    row_paths = list(rows)
    _require(
        row_paths == sorted(row_paths)
        and "artifact-manifest.json" not in row_paths,
        "G04 finalized artifact rows are not in canonical path order",
    )
    files = tuple(getattr(snapshot, "files", ()))
    directories = tuple(getattr(snapshot, "directories", ()))
    observed_files = {getattr(item, "path", None): item for item in files}
    observed_directories = {
        getattr(item, "path", None): item for item in directories
    }
    _require(
        len(observed_files) == len(files)
        and set(observed_files) == {"artifact-manifest.json", *row_paths},
        "G04 finalized file closure differs from its artifact manifest",
    )
    declared_directories = manifest.get("directories")
    _require(
        isinstance(declared_directories, list)
        and len(observed_directories) == len(directories)
        and set(observed_directories) == {"", *declared_directories}
        and [getattr(item, "path", None) for item in directories if item.path]
        == declared_directories,
        "G04 finalized directory closure differs from its artifact manifest",
    )
    manifest_file = observed_files["artifact-manifest.json"]
    _require(
        manifest_file.sha256 == _sha256(manifest_payload)
        and manifest_file.size_bytes == len(manifest_payload),
        "G04 finalized artifact manifest changed during transitive reopen",
    )
    for relative, row in rows.items():
        item = observed_files[relative]
        _require(
            row.get("sha256") == item.sha256
            and row.get("size_bytes") == item.size_bytes,
            f"G04 finalized descendant differs from its manifest: {relative}",
        )
    immutable = getattr(stat, "UF_IMMUTABLE", 0)
    write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
    _require(immutable != 0, "macOS user-immutable flags are unavailable")
    for item in files:
        _require(
            not item.mode & write_bits and item.flags & immutable,
            f"G04 finalized file is mutable: {item.path}",
        )
    for item in directories:
        _require(
            not item.mode & write_bits and item.flags & immutable,
            f"G04 finalized directory is mutable: {item.path or '<root>'}",
        )


def _snapshot_finalized_g04_root(root: Path) -> object:
    try:
        before = os.lstat(root)
        flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )
        descriptor = os.open(root, flags)
    except OSError as error:
        raise G05CurrentSourceError(
            "G04 finalized root cannot be opened for transitive verification"
        ) from error
    try:
        opened = os.fstat(descriptor)
        _require(
            stat.S_ISDIR(before.st_mode)
            and stat.S_ISDIR(opened.st_mode)
            and (before.st_dev, before.st_ino) == (opened.st_dev, opened.st_ino),
            "G04 finalized root changed while opening",
        )
        try:
            snapshot = _snapshot_evidence_tree(descriptor)
        except EvidenceWrapperError as error:
            raise G05CurrentSourceError(
                f"G04 finalized root traversal failed closed: {error}"
            ) from error
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        current = os.lstat(root)
    except OSError as error:
        raise G05CurrentSourceError(
            "G04 finalized root changed after transitive verification"
        ) from error
    def identity(metadata: os.stat_result) -> tuple[int, ...]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IFMT(metadata.st_mode),
            stat.S_IMODE(metadata.st_mode),
            getattr(metadata, "st_flags", 0),
            metadata.st_nlink,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )
    _require(
        identity(before) == identity(opened) == identity(after) == identity(current),
        "G04 finalized root identity changed during transitive verification",
    )
    root_snapshot = _g04_snapshot_root(snapshot)
    _require(
        (root_snapshot.device, root_snapshot.inode)
        == (current.st_dev, current.st_ino),
        "G04 finalized descriptor snapshot root identity differs",
    )
    return snapshot


def _validate_g04_publication_transaction(
    *,
    document: Mapping[str, Any],
    payload: bytes,
    root: Path,
    root_snapshot: object,
    source_commit: str,
) -> None:
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
        and document.get("schema_version") == "1.0.0"
        and document.get("artifact_kind")
        == "evidence_wrapper_publication_transaction"
        and isinstance(document.get("transaction_token"), str)
        and re.fullmatch(r"[0-9a-f]{32}", str(document["transaction_token"]))
        is not None
        and isinstance(document.get("created_utc"), str)
        and UTC_PATTERN.fullmatch(str(document["created_utc"])) is not None
        and document.get("project_commit") == source_commit
        and document.get("partial_name") == f".{root.name}.partial"
        and document.get("final_name") == root.name
        and document.get("failure_name") == f"{root.name}.failed"
        and document.get("gate_ids") == ["G04"]
        and type(document.get("root_device")) is int
        and document.get("root_device") >= 0
        and type(document.get("root_inode")) is int
        and document.get("root_inode") == root_snapshot.inode
        and payload == document_bytes(document),
        "G04 publication transaction identity, commit, gates, or root differs",
    )


def _validate_finalized_g04_closure(
    *,
    root: Path,
    manifest: Mapping[str, Any],
    manifest_payload: bytes,
    source_commit: str,
) -> Mapping[str, Any]:
    _validate_schema_document(
        manifest,
        EVIDENCE_WRAPPER_MANIFEST_SCHEMA,
        "G04 finalized artifact manifest",
    )
    _require(
        manifest_payload == document_bytes(manifest),
        "G04 finalized artifact manifest is not canonical JSON",
    )
    snapshot = _snapshot_finalized_g04_root(root)
    _validate_g04_snapshot_closure(
        manifest=manifest,
        manifest_payload=manifest_payload,
        snapshot=snapshot,
    )
    _require(
        _read_regular(root / "artifact-manifest.json", "G04 artifact manifest reopen")
        == manifest_payload,
        "G04 artifact manifest changed after transitive verification",
    )
    rows = _manifest_rows(manifest, "G04 finalized artifact manifest")
    transaction_row = rows.get("publication-transaction.json")
    _require(
        transaction_row is not None,
        "G04 finalized closure omits its publication transaction",
    )
    transaction_payload = _read_regular(
        root / "publication-transaction.json",
        "G04 publication transaction",
    )
    _require(
        transaction_row.get("sha256") == _sha256(transaction_payload)
        and transaction_row.get("size_bytes") == len(transaction_payload),
        "G04 publication transaction differs from its manifest binding",
    )
    _validate_g04_publication_transaction(
        document=_json_object(
            transaction_payload,
            "G04 publication transaction",
        ),
        payload=transaction_payload,
        root=root,
        root_snapshot=_g04_snapshot_root(snapshot),
        source_commit=source_commit,
    )
    try:
        return build_g04_closure_attestation(
            manifest=manifest,
            manifest_sha256=_sha256(manifest_payload),
        )
    except G05GateError as error:
        raise G05CurrentSourceError(
            f"G04 transitive closure attestation cannot be built: {error}"
        ) from error


def _validate_upstream(
    *,
    partial_root: Path,
    g03_root: Path,
    expected_g03_manifest_sha256: str,
    g04_root: Path,
    expected_g04_manifest_sha256: str,
    source_commit: str,
) -> Mapping[str, Any]:
    bindings: dict[str, Any] = {"schema_version": "1.0.0", "gates": {}}
    for root, expected_hash, label in (
        (g03_root, expected_g03_manifest_sha256, "G03"),
        (g04_root, expected_g04_manifest_sha256, "G04"),
    ):
        _require_frozen(root, f"{label} finalized root")
        manifest_path = root / "artifact-manifest.json"
        _require_frozen(manifest_path, f"{label} artifact manifest")
        manifest_payload = _read_regular(manifest_path, f"{label} artifact manifest")
        _require(
            _sha256(manifest_payload) == expected_hash,
            f"{label} artifact manifest differs from its caller-supplied hash",
        )
        manifest = _json_object(manifest_payload, f"{label} artifact manifest")
        _require(
            type(manifest.get("working_tree_clean")) is bool,
            f"{label} manifest does not bind an explicit checkout state",
        )
        if label == "G04":
            _require(
                manifest.get("working_tree_clean") is True
                and manifest.get("project_commit") == source_commit,
                "G04 manifest is not clean current-source evidence",
            )
            closure_attestation = _validate_finalized_g04_closure(
                root=root,
                manifest=manifest,
                manifest_payload=manifest_payload,
                source_commit=source_commit,
            )
        else:
            closure_attestation = None
        rows = _manifest_rows(manifest, f"{label} artifact manifest")
        destination_root = partial_root / "inputs" / label.lower()
        _canonical_directory(destination_root, f"{label} staged input directory")
        copied: list[Mapping[str, Any]] = []
        copied.append(
            _copy_new(
                manifest_path,
                destination_root / "artifact-manifest.json",
                f"{label} artifact manifest",
                binding_root=partial_root,
            )
        )
        if label == "G03":
            canonical_assessment_payload: Optional[bytes] = None
            for relative in G03_CANONICAL_FILES:
                path, payload, _ = _manifest_bound_file(
                    root, rows, relative, f"G03 canonical file {relative}"
                )
                if relative == G03_CANONICAL_FILES[0]:
                    canonical_assessment_payload = payload
                copied.append(
                    _copy_new(
                        path,
                        destination_root / Path(relative).name,
                        relative,
                        binding_root=partial_root,
                    )
                )
            assert canonical_assessment_payload is not None
            assessment = _json_object(
                canonical_assessment_payload,
                "G03 gate assessment",
            )
            _require(
                assessment.get("status") == "pass"
                and assessment.get("holdout_accessed") is not True,
                "G03 canonical assessment is not passing and holdout-free",
            )
        else:
            required = G04_CANONICAL_FILES
            documents: dict[str, Mapping[str, Any]] = {}
            for relative in required:
                path, payload, _ = _manifest_bound_file(
                    root, rows, relative, f"G04 {relative}"
                )
                copied.append(
                    _copy_new(
                        path,
                        destination_root / Path(relative).name,
                        relative,
                        binding_root=partial_root,
                    )
                )
                documents[relative] = _json_object(payload, f"G04 {relative}")
            assessment = documents[required[0]]
            tests = documents[required[1]]
            _require(
                assessment.get("status") == "pass"
                and assessment.get("holdout_accessed") is False
                and assessment.get("project_commit") == source_commit,
                "G04 assessment is not a same-source passing no-holdout result",
            )
            _validate_g04_test_evidence(
                tests,
                rows,
                manifest.get("directories"),
            )
        gate_binding = {
            "status": "pass",
            "source_commit": manifest.get("project_commit"),
            "manifest_file_sha256": expected_hash,
            "copied_files": copied,
        }
        if closure_attestation is not None:
            gate_binding["closure_attestation"] = closure_attestation
        bindings["gates"][label] = gate_binding
    return bindings


def _zero(document: Mapping[str, Any], fields: Sequence[str], label: str) -> None:
    for field in fields:
        if field in document:
            _require(document.get(field) == 0, f"{label} reports nonzero {field}")


def _validate_g04_test_evidence(
    tests: Mapping[str, Any],
    manifest_rows: Mapping[str, Mapping[str, Any]],
    manifest_directories: object,
) -> None:
    _require(tests.get("status") == "pass", "G04 test-results status is not pass")
    xcode = tests.get("xcode_full", tests.get("xcode_debug"))
    release = tests.get("release_build", tests.get("release_arm64"))
    python = tests.get(
        "python",
        tests.get("quality_python", tests.get("python_quality")),
    )
    _require(isinstance(xcode, Mapping), "G04 Xcode evidence is absent")
    _require(isinstance(release, Mapping), "G04 release-build evidence is absent")
    _require(isinstance(python, Mapping), "G04 Python evidence is absent")
    _require(xcode.get("status") in {"pass", "passed"}, "G04 Xcode evidence failed")
    _zero(xcode, ("failed", "failures", "errors", "unexpected_skips"), "G04 Xcode")
    skipped = xcode.get("skipped", 0)
    _require(type(skipped) is int and skipped >= 0, "G04 Xcode skip count is invalid")
    if skipped:
        expected = xcode.get(
            "expected_skips",
            xcode.get(
                "expected_skip",
                xcode.get("expected_non_g04_skip"),
            ),
        )
        _require(expected not in (None, "", []), "G04 Xcode has an unexpected skip")
        if isinstance(expected, list):
            _require(len(expected) == skipped, "G04 Xcode expected-skip count differs")
        else:
            _require(skipped == 1, "G04 Xcode expected-skip record is ambiguous")
    _require(
        release.get("status") in {"pass", "passed", "succeeded"},
        "G04 release-build evidence failed",
    )
    _zero(release, ("warnings", "errors", "analyzer_warnings"), "G04 release build")
    _require(python.get("status") in {"pass", "passed"}, "G04 Python evidence failed")
    _zero(python, ("failures", "failed", "errors", "skips"), "G04 Python")
    for record in (xcode, release, python):
        for key, value in record.items():
            if key in {"summary", "coverage", "log"} and isinstance(value, str):
                _require(value in manifest_rows, f"G04 referenced file is unbound: {value}")
            if key == "result_bundle" and isinstance(value, str):
                _require(
                    isinstance(manifest_directories, list)
                    and value in manifest_directories,
                    f"G04 result bundle is unbound: {value}",
                )


def _validate_quality_locks(repository_root: Path, partial_root: Path) -> Mapping[str, Any]:
    checked_path = repository_root / QUALITY_MANIFEST_RELATIVE
    rebuild_a = partial_root / "inputs/quality-harness-lock-a.json"
    rebuild_b = partial_root / "inputs/quality-harness-lock-b.json"
    checked_payload = _read_regular(checked_path, "checked-in quality-harness manifest")
    a_payload = _read_regular(rebuild_a, "quality-harness rebuild A")
    b_payload = _read_regular(rebuild_b, "quality-harness rebuild B")
    _require(
        checked_payload == a_payload == b_payload,
        "quality-harness rebuilds are not byte-identical to the checked-in lock",
    )
    checked = _json_object(checked_payload, "checked-in quality-harness manifest")
    validated = validate_quality_harness_implementation_manifest(
        checked, repository_root
    )
    rebuilt = create_quality_harness_implementation_manifest(repository_root)
    _require(
        canonical_json_bytes(rebuilt) == canonical_json_bytes(checked),
        "quality-harness validation API rebuild differs from the checked-in lock",
    )
    return {
        "schema_version": "1.0.0",
        "status": "pass",
        "manifest_sha256": validated,
        "manifest_file_sha256": _sha256(checked_payload),
        "rebuild_count": 2,
        "byte_identical": True,
    }


def _validate_and_copy_spatial_lock(
    repository_root: Path, partial_root: Path
) -> Mapping[str, Any]:
    preregistration = repository_root / SPATIAL_PREREGISTRATION_RELATIVE
    lock = repository_root / SPATIAL_LOCK_RELATIVE
    lock_payload = _read_regular(lock, "spatial-policy admissibility lock")
    internal_sha256 = validate_spatial_policy_admissibility_manifest_file(
        lock, repository_root=repository_root
    )
    rebuilt = build_spatial_policy_admissibility_manifest(repository_root)
    _require(
        lock_payload == canonical_json_bytes(rebuilt) + b"\n",
        "spatial-policy admissibility deterministic regeneration differs",
    )
    preregistration_payload = _read_regular(
        preregistration, "spatial-semantics preregistration"
    )
    destinations = (
        (
            preregistration,
            partial_root / "inputs/spatial-semantics-preregistration-v2.json",
            "spatial-semantics preregistration",
        ),
        (
            lock,
            partial_root / "inputs/spatial-policy-admissibility-manifest.json",
            "spatial-policy admissibility lock",
        ),
    )
    for source, destination, label in destinations:
        _copy_new(source, destination, label)
    return {
        "schema_version": "1.0.0",
        "status": "pass",
        "preregistration_file_sha256": _sha256(preregistration_payload),
        "lock_file_sha256": _sha256(lock_payload),
        "lock_manifest_sha256": internal_sha256,
        "deterministic_regeneration": True,
        "selection_performed": False,
        "holdout_accessed": False,
    }


def _command_contracts(
    *,
    repository_root: Path,
    partial_root: Path,
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> Mapping[str, Mapping[str, Any]]:
    python_executable = os.fspath(Path(sys.executable).resolve(strict=True))
    swiftlint = shutil.which("swiftlint", path=CANONICAL_PATH)
    _require(swiftlint is not None, "SwiftLint executable is absent")
    swiftlint_executable = os.fspath(Path(swiftlint).resolve(strict=True))
    python_environment = dict(
        _canonical_command_environment(repository_root, python=True)
    )
    native_environment = dict(
        _canonical_command_environment(repository_root, python=False)
    )
    result: dict[str, Mapping[str, Any]] = {}
    for identifier, run_name in zip(COMMAND_IDS[:3], RUN_NAMES):
        result[identifier] = {
            "id": identifier,
            "argv": [
                python_executable,
                "validation/spatial_v2/run_p05_evidence.py",
                "--output",
                os.fspath(partial_root / "evidence" / run_name),
            ],
            "cwd": os.fspath(repository_root),
            "environment": python_environment,
            "exit_status": 0,
            "output_path": f"outputs/{identifier}.log",
        }
    for identifier, suffix in (
        ("quality-lock-a", "a"),
        ("quality-lock-b", "b"),
    ):
        result[identifier] = {
            "id": identifier,
            "argv": [
                python_executable,
                "validation/quality/tools/"
                "build_quality_harness_implementation_manifest.py",
                "--repository-root",
                os.fspath(repository_root),
                "--output",
                os.fspath(
                    partial_root / f"inputs/quality-harness-lock-{suffix}.json"
                ),
            ],
            "cwd": os.fspath(repository_root),
            "environment": python_environment,
            "exit_status": 0,
            "output_path": f"outputs/{identifier}.log",
        }
    result["swiftlint"] = {
        "id": "swiftlint",
        "argv": [
            swiftlint_executable,
            "lint",
            "--strict",
            "--config",
            ".swiftlint.yml",
        ],
        "cwd": os.fspath(repository_root),
        "environment": native_environment,
        "exit_status": 0,
        "output_path": "outputs/swiftlint.log",
    }
    result["attribution"] = {
        "id": "attribution",
        "argv": [
            python_executable,
            "tools/scan_project_attribution.py",
            os.fspath(repository_root),
            "--policy",
            "config/attribution_policy.json",
            "--base",
            p00_baseline_commit,
            "--include",
            os.fspath(partial_root),
        ],
        "cwd": INSTRUCTION_PACKAGE_ROOT_TOKEN,
        "environment": python_environment,
        "exit_status": 0,
        "output_path": "outputs/attribution.log",
    }
    result["instruction-package"] = {
        "id": "instruction-package",
        "argv": [python_executable, "tools/validate_instruction_package.py"],
        "cwd": INSTRUCTION_PACKAGE_ROOT_TOKEN,
        "environment": python_environment,
        "exit_status": 0,
        "output_path": "outputs/instruction-package.log",
    }
    result["diff-check"] = {
        "id": "diff-check",
        "argv": ["/usr/bin/git", "diff", "--check"],
        "cwd": os.fspath(repository_root),
        "environment": native_environment,
        "exit_status": 0,
        "output_path": "outputs/diff-check.log",
    }
    return result


def _instruction_validation_output(instruction_package_root: Path) -> bytes:
    files = tuple(
        sorted(
            path.relative_to(instruction_package_root)
            for path in instruction_package_root.rglob("*")
            if path.is_file()
        )
    )
    excluded = {Path("package_manifest.json"), Path("SHA256SUMS.txt")}
    payload_files = tuple(path for path in files if path not in excluded)
    lines = [
        "PASS",
        f"total_files={len(files)}",
        f"payload_files={len(payload_files)}",
        f"checksum_entries={len(files) - 1}",
    ]
    for relative in payload_files:
        payload = _read_regular(
            instruction_package_root / relative,
            f"instruction package payload {relative.as_posix()}",
        )
        lines.append(f"{_sha256(payload)}  {relative.as_posix()}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def _validate_attribution_payload(payload: bytes, p00_baseline_commit: str) -> None:
    document = _json_object(payload, "attribution scan output")
    _require(
        set(document) == {"status", "base", "changed_file_count", "findings"}
        and document.get("status") == "pass"
        and document.get("base") == p00_baseline_commit
        and type(document.get("changed_file_count")) is int
        and document["changed_file_count"] >= 0
        and document.get("findings") == [],
        "attribution output does not prove a clean baseline-bound scan",
    )


def _execute_bound_command(
    *,
    command_plan: Mapping[str, Any],
    instruction_package_root: Path,
    identifier: str,
) -> bytes:
    rows = command_plan.get("commands")
    _require(isinstance(rows, list), f"{identifier} command plan rows are absent")
    matches = [
        row
        for row in rows
        if isinstance(row, Mapping) and row.get("id") == identifier
    ]
    _require(len(matches) == 1, f"{identifier} command plan row is ambiguous")
    row = matches[0]
    cwd = row.get("cwd")
    if cwd == INSTRUCTION_PACKAGE_ROOT_TOKEN:
        resolved_cwd = instruction_package_root
    else:
        _require(isinstance(cwd, str), f"{identifier} command cwd is absent")
        resolved_cwd = _canonical_directory(Path(cwd), f"{identifier} command cwd")
    result = subprocess.run(
        tuple(row["argv"]),
        cwd=resolved_cwd,
        env=dict(row["environment"]),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    _require(
        result.returncode == 0 and result.stderr == b"",
        f"{identifier} bound command failed or emitted stderr",
    )
    return result.stdout


def _command_row(
    command_plan: Mapping[str, Any],
    identifier: str,
) -> Mapping[str, Any]:
    rows = command_plan.get("commands")
    _require(isinstance(rows, list), f"{identifier} command plan rows are absent")
    matches = [
        row
        for row in rows
        if isinstance(row, Mapping) and row.get("id") == identifier
    ]
    _require(len(matches) == 1, f"{identifier} command plan row is ambiguous")
    return matches[0]


def _p05_result_paths(
    partial_root: Path,
    identifier: str,
) -> tuple[Path, Path, Path, Path]:
    _require(identifier in RUN_NAMES, f"unsupported P05 command class: {identifier}")
    return (
        partial_root / "evidence" / identifier,
        partial_root / "outputs" / f"{identifier}.log",
        partial_root / "outputs" / f"{identifier}.stderr.log",
        partial_root / "outputs" / f"{identifier}.result.json",
    )


def _quality_result_paths(
    partial_root: Path,
    identifier: str,
) -> tuple[Path, Path, Path]:
    _require(
        identifier in {"quality-lock-a", "quality-lock-b"},
        f"unsupported quality command class: {identifier}",
    )
    suffix = identifier[-1]
    return (
        partial_root / "inputs" / f"quality-harness-lock-{suffix}.json",
        partial_root / "outputs" / f"{identifier}.log",
        partial_root / "outputs" / f"{identifier}.stderr.log",
    )


def _artifact_binding(partial_root: Path, path: Path, label: str) -> Mapping[str, Any]:
    payload = _read_regular(path, label)
    return {
        "path": path.relative_to(partial_root).as_posix(),
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _write_command_result_receipt(
    *,
    partial_root: Path,
    row: Mapping[str, Any],
    identifier: str,
    started_utc: str,
    ended_utc: str,
    actual_exit_status: int,
    status: str,
    stdout_path: Path,
    stderr_path: Path,
    produced_artifacts: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    body: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_bound_command_result",
        "command_id": identifier,
        "status": status,
        "started_utc": started_utc,
        "ended_utc": ended_utc,
        "expected_exit_status": row.get("exit_status"),
        "actual_exit_status": actual_exit_status,
        "command_plan_row_sha256": canonical_sha256(row),
        "stdout": _artifact_binding(
            partial_root,
            stdout_path,
            f"{identifier} captured stdout",
        ),
        "stderr": _artifact_binding(
            partial_root,
            stderr_path,
            f"{identifier} captured stderr",
        ),
        "produced_artifacts": list(produced_artifacts),
    }
    document = {**body, "receipt_sha256": canonical_sha256(body)}
    result_path = partial_root / "outputs" / f"{identifier}.result.json"
    _write_json_new(result_path, document, f"{identifier} result receipt")
    return document


def _expected_command_products(identifier: str) -> tuple[str, ...]:
    if identifier in RUN_NAMES:
        return tuple(f"evidence/{identifier}/{name}" for name in P05_OUTPUT_NAMES)
    if identifier in {"quality-lock-a", "quality-lock-b"}:
        return (f"inputs/quality-harness-lock-{identifier[-1]}.json",)
    if identifier == "instruction-package":
        return tuple(relative for _, relative in INSTRUCTION_PACKAGE_PRODUCTS)
    return ()


def _validate_command_result_receipts(
    *,
    command_plan: Mapping[str, Any],
    partial_root: Path,
    require_pass: bool,
    identifiers: Sequence[str] = COMMAND_IDS,
) -> None:
    for identifier in identifiers:
        _require(identifier in COMMAND_IDS, f"unsupported command receipt class: {identifier}")
        row = _command_row(command_plan, identifier)
        stdout_path = partial_root / str(row["output_path"])
        stderr_path = partial_root / "outputs" / f"{identifier}.stderr.log"
        result_path = partial_root / "outputs" / f"{identifier}.result.json"
        document = _json_object(
            _read_regular(result_path, f"{identifier} result receipt"),
            f"{identifier} result receipt",
        )
        unhashed = dict(document)
        claimed = unhashed.pop("receipt_sha256", None)
        _require(
            set(unhashed)
            == {
                "schema_version",
                "artifact_kind",
                "command_id",
                "status",
                "started_utc",
                "ended_utc",
                "expected_exit_status",
                "actual_exit_status",
                "command_plan_row_sha256",
                "stdout",
                "stderr",
                "produced_artifacts",
            }
            and claimed == canonical_sha256(unhashed)
            and unhashed.get("schema_version") == "1.0.0"
            and unhashed.get("artifact_kind") == "g05_bound_command_result"
            and unhashed.get("command_id") == identifier
            and unhashed.get("status") in {"pass", "fail"}
            and unhashed.get("expected_exit_status") == row.get("exit_status")
            and type(unhashed.get("actual_exit_status")) is int
            and unhashed.get("command_plan_row_sha256") == canonical_sha256(row),
            f"{identifier} result receipt identity or self-hash differs",
        )
        started = _parse_utc(unhashed.get("started_utc"), f"{identifier} command start")
        ended = _parse_utc(unhashed.get("ended_utc"), f"{identifier} command end")
        _require(ended >= started, f"{identifier} command end precedes its start")
        for stream, path in (("stdout", stdout_path), ("stderr", stderr_path)):
            binding = unhashed.get(stream)
            payload = _read_regular(path, f"{identifier} captured {stream}")
            _require(
                isinstance(binding, Mapping)
                and set(binding) == {"path", "sha256", "size_bytes"}
                and binding.get("path") == path.relative_to(partial_root).as_posix()
                and binding.get("sha256") == _sha256(payload)
                and binding.get("size_bytes") == len(payload),
                f"{identifier} result receipt {stream} binding differs",
            )
        produced = unhashed.get("produced_artifacts")
        expected_products = _expected_command_products(identifier)
        _require(
            isinstance(produced, list)
            and all(isinstance(binding, Mapping) for binding in produced),
            f"{identifier} result receipt produced-artifact bindings are invalid",
        )
        if require_pass:
            _require(
                [binding.get("path") for binding in produced]
                == list(expected_products),
                f"{identifier} result receipt product closure differs",
            )
            for binding, relative in zip(produced, expected_products):
                payload = _read_regular(
                    partial_root.joinpath(*PurePosixPath(relative).parts),
                    f"{identifier} produced artifact {relative}",
                )
                _require(
                    set(binding) == {"path", "sha256", "size_bytes"}
                    and binding.get("sha256") == _sha256(payload)
                    and binding.get("size_bytes") == len(payload),
                    f"{identifier} result receipt product binding differs",
                )
        if require_pass:
            _require(
                unhashed.get("status") == "pass"
                and unhashed.get("actual_exit_status") == row.get("exit_status")
                and unhashed["stderr"].get("size_bytes") == 0,
                f"{identifier} result receipt does not record a passing command",
            )


def _build_command_execution_aggregate(
    *,
    partial_root: Path,
    command_plan: Mapping[str, Any],
    source_commit: str,
) -> Mapping[str, Any]:
    _validate_command_result_receipts(
        command_plan=command_plan,
        partial_root=partial_root,
        require_pass=True,
    )
    identity = _json_object(
        _read_regular(
            partial_root / "run-identity.json",
            "aggregate run identity interval",
        ),
        "aggregate run identity interval",
    )
    run_started = _parse_utc(identity.get("started_utc"), "aggregate run start")
    run_ended = _parse_utc(identity.get("ended_utc"), "aggregate run end")
    previous_ended = run_started
    for identifier in COMMAND_IDS:
        result = _json_object(
            _read_regular(
                partial_root / "outputs" / f"{identifier}.result.json",
                f"aggregate {identifier} result interval",
            ),
            f"aggregate {identifier} result interval",
        )
        command_started = _parse_utc(
            result.get("started_utc"),
            f"aggregate {identifier} command start",
        )
        command_ended = _parse_utc(
            result.get("ended_utc"),
            f"aggregate {identifier} command end",
        )
        _require(
            run_started <= command_started <= command_ended <= run_ended
            and previous_ended <= command_started,
            "run identity interval does not enclose the exact command order",
        )
        previous_ended = command_ended
    body: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_command_execution_aggregate",
        "status": "pass",
        "source_commit": source_commit,
        "command_plan": _artifact_binding(
            partial_root,
            partial_root / "inputs/g05-command-plan.json",
            "aggregate command plan",
        ),
        "run_identity": _artifact_binding(
            partial_root,
            partial_root / "run-identity.json",
            "aggregate run identity",
        ),
        "commands": [
            {
                "id": identifier,
                "stdout": _artifact_binding(
                    partial_root,
                    partial_root / "outputs" / f"{identifier}.log",
                    f"aggregate {identifier} stdout",
                ),
                "stderr": _artifact_binding(
                    partial_root,
                    partial_root / "outputs" / f"{identifier}.stderr.log",
                    f"aggregate {identifier} stderr",
                ),
                "result": _artifact_binding(
                    partial_root,
                    partial_root / "outputs" / f"{identifier}.result.json",
                    f"aggregate {identifier} result receipt",
                ),
            }
            for identifier in COMMAND_IDS
        ],
    }
    return {**body, "aggregate_sha256": canonical_sha256(body)}


def _validate_command_execution_aggregate(
    *,
    wrapper_root: Path,
    command_plan: Mapping[str, Any],
    source_commit: str,
) -> Mapping[str, Any]:
    path = wrapper_root / COMMAND_AGGREGATE_RELATIVE
    document = _json_object(
        _read_regular(path, "command execution aggregate"),
        "command execution aggregate",
    )
    unhashed = dict(document)
    claimed = unhashed.pop("aggregate_sha256", None)
    _require(
        set(unhashed)
        == {
            "schema_version",
            "artifact_kind",
            "status",
            "source_commit",
            "command_plan",
            "run_identity",
            "commands",
        }
        and claimed == canonical_sha256(unhashed)
        and unhashed.get("schema_version") == "1.0.0"
        and unhashed.get("artifact_kind") == "g05_command_execution_aggregate"
        and unhashed.get("status") == "pass"
        and unhashed.get("source_commit") == source_commit,
        "command execution aggregate identity or self-hash differs",
    )
    expected_bindings = (
        (
            unhashed.get("command_plan"),
            "inputs/g05-command-plan.json",
        ),
        (unhashed.get("run_identity"), "run-identity.json"),
    )
    for binding, relative in expected_bindings:
        payload = _read_regular(
            wrapper_root.joinpath(*PurePosixPath(relative).parts),
            f"aggregate bound file {relative}",
        )
        _require(
            isinstance(binding, Mapping)
            and set(binding) == {"path", "sha256", "size_bytes"}
            and binding.get("path") == relative
            and binding.get("sha256") == _sha256(payload)
            and binding.get("size_bytes") == len(payload),
            f"aggregate binding differs for {relative}",
        )
    rows = unhashed.get("commands")
    _require(
        isinstance(rows, list)
        and [row.get("id") for row in rows if isinstance(row, Mapping)]
        == list(COMMAND_IDS),
        "command execution aggregate row closure differs",
    )
    for row, identifier in zip(rows, COMMAND_IDS):
        _require(
            isinstance(row, Mapping)
            and set(row) == {"id", "stdout", "stderr", "result"},
            f"command execution aggregate row differs for {identifier}",
        )
        for field, suffix in (
            ("stdout", ".log"),
            ("stderr", ".stderr.log"),
            ("result", ".result.json"),
        ):
            relative = f"outputs/{identifier}{suffix}"
            binding = row.get(field)
            payload = _read_regular(
                wrapper_root / relative,
                f"aggregate {identifier} {field}",
            )
            _require(
                isinstance(binding, Mapping)
                and set(binding) == {"path", "sha256", "size_bytes"}
                and binding.get("path") == relative
                and binding.get("sha256") == _sha256(payload)
                and binding.get("size_bytes") == len(payload),
                f"aggregate {identifier} {field} binding differs",
            )
    _validate_command_result_receipts(
        command_plan=command_plan,
        partial_root=wrapper_root,
        require_pass=True,
    )
    return document


def _execute_bound_p05_runs(
    *,
    command_plan: Mapping[str, Any],
    repository_root: Path,
    partial_root: Path,
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> None:
    for identifier in RUN_NAMES:
        row = _command_row(command_plan, identifier)
        run_root, stdout_path, stderr_path, result_path = _p05_result_paths(
            partial_root,
            identifier,
        )
        for path, label in (
            (run_root, f"{identifier} P05 evidence root"),
            (stdout_path, f"{identifier} stdout evidence"),
            (stderr_path, f"{identifier} stderr evidence"),
            (result_path, f"{identifier} result receipt"),
        ):
            _require(
                not os.path.lexists(path),
                f"{label} was staged before its bound command execution",
            )
        started_utc = _utc_now()
        result = subprocess.run(
            tuple(row["argv"]),
            cwd=repository_root,
            env=dict(row["environment"]),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        ended_utc = _utc_now()
        _write_new(stdout_path, result.stdout, f"{identifier} captured stdout")
        _write_new(stderr_path, result.stderr, f"{identifier} captured stderr")
        expected_exit_status = row.get("exit_status")
        command_passed = (
            type(result.returncode) is int
            and result.returncode == expected_exit_status
            and result.stderr == b""
        )
        produced_artifacts = [
            _artifact_binding(
                partial_root,
                partial_root.joinpath(*PurePosixPath(relative).parts),
                f"{identifier} produced artifact {relative}",
            )
            for relative in _expected_command_products(identifier)
            if os.path.lexists(
                partial_root.joinpath(*PurePosixPath(relative).parts)
            )
        ]
        _write_command_result_receipt(
            partial_root=partial_root,
            row=row,
            identifier=identifier,
            started_utc=started_utc,
            ended_utc=ended_utc,
            actual_exit_status=result.returncode,
            status="pass" if command_passed else "fail",
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            produced_artifacts=produced_artifacts,
        )
        _validate_command_result_receipts(
            command_plan=command_plan,
            partial_root=partial_root,
            require_pass=False,
            identifiers=(identifier,),
        )
        _require(
            command_passed,
            f"{identifier} bound P05 command failed or emitted stderr",
        )
        _canonical_directory(run_root, f"{identifier} generated P05 evidence root")
        _validate_command_output(
            identifier=identifier,
            output_path=stdout_path,
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=p00_baseline_commit,
        )
        _validate_command_result_receipts(
            command_plan=command_plan,
            partial_root=partial_root,
            require_pass=True,
            identifiers=(identifier,),
        )


def _execute_bound_quality_locks(
    *,
    command_plan: Mapping[str, Any],
    repository_root: Path,
    partial_root: Path,
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> None:
    for identifier in ("quality-lock-a", "quality-lock-b"):
        row = _command_row(command_plan, identifier)
        manifest_path, stdout_path, stderr_path = _quality_result_paths(
            partial_root,
            identifier,
        )
        result_path = partial_root / "outputs" / f"{identifier}.result.json"
        for path, label in (
            (manifest_path, f"{identifier} generated manifest"),
            (stdout_path, f"{identifier} stdout evidence"),
            (stderr_path, f"{identifier} stderr evidence"),
            (result_path, f"{identifier} result receipt"),
        ):
            _require(
                not os.path.lexists(path),
                f"{label} was staged before its bound command execution",
            )
        started_utc = _utc_now()
        result = subprocess.run(
            tuple(row["argv"]),
            cwd=repository_root,
            env=dict(row["environment"]),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        ended_utc = _utc_now()
        _write_new(stdout_path, result.stdout, f"{identifier} captured stdout")
        _write_new(stderr_path, result.stderr, f"{identifier} captured stderr")
        command_passed = (
            result.returncode == row.get("exit_status") and result.stderr == b""
        )
        produced_artifacts = (
            [
                _artifact_binding(
                    partial_root,
                    manifest_path,
                    f"{identifier} generated manifest",
                )
            ]
            if os.path.lexists(manifest_path)
            else []
        )
        _write_command_result_receipt(
            partial_root=partial_root,
            row=row,
            identifier=identifier,
            started_utc=started_utc,
            ended_utc=ended_utc,
            actual_exit_status=result.returncode,
            status="pass" if command_passed else "fail",
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            produced_artifacts=produced_artifacts,
        )
        _require(
            command_passed,
            f"{identifier} bound command failed or emitted stderr",
        )
        _canonical_regular(manifest_path, f"{identifier} generated manifest")
        _validate_command_output(
            identifier=identifier,
            output_path=stdout_path,
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=p00_baseline_commit,
        )
        _validate_command_result_receipts(
            command_plan=command_plan,
            partial_root=partial_root,
            require_pass=True,
            identifiers=(identifier,),
        )


def _execute_bound_attribution(
    *,
    command_plan: Mapping[str, Any],
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> bytes:
    row = _command_row(command_plan, "attribution")
    _require(
        row.get("cwd") == INSTRUCTION_PACKAGE_ROOT_TOKEN,
        "attribution command does not use the logical instruction-package cwd",
    )
    result = subprocess.run(
        tuple(row["argv"]),
        cwd=instruction_package_root,
        env=dict(row["environment"]),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise G05SetupError(
            "untrusted staged content failed the bound prohibited-content scan"
        )
    if result.stderr != b"":
        raise G05SetupError(
            "bound prohibited-content scan emitted unexpected stderr"
        )
    _validate_attribution_payload(result.stdout, p00_baseline_commit)
    return result.stdout


def _copy_instruction_package_products(
    *,
    partial_root: Path,
    instruction_package_root: Path,
) -> tuple[Mapping[str, Any], ...]:
    destination_root = partial_root / "inputs/instruction-package"
    _canonical_absent_leaf(
        destination_root,
        "instruction-package produced-artifact directory",
    )
    os.mkdir(destination_root, 0o755)
    destination_root = _canonical_directory(
        destination_root,
        "instruction-package produced-artifact directory",
    )
    parent_descriptor = os.open(
        destination_root.parent,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
    bindings: list[Mapping[str, Any]] = []
    for source_name, relative in INSTRUCTION_PACKAGE_PRODUCTS:
        source = instruction_package_root / source_name
        destination = partial_root.joinpath(*PurePosixPath(relative).parts)
        payload = _read_regular(
            source,
            f"instruction-package source {source_name}",
        )
        _write_new(
            destination,
            payload,
            f"instruction-package produced artifact {source_name}",
        )
        _require(
            _read_regular(
                source,
                f"instruction-package source {source_name} after copy",
            )
            == payload
            and _read_regular(
                destination,
                f"instruction-package copied {source_name}",
            )
            == payload,
            f"instruction-package source changed while copying {source_name}",
        )
        bindings.append(
            _artifact_binding(
                partial_root,
                destination,
                f"instruction-package produced artifact {source_name}",
            )
        )
    return tuple(bindings)


def _execute_captured_replay(
    *,
    command_plan: Mapping[str, Any],
    partial_root: Path,
    instruction_package_root: Path,
    p00_baseline_commit: str,
    identifier: str,
    stdout_must_exist: bool,
) -> bytes:
    row = _command_row(command_plan, identifier)
    cwd = row.get("cwd")
    if cwd == INSTRUCTION_PACKAGE_ROOT_TOKEN:
        resolved_cwd = instruction_package_root
    else:
        _require(isinstance(cwd, str), f"{identifier} command cwd is absent")
        resolved_cwd = _canonical_directory(Path(cwd), f"{identifier} command cwd")
    stdout_path = partial_root / str(row["output_path"])
    stderr_path = partial_root / "outputs" / f"{identifier}.stderr.log"
    result_path = partial_root / "outputs" / f"{identifier}.result.json"
    _require(
        os.path.lexists(stdout_path) is stdout_must_exist
        and not os.path.lexists(stderr_path)
        and not os.path.lexists(result_path),
        f"{identifier} captured replay paths violate the absent-output contract",
    )
    if identifier == "instruction-package":
        _require(
            not os.path.lexists(partial_root / "inputs/instruction-package"),
            "instruction-package products were staged before bound execution",
        )
    staged_stdout = (
        _read_regular(stdout_path, f"{identifier} staged stdout")
        if stdout_must_exist
        else None
    )
    started_utc = _utc_now()
    result = subprocess.run(
        tuple(row["argv"]),
        cwd=resolved_cwd,
        env=dict(row["environment"]),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if not stdout_must_exist:
        _write_new(stdout_path, result.stdout, f"{identifier} captured stdout")
        staged_stdout = result.stdout
    _write_new(stderr_path, result.stderr, f"{identifier} captured stderr")
    command_passed = (
        result.returncode == row.get("exit_status")
        and result.stderr == b""
        and result.stdout == staged_stdout
    )
    produced_artifacts: Sequence[Mapping[str, Any]] = ()
    if command_passed and identifier == "instruction-package":
        produced_artifacts = _copy_instruction_package_products(
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
        )
    ended_utc = _utc_now()
    _write_command_result_receipt(
        partial_root=partial_root,
        row=row,
        identifier=identifier,
        started_utc=started_utc,
        ended_utc=ended_utc,
        actual_exit_status=result.returncode,
        status="pass" if command_passed else "fail",
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        produced_artifacts=produced_artifacts,
    )
    if identifier == "attribution" and result.returncode != row.get("exit_status"):
        raise G05SetupError(
            "untrusted staged content failed the bound prohibited-content scan"
        )
    _require(command_passed, f"{identifier} captured live replay differs or failed")
    _validate_command_output(
        identifier=identifier,
        output_path=stdout_path,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=p00_baseline_commit,
    )
    _validate_command_result_receipts(
        command_plan=command_plan,
        partial_root=partial_root,
        require_pass=True,
        identifiers=(identifier,),
    )
    return result.stdout


def _validate_live_command_replays(
    *,
    command_plan: Mapping[str, Any],
    partial_root: Path,
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> None:
    for identifier in ("swiftlint", "instruction-package", "diff-check"):
        _execute_captured_replay(
            command_plan=command_plan,
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=p00_baseline_commit,
            identifier=identifier,
            stdout_must_exist=True,
        )


def _validate_command_output(
    *,
    identifier: str,
    output_path: Path,
    partial_root: Path,
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> None:
    payload = _read_regular(output_path, f"{identifier} command output")
    if identifier in RUN_NAMES:
        run_root = partial_root / "evidence" / identifier
        expected = b"".join(
            (
                f"{_sha256(_read_regular(run_root / filename, f'{identifier} {filename}'))}  "
                f"{filename}\n"
            ).encode("utf-8")
            for filename in P05_OUTPUT_NAMES
        )
        _require(
            payload == expected,
            f"{identifier} output does not bind its exact eight-file P05 result",
        )
        return
    if identifier in {"quality-lock-a", "quality-lock-b"}:
        suffix = identifier[-1]
        document = _json_object(
            _read_regular(
                partial_root / f"inputs/quality-harness-lock-{suffix}.json",
                f"{identifier} generated manifest",
            ),
            f"{identifier} generated manifest",
        )
        expected = document.get("manifest_sha256")
        _require(
            isinstance(expected, str)
            and SHA256_PATTERN.fullmatch(expected) is not None
            and payload == f"{expected}\n".encode("ascii"),
            f"{identifier} output does not bind its manifest self-hash",
        )
        return
    if identifier == "swiftlint":
        try:
            text = payload.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise G05CurrentSourceError("SwiftLint output is not UTF-8") from error
        summaries = re.findall(
            r"Found 0 violations, 0 serious in [1-9][0-9]* files\.",
            text,
        )
        _require(
            len(summaries) == 1
            and re.search(r"Found [1-9][0-9]* violations", text) is None
            and "error:" not in text.lower(),
            "SwiftLint output does not prove one zero-violation strict run",
        )
        return
    if identifier == "attribution":
        _validate_attribution_payload(payload, p00_baseline_commit)
        return
    if identifier == "instruction-package":
        _require(
            payload == _instruction_validation_output(instruction_package_root),
            "instruction-package output differs from the bound package closure",
        )
        return
    if identifier == "diff-check":
        _require(payload == b"", "Git diff-check output is not empty")
        return
    raise G05CurrentSourceError(f"unsupported G05 command class: {identifier}")


def _validate_command_plan(
    *,
    repository_root: Path,
    partial_root: Path,
    instruction_package_root: Path,
    source_commit: str,
    p00_baseline_commit: str,
    attribution_output_required: bool = True,
    p05_output_required: bool = True,
    p05_partial_failure_allowed: bool = False,
    quality_output_required: bool = True,
    quality_partial_failure_allowed: bool = False,
) -> Mapping[str, Any]:
    _require(
        not p05_partial_failure_allowed or not p05_output_required,
        "partial P05 failure mode conflicts with required P05 outputs",
    )
    _require(
        not quality_partial_failure_allowed or not quality_output_required,
        "partial quality failure mode conflicts with required quality outputs",
    )
    path = partial_root / "inputs/g05-command-plan.json"
    payload = _read_regular(path, "G05 structured command plan")
    document = _json_object(payload, "G05 structured command plan")
    _validate_schema_document(document, COMMAND_PLAN_SCHEMA, "G05 command plan")
    _require(
        document.get("source_commit") == source_commit,
        "G05 command plan source commit differs",
    )
    rows = document.get("commands")
    _require(isinstance(rows, list), "G05 command plan rows are absent")
    _require(
        [row.get("id") for row in rows if isinstance(row, Mapping)]
        == list(COMMAND_IDS),
        "G05 command plan order or exact command classes differ",
    )
    contracts = _command_contracts(
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=p00_baseline_commit,
    )
    for index, row in enumerate(rows):
        label = f"G05 command plan row {index}"
        _require(isinstance(row, Mapping), f"{label} is not an object")
        identifier = row.get("id")
        _require(
            isinstance(identifier, str) and row == contracts.get(identifier),
            f"{label} differs from its canonical argv/cwd/environment/output contract",
        )
        if row["cwd"] == INSTRUCTION_PACKAGE_ROOT_TOKEN:
            _canonical_directory(
                instruction_package_root,
                f"{label} resolved instruction-package cwd",
            )
        else:
            _canonical_directory(Path(str(row["cwd"])), f"{label} cwd")
        parsed_output = _safe_relative(row["output_path"], f"{label} output")
        output = partial_root.joinpath(*parsed_output.parts)
        if identifier in RUN_NAMES and not p05_output_required:
            run_root, stdout_path, stderr_path, result_path = _p05_result_paths(
                partial_root,
                identifier,
            )
            _require(
                output == stdout_path,
                f"{label} output differs from its P05 receipt binding",
            )
            if not p05_partial_failure_allowed:
                for staged_path, staged_label in (
                    (run_root, "evidence root"),
                    (stdout_path, "stdout"),
                    (stderr_path, "stderr"),
                    (result_path, "result receipt"),
                ):
                    _require(
                        not os.path.lexists(staged_path),
                        f"{identifier} {staged_label} was staged before execution",
                    )
            continue
        if identifier in {"quality-lock-a", "quality-lock-b"} and not quality_output_required:
            manifest_path, stdout_path, stderr_path = _quality_result_paths(
                partial_root,
                identifier,
            )
            _require(
                output == stdout_path,
                f"{label} output differs from its quality-lock binding",
            )
            if not quality_partial_failure_allowed:
                for staged_path, staged_label in (
                    (manifest_path, "generated manifest"),
                    (stdout_path, "stdout"),
                    (stderr_path, "stderr"),
                ):
                    _require(
                        not os.path.lexists(staged_path),
                        f"{identifier} {staged_label} was staged before execution",
                    )
            continue
        if identifier == "attribution" and not attribution_output_required:
            _require(
                not os.path.lexists(output),
                "attribution output was staged before the complete wrapper scan",
            )
            continue
        _require(
            output.resolve(strict=True) == output,
            f"{label} output is not canonical",
        )
        _validate_command_output(
            identifier=identifier,
            output_path=output,
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=p00_baseline_commit,
        )
    return document


def _verify_live_metadata(arguments: argparse.Namespace) -> Mapping[str, Any]:
    _require(
        arguments.live_preopen_version_id == "p06-spatial-v2",
        "live preopen version is not p06-spatial-v2",
    )
    expected_receipt_name = (
        f"holdout-preopen-receipt.{arguments.live_preopen_version_id}.json"
    )
    _require(
        arguments.live_preopen_receipt_path.name == expected_receipt_name,
        "live preopen receipt filename differs from the explicit v2 version",
    )
    verification = dict(
        verify_live_holdout_preopen(
            live_ledger_path=arguments.live_ledger_path,
            live_anchor_path=arguments.live_anchor_path,
            live_preopen_receipt_path=arguments.live_preopen_receipt_path,
            expected_live_ledger_root_identity_sha256=(
                arguments.expected_live_ledger_root_identity_sha256
            ),
            expected_live_anchor_root_identity_sha256=(
                arguments.expected_live_anchor_root_identity_sha256
            ),
            expected_live_preopen_receipt_sha256=(
                arguments.expected_live_preopen_receipt_sha256
            ),
            repository_sealed_copy_path=arguments.repository_sealed_copy_path,
            expected_repository_sealed_copy_sha256=(
                arguments.expected_repository_sealed_copy_sha256
            ),
            repository_attestation_path=arguments.repository_attestation_path,
            expected_repository_attestation_sha256=(
                arguments.expected_repository_attestation_sha256
            ),
        )
    )
    _require(
        verification.get("verification_status") == "pass"
        and verification.get("access_status") == "unopened"
        and verification.get("access_count") == 0
        and verification.get("open_intent_anchor_present") is False
        and verification.get("pixel_content_included") is False,
        "live metadata does not prove a v2 unopened, zero-access, no-pixel state",
    )
    return verification


def _copy_live_metadata(
    arguments: argparse.Namespace,
    partial_root: Path,
    verification: Mapping[str, Any],
) -> Mapping[str, Any]:
    destination_root = partial_root / "inputs/live-preopen"
    sources = (
        (
            arguments.live_ledger_path,
            destination_root / "holdout-access-ledger.p06-spatial-v2.json",
            "live v2 access ledger",
        ),
        (
            arguments.live_preopen_receipt_path,
            destination_root / "holdout-preopen-receipt.p06-spatial-v2.json",
            "live v2 preopen receipt",
        ),
        (
            arguments.repository_sealed_copy_path,
            destination_root / "repository-sealed-holdout-access-ledger.json",
            "repository sealed holdout ledger",
        ),
        (
            arguments.repository_attestation_path,
            destination_root / "repository-holdout-seal-attestation.json",
            "repository no-pixel holdout attestation",
        ),
    )
    bindings = [
        _copy_new(
            source,
            destination,
            label,
            binding_root=partial_root,
        )
        for source, destination, label in sources
    ]
    verified_hashes = (
        verification.get("live_ledger_sha256"),
        verification.get("live_preopen_receipt_sha256"),
        verification.get("repository_sealed_copy_sha256"),
        verification.get("repository_attestation_sha256"),
    )
    _require(
        all(
            binding.get("sha256") == verified_hash
            for binding, verified_hash in zip(bindings, verified_hashes)
        ),
        "copied live metadata differs from the verified preopen snapshot",
    )
    document = {
        "status": "pass",
        "version_id": arguments.live_preopen_version_id,
        "metadata_only": True,
        "pixel_content_included": False,
        "open_intent_anchor_present": False,
        "bindings": bindings,
    }
    _validate_live_metadata_closure(document, partial_root)
    return document


def _validate_live_metadata_closure(
    document: Mapping[str, Any],
    partial_root: Path,
) -> None:
    expected_paths = (
        "inputs/live-preopen/holdout-access-ledger.p06-spatial-v2.json",
        "inputs/live-preopen/holdout-preopen-receipt.p06-spatial-v2.json",
        "inputs/live-preopen/repository-sealed-holdout-access-ledger.json",
        "inputs/live-preopen/repository-holdout-seal-attestation.json",
    )
    _require(
        set(document)
        == {
            "status",
            "version_id",
            "metadata_only",
            "pixel_content_included",
            "open_intent_anchor_present",
            "bindings",
        }
        and document.get("status") == "pass"
        and document.get("version_id") == "p06-spatial-v2"
        and document.get("metadata_only") is True
        and document.get("pixel_content_included") is False
        and document.get("open_intent_anchor_present") is False,
        "live metadata closure semantics differ from the exact v2 preopen contract",
    )
    bindings = document.get("bindings")
    _require(
        isinstance(bindings, list)
        and len(bindings) == 4
        and [binding.get("path") for binding in bindings if isinstance(binding, Mapping)]
        == list(expected_paths),
        "live metadata closure does not bind the exact four canonical files",
    )
    for index, (binding, expected_path) in enumerate(zip(bindings, expected_paths)):
        _require(
            isinstance(binding, Mapping)
            and set(binding) == {"path", "sha256", "size_bytes"}
            and binding.get("path") == expected_path
            and isinstance(binding.get("sha256"), str)
            and SHA256_PATTERN.fullmatch(str(binding["sha256"])) is not None
            and type(binding.get("size_bytes")) is int
            and binding["size_bytes"] >= 0,
            f"live metadata binding {index} is not an exact content binding",
        )
        payload = _read_regular(
            partial_root / expected_path,
            f"live metadata closure file {index}",
        )
        _require(
            binding["sha256"] == _sha256(payload)
            and binding["size_bytes"] == len(payload),
            f"live metadata binding {index} differs from its copied file",
        )


def _status_values(value: object) -> list[object]:
    result: list[object] = []
    if isinstance(value, Mapping):
        for key, child in value.items():
            if key == "status":
                result.append(child)
            result.extend(_status_values(child))
    elif isinstance(value, list):
        for child in value:
            result.extend(_status_values(child))
    return result


def _collect_tree_closure(root: Path) -> tuple[tuple[str, ...], tuple[str, ...]]:
    directory_result: list[str] = []
    file_result: list[str] = []
    for current_name, directories, files in os.walk(root, topdown=True, followlinks=False):
        current = Path(current_name)
        _require(current.resolve(strict=True) == current, "partial tree contains a linked directory")
        directories.sort()
        files.sort()
        for directory in directories:
            child = current / directory
            metadata = os.lstat(child)
            _require(
                stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
                f"partial tree entry is not a directory: {child}",
            )
            directory_result.append(child.relative_to(root).as_posix())
        for filename in files:
            path = current / filename
            relative = path.relative_to(root).as_posix()
            _require(relative not in RESERVED_PARTIAL_FILES, f"reserved partial file is pre-staged: {relative}")
            _read_regular(path, f"partial artifact {relative}")
            file_result.append(relative)
    _require(file_result, "partial evidence tree has no files")
    return tuple(sorted(directory_result)), tuple(sorted(file_result))


def _collect_directories(root: Path) -> tuple[str, ...]:
    result: list[str] = []
    for current_name, directories, _ in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        if root == Path("."):
            _require(
                not current.is_absolute()
                and all(part != ".." for part in current.parts),
                "tree escaped its pinned directory",
            )
        else:
            _require(
                current.resolve(strict=True) == current,
                "tree contains a linked directory",
            )
        directories.sort()
        for directory in directories:
            child = current / directory
            metadata = os.lstat(child)
            _require(
                stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
                f"tree entry is not a directory: {child}",
            )
            result.append(child.relative_to(root).as_posix())
    return tuple(sorted(result))


def _collect_files(root: Path) -> tuple[str, ...]:
    return _collect_tree_closure(root)[1]


def _ancestor_directories(paths: Sequence[str]) -> tuple[str, ...]:
    directories: set[str] = set()
    for index, relative in enumerate(paths):
        parsed = _safe_relative(relative, f"closure file {index}")
        for length in range(1, len(parsed.parts)):
            directories.add(PurePosixPath(*parsed.parts[:length]).as_posix())
    return tuple(sorted(directories))


def _initial_staged_paths() -> tuple[str, ...]:
    return (
        "inputs/g05-command-plan.json",
        "outputs/diff-check.log",
        "outputs/instruction-package.log",
        "outputs/swiftlint.log",
    )


def _initial_staged_directories() -> tuple[str, ...]:
    return (
        "analysis",
        "evidence",
        "inputs",
        "inputs/g03",
        "inputs/g04",
        "inputs/live-preopen",
        "outputs",
    )


def _success_wrapper_paths() -> tuple[str, ...]:
    paths = {
        "GATE_REPORT.md",
        "README.md",
        "analysis/g05-gate-assessment.json",
        "analysis/independent-audit.json",
        "analysis/live-holdout-preopen-verification.json",
        "analysis/quality-lock-audit.json",
        "commands.log",
        "environment.json",
        "git-state.txt",
        "inputs/command-execution-aggregate.json",
        "inputs/g05-command-plan.json",
        "analysis/g05-scoped-finding-register.json",
        "inputs/instruction-package/package_manifest.json",
        "inputs/instruction-package/SHA256SUMS.txt",
        "inputs/pre-finalization-semantic-bindings.json",
        "inputs/provenance-map.json",
        "inputs/quality-harness-lock-a.json",
        "inputs/quality-harness-lock-b.json",
        "inputs/spatial-policy-admissibility-manifest.json",
        "inputs/spatial-semantics-preregistration-v2.json",
        "inputs/upstream-bindings.json",
        "receipt.json",
        "run-identity.json",
        "test-results.json",
        SUPPLEMENTAL_SCAN_RELATIVE,
    }
    for relative in ("artifact-manifest.json", *G03_CANONICAL_FILES):
        paths.add(f"inputs/g03/{Path(relative).name}")
    for relative in ("artifact-manifest.json", *G04_CANONICAL_FILES):
        paths.add(f"inputs/g04/{Path(relative).name}")
    paths.update(
        {
            "inputs/live-preopen/holdout-access-ledger.p06-spatial-v2.json",
            "inputs/live-preopen/holdout-preopen-receipt.p06-spatial-v2.json",
            "inputs/live-preopen/repository-holdout-seal-attestation.json",
            "inputs/live-preopen/repository-sealed-holdout-access-ledger.json",
        }
    )
    for identifier in RUN_NAMES:
        for filename in P05_OUTPUT_NAMES:
            paths.add(f"evidence/{identifier}/{filename}")
    for identifier in COMMAND_IDS:
        paths.update(
            {
                f"outputs/{identifier}.log",
                f"outputs/{identifier}.stderr.log",
                f"outputs/{identifier}.result.json",
            }
        )
    return tuple(sorted(paths))


def _failure_wrapper_allowed_paths() -> tuple[str, ...]:
    paths = set(_success_wrapper_paths())
    paths.update(
        {
            "g05-failure-classification.json",
            "analysis/live-holdout-preopen-verification.pre-failure.json",
            "run-identity.pre-failure.json",
            "inputs/pre-finalization-semantic-bindings.pre-failure.json",
            "inputs/provenance-map.pre-failure.json",
            "outputs/attribution.pre-failure.log",
            "outputs/attribution.pre-failure.stderr.log",
            "outputs/attribution.pre-failure.result.json",
            "outputs/supplemental-content-scan.pre-failure.json",
        }
    )
    return tuple(sorted(paths))


def _require_file_closure(
    root: Path,
    expected: Sequence[str],
    label: str,
    *,
    exact: bool,
    expected_directories: Optional[Sequence[str]] = None,
) -> tuple[str, ...]:
    actual_directories, actual = _collect_tree_closure(root)
    expected_set = set(expected)
    actual_set = set(actual)
    normalized_expected_directories = tuple(
        sorted(
            expected_directories
            if expected_directories is not None
            else _ancestor_directories(expected)
        )
    )
    for index, relative in enumerate(normalized_expected_directories):
        _safe_relative(relative, f"{label} directory {index}")
    _require(
        len(normalized_expected_directories)
        == len(set(normalized_expected_directories)),
        f"{label} directory closure is ambiguous",
    )
    expected_directory_set = set(normalized_expected_directories)
    actual_directory_set = set(actual_directories)
    if exact:
        condition = (
            actual_set == expected_set
            and actual_directory_set == expected_directory_set
        )
    else:
        condition = (
            actual_set <= expected_set
            and actual_directory_set <= expected_directory_set
        )
    _require(condition, f"{label} contains an unexpected or missing file")
    return actual


def _git_paths_z(
    repository_root: Path,
    arguments: Sequence[str],
    label: str,
) -> tuple[str, ...]:
    payload = _run_git(repository_root, arguments)
    if payload and not payload.endswith(b"\0"):
        raise G05SetupError(f"{label} did not return a NUL-terminated path set")
    result: list[str] = []
    for index, raw in enumerate(payload.split(b"\0")):
        if not raw:
            continue
        try:
            value = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise G05SetupError(f"{label} path {index} is not UTF-8") from error
        parsed = _safe_relative(value, f"{label} path {index}")
        result.append(parsed.as_posix())
    _require_setup(len(result) == len(set(result)), f"{label} paths are ambiguous")
    return tuple(result)


def _supplemental_patterns(
    instruction_package_root: Path,
) -> tuple[bytes, tuple[re.Pattern[str], ...]]:
    policy_path = instruction_package_root / "config/attribution_policy.json"
    payload = _read_regular(policy_path, "supplemental scan policy")
    policy = _json_object(payload, "supplemental scan policy")
    values = policy.get("scan_patterns")
    _require_setup(
        isinstance(values, list)
        and bool(values)
        and all(isinstance(value, str) and value for value in values),
        "supplemental scan policy patterns are absent",
    )
    try:
        patterns = tuple(re.compile(value) for value in values)
    except re.error as error:
        raise G05SetupError("supplemental scan policy contains an invalid pattern") from error
    return payload, patterns


def _supplemental_match(
    *,
    logical_path: str,
    payload: Optional[bytes],
    patterns: Sequence[re.Pattern[str]],
) -> str:
    for pattern in patterns:
        if pattern.search(logical_path):
            raise G05SetupError(
                "supplemental prohibited-content filename scan rejected staged content"
            )
    if payload is None:
        return "not_applicable_absent_at_source"
    if b"\0" in payload:
        return "excluded_nul_binary_by_policy_scope"
    text = payload.decode("utf-8", errors="replace")
    for pattern in patterns:
        if pattern.search(text):
            raise G05SetupError(
                "supplemental prohibited-content text scan rejected staged content"
            )
    return "performed_nul_free_content"


def _build_supplemental_scan_evidence(
    *,
    repository_root: Path,
    partial_root: Path,
    instruction_package_root: Path,
    baseline_commit: str,
    source_commit: str,
    wrapper_paths: Sequence[str],
    wrapper_directories: Optional[Sequence[str]] = None,
) -> tuple[Mapping[str, Any], tuple[re.Pattern[str], ...]]:
    policy_payload, patterns = _supplemental_patterns(instruction_package_root)
    committed = _git_paths_z(
        repository_root,
        (
            "diff",
            "--name-only",
            "--diff-filter=ACMRTD",
            "-z",
            f"{baseline_commit}...{source_commit}",
        ),
        "baseline-changed repository",
    )
    working = _git_paths_z(
        repository_root,
        ("diff", "--name-only", "--diff-filter=ACMRTD", "-z"),
        "working-tree changed repository",
    )
    untracked = _git_paths_z(
        repository_root,
        ("ls-files", "--others", "--exclude-standard", "-z"),
        "untracked repository",
    )
    repository_paths = tuple(sorted(set((*committed, *working, *untracked))))
    repository_rows: list[Mapping[str, Any]] = []
    for relative in repository_paths:
        path = repository_root.joinpath(*PurePosixPath(relative).parts)
        if os.path.lexists(path):
            payload = _read_regular(path, f"supplemental repository file {relative}")
            state = "present_regular"
            digest: Optional[str] = _sha256(payload)
            size: Optional[int] = len(payload)
        else:
            payload = None
            state = "absent_at_source_commit"
            digest = None
            size = None
        content_scan = _supplemental_match(
            logical_path=relative,
            payload=payload,
            patterns=patterns,
        )
        repository_rows.append(
            {
                "path": relative,
                "state": state,
                "sha256": digest,
                "size_bytes": size,
                "content_scan": content_scan,
            }
        )
    normalized_wrapper_paths = tuple(sorted(wrapper_paths))
    _require(
        normalized_wrapper_paths
        and len(normalized_wrapper_paths) == len(set(normalized_wrapper_paths)),
        "supplemental wrapper scan path closure is empty or ambiguous",
    )
    for index, relative in enumerate(normalized_wrapper_paths):
        _safe_relative(relative, f"supplemental wrapper path {index}")
        _supplemental_match(
            logical_path=relative,
            payload=None,
            patterns=patterns,
        )
    normalized_wrapper_directories = tuple(
        sorted(
            wrapper_directories
            if wrapper_directories is not None
            else _ancestor_directories(normalized_wrapper_paths)
        )
    )
    _require(
        len(normalized_wrapper_directories)
        == len(set(normalized_wrapper_directories)),
        "supplemental wrapper directory closure is ambiguous",
    )
    for index, relative in enumerate(normalized_wrapper_directories):
        _safe_relative(relative, f"supplemental wrapper directory {index}")
        _supplemental_match(
            logical_path=relative,
            payload=None,
            patterns=patterns,
        )
    body: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_supplemental_content_scan",
        "status": "pass",
        "baseline_commit": baseline_commit,
        "source_commit": source_commit,
        "policy": {
            "root": INSTRUCTION_PACKAGE_ROOT_TOKEN,
            "path": "config/attribution_policy.json",
            "sha256": _sha256(policy_payload),
            "size_bytes": len(policy_payload),
        },
        "coverage": "all_filenames_and_all_nul_free_file_content",
        "repository_files": repository_rows,
        "wrapper_directories": list(normalized_wrapper_directories),
        "wrapper_directory_set_sha256": _sha256(
            "".join(
                f"{path}\n" for path in normalized_wrapper_directories
            ).encode("utf-8")
        ),
        "wrapper_paths": list(normalized_wrapper_paths),
        "wrapper_path_set_sha256": _sha256(
            "".join(f"{path}\n" for path in normalized_wrapper_paths).encode("utf-8")
        ),
    }
    return {**body, "scan_evidence_sha256": canonical_sha256(body)}, patterns


def _validate_supplemental_wrapper_scan(
    *,
    partial_root: Path,
    document: Mapping[str, Any],
    patterns: Sequence[re.Pattern[str]],
    candidate_files: Mapping[str, bytes],
) -> None:
    wrapper_paths = document.get("wrapper_paths")
    wrapper_directories = document.get("wrapper_directories")
    _require(
        isinstance(wrapper_paths, list)
        and all(isinstance(path, str) for path in wrapper_paths)
        and isinstance(wrapper_directories, list)
        and all(isinstance(path, str) for path in wrapper_directories),
        "supplemental wrapper scan evidence closure is absent",
    )
    existing_directories, existing_files = _collect_tree_closure(partial_root)
    existing = set(existing_files)
    candidate_paths = set(candidate_files)
    _require(
        existing.isdisjoint(candidate_paths)
        and set(wrapper_paths) == existing | candidate_paths
        and set(wrapper_directories) == set(existing_directories),
        "supplemental wrapper scan evidence differs from the exact candidate closure",
    )
    for relative in wrapper_directories:
        _supplemental_match(
            logical_path=relative,
            payload=None,
            patterns=patterns,
        )
    for relative in wrapper_paths:
        payload = candidate_files.get(relative)
        if payload is None:
            payload = _read_regular(
                partial_root.joinpath(*PurePosixPath(relative).parts),
                f"supplemental wrapper file {relative}",
            )
        _supplemental_match(
            logical_path=relative,
            payload=payload,
            patterns=patterns,
        )


def _build_semantic_bindings_snapshot(
    *,
    partial_root: Path,
    source_commit: str,
    expected_paths: Sequence[str],
    candidate_files: Mapping[str, bytes],
) -> Mapping[str, Any]:
    normalized = tuple(sorted(expected_paths))
    _require(
        tuple(expected_paths) == normalized
        and len(normalized) == len(set(normalized))
        and SEMANTIC_BINDINGS_RELATIVE in normalized,
        "semantic snapshot path closure is not exact and canonical",
    )
    bindings: list[Mapping[str, Any]] = []
    for relative in normalized:
        if relative == SEMANTIC_BINDINGS_RELATIVE:
            continue
        payload = candidate_files.get(relative)
        if payload is None:
            payload = _read_regular(
                partial_root.joinpath(*PurePosixPath(relative).parts),
                f"semantic snapshot file {relative}",
            )
        bindings.append(
            {
                "path": relative,
                "sha256": _sha256(payload),
                "size_bytes": len(payload),
            }
        )
    body: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_pre_finalization_semantic_bindings",
        "status": "pass",
        "source_commit": source_commit,
        "snapshot_excludes_self": True,
        "bindings": bindings,
    }
    return {**body, "snapshot_sha256": canonical_sha256(body)}


def _validate_semantic_bindings_snapshot(
    *,
    wrapper_root: Path,
    source_commit: str,
    expected_paths: Sequence[str],
) -> Mapping[str, Any]:
    path = wrapper_root / SEMANTIC_BINDINGS_RELATIVE
    document = _json_object(
        _read_regular(path, "pre-finalization semantic bindings"),
        "pre-finalization semantic bindings",
    )
    unhashed = dict(document)
    claimed = unhashed.pop("snapshot_sha256", None)
    expected_bound_paths = [
        relative
        for relative in sorted(expected_paths)
        if relative != SEMANTIC_BINDINGS_RELATIVE
    ]
    bindings = unhashed.get("bindings")
    _require(
        set(unhashed)
        == {
            "schema_version",
            "artifact_kind",
            "status",
            "source_commit",
            "snapshot_excludes_self",
            "bindings",
        }
        and claimed == canonical_sha256(unhashed)
        and unhashed.get("schema_version") == "1.0.0"
        and unhashed.get("artifact_kind")
        == "g05_pre_finalization_semantic_bindings"
        and unhashed.get("status") == "pass"
        and unhashed.get("source_commit") == source_commit
        and unhashed.get("snapshot_excludes_self") is True
        and isinstance(bindings, list)
        and [binding.get("path") for binding in bindings if isinstance(binding, Mapping)]
        == expected_bound_paths,
        "pre-finalization semantic binding identity or closure differs",
    )
    for binding, relative in zip(bindings, expected_bound_paths):
        payload = _read_regular(
            wrapper_root.joinpath(*PurePosixPath(relative).parts),
            f"semantic-bound file {relative}",
        )
        _require(
            isinstance(binding, Mapping)
            and set(binding) == {"path", "sha256", "size_bytes"}
            and binding.get("sha256") == _sha256(payload)
            and binding.get("size_bytes") == len(payload),
            f"semantic file binding differs for {relative}",
        )
    return document


def _owned_regular_identity(path: Path, label: str) -> tuple[int, int]:
    before = os.lstat(path)
    payload = _read_regular(path, label)
    after = os.lstat(path)
    _require(
        stat.S_ISREG(before.st_mode)
        and not stat.S_ISLNK(before.st_mode)
        and before.st_nlink == 1
        and before.st_size == len(payload)
        and (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        == (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ),
        f"{label} identity is not an owned single-link regular file",
    )
    return before.st_dev, before.st_ino


def _owned_directory_identity(path: Path, label: str) -> tuple[int, int]:
    before = os.lstat(path)
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after = os.lstat(path)
    _require(
        stat.S_ISDIR(before.st_mode)
        and not stat.S_ISLNK(before.st_mode)
        and stat.S_ISDIR(opened.st_mode)
        and (
            before.st_dev,
            before.st_ino,
            stat.S_IFMT(before.st_mode),
        )
        == (
            opened.st_dev,
            opened.st_ino,
            stat.S_IFMT(opened.st_mode),
        )
        == (
            after.st_dev,
            after.st_ino,
            stat.S_IFMT(after.st_mode),
        ),
        f"{label} identity is not an owned directory",
    )
    return before.st_dev, before.st_ino


def _cleanup_transient_provenance(
    path: Path,
    *,
    expected_identity: tuple[int, int],
    token: str,
    label: str,
) -> None:
    parent = _canonical_directory(path.parent, f"{label} parent")
    descriptor = os.open(
        parent,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        _remove_owned_record(
            descriptor,
            name=path.name,
            expected_identity=expected_identity,
            token=token,
        )
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _require(
        not os.path.lexists(path),
        f"{label} remains after ownership-safe cleanup",
    )


def _finalize_with_transient_provenance(
    *,
    partial_root: Path,
    final_root: Path,
    repository_root: Path,
    provenance_path: Path,
    label: str,
) -> Path:
    expected_identity = _owned_regular_identity(provenance_path, label)
    token = uuid.uuid4().hex
    published: Optional[Path] = None
    primary: Optional[BaseException] = None
    try:
        published = finalize_evidence_wrapper(
            partial=partial_root,
            final=final_root,
            gate_ids=("G05", "P05"),
            project_root=repository_root,
            provenance_map=provenance_path,
        )
    except BaseException as error:
        primary = error
    cleanup: Optional[BaseException] = None
    try:
        _cleanup_transient_provenance(
            provenance_path,
            expected_identity=expected_identity,
            token=token,
            label=label,
        )
    except BaseException as error:
        cleanup = error
    if primary is not None:
        if cleanup is not None:
            raise G05CurrentSourceError(
                f"{label} cleanup failed after finalizer failure: {cleanup}"
            ) from primary
        raise primary
    if cleanup is not None:
        raise cleanup
    assert published is not None
    return published


def _quarantine_published_wrapper(final_root: Path) -> Path:
    failure_root = final_root.with_name(final_root.name + ".failed")
    parent = _canonical_directory(final_root.parent, "published wrapper parent")
    _canonical_absent_leaf(failure_root, "post-final quarantine root")
    before = os.lstat(final_root)
    _require(
        stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode),
        "published success root is not an owned directory",
    )
    _require_frozen(final_root, "published success root before quarantine")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    parent_descriptor = os.open(parent, flags)
    root_descriptor = -1
    try:
        root_descriptor = os.open(
            final_root.name,
            flags,
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(root_descriptor)
        current = os.stat(
            final_root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        _require(
            (opened.st_dev, opened.st_ino)
            == (before.st_dev, before.st_ino)
            == (current.st_dev, current.st_ino),
            "published success root identity changed while pinning quarantine",
        )
        _quarantine_owned_root(
            parent_descriptor,
            source_name=final_root.name,
            final_name=final_root.name,
            failure_name=failure_root.name,
            root_descriptor=root_descriptor,
            expected_identity=opened,
            token=uuid.uuid4().hex,
        )
        os.fsync(parent_descriptor)
        after = os.stat(
            failure_root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        _require(
            (after.st_dev, after.st_ino) == (before.st_dev, before.st_ino)
            and not os.path.lexists(final_root),
            "post-final quarantine did not preserve the exact published identity",
        )
    finally:
        if root_descriptor >= 0:
            os.close(root_descriptor)
        os.close(parent_descriptor)
    _require_frozen(failure_root, "post-final quarantined wrapper")
    return failure_root


def _raise_quarantined_post_final_failure(
    final_root: Path,
    error: BaseException,
    *,
    context: str,
) -> None:
    try:
        failure_root = _quarantine_published_wrapper(final_root)
    except BaseException as quarantine_error:
        raise G05CurrentSourceError(
            f"{context} and published wrapper quarantine failed: "
            f"{quarantine_error}"
        ) from error
    raise G05PostFinalReopenError(
        f"{context}: {error}",
        failure_root,
    ) from error


def _collect_sealed_files(root: Path) -> tuple[str, ...]:
    _require_frozen(root, "sealed G05 wrapper root")
    result: list[str] = []
    for current_name, directories, files in os.walk(root, topdown=True, followlinks=False):
        current = Path(current_name)
        if root == Path("."):
            _require(
                not current.is_absolute()
                and all(part != ".." for part in current.parts),
                "sealed wrapper escaped its pinned directory",
            )
        else:
            _require(
                current.resolve(strict=True) == current,
                "sealed wrapper contains a linked directory",
            )
        directories.sort()
        files.sort()
        for directory in directories:
            child = current / directory
            metadata = os.lstat(child)
            _require(
                stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
                f"sealed wrapper entry is not a directory: {child}",
            )
            _require_frozen(child, f"sealed wrapper directory {child.relative_to(root)}")
        for filename in files:
            path = current / filename
            relative = path.relative_to(root).as_posix()
            _require_frozen(path, f"sealed wrapper file {relative}")
            _read_regular(path, f"sealed wrapper file {relative}")
            result.append(relative)
    return tuple(sorted(result))


def _validate_g05_finalized_manifest_and_transaction(
    *,
    root: Path,
    publication_name: str,
    source_commit: str,
    expected_pre_final: Sequence[str],
    expected_directories: Sequence[str],
    expected_root_identity: tuple[int, int],
    expected_command_plan: Optional[Mapping[str, Any]] = None,
    label: str,
) -> Mapping[str, Any]:
    normalized_pre_final = tuple(sorted(expected_pre_final))
    normalized_directories = tuple(sorted(expected_directories))
    _require(
        tuple(expected_pre_final) == normalized_pre_final
        and len(normalized_pre_final) == len(set(normalized_pre_final))
        and tuple(expected_directories) == normalized_directories
        and len(normalized_directories) == len(set(normalized_directories))
        and "inputs/g05-command-plan.json" in normalized_pre_final
        and "inputs/provenance-map.json" in normalized_pre_final,
        f"{label} pre-final closure is not exact and canonical",
    )
    manifest_payload = _read_regular(
        root / "artifact-manifest.json",
        f"{label} artifact manifest",
    )
    manifest = _json_object(manifest_payload, f"{label} artifact manifest")
    _validate_schema_document(
        manifest,
        EVIDENCE_WRAPPER_MANIFEST_SCHEMA,
        f"{label} artifact manifest",
    )
    _require(
        manifest_payload == document_bytes(manifest),
        f"{label} artifact manifest is not canonical JSON",
    )
    expected_manifest_paths = tuple(
        sorted((*normalized_pre_final, "publication-transaction.json"))
    )
    raw_rows = manifest.get("artifacts")
    _require(
        manifest.get("project_commit") == source_commit
        and manifest.get("working_tree_clean") is True
        and manifest.get("directories") == list(normalized_directories)
        and isinstance(raw_rows, list)
        and [
            row.get("path")
            for row in raw_rows
            if isinstance(row, Mapping)
        ]
        == list(expected_manifest_paths),
        f"{label} manifest identity, directory, or artifact closure differs",
    )
    rows = _manifest_rows(manifest, f"{label} artifact manifest")

    command_plan_payload = _read_regular(
        root / "inputs/g05-command-plan.json",
        f"{label} command plan",
    )
    command_plan = _json_object(command_plan_payload, f"{label} command plan")
    _validate_schema_document(
        command_plan,
        COMMAND_PLAN_SCHEMA,
        f"{label} command plan",
    )
    _require(
        command_plan_payload == document_bytes(command_plan)
        and command_plan.get("source_commit") == source_commit
        and (
            expected_command_plan is None
            or command_plan == expected_command_plan
        ),
        f"{label} command plan source commit, bytes, or fields differ",
    )

    provenance_payload = _read_regular(
        root / "inputs/provenance-map.json",
        f"{label} provenance map",
    )
    provenance = _json_object(provenance_payload, f"{label} provenance map")
    expected_provenance = _provenance_document(
        normalized_pre_final,
        command_plan,
    )
    _require(
        provenance_payload == document_bytes(provenance)
        and provenance == expected_provenance,
        f"{label} provenance map differs from exact path provenance",
    )
    provenance_by_path = {
        str(rule["exact_path"]): rule
        for rule in expected_provenance["rules"]
    }

    for relative in normalized_pre_final:
        payload = _read_regular(
            root.joinpath(*PurePosixPath(relative).parts),
            f"{label} manifest artifact {relative}",
        )
        row = rows.get(relative)
        rule = provenance_by_path.get(relative)
        _require(
            isinstance(row, Mapping)
            and isinstance(rule, Mapping)
            and row.get("sha256") == _sha256(payload)
            and row.get("size_bytes") == len(payload)
            and row.get("producer") == rule.get("producer")
            and row.get("command") == rule.get("command")
            and row.get("platform") == rule.get("platform")
            and row.get("machine") == rule.get("machine")
            and row.get("gate_ids") == rule.get("gate_ids"),
            f"{label} manifest binding or provenance differs for {relative}",
        )

    transaction_payload = _read_regular(
        root / "publication-transaction.json",
        f"{label} publication transaction",
    )
    transaction_row = rows.get("publication-transaction.json")
    transaction_provenance = {
        "producer": "Mirmir evidence-wrapper recovery",
        "command": "finalize_evidence_wrapper transaction recovery",
        "platform": platform.platform(),
        "machine": platform.node() or platform.machine() or "unknown-machine",
        "gate_ids": ["G05", "P05"],
    }
    _require(
        isinstance(transaction_row, Mapping)
        and transaction_row.get("sha256") == _sha256(transaction_payload)
        and transaction_row.get("size_bytes") == len(transaction_payload)
        and all(
            transaction_row.get(field) == value
            for field, value in transaction_provenance.items()
        ),
        f"{label} publication transaction manifest binding or provenance differs",
    )
    transaction = _json_object(
        transaction_payload,
        f"{label} publication transaction",
    )
    root_metadata = os.lstat(root)
    required_transaction_fields = {
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
        stat.S_ISDIR(root_metadata.st_mode)
        and not stat.S_ISLNK(root_metadata.st_mode)
        and (root_metadata.st_dev, root_metadata.st_ino)
        == expected_root_identity
        and set(transaction) == required_transaction_fields
        and transaction.get("schema_version") == "1.0.0"
        and transaction.get("artifact_kind")
        == "evidence_wrapper_publication_transaction"
        and isinstance(transaction.get("transaction_token"), str)
        and re.fullmatch(
            r"[0-9a-f]{32}",
            str(transaction["transaction_token"]),
        )
        is not None
        and isinstance(transaction.get("created_utc"), str)
        and UTC_PATTERN.fullmatch(str(transaction["created_utc"])) is not None
        and transaction.get("project_commit") == source_commit
        and transaction.get("partial_name") == f".{publication_name}.partial"
        and transaction.get("final_name") == publication_name
        and transaction.get("failure_name") == f"{publication_name}.failed"
        and transaction.get("gate_ids") == ["G05", "P05"]
        and type(transaction.get("root_device")) is int
        and type(transaction.get("root_inode")) is int
        and (
            transaction.get("root_device"),
            transaction.get("root_inode"),
        )
        == expected_root_identity
        and transaction_payload == document_bytes(transaction),
        f"{label} publication transaction identity, commit, gates, or root differs",
    )
    return command_plan


def _strict_reopen_final_wrapper_pinned(
    *,
    repository_root: Path,
    wrapper_root: Path,
    publication_name: str,
    instruction_package_root: Path,
    source_commit: str,
    baseline_commit: str,
    command_plan: Mapping[str, Any],
    expected_p05_closure: Mapping[str, Any],
    expected_root_identity: tuple[int, int],
) -> None:
    expected_pre_final = _success_wrapper_paths()
    expected_final = tuple(
        sorted((*expected_pre_final, "artifact-manifest.json", "publication-transaction.json"))
    )
    _require(
        _collect_sealed_files(wrapper_root) == expected_final,
        "sealed G05 wrapper file closure differs from the pre-final contract",
    )
    _require(
        _collect_directories(wrapper_root)
        == _ancestor_directories(expected_pre_final),
        "sealed G05 wrapper directory closure differs from the pre-final contract",
    )
    reopened_plan = _validate_g05_finalized_manifest_and_transaction(
        root=wrapper_root,
        publication_name=publication_name,
        source_commit=source_commit,
        expected_pre_final=expected_pre_final,
        expected_directories=_ancestor_directories(expected_pre_final),
        expected_root_identity=expected_root_identity,
        expected_command_plan=command_plan,
        label="sealed G05 wrapper",
    )
    _validate_semantic_bindings_snapshot(
        wrapper_root=wrapper_root,
        source_commit=source_commit,
        expected_paths=expected_pre_final,
    )
    identity = _json_object(
        _read_regular(wrapper_root / "run-identity.json", "sealed run identity"),
        "sealed run identity",
    )
    identity_unhashed = dict(identity)
    identity_claimed = identity_unhashed.pop("identity_sha256", None)
    _validate_schema_document(identity, RUN_IDENTITY_SCHEMA, "sealed run identity")
    _require(
        identity_claimed == canonical_sha256(identity_unhashed)
        and identity.get("source_commit") == source_commit
        and identity.get("p00_baseline", {}).get("baseline_commit") == baseline_commit,
        "sealed run identity self-binding differs",
    )
    _validate_command_execution_aggregate(
        wrapper_root=wrapper_root,
        command_plan=reopened_plan,
        source_commit=source_commit,
    )
    receipt = _json_object(
        _read_regular(wrapper_root / "receipt.json", "sealed G05 receipt"),
        "sealed G05 receipt",
    )
    validate_g05_receipt(
        repository_root=repository_root,
        wrapper_root=wrapper_root,
        receipt=receipt,
    )
    upstream = _json_object(
        _read_regular(
            wrapper_root / "inputs/upstream-bindings.json",
            "sealed upstream bindings",
        ),
        "sealed upstream bindings",
    )
    validate_g05_upstream_bindings(
        repository_root=repository_root,
        wrapper_root=wrapper_root,
        document=upstream,
        source_commit=source_commit,
    )
    _validate_live_metadata_closure(upstream["live_preopen_metadata"], wrapper_root)
    reopened_p05 = validate_g05_evidence(
        repository_root,
        tuple(wrapper_root / "evidence" / name for name in RUN_NAMES),
    )
    _require(reopened_p05 == expected_p05_closure, "sealed P05 closure differs")
    _require(
        _validate_quality_locks(repository_root, wrapper_root).get("status") == "pass",
        "sealed quality-lock closure differs",
    )
    supplemental = _json_object(
        _read_regular(
            wrapper_root / SUPPLEMENTAL_SCAN_RELATIVE,
            "sealed supplemental scan evidence",
        ),
        "sealed supplemental scan evidence",
    )
    rebuilt_supplemental, patterns = _build_supplemental_scan_evidence(
        repository_root=repository_root,
        partial_root=wrapper_root,
        instruction_package_root=instruction_package_root,
        baseline_commit=baseline_commit,
        source_commit=source_commit,
        wrapper_paths=expected_pre_final,
    )
    _require(
        supplemental == rebuilt_supplemental,
        "sealed supplemental scan evidence differs from current-source reopening",
    )
    for relative in expected_pre_final:
        _supplemental_match(
            logical_path=relative,
            payload=_read_regular(
                wrapper_root.joinpath(*PurePosixPath(relative).parts),
                f"sealed supplemental file {relative}",
            ),
            patterns=patterns,
        )


def _strict_reopen_failure_wrapper_pinned(
    *,
    repository_root: Path,
    wrapper_root: Path,
    publication_name: str,
    instruction_package_root: Path,
    source_commit: str,
    baseline_commit: str,
    expected_pre_final: Sequence[str],
    expected_directories: Sequence[str],
    command_plan: Mapping[str, Any],
    expected_root_identity: tuple[int, int],
) -> None:
    normalized_pre_final = tuple(sorted(expected_pre_final))
    normalized_directories = tuple(sorted(expected_directories))
    _require(
        tuple(expected_pre_final) == normalized_pre_final
        and len(normalized_pre_final) == len(set(normalized_pre_final))
        and tuple(expected_directories) == normalized_directories
        and len(normalized_directories) == len(set(normalized_directories)),
        "failure sealed-reopen closure is not exact and canonical",
    )
    expected_final = tuple(
        sorted(
            (
                *normalized_pre_final,
                "artifact-manifest.json",
                "publication-transaction.json",
            )
        )
    )
    _require(
        _collect_sealed_files(wrapper_root) == expected_final,
        "sealed G05 failure file closure differs from the pre-final contract",
    )
    _require(
        _collect_directories(wrapper_root) == normalized_directories,
        "sealed G05 failure directory closure differs from the pre-final contract",
    )
    _validate_g05_finalized_manifest_and_transaction(
        root=wrapper_root,
        publication_name=publication_name,
        source_commit=source_commit,
        expected_pre_final=normalized_pre_final,
        expected_directories=normalized_directories,
        expected_root_identity=expected_root_identity,
        expected_command_plan=command_plan,
        label="sealed G05 failure wrapper",
    )
    _validate_semantic_bindings_snapshot(
        wrapper_root=wrapper_root,
        source_commit=source_commit,
        expected_paths=normalized_pre_final,
    )
    classification = _json_object(
        _read_regular(
            wrapper_root / "g05-failure-classification.json",
            "sealed G05 failure classification",
        ),
        "sealed G05 failure classification",
    )
    holdout_status = classification.get("holdout_access_status")
    holdout_proven = holdout_status == "proven_unopened"
    _require(
        classification.get("status") == "fail"
        and holdout_status
        in {"proven_unopened", "unknown_not_proven_unopened"}
        and classification.get("holdout_accessed")
        is (False if holdout_proven else None)
        and classification.get("holdout_verification")
        == (
            "analysis/live-holdout-preopen-verification.json"
            if holdout_proven
            else None
        )
        and classification.get("assessor_pixel_accessed") is False,
        "sealed G05 failure classification has invalid holdout semantics",
    )
    identity = _json_object(
        _read_regular(
            wrapper_root / "run-identity.json",
            "sealed G05 failure run identity",
        ),
        "sealed G05 failure run identity",
    )
    identity_unhashed = dict(identity)
    identity_claimed = identity_unhashed.pop("identity_sha256", None)
    _validate_schema_document(identity, RUN_IDENTITY_SCHEMA, "sealed failure run identity")
    _require(
        identity_claimed == canonical_sha256(identity_unhashed)
        and identity.get("source_commit") == source_commit
        and identity.get("outcome") == "fail"
        and identity.get("holdout_access_status") == holdout_status
        and identity.get("holdout_accessed")
        is (False if holdout_proven else None),
        "sealed G05 failure run identity differs from its classification",
    )
    supplemental = _json_object(
        _read_regular(
            wrapper_root / SUPPLEMENTAL_SCAN_RELATIVE,
            "sealed failure supplemental scan evidence",
        ),
        "sealed failure supplemental scan evidence",
    )
    rebuilt_supplemental, patterns = _build_supplemental_scan_evidence(
        repository_root=repository_root,
        partial_root=wrapper_root,
        instruction_package_root=instruction_package_root,
        baseline_commit=baseline_commit,
        source_commit=source_commit,
        wrapper_paths=normalized_pre_final,
        wrapper_directories=normalized_directories,
    )
    _require(
        supplemental == rebuilt_supplemental,
        "sealed failure supplemental scan evidence differs from current-source reopening",
    )
    for relative in normalized_pre_final:
        _supplemental_match(
            logical_path=relative,
            payload=_read_regular(
                wrapper_root.joinpath(*PurePosixPath(relative).parts),
                f"sealed failure supplemental file {relative}",
            ),
            patterns=patterns,
        )


def _require_published_namespace_identity(
    root: Path,
    expected_identity: tuple[int, int],
    label: str,
) -> None:
    try:
        observed = _owned_directory_identity(root, label)
    except (G05CurrentSourceError, OSError) as error:
        raise G05CurrentSourceError(
            f"{label} is absent or changed after pinned reopen"
        ) from error
    _require(
        observed == expected_identity,
        f"{label} namespace identity changed after pinned reopen",
    )


def _strict_reopen_final_wrapper(
    *,
    repository_root: Path,
    final_root: Path,
    instruction_package_root: Path,
    source_commit: str,
    baseline_commit: str,
    command_plan: Mapping[str, Any],
    expected_p05_closure: Mapping[str, Any],
    expected_root_identity: tuple[int, int],
) -> None:
    with pinned_wrapper_root(final_root, expected_root_identity) as wrapper_root:
        _strict_reopen_final_wrapper_pinned(
            repository_root=repository_root,
            wrapper_root=wrapper_root,
            publication_name=final_root.name,
            instruction_package_root=instruction_package_root,
            source_commit=source_commit,
            baseline_commit=baseline_commit,
            command_plan=command_plan,
            expected_p05_closure=expected_p05_closure,
            expected_root_identity=expected_root_identity,
        )
    _require_published_namespace_identity(
        final_root,
        expected_root_identity,
        "published G05 success wrapper",
    )


def reopen_finalized_g04_current_source(
    *,
    root: Path,
    source_commit: str,
) -> Mapping[str, Any]:
    """Public semantic reopener for one already-finalized current-source G04."""

    expected_commit = _require_commit(source_commit)
    final_root = _canonical_directory(root, "published G04 success wrapper")
    manifest_payload = _read_regular(
        final_root / "artifact-manifest.json",
        "G04 finalized artifact manifest",
    )
    manifest = _json_object(
        manifest_payload,
        "G04 finalized artifact manifest",
    )
    _require(
        manifest.get("project_commit") == expected_commit
        and manifest.get("working_tree_clean") is True,
        "G04 finalized manifest is not the exact clean current source",
    )
    attestation = _validate_finalized_g04_closure(
        root=final_root,
        manifest=manifest,
        manifest_payload=manifest_payload,
        source_commit=expected_commit,
    )
    return {
        "gate_id": "G04",
        "source_commit": expected_commit,
        "working_tree_clean": True,
        "holdout_accessed": False,
        "manifest_sha256": _sha256(manifest_payload),
        "closure_attestation": attestation,
    }


def reopen_finalized_g05_current_source(
    *,
    repository_root: Path,
    final_root: Path,
    instruction_package_root: Path,
    source_commit: str,
    baseline_commit: str,
) -> Mapping[str, Any]:
    """Public strict reopener for a published current-source G05 closure."""

    repository = _canonical_directory(
        repository_root,
        "G05 repository root",
    )
    wrapper = _canonical_directory(
        final_root,
        "published G05 success wrapper",
    )
    instructions = _canonical_directory(
        instruction_package_root,
        "G05 instruction package root",
    )
    expected_commit = _require_commit(source_commit)
    expected_baseline = _require_commit(baseline_commit)
    command_plan_payload = _read_regular(
        wrapper / "inputs/g05-command-plan.json",
        "published G05 command plan",
    )
    command_plan = _json_object(
        command_plan_payload,
        "published G05 command plan",
    )
    closure = validate_g05_evidence(
        repository,
        tuple(wrapper / "evidence" / name for name in RUN_NAMES),
    )
    root_identity = _owned_directory_identity(
        wrapper,
        "published G05 success wrapper",
    )
    _strict_reopen_final_wrapper(
        repository_root=repository,
        final_root=wrapper,
        instruction_package_root=instructions,
        source_commit=expected_commit,
        baseline_commit=expected_baseline,
        command_plan=command_plan,
        expected_p05_closure=closure,
        expected_root_identity=root_identity,
    )
    manifest_payload = _read_regular(
        wrapper / "artifact-manifest.json",
        "published G05 artifact manifest",
    )
    manifest = _json_object(
        manifest_payload,
        "published G05 artifact manifest",
    )
    _require(
        manifest.get("project_commit") == expected_commit
        and manifest.get("working_tree_clean") is True,
        "G05 finalized manifest is not the exact clean current source",
    )
    return {
        "gate_id": "G05",
        "source_commit": expected_commit,
        "working_tree_clean": True,
        "holdout_accessed": False,
        "manifest_sha256": _sha256(manifest_payload),
        "command_plan_sha256": _sha256(command_plan_payload),
        "p05_closure_sha256": canonical_sha256(closure),
    }


def _strict_reopen_failure_wrapper(
    *,
    repository_root: Path,
    failure_root: Path,
    instruction_package_root: Path,
    source_commit: str,
    baseline_commit: str,
    expected_pre_final: Sequence[str],
    expected_directories: Sequence[str],
    command_plan: Mapping[str, Any],
    expected_root_identity: tuple[int, int],
) -> None:
    with pinned_wrapper_root(failure_root, expected_root_identity) as wrapper_root:
        _strict_reopen_failure_wrapper_pinned(
            repository_root=repository_root,
            wrapper_root=wrapper_root,
            publication_name=failure_root.name,
            instruction_package_root=instruction_package_root,
            source_commit=source_commit,
            baseline_commit=baseline_commit,
            expected_pre_final=expected_pre_final,
            expected_directories=expected_directories,
            command_plan=command_plan,
            expected_root_identity=expected_root_identity,
        )
    _require_published_namespace_identity(
        failure_root,
        expected_root_identity,
        "published G05 failure wrapper",
    )


def _command_provenance(row: Mapping[str, Any]) -> tuple[str, str]:
    identifier = str(row["id"])
    command = json.dumps(
        {
            "argv": row["argv"],
            "cwd": row["cwd"],
            "environment": row["environment"],
        },
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return f"G05 bound command class {identifier}", command


def _path_provenance(
    path: str,
    command_rows: Mapping[str, Mapping[str, Any]],
) -> tuple[str, str, list[str]]:
    for identifier in RUN_NAMES:
        if path.startswith(f"evidence/{identifier}/"):
            producer, command = _command_provenance(command_rows[identifier])
            return producer, command, ["G05", "P05"]
        if path in {
            f"outputs/{identifier}.log",
            f"outputs/{identifier}.stderr.log",
            f"outputs/{identifier}.result.json",
        }:
            producer, command = _command_provenance(command_rows[identifier])
            return producer, command, ["G05", "P05"]
    for identifier, relative in (
        ("quality-lock-a", "inputs/quality-harness-lock-a.json"),
        ("quality-lock-b", "inputs/quality-harness-lock-b.json"),
    ):
        if path in {
            relative,
            f"outputs/{identifier}.log",
            f"outputs/{identifier}.stderr.log",
        }:
            producer, command = _command_provenance(command_rows[identifier])
            return producer, command, ["G05", "P05"]
    for identifier, row in command_rows.items():
        if path in {
            row.get("output_path"),
            f"outputs/{identifier}.stderr.log",
            f"outputs/{identifier}.result.json",
        }:
            producer, command = _command_provenance(row)
            return producer, command, ["G05", "P05"]
    if path in {
        "outputs/attribution.pre-failure.log",
        "outputs/attribution.pre-failure.stderr.log",
        "outputs/attribution.pre-failure.result.json",
    }:
        producer, command = _command_provenance(command_rows["attribution"])
        return producer, command, ["G05", "P05"]
    if path in {
        relative for _, relative in INSTRUCTION_PACKAGE_PRODUCTS
    }:
        producer, command = _command_provenance(
            command_rows["instruction-package"]
        )
        return producer, command, ["G05", "P05"]
    if path.startswith("inputs/g03/"):
        return (
            "G03 finalized evidence binder",
            "run_g05_current_source.py copy verified manifest-bound G03 artifact",
            ["G03", "G05", "P05"],
        )
    if path.startswith("inputs/g04/"):
        return (
            "G04 finalized evidence binder",
            "run_g05_current_source.py copy verified same-source G04 artifact",
            ["G04", "G05", "P05"],
        )
    if path.startswith("inputs/live-preopen/"):
        return (
            "P06 live-preopen metadata binder",
            "run_g05_current_source.py copy verified metadata-only unopened proof",
            ["G05", "P05", "P06"],
        )
    if path in {
        "inputs/spatial-semantics-preregistration-v2.json",
        "inputs/spatial-policy-admissibility-manifest.json",
    }:
        return (
            "G05 spatial-policy source binder",
            "run_g05_current_source.py verify, regenerate, and copy spatial-policy lock",
            ["G05", "P05"],
        )
    if path == "inputs/g05-command-plan.json":
        return (
            "G05 structured command recorder",
            "run_g05_current_source.py schema and command-contract validation",
            ["G05", "P05"],
        )
    if path == "run-identity.json":
        return (
            "G05 run-identity recorder",
            "run_g05_current_source.py schema-bound run identity",
            ["G05", "P05"],
        )
    if path == "g05-failure-classification.json":
        return (
            "G05 failure classifier",
            "run_g05_current_source.py classify and preserve failed transaction",
            ["G05", "P05"],
        )
    if path in set(_failure_wrapper_allowed_paths()):
        return (
            "Mirmir G05 current-source assessor and evidence binder",
            "run_g05_current_source.py deterministic assessment artifact",
            ["G05", "P05"],
        )
    raise G05CurrentSourceError(
        f"no exact producer provenance exists for wrapper path: {path}"
    )


def _provenance_document(
    paths: Sequence[str],
    command_plan: Optional[Mapping[str, Any]] = None,
) -> Mapping[str, Any]:
    system = platform.system() or "unknown"
    release = platform.release() or "unknown"
    machine = platform.machine() or "unknown"
    node = platform.node() or "unknown"
    command_rows = {
        str(row["id"]): row
        for row in (command_plan or {}).get("commands", [])
        if isinstance(row, Mapping) and isinstance(row.get("id"), str)
    }
    if command_plan is not None:
        _require(
            tuple(command_rows) == COMMAND_IDS,
            "provenance command rows differ from the validated command plan",
        )
    rules = []
    _require(command_plan is not None, "provenance requires a validated command plan")
    for path in paths:
        producer, command, gate_ids = _path_provenance(path, command_rows)
        rules.append(
            {
                "exact_path": path,
                "producer": producer,
                "command": command,
                "platform": f"{system} {release}",
                "machine": f"{node}; {machine}",
                "gate_ids": gate_ids,
            }
        )
    return {"schema_version": "1.0.0", "rules": rules}


def _report_text() -> bytes:
    return (
        "# G05 current-source gate report\n\n"
        "## Result: pass\n\n"
        "All G05 criteria pass.\n\n"
        "The wrapper binds three byte-identical synthetic P05 runs, current-source "
        "quality and spatial-policy locks, same-source passing G04 evidence, preserved "
        "canonical G03 evidence, structured successful commands, and metadata-only "
        "p06-spatial-v2 unopened verification. No holdout pixels were accessed.\n"
    ).encode("utf-8")


def _assemble_documents(
    *,
    repository_root: Path,
    partial_root: Path,
    source_commit: str,
    run_roots: Sequence[Path],
    closure: Mapping[str, Any],
    quality: Mapping[str, Any],
    spatial: Mapping[str, Any],
    upstream: Mapping[str, Any],
    live: Mapping[str, Any],
    command_plan: Mapping[str, Any],
) -> None:
    upstream_path = partial_root / "inputs/upstream-bindings.json"
    _write_json_new(
        upstream_path,
        upstream,
        "G05 upstream bindings",
    )
    assessment, finding_register = build_g05_documents(
        repository_root=repository_root,
        run_roots=run_roots,
        source_commit=source_commit,
    )
    assessment_path = partial_root / "analysis/g05-gate-assessment.json"
    finding_path = partial_root / "analysis/g05-scoped-finding-register.json"
    _write_json_new(assessment_path, assessment, "G05 assessment")
    _write_json_new(finding_path, finding_register, "G05 finding register")
    independent = {
        "schema_version": "1.0.0",
        "status": "pass",
        "phase": "P05",
        "gate": "G05",
        "source_commit": source_commit,
        "run_count": 3,
        "run_sha256": closure.get("run_sha256"),
        "criterion_counts": closure.get("criterion_counts"),
        "quality_lock": quality,
        "spatial_policy": spatial,
        "upstream": upstream,
        "live_preopen_verification": live,
        "holdout_accessed": False,
    }
    _write_json_new(
        partial_root / "analysis/independent-audit.json",
        independent,
        "G05 independent audit",
    )
    _write_json_new(
        partial_root / "analysis/quality-lock-audit.json",
        quality,
        "G05 quality-lock audit",
    )
    _write_json_new(
        partial_root / "analysis/live-holdout-preopen-verification.json",
        live,
        "G05 live preopen verification",
    )
    test_results = {
        "schema_version": "1.0.0",
        "phase": "P05",
        "gate": "G05",
        "status": "pass",
        "source_commit": source_commit,
        "spatial_evidence": {"status": "pass", "run_count": 3},
        "quality_lock": {"status": "pass"},
        "spatial_policy": {"status": "pass"},
        "upstream_gates": {"status": "pass", "G03": "pass", "G04": "pass"},
        "command_evidence": {"status": "pass", "count": len(command_plan["commands"])},
        "live_preopen": {"status": "pass", "pixel_content_included": False},
        "holdout_accessed": False,
    }
    _write_json_new(partial_root / "test-results.json", test_results, "G05 test results")
    git_state = (
        f"commit={source_commit}\n"
        "status=clean\n"
        "remote_boundary=local-only; no remote operation\n"
    ).encode("utf-8")
    _write_new(partial_root / "git-state.txt", git_state, "G05 Git state")
    environment = {
        "schema_version": "1.0.0",
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
    }
    _write_json_new(partial_root / "environment.json", environment, "G05 environment")
    _write_new(
        partial_root / "commands.log",
        (
            "G05 structured command evidence: inputs/g05-command-plan.json\n"
            f"command_count={len(command_plan['commands'])}\n"
            "all_exit_statuses=0\n"
            "holdout_pixels_accessed=false\n"
        ).encode("utf-8"),
        "G05 command log",
    )
    _write_new(
        partial_root / "README.md",
        (
            "# G05 current-source evidence\n\n"
            "This wrapper contains deterministic synthetic P05 evidence and its "
            "current-source assessment. The holdout proof is metadata-only and "
            "contains no pixel content.\n"
        ).encode("utf-8"),
        "G05 wrapper README",
    )
    report = _report_text()
    _require(
        b"# G05 " in report
        and b"## Result: pass" in report
        and b"All G05 criteria pass." in report,
        "G05 report markers differ from the P06 consumer contract",
    )
    _write_new(partial_root / "GATE_REPORT.md", report, "G05 gate report")


def _assemble_receipt(
    *,
    repository_root: Path,
    partial_root: Path,
    source_commit: str,
    run_roots: Sequence[Path],
) -> Mapping[str, Any]:
    receipt = build_g05_receipt(
        repository_root=repository_root,
        wrapper_root=partial_root,
        source_commit=source_commit,
        run_roots=run_roots,
        assessment_path=partial_root / "analysis/g05-gate-assessment.json",
        finding_register_path=partial_root / "analysis/g05-scoped-finding-register.json",
        upstream_bindings_path=partial_root / "inputs/upstream-bindings.json",
        command_execution_path=partial_root / COMMAND_AGGREGATE_RELATIVE,
    )
    _require(
        receipt.get("holdout_accessed") is False
        and _status_values(receipt)
        and all(value == "pass" for value in _status_values(receipt)),
        "G05 receipt does not contain the exact all-pass no-holdout semantics",
    )
    validate_g05_receipt(
        repository_root=repository_root,
        wrapper_root=partial_root,
        receipt=receipt,
    )
    _write_json_new(partial_root / "receipt.json", receipt, "G05 receipt")
    return receipt


def _failure_classification(
    *,
    arguments: argparse.Namespace,
    partial_root: Path,
    final_root: Path,
    instruction_package_root: Path,
    error: BaseException,
    ended_utc: str,
    holdout_access_status: str = "unknown_not_proven_unopened",
) -> Mapping[str, Any]:
    severity = "S1" if isinstance(error, LiveHoldoutPreopenError) else "S2"
    classification = (
        "holdout_boundary_verification_failure"
        if severity == "S1"
        else "mandatory_g05_gate_failure"
    )
    message = _sanitize_caller_paths(str(error), arguments)
    formatted_traceback = _sanitize_caller_paths("".join(
        traceback.format_exception(
            type(error),
            error,
            error.__traceback__,
        )
    ), arguments)
    _require(
        holdout_access_status
        in {"proven_unopened", "unknown_not_proven_unopened"},
        "failure holdout-access status is invalid",
    )
    holdout_unknown = holdout_access_status != "proven_unopened"
    return {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_failure_classification",
        "gate": "G05",
        "phase": "P05",
        "run_id": _require_uuid(arguments.run_id),
        "ended_utc": ended_utc,
        "status": "fail",
        "severity": severity,
        "classification": classification,
        "holdout_accessed": None if holdout_unknown else False,
        "holdout_access_status": holdout_access_status,
        "holdout_verification": (
            None
            if holdout_unknown
            else "analysis/live-holdout-preopen-verification.json"
        ),
        "assessor_pixel_accessed": False,
        "error": {
            "type": f"{type(error).__module__}.{type(error).__qualname__}",
            "message": message,
            "traceback": formatted_traceback,
        },
        "runtime_context": {
            "command_buffer_error": None,
            "frame_index": None,
            "pts": None,
            "not_applicable_reason": "g05_synthetic_evidence_assessment",
        },
        "transaction": {
            "state": "gate_rejected_before_success_publication",
            "temporary_namespace": partial_root.name,
            "intended_success_namespace": final_root.name,
            "failure_namespace": f"{final_root.name}.failed",
            "cleanup_result": "owned_partial_preserved_as_immutable_failure_evidence",
        },
    }


def _failure_holdout_verification(
    arguments: argparse.Namespace,
    partial_root: Path,
) -> tuple[str, Optional[Mapping[str, Any]]]:
    path = partial_root / "analysis/live-holdout-preopen-verification.json"
    preserved = partial_root / (
        "analysis/live-holdout-preopen-verification.pre-failure.json"
    )

    def preserve_prior_record() -> None:
        if not os.path.lexists(path):
            return
        if not os.path.lexists(preserved):
            _rename_owned_entry(path, preserved, require_directory=False)
            return
        _require(
            _read_regular(path, "prior live preopen verification")
            == _read_regular(
                preserved,
                "preserved prior live preopen verification",
            ),
            "distinct prior live preopen verification records cannot be preserved",
        )
        _cleanup_transient_provenance(
            path,
            expected_identity=_owned_regular_identity(
                path,
                "duplicate prior live preopen verification",
            ),
            token=uuid.uuid4().hex,
            label="duplicate prior live preopen verification",
        )

    try:
        verification = _verify_live_metadata(arguments)
        payload = document_bytes(verification)
        if os.path.lexists(path):
            if _read_regular(path, "prior live preopen verification") != payload:
                _rename_owned_entry(path, preserved, require_directory=False)
                _write_new(path, payload, "failure-time live preopen verification")
        else:
            _write_new(path, payload, "failure-time live preopen verification")
        _require(
            _read_regular(path, "failure-time live preopen verification")
            == payload,
            "failure-time live preopen verification bytes differ",
        )
    except Exception:
        preserve_prior_record()
        return "unknown_not_proven_unopened", None
    return "proven_unopened", verification


def _sanitize_caller_paths(text: str, arguments: argparse.Namespace) -> str:
    fields = (
        ("instruction_package_root", INSTRUCTION_PACKAGE_ROOT_TOKEN),
        ("repository_root", "{repository-root}"),
        ("partial_root", "{partial-root}"),
        ("final_root", "{final-root}"),
        ("g03_root", "{g03-root}"),
        ("g04_root", "{g04-root}"),
        ("live_ledger_path", "{live-ledger-path}"),
        ("live_anchor_path", "{live-anchor-path}"),
        ("live_preopen_receipt_path", "{live-preopen-receipt-path}"),
        ("repository_sealed_copy_path", "{repository-sealed-copy-path}"),
        ("repository_attestation_path", "{repository-attestation-path}"),
    )
    replacements: list[tuple[str, str]] = []
    for field, token in fields:
        value = getattr(arguments, field, None)
        if isinstance(value, (str, os.PathLike)):
            raw = os.fspath(value)
            if raw:
                replacements.append((raw, token))
    sanitized = text
    for raw, token in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
        sanitized = sanitized.replace(raw, token)
    return sanitized


def _rename_owned_entry(
    source: Path,
    destination: Path,
    *,
    require_directory: bool,
) -> None:
    _require(
        source.parent == destination.parent,
        "failure staging rename crosses an artifact parent",
    )
    _canonical_absent_leaf(destination, "exclusive rename destination")
    before = os.lstat(source)
    if require_directory:
        _require(
            stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode),
            "exclusive rename source is not an owned directory",
        )
    else:
        _require(
            stat.S_ISREG(before.st_mode)
            and not stat.S_ISLNK(before.st_mode)
            and before.st_nlink == 1,
            "exclusive rename source is not an owned single-link regular file",
        )
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(source.parent, flags)
    try:
        _rename_exclusive_at(descriptor, source.name, destination.name)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    after = os.lstat(destination)
    _require(
        (after.st_dev, after.st_ino) == (before.st_dev, before.st_ino)
        and not os.path.lexists(source),
        "failure staging rename changed the owned directory identity",
    )


def _publish_gate_failure(
    arguments: argparse.Namespace,
    error: BaseException,
) -> Path:
    source_commit = _require_commit(arguments.expected_source_commit)
    (
        repository_root,
        partial_root,
        final_root,
        _,
        _,
        instruction_package_root,
    ) = _preflight(arguments)
    dirty_state_sha256 = _validate_repository_state(
        repository_root,
        source_commit,
    )
    success_provenance = final_root.with_name(
        f".{final_root.name}.provenance-map.partial"
    )
    if os.path.lexists(success_provenance):
        _cleanup_transient_provenance(
            success_provenance,
            expected_identity=_owned_regular_identity(
                success_provenance,
                "abandoned transient success provenance map",
            ),
            token=uuid.uuid4().hex,
            label="abandoned transient success provenance map",
        )
    p00_baseline_binding = _validate_baseline_commit(
        repository_root,
        _require_commit(arguments.p00_baseline_commit),
        source_commit,
    )
    ended_utc = _utc_now()
    holdout_access_status, _ = _failure_holdout_verification(
        arguments,
        partial_root,
    )
    for source, destination in (
        (
            partial_root / "run-identity.json",
            partial_root / "run-identity.pre-failure.json",
        ),
        (
            partial_root / "inputs/provenance-map.json",
            partial_root / "inputs/provenance-map.pre-failure.json",
        ),
        (
            partial_root / SEMANTIC_BINDINGS_RELATIVE,
            partial_root
            / "inputs/pre-finalization-semantic-bindings.pre-failure.json",
        ),
        (
            partial_root / "outputs/attribution.log",
            partial_root / "outputs/attribution.pre-failure.log",
        ),
        (
            partial_root / "outputs/attribution.stderr.log",
            partial_root / "outputs/attribution.pre-failure.stderr.log",
        ),
        (
            partial_root / "outputs/attribution.result.json",
            partial_root / "outputs/attribution.pre-failure.result.json",
        ),
        (
            partial_root / SUPPLEMENTAL_SCAN_RELATIVE,
            partial_root / "outputs/supplemental-content-scan.pre-failure.json",
        ),
    ):
        if os.path.lexists(source):
            _rename_owned_entry(
                source,
                destination,
                require_directory=False,
            )
    run_identity = _build_run_identity(
        arguments=arguments,
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        source_commit=source_commit,
        dirty_state_sha256=dirty_state_sha256,
        toolchain=_toolchain_identity(),
        p00_baseline_binding=p00_baseline_binding,
        ended_utc=ended_utc,
        outcome="fail",
        closure=None,
        holdout_access_status=holdout_access_status,
    )
    _write_json_new(
        partial_root / "run-identity.json",
        run_identity,
        "failed G05 run identity",
    )
    _write_json_new(
        partial_root / "g05-failure-classification.json",
        _failure_classification(
            arguments=arguments,
            partial_root=partial_root,
            final_root=final_root,
            instruction_package_root=instruction_package_root,
            error=error,
            ended_utc=ended_utc,
            holdout_access_status=holdout_access_status,
        ),
        "G05 failure classification",
    )
    _require_file_closure(
        partial_root,
        _failure_wrapper_allowed_paths(),
        "failed G05 staged closure",
        exact=False,
    )
    try:
        command_plan = _validate_command_plan(
            repository_root=repository_root,
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
            source_commit=source_commit,
            p00_baseline_commit=_require_commit(arguments.p00_baseline_commit),
            attribution_output_required=False,
            p05_output_required=False,
            p05_partial_failure_allowed=True,
            quality_output_required=False,
            quality_partial_failure_allowed=True,
        )
    except (G05CurrentSourceError, OSError, ValueError) as validation_error:
        raise G05SetupError(
            "untrusted staged command evidence cannot be failure-published"
        ) from validation_error
    attribution_payload = _execute_captured_replay(
        command_plan=command_plan,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=_require_commit(
            arguments.p00_baseline_commit
        ),
        identifier="attribution",
        stdout_must_exist=False,
    )
    provenance_relative = "inputs/provenance-map.json"
    paths_before = _collect_files(partial_root)
    expected_paths = tuple(
        sorted(
            (
                *paths_before,
                provenance_relative,
                SUPPLEMENTAL_SCAN_RELATIVE,
                SEMANTIC_BINDINGS_RELATIVE,
            )
        )
    )
    expected_directories = _collect_directories(partial_root)
    provenance = _provenance_document(expected_paths, command_plan)
    provenance_payload = canonical_json_bytes(provenance) + b"\n"
    _write_new(
        partial_root / provenance_relative,
        provenance_payload,
        "failed in-wrapper exact provenance map",
    )
    supplemental, supplemental_patterns = _build_supplemental_scan_evidence(
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        baseline_commit=_require_commit(arguments.p00_baseline_commit),
        source_commit=source_commit,
        wrapper_paths=expected_paths,
        wrapper_directories=expected_directories,
    )
    supplemental_payload = document_bytes(supplemental)
    snapshot = _build_semantic_bindings_snapshot(
        partial_root=partial_root,
        source_commit=source_commit,
        expected_paths=expected_paths,
        candidate_files={SUPPLEMENTAL_SCAN_RELATIVE: supplemental_payload},
    )
    snapshot_payload = document_bytes(snapshot)
    _validate_supplemental_wrapper_scan(
        partial_root=partial_root,
        document=supplemental,
        patterns=supplemental_patterns,
        candidate_files={
            SUPPLEMENTAL_SCAN_RELATIVE: supplemental_payload,
            SEMANTIC_BINDINGS_RELATIVE: snapshot_payload,
        },
    )
    _write_new(
        partial_root / SUPPLEMENTAL_SCAN_RELATIVE,
        supplemental_payload,
        "failed-wrapper supplemental scan evidence",
    )
    _write_new(
        partial_root / SEMANTIC_BINDINGS_RELATIVE,
        snapshot_payload,
        "failed-wrapper pre-finalization semantic bindings",
    )
    _require_file_closure(
        partial_root,
        expected_paths,
        "complete G05 failure closure",
        exact=True,
        expected_directories=expected_directories,
    )
    _validate_semantic_bindings_snapshot(
        wrapper_root=partial_root,
        source_commit=source_commit,
        expected_paths=expected_paths,
    )
    _require(
        _execute_bound_attribution(
            command_plan=command_plan,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=_require_commit(
                arguments.p00_baseline_commit
            ),
        )
        == attribution_payload,
        "immediate pre-finalization failed-wrapper scan differs",
    )
    failure_root = final_root.with_name(final_root.name + ".failed")
    failure_partial = failure_root.parent / f".{failure_root.name}.partial"
    failure_provenance = final_root.with_name(
        f".{failure_root.name}.provenance-map.partial"
    )
    _canonical_absent_leaf(failure_root, "failure final root")
    _canonical_absent_leaf(failure_provenance, "failure provenance map")
    _write_new(
        failure_provenance,
        provenance_payload,
        "external failure provenance map",
    )
    publication_root_identity = _owned_directory_identity(
        partial_root,
        "G05 failure staged root",
    )
    _rename_owned_entry(
        partial_root,
        failure_partial,
        require_directory=True,
    )
    published = _finalize_with_transient_provenance(
        partial_root=failure_partial,
        final_root=failure_root,
        repository_root=repository_root,
        provenance_path=failure_provenance,
        label="transient failure provenance map",
    )
    _require(
        published == failure_root,
        "failure finalizer returned an unexpected publication path",
    )
    _strict_reopen_failure_wrapper(
        repository_root=repository_root,
        failure_root=failure_root,
        instruction_package_root=instruction_package_root,
        source_commit=source_commit,
        baseline_commit=_require_commit(arguments.p00_baseline_commit),
        expected_pre_final=expected_paths,
        expected_directories=expected_directories,
        command_plan=command_plan,
        expected_root_identity=publication_root_identity,
    )
    return failure_root


def _preflight(
    arguments: argparse.Namespace,
) -> tuple[Path, Path, Path, Path, Path, Path]:
    source_commit = _require_commit(arguments.expected_source_commit)
    repository_root = _canonical_directory(arguments.repository_root, "repository root")
    _require_setup(
        repository_root == REPOSITORY_ROOT,
        "repository root differs from the loaded G05 assessor source tree",
    )
    partial_root = _canonical_directory(arguments.partial_root, "partial root")
    final_root = _canonical_absent_leaf(arguments.final_root, "final root")
    instruction_package_root = _canonical_directory(
        arguments.instruction_package_root,
        "instruction package root",
    )
    _canonical_regular(
        instruction_package_root / "package_manifest.json",
        "instruction package manifest",
    )
    _canonical_regular(
        instruction_package_root / "SHA256SUMS.txt",
        "instruction package checksum index",
    )
    run_id = _require_uuid(arguments.run_id)
    started = _parse_utc(arguments.started_utc, "run start")
    configuration_sha256 = _require_sha256(
        arguments.configuration_sha256,
        "G05 configuration",
    )
    _require_sha256(arguments.synthetic_input_sha256, "G05 synthetic input")
    _require_sha256(arguments.synthetic_target_sha256, "G05 synthetic target")
    baseline_commit = _require_commit(arguments.p00_baseline_commit)
    expected_partial = final_root.parent / f".{final_root.name}.partial"
    _require_setup(
        partial_root == expected_partial,
        "partial root is not the exact .<final-name>.partial sibling",
    )
    try:
        relative_final = final_root.relative_to(repository_root)
    except ValueError as error:
        raise G05SetupError(
            "final root is outside repository Artifacts/ASH"
        ) from error
    expected_name = (
        f"{started.strftime('%Y%m%d')}-{RUN_ROUTE}-{RUN_MODE}-"
        f"{configuration_sha256[:8]}-{run_id}"
    )
    _require_setup(
        relative_final.parts == ("Artifacts", "ASH", expected_name),
        "final root does not use the canonical UTC-route-mode-config-UUID name",
    )
    _require_setup(
        not os.path.lexists(final_root.with_name(final_root.name + ".failed")),
        "failure publication destination already exists",
    )
    g03_root = _canonical_directory(arguments.g03_root, "G03 root")
    g04_root = _canonical_directory(arguments.g04_root, "G04 root")
    _require_setup(
        len(
            {
                repository_root,
                partial_root,
                g03_root,
                g04_root,
                instruction_package_root,
            }
        )
        == 5,
        "repository, partial, G03, G04, and instruction roots must be distinct",
    )
    scoped_roots = (partial_root, g03_root, g04_root)
    for index, left in enumerate(scoped_roots):
        for right in scoped_roots[index + 1 :]:
            _require_setup(
                left not in right.parents and right not in left.parents,
                "partial, G03, and G04 roots must not contain one another",
            )
    _validate_baseline_commit(repository_root, baseline_commit, source_commit)
    return (
        repository_root,
        partial_root,
        final_root,
        g03_root,
        g04_root,
        instruction_package_root,
    )


def _execute(arguments: argparse.Namespace) -> Path:
    source_commit = _require_commit(arguments.expected_source_commit)
    (
        repository_root,
        partial_root,
        final_root,
        g03_root,
        g04_root,
        instruction_package_root,
    ) = _preflight(arguments)
    dirty_state_sha256 = _validate_repository_state(
        repository_root,
        source_commit,
    )
    p00_baseline_binding = _validate_baseline_commit(
        repository_root,
        _require_commit(arguments.p00_baseline_commit),
        source_commit,
    )
    run_roots = tuple(partial_root / "evidence" / name for name in RUN_NAMES)
    for directory in (
        partial_root / "analysis",
        partial_root / "evidence",
        partial_root / "inputs",
        partial_root / "inputs/g03",
        partial_root / "inputs/g04",
        partial_root / "inputs/live-preopen",
        partial_root / "outputs",
    ):
        _canonical_directory(directory, f"staged directory {directory.relative_to(partial_root)}")
    _require_file_closure(
        partial_root,
        _initial_staged_paths(),
        "initial G05 staged closure",
        exact=True,
        expected_directories=_initial_staged_directories(),
    )
    baseline_commit = _require_commit(arguments.p00_baseline_commit)
    command_plan = _validate_command_plan(
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        source_commit=source_commit,
        p00_baseline_commit=baseline_commit,
        attribution_output_required=False,
        p05_output_required=False,
        quality_output_required=False,
    )
    _execute_bound_p05_runs(
        command_plan=command_plan,
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=baseline_commit,
    )
    _validate_command_result_receipts(
        command_plan=command_plan,
        partial_root=partial_root,
        require_pass=True,
        identifiers=RUN_NAMES,
    )
    _execute_bound_quality_locks(
        command_plan=command_plan,
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=baseline_commit,
    )
    for index, run_root in enumerate(run_roots, start=1):
        _canonical_directory(run_root, f"P05 evidence run {index}")
    closure = validate_g05_evidence(repository_root, run_roots)
    quality = _validate_quality_locks(repository_root, partial_root)
    upstream = _validate_upstream(
        partial_root=partial_root,
        g03_root=g03_root,
        expected_g03_manifest_sha256=_require_sha256(
            arguments.expected_g03_manifest_file_sha256, "expected G03 manifest"
        ),
        g04_root=g04_root,
        expected_g04_manifest_sha256=_require_sha256(
            arguments.expected_g04_manifest_file_sha256, "expected G04 manifest"
        ),
        source_commit=source_commit,
    )
    spatial = _validate_and_copy_spatial_lock(repository_root, partial_root)
    live = _verify_live_metadata(arguments)
    upstream = dict(upstream)
    upstream["live_preopen_metadata"] = _copy_live_metadata(
        arguments,
        partial_root,
        live,
    )
    _require(
        _verify_live_metadata(arguments) == live,
        "live preopen metadata changed while its evidence copy was assembled",
    )
    validate_g05_upstream_bindings(
        repository_root=repository_root,
        wrapper_root=partial_root,
        document=upstream,
        source_commit=source_commit,
    )
    _assemble_documents(
        repository_root=repository_root,
        partial_root=partial_root,
        source_commit=source_commit,
        run_roots=run_roots,
        closure=closure,
        quality=quality,
        spatial=spatial,
        upstream=upstream,
        live=live,
        command_plan=command_plan,
    )
    dirty_state_sha256 = _validate_repository_state(
        repository_root,
        source_commit,
    )
    _require(
        _verify_live_metadata(arguments) == live,
        "live preopen metadata changed before G05 immutable publication",
    )
    _validate_live_metadata_closure(
        upstream["live_preopen_metadata"],
        partial_root,
    )
    _require(
        validate_g05_evidence(repository_root, run_roots) == closure,
        "P05 evidence changed before G05 immutable publication",
    )
    _validate_command_result_receipts(
        command_plan=command_plan,
        partial_root=partial_root,
        require_pass=True,
        identifiers=(*RUN_NAMES, "quality-lock-a", "quality-lock-b"),
    )
    _execute_captured_replay(
        command_plan=command_plan,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=_require_commit(arguments.p00_baseline_commit),
        identifier="swiftlint",
        stdout_must_exist=True,
    )
    attribution_payload = _execute_captured_replay(
        command_plan=command_plan,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=_require_commit(arguments.p00_baseline_commit),
        identifier="attribution",
        stdout_must_exist=False,
    )
    for identifier in ("instruction-package", "diff-check"):
        _execute_captured_replay(
            command_plan=command_plan,
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=_require_commit(arguments.p00_baseline_commit),
            identifier=identifier,
            stdout_must_exist=True,
        )
    _validate_command_result_receipts(
        command_plan=command_plan,
        partial_root=partial_root,
        require_pass=True,
    )
    run_identity = _build_run_identity(
        arguments=arguments,
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        source_commit=source_commit,
        dirty_state_sha256=dirty_state_sha256,
        toolchain=_toolchain_identity(),
        p00_baseline_binding=p00_baseline_binding,
        ended_utc=_utc_now(),
        outcome="pass",
        closure=closure,
    )
    _write_json_new(
        partial_root / "run-identity.json",
        run_identity,
        "G05 run identity",
    )
    aggregate = _build_command_execution_aggregate(
        partial_root=partial_root,
        command_plan=command_plan,
        source_commit=source_commit,
    )
    _write_json_new(
        partial_root / COMMAND_AGGREGATE_RELATIVE,
        aggregate,
        "G05 command execution aggregate",
    )
    _validate_command_execution_aggregate(
        wrapper_root=partial_root,
        command_plan=command_plan,
        source_commit=source_commit,
    )
    _assemble_receipt(
        repository_root=repository_root,
        partial_root=partial_root,
        source_commit=source_commit,
        run_roots=run_roots,
    )
    provenance_relative = "inputs/provenance-map.json"
    paths_before_provenance = _collect_files(partial_root)
    _require(
        set(paths_before_provenance)
        | {
            provenance_relative,
            SUPPLEMENTAL_SCAN_RELATIVE,
            SEMANTIC_BINDINGS_RELATIVE,
        }
        == set(_success_wrapper_paths()),
        "pre-final semantic file closure differs before provenance binding",
    )
    expected_paths = _success_wrapper_paths()
    provenance = _provenance_document(expected_paths, command_plan)
    provenance_payload = canonical_json_bytes(provenance) + b"\n"
    _write_new(
        partial_root / provenance_relative,
        provenance_payload,
        "in-wrapper exact provenance map",
    )
    supplemental, supplemental_patterns = _build_supplemental_scan_evidence(
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        baseline_commit=_require_commit(arguments.p00_baseline_commit),
        source_commit=source_commit,
        wrapper_paths=expected_paths,
    )
    supplemental_payload = document_bytes(supplemental)
    snapshot = _build_semantic_bindings_snapshot(
        partial_root=partial_root,
        source_commit=source_commit,
        expected_paths=expected_paths,
        candidate_files={SUPPLEMENTAL_SCAN_RELATIVE: supplemental_payload},
    )
    snapshot_payload = document_bytes(snapshot)
    _validate_supplemental_wrapper_scan(
        partial_root=partial_root,
        document=supplemental,
        patterns=supplemental_patterns,
        candidate_files={
            SUPPLEMENTAL_SCAN_RELATIVE: supplemental_payload,
            SEMANTIC_BINDINGS_RELATIVE: snapshot_payload,
        },
    )
    _write_new(
        partial_root / SUPPLEMENTAL_SCAN_RELATIVE,
        supplemental_payload,
        "G05 supplemental content scan evidence",
    )
    _write_new(
        partial_root / SEMANTIC_BINDINGS_RELATIVE,
        snapshot_payload,
        "G05 pre-finalization semantic bindings",
    )
    _require_file_closure(
        partial_root,
        expected_paths,
        "complete G05 success closure",
        exact=True,
    )
    _validate_semantic_bindings_snapshot(
        wrapper_root=partial_root,
        source_commit=source_commit,
        expected_paths=expected_paths,
    )
    selectors = [row["exact_path"] for row in provenance["rules"]]
    _require(
        selectors == list(expected_paths) and len(selectors) == len(set(selectors)),
        "external provenance map does not exactly cover the success closure",
    )
    provenance_path = final_root.with_name(
        f".{final_root.name}.provenance-map.partial"
    )
    _canonical_absent_leaf(provenance_path, "external provenance map")
    _write_new(
        provenance_path,
        provenance_payload,
        "external provenance map",
    )
    _require(
        _execute_bound_attribution(
            command_plan=command_plan,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=_require_commit(arguments.p00_baseline_commit),
        )
        == attribution_payload,
        "immediate pre-finalization attribution rerun differs",
    )
    _validate_repository_state(repository_root, source_commit)
    publication_root_identity = _owned_directory_identity(
        partial_root,
        "G05 success staged root",
    )
    try:
        published = _finalize_with_transient_provenance(
            partial_root=partial_root,
            final_root=final_root,
            repository_root=repository_root,
            provenance_path=provenance_path,
            label="transient success provenance map",
        )
        _require(
            published == final_root,
            "finalizer returned an unexpected publication path",
        )
    except BaseException as error:
        if os.path.lexists(final_root):
            _raise_quarantined_post_final_failure(
                final_root,
                error,
                context="success finalization completion failed",
            )
        raise
    try:
        _strict_reopen_final_wrapper(
            repository_root=repository_root,
            final_root=final_root,
            instruction_package_root=instruction_package_root,
            source_commit=source_commit,
            baseline_commit=_require_commit(arguments.p00_baseline_commit),
            command_plan=command_plan,
            expected_p05_closure=closure,
            expected_root_identity=publication_root_identity,
        )
    except BaseException as error:
        _raise_quarantined_post_final_failure(
            final_root,
            error,
            context="published G05 wrapper failed strict reopen",
        )
    return final_root


def _arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--partial-root", required=True, type=Path)
    parser.add_argument("--final-root", required=True, type=Path)
    parser.add_argument("--expected-source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--started-utc", required=True)
    parser.add_argument("--configuration-sha256", required=True)
    parser.add_argument("--synthetic-input-sha256", required=True)
    parser.add_argument("--synthetic-target-sha256", required=True)
    parser.add_argument("--instruction-package-root", required=True, type=Path)
    parser.add_argument("--p00-baseline-commit", required=True)
    parser.add_argument("--g03-root", required=True, type=Path)
    parser.add_argument("--expected-g03-manifest-file-sha256", required=True)
    parser.add_argument("--g04-root", required=True, type=Path)
    parser.add_argument("--expected-g04-manifest-file-sha256", required=True)
    parser.add_argument("--live-preopen-version-id", required=True)
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
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(argv)
    try:
        final_root = _execute(arguments)
    except G05SetupError as error:
        print(f"G05 setup failed: {error}", file=sys.stderr)
        return 2
    except G05PostFinalReopenError as error:
        print(
            f"G05 post-final strict reopen failed; quarantined evidence: "
            f"{error.failure_root}; {error}",
            file=sys.stderr,
        )
        return 2
    except (
        G05CurrentSourceError,
        G05GateError,
        QualityHarnessManifestError,
        SpatialPolicyContractError,
        LiveHoldoutPreopenError,
    ) as error:
        try:
            failure_root = _publish_gate_failure(arguments, error)
        except BaseException as preservation_error:
            print(
                f"G05 gate failed and immutable failure publication failed: "
                f"{preservation_error}",
                file=sys.stderr,
            )
            return 2
        print(
            f"G05 gate failed: {error}; failure evidence: {failure_root}",
            file=sys.stderr,
        )
        return 1
    except (EvidenceWrapperError, OSError, ValueError) as error:
        failure_root = arguments.final_root.with_name(
            arguments.final_root.name + ".failed"
        )
        if not failure_root.exists() and arguments.partial_root.exists():
            try:
                failure_root = _publish_gate_failure(arguments, error)
            except BaseException as preservation_error:
                print(
                    f"G05 finalization failed and immutable failure publication "
                    f"failed: {preservation_error}",
                    file=sys.stderr,
                )
                return 2
        print(f"G05 finalization failed: {error}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "schema_version": "1.0.0",
                "gate": "G05",
                "phase": "P05",
                "status": "pass",
                "holdout_accessed": False,
                "final_root": os.fspath(final_root),
            },
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
