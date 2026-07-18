#!/usr/bin/env python3
"""Validate and immutably publish one caller-staged current-source G04 wrapper.

This command does not execute the quality benchmark and does not create a gate
decision.  The caller must stage the complete evidence, including an explicit
passing assessment and test-results document, in the deterministic hidden
``.<final-name>.partial`` sibling.  This command validates those claims against
the exact committed source, publishes with the shared schema-2 transaction,
and reopens the result through the downstream G05 acceptance contract.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
from typing import Any, Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.g05 import gate as g05_gate  # noqa: E402
from validation.calibration_v2.release_evidence import (  # noqa: E402
    actionable_diagnostic_counts,
)
from validation.calibration_v2.tools import run_g05_current_source as g05  # noqa: E402
from validation.calibration_v2.tools.run_g06_verification import (  # noqa: E402
    G06VerificationError,
    parse_unittest_output,
    parse_xcresult_summary,
)
from validation.calibration_v2.tools.finalize_evidence_wrapper import (  # noqa: E402
    EvidenceWrapperError,
    _repository_state,
    finalize_evidence_wrapper,
)
from validation.quality.src.mirmir_quality.harness_manifest import (  # noqa: E402
    QualityHarnessManifestError,
    create_quality_harness_implementation_manifest,
    validate_quality_harness_implementation_manifest,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    validate_schema,
)


COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
ASSESSMENT_RELATIVE = "analysis/g04-gate-assessment.json"
TEST_RESULTS_RELATIVE = "test-results.json"
RESERVED_RELATIVES = {"artifact-manifest.json", "publication-transaction.json"}
QUALITY_REBUILD_RELATIVES = (
    "inputs/quality-harness-lock-a.json",
    "inputs/quality-harness-lock-b.json",
)
ACTUAL_CODEC_SCHEMA_RELATIVE = Path(
    "validation/quality/schemas/actual-codec-fixture.schema.json"
)
PRODUCTION_MANIFEST_SCHEMA_RELATIVE = Path(
    "validation/quality/schemas/artifact-manifest.schema.json"
)
REFERENCE_KEYS = {
    "coverage",
    "data_access_attestation",
    "log",
    "production_run_verification",
    "result_bundle",
    "summary",
    "test_results",
    "verification",
}


@dataclass(frozen=True)
class FileBindingSnapshot:
    """One prepublication mandatory evidence-file identity."""

    path: str
    sha256: str
    size_bytes: int


@dataclass(frozen=True)
class BundleClosureSnapshot:
    """The exact staged descendant closure of one validated xcresult bundle."""

    root: str
    files: tuple[str, ...]
    directories: tuple[str, ...]


@dataclass(frozen=True)
class ValidatedG04Evidence:
    """The semantic decision and mandatory bytes accepted before publication."""

    assessment: Mapping[str, Any]
    tests: Mapping[str, Any]
    files: tuple[FileBindingSnapshot, ...]
    result_bundles: tuple[BundleClosureSnapshot, ...]


class G04CurrentSourceError(RuntimeError):
    """The staged G04 evidence does not satisfy the current-source contract."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise G04CurrentSourceError(message)


def _canonical_directory(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    try:
        resolved = absolute.resolve(strict=True)
        metadata = os.lstat(absolute)
    except OSError as error:
        raise G04CurrentSourceError(f"{label} is absent") from error
    _require(
        resolved == absolute
        and stat.S_ISDIR(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode),
        f"{label} is linked, aliased, or not a directory",
    )
    return absolute


def _canonical_absent(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    parent = _canonical_directory(absolute.parent, f"{label} parent")
    _require(absolute.parent == parent, f"{label} parent differs")
    _require(not os.path.lexists(absolute), f"{label} already exists")
    return absolute


def _safe_relative(value: object, label: str) -> PurePosixPath:
    _require(isinstance(value, str) and bool(value), f"{label} is empty")
    parsed = PurePosixPath(str(value))
    _require(
        not parsed.is_absolute()
        and parsed.as_posix() == value
        and "\\" not in str(value)
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"{label} is unsafe",
    )
    return parsed


def _strict_document(path: Path, label: str) -> tuple[bytes, Mapping[str, Any]]:
    payload = g05._read_regular(path, label)
    document = g05._json_object(payload, label)
    _require(
        payload == canonical_json_bytes(document) + b"\n",
        f"{label} is not canonical one-LF JSON",
    )
    return payload, document


def _tree_paths(root: Path) -> tuple[set[str], set[str]]:
    files: set[str] = set()
    directories: set[str] = set()
    for current_name, child_directories, child_files in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        _require(
            current.resolve(strict=True) == current,
            "staged G04 tree contains an aliased directory",
        )
        child_directories.sort()
        child_files.sort()
        for name in child_directories:
            child = current / name
            metadata = os.lstat(child)
            _require(
                stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
                f"staged G04 directory is linked or special: {child}",
            )
            directories.add(child.relative_to(root).as_posix())
        for name in child_files:
            child = current / name
            metadata = os.lstat(child)
            relative = child.relative_to(root).as_posix()
            _require(
                stat.S_ISREG(metadata.st_mode)
                and not stat.S_ISLNK(metadata.st_mode)
                and metadata.st_nlink == 1,
                f"staged G04 file is linked or special: {relative}",
            )
            _require(relative not in files, f"duplicate staged G04 path: {relative}")
            files.add(relative)
    return files, directories


def _required_payload(
    *,
    root: Path,
    relative: object,
    files: set[str],
    required: set[str],
    label: str,
) -> tuple[str, bytes]:
    normalized = _safe_relative(relative, label).as_posix()
    _require(normalized in files, f"{label} file is absent: {normalized}")
    payload = g05._read_regular(root / normalized, label)
    required.add(normalized)
    return normalized, payload


def _required_reference(
    *,
    record: Mapping[str, Any],
    key: str,
    root: Path,
    files: set[str],
    required: set[str],
    label: str,
) -> tuple[str, bytes]:
    return _required_payload(
        root=root,
        relative=record.get(key),
        files=files,
        required=required,
        label=f"{label} {key}",
    )


def _required_binding(
    *,
    value: object,
    root: Path,
    files: set[str] | None,
    required: set[str] | None,
    label: str,
) -> tuple[str, bytes]:
    _require(
        isinstance(value, Mapping)
        and set(value) == {"path", "sha256", "size_bytes"},
        f"{label} is not an exact file binding",
    )
    relative = _safe_relative(value.get("path"), f"{label} path").as_posix()
    if files is not None:
        _require(relative in files, f"{label} file is absent: {relative}")
    path = root / relative
    try:
        canonical = path.resolve(strict=True)
    except OSError as error:
        raise G04CurrentSourceError(f"{label} is absent") from error
    _require(canonical == path, f"{label} traverses an alias or symbolic link")
    payload = g05._read_regular(path, label)
    _require(
        value.get("sha256") == hashlib.sha256(payload).hexdigest()
        and type(value.get("size_bytes")) is int
        and value.get("size_bytes") == len(payload),
        f"{label} differs from its file bytes",
    )
    if required is not None:
        required.add(relative)
    return relative, payload


def _required_staged_binding(
    *,
    value: object,
    root: Path,
    files: set[str],
    required: set[str],
    label: str,
) -> tuple[str, bytes]:
    """Resolve one produced-evidence binding only inside the staged wrapper."""

    return _required_binding(
        value=value,
        root=root,
        files=files,
        required=required,
        label=label,
    )


def _required_repository_binding(
    *,
    value: object,
    repository_root: Path,
    label: str,
) -> tuple[str, bytes]:
    """Resolve one implementation binding only inside the repository root."""

    return _required_binding(
        value=value,
        root=repository_root,
        files=None,
        required=None,
        label=label,
    )


def _evidence_document(payload: bytes, label: str) -> Mapping[str, Any]:
    return g05._json_object(payload, label)


def _text(payload: bytes, label: str) -> str:
    try:
        return payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise G04CurrentSourceError(f"{label} is not UTF-8") from error


def _xcresult_document(
    *,
    bundle: Path,
    kind: str,
    label: str,
) -> Mapping[str, Any]:
    if kind == "test-summary":
        arguments = ("test-results", "summary")
    elif kind == "build-results":
        arguments = ("build-results",)
    else:
        raise G04CurrentSourceError(f"unsupported xcresult extraction kind: {kind}")
    result = subprocess.run(
        (
            "/usr/bin/xcrun",
            "xcresulttool",
            "get",
            *arguments,
            "--path",
            os.fspath(bundle),
            "--compact",
        ),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env={"PATH": g05.CANONICAL_PATH, "LANG": "C", "LC_ALL": "C"},
    )
    _require(
        result.returncode == 0 and result.stderr == b"",
        f"{label} cannot be extracted from its result bundle",
    )
    return _evidence_document(result.stdout, f"{label} extracted result")


def _bundle_snapshot(
    *,
    root: Path,
    relative: object,
    files: set[str],
    directories: set[str],
    label: str,
) -> BundleClosureSnapshot:
    normalized = _safe_relative(relative, label).as_posix()
    _require(normalized in directories, f"{label} directory is absent")
    prefix = f"{normalized}/"
    bundle_files = tuple(sorted(path for path in files if path.startswith(prefix)))
    bundle_directories = tuple(
        sorted(path for path in directories if path == normalized or path.startswith(prefix))
    )
    _require(
        f"{normalized}/Info.plist" in bundle_files
        and f"{normalized}/Data" in bundle_directories,
        f"{label} lacks the canonical xcresult Info.plist or Data closure",
    )
    _canonical_directory(root / normalized, label)
    return BundleClosureSnapshot(
        root=normalized,
        files=bundle_files,
        directories=bundle_directories,
    )


def _data_boundary(value: object, label: str) -> Mapping[str, Any]:
    _require(isinstance(value, Mapping), f"{label} is absent")
    _require(
        value.get("holdout_accessed") is False
        and value.get("holdout_media_bytes_read") is False
        and value.get("validation_pixels_decoded_or_evaluated") is False
        and value.get("validation_metrics_computed") is False
        and value.get("validation_used_for_selection") is False,
        f"{label} does not prove the open-split data boundary",
    )
    return value


def _validate_xcode_evidence(
    *,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    directories: set[str],
    required: set[str],
) -> BundleClosureSnapshot:
    record = tests.get("xcode_full")
    _require(isinstance(record, Mapping), "G04 Xcode record is absent")
    _, summary_payload = _required_reference(
        record=record,
        key="summary",
        root=root,
        files=files,
        required=required,
        label="G04 Xcode",
    )
    summary = _evidence_document(summary_payload, "G04 Xcode summary")
    counts = parse_xcresult_summary(summary)
    _require(
        counts.get("terminal_status") == "passed"
        and counts.get("expected_failures") == 0
        and counts.get("test_count") == record.get("total")
        and counts.get("passed") == record.get("passed")
        and counts.get("failed") == record.get("failed")
        and counts.get("skipped") == record.get("skipped"),
        "G04 Xcode summary content differs from test-results",
    )
    _, coverage_payload = _required_reference(
        record=record,
        key="coverage",
        root=root,
        files=files,
        required=required,
        label="G04 Xcode",
    )
    _require(
        bool(_evidence_document(coverage_payload, "G04 Xcode coverage")),
        "G04 Xcode coverage document is empty",
    )
    _, log_payload = _required_reference(
        record=record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 Xcode",
    )
    log = _text(log_payload, "G04 Xcode log")
    diagnostics = actionable_diagnostic_counts(log)
    _require(
        log.count("** TEST SUCCEEDED **") == 1
        and diagnostics.get("error_count") == 0,
        "G04 Xcode log does not prove a successful error-free test run",
    )
    bundle = _bundle_snapshot(
        root=root,
        relative=record.get("result_bundle"),
        files=files,
        directories=directories,
        label="G04 Xcode result bundle",
    )
    _require(
        _xcresult_document(
            bundle=root / bundle.root,
            kind="test-summary",
            label="G04 Xcode",
        )
        == summary,
        "G04 Xcode summary differs from its actual result bundle",
    )
    return bundle


def _validate_release_evidence(
    *,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    directories: set[str],
    required: set[str],
) -> BundleClosureSnapshot:
    record = tests.get("release_build")
    _require(isinstance(record, Mapping), "G04 Release record is absent")
    _, summary_payload = _required_reference(
        record=record,
        key="summary",
        root=root,
        files=files,
        required=required,
        label="G04 Release",
    )
    summary = _evidence_document(summary_payload, "G04 Release summary")
    destination = summary.get("destination")
    _require(
        summary.get("status") == "succeeded"
        and isinstance(destination, Mapping)
        and destination.get("architecture") == "arm64"
        and destination.get("platform") == "macOS"
        and all(
            type(summary.get(key)) is int and summary.get(key) == 0
            for key in ("warningCount", "errorCount", "analyzerWarningCount")
        )
        and summary.get("warnings") == []
        and summary.get("errors") == []
        and summary.get("analyzerWarnings") == [],
        "G04 Release summary is not a clean arm64 macOS success",
    )
    _, log_payload = _required_reference(
        record=record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 Release",
    )
    log = _text(log_payload, "G04 Release log")
    diagnostics = actionable_diagnostic_counts(log)
    _require(
        log.count("** BUILD SUCCEEDED **") == 1
        and diagnostics == {"warning_count": 0, "error_count": 0},
        "G04 Release log does not prove a clean successful build",
    )
    _, verification_payload = _required_reference(
        record=record,
        key="verification",
        root=root,
        files=files,
        required=required,
        label="G04 Release",
    )
    verification = _text(verification_payload, "G04 Release verification")
    binary_sha256 = record.get("binary_sha256")
    _require(
        isinstance(binary_sha256, str)
        and re.fullmatch(r"[0-9a-f]{64}", binary_sha256) is not None
        and record.get("architecture") == "arm64"
        and record.get("hardened_runtime") is True
        and "Mach-O 64-bit executable arm64" in verification
        and "Format=app bundle with Mach-O thin (arm64)" in verification
        and re.search(r"flags=0x[0-9a-f]+\([^\n]*runtime[^\n]*\)", verification)
        is not None
        and re.search(rf"(?m)^{binary_sha256}  .+/Mirmir$", verification)
        is not None,
        "G04 Release binary verification does not prove arm64 hardened bytes",
    )
    bundle = _bundle_snapshot(
        root=root,
        relative=record.get("result_bundle"),
        files=files,
        directories=directories,
        label="G04 Release result bundle",
    )
    _require(
        _xcresult_document(
            bundle=root / bundle.root,
            kind="build-results",
            label="G04 Release",
        )
        == summary,
        "G04 Release summary differs from its actual result bundle",
    )
    return bundle


def _validate_python_evidence(
    *,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    record = tests.get("python")
    _require(isinstance(record, Mapping), "G04 Python record is absent")
    _, payload = _required_reference(
        record=record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 Python",
    )
    parsed = parse_unittest_output(_text(payload, "G04 Python log"))
    _require(
        parsed.get("terminal_status") == "passed"
        and parsed.get("test_count") == record.get("test_count")
        and record.get("failures") == 0
        and record.get("skips") == 0,
        "G04 Python log content differs from test-results",
    )


def _validate_production_evidence(
    *,
    repository_root: Path,
    source_commit: str,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    record = tests.get("production_dry_run")
    _require(isinstance(record, Mapping), "G04 production dry-run record is absent")
    boundary = _data_boundary(record.get("data_access"), "G04 production data access")
    _, verification_payload = _required_reference(
        record=record,
        key="verification",
        root=root,
        files=files,
        required=required,
        label="G04 production dry run",
    )
    verification = _evidence_document(
        verification_payload,
        "G04 production-run verification",
    )
    _, attestation_payload = _required_reference(
        record=record,
        key="data_access_attestation",
        root=root,
        files=files,
        required=required,
        label="G04 production dry run",
    )
    attestation = _evidence_document(
        attestation_payload,
        "G04 data-access attestation",
    )
    manifest_relative, manifest_payload = _required_staged_binding(
        value=record.get("artifact_manifest"),
        root=root,
        files=files,
        required=required,
        label="G04 production artifact manifest",
    )
    manifest_document = _evidence_document(
        manifest_payload,
        "G04 production artifact manifest",
    )
    validate_schema(
        manifest_document,
        repository_root / PRODUCTION_MANIFEST_SCHEMA_RELATIVE,
    )
    failure_relative, failure_payload = _required_staged_binding(
        value=record.get("injected_failure"),
        root=root,
        files=files,
        required=required,
        label="G04 production injected failure",
    )
    _require(
        bool(_evidence_document(failure_payload, "G04 injected failure")),
        "G04 injected-failure evidence is empty",
    )
    execution_relative, execution_payload = _required_staged_binding(
        value=attestation.get("execution_binding"),
        root=root,
        files=files,
        required=required,
        label="G04 production execution binding",
    )
    _require(
        bool(_evidence_document(execution_payload, "G04 execution binding")),
        "G04 production execution binding is empty",
    )
    _required_repository_binding(
        value=attestation.get("implementation_binding"),
        repository_root=repository_root,
        label="G04 production implementation binding",
    )
    _require(
        verification.get("schema_version") == "1.0.0"
        and verification.get("status") == "pass"
        and verification.get("source_commit") == source_commit
        and verification.get("semantic_reverification") is True
        and verification.get("resume_recomputed") is True
        and verification.get("writer_run_count") == record.get("writer_run_count")
        and verification.get("data_access") == boundary
        and verification.get("artifact_manifest") == record.get("artifact_manifest")
        and verification.get("injected_failure") == record.get("injected_failure"),
        "G04 production verification differs from the bound test result",
    )
    observed = attestation.get("observed_input_binding_flags")
    _require(
        attestation.get("schema_version") == "1.0.0"
        and attestation.get("status") == "pass"
        and attestation.get("source_commit") == source_commit
        and attestation.get("execution_boundary") == boundary
        and isinstance(observed, Mapping)
        and observed.get("all_split_evidence_rehashed") is True
        and observed.get("holdout_accessed") is False
        and observed.get("holdout_media_rehashed") is False,
        "G04 data-access attestation differs or does not prove no holdout access",
    )
    _require(
        manifest_relative in required
        and failure_relative in required
        and execution_relative in required,
        "G04 production transitive evidence closure is incomplete",
    )


def _validate_actual_codec_evidence(
    *,
    repository_root: Path,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    record = tests.get("actual_codec_cli")
    _require(isinstance(record, Mapping), "G04 actual-codec record is absent")
    evidence_relative, evidence_payload = _required_staged_binding(
        value=record.get("evidence"),
        root=root,
        files=files,
        required=required,
        label="G04 actual-codec evidence",
    )
    evidence = _evidence_document(evidence_payload, "G04 actual-codec evidence")
    validate_schema(evidence, repository_root / ACTUAL_CODEC_SCHEMA_RELATIVE)
    fixture_relative, fixture_payload = _required_staged_binding(
        value=record.get("fixture"),
        root=root,
        files=files,
        required=required,
        label="G04 actual-codec fixture",
    )
    fixture = evidence.get("fixture")
    _require(isinstance(fixture, Mapping), "G04 actual-codec fixture is absent")
    fixture_name = _safe_relative(
        fixture.get("path"),
        "G04 actual-codec report fixture path",
    )
    _require(
        len(fixture_name.parts) == 1
        and fixture_relative
        == (PurePosixPath(evidence_relative).parent / fixture_name).as_posix()
        and fixture.get("sha256") == hashlib.sha256(fixture_payload).hexdigest()
        and fixture.get("size_bytes") == len(fixture_payload),
        "G04 actual-codec fixture bytes differ from the report",
    )
    _, log_payload = _required_reference(
        record=record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 actual codec",
    )
    evidence_sha256 = hashlib.sha256(evidence_payload).hexdigest()
    _require(
        record.get("status") == "pass"
        and record.get("evidence_sha256") == evidence_sha256
        and log_payload
        == f"actual codec fixture verification passed: {evidence_sha256}\n".encode(
            "ascii"
        ),
        "G04 actual-codec log or evidence digest differs",
    )


def _validate_attribution_evidence(
    *,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    record = tests.get("attribution_scan")
    _require(isinstance(record, Mapping), "G04 attribution record is absent")
    _, payload = _required_reference(
        record=record,
        key="path",
        root=root,
        files=files,
        required=required,
        label="G04 attribution",
    )
    document = _evidence_document(payload, "G04 attribution result")
    _require(
        set(document) == {"status", "base", "changed_file_count", "findings"}
        and document.get("status") == "pass"
        and isinstance(document.get("base"), str)
        and COMMIT_PATTERN.fullmatch(str(document["base"])) is not None
        and type(document.get("changed_file_count")) is int
        and document["changed_file_count"] >= 0
        and document.get("findings") == []
        and record.get("findings") == 0,
        "G04 attribution evidence does not prove a finding-free scan",
    )


def _validate_metric_oracle_evidence(
    *,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    record = tests.get("metric_oracle")
    _require(isinstance(record, Mapping), "G04 metric-oracle record is absent")
    _, payload = _required_reference(
        record=record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 metric oracle",
    )
    document = _evidence_document(payload, "G04 metric-oracle output")
    fixture = document.get("fixture")
    expected = document.get("expected")
    _require(
        set(document) == {"schema_version", "oracle", "fixture", "expected"}
        and document.get("schema_version") == "1.0.0"
        and isinstance(document.get("oracle"), str)
        and bool(document.get("oracle"))
        and isinstance(fixture, Mapping)
        and set(fixture)
        == {
            "id",
            "dimensions",
            "candidate_f64le_sha256",
            "reference_f64le_sha256",
        }
        and isinstance(fixture.get("dimensions"), list)
        and len(fixture["dimensions"]) == 2
        and all(type(value) is int and value > 0 for value in fixture["dimensions"])
        and all(
            isinstance(fixture.get(key), str)
            and re.fullmatch(r"[0-9a-f]{64}", str(fixture[key])) is not None
            for key in ("candidate_f64le_sha256", "reference_f64le_sha256")
        )
        and isinstance(expected, Mapping)
        and set(expected)
        == {"ssim", "ms_ssim", "scale_ssim_means", "scale_contrast_structure_means"}
        and all(
            isinstance(expected.get(key), (int, float))
            and not isinstance(expected.get(key), bool)
            and math.isfinite(float(expected[key]))
            and 0.0 <= float(expected[key]) <= 1.0
            for key in ("ssim", "ms_ssim")
        )
        and all(
            isinstance(expected.get(key), list)
            and len(expected[key]) == 5
            and all(
                isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(float(value))
                and 0.0 <= float(value) <= 1.0
                for value in expected[key]
            )
            for key in ("scale_ssim_means", "scale_contrast_structure_means")
        ),
        "G04 metric-oracle output is not a complete finite five-scale result",
    )


def _validate_swiftlint_evidence(
    *,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    record = tests.get("swiftlint")
    _require(isinstance(record, Mapping), "G04 SwiftLint record is absent")
    _, payload = _required_reference(
        record=record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 SwiftLint",
    )
    text = _text(payload, "G04 SwiftLint log")
    summaries = re.findall(
        r"Found 0 violations, 0 serious in [1-9][0-9]* files\.",
        text,
    )
    _require(
        record.get("violations") == 0
        and len(summaries) == 1
        and re.search(r"Found [1-9][0-9]* violations", text) is None
        and "error:" not in text.lower(),
        "G04 SwiftLint log does not prove one zero-violation strict run",
    )


def _validate_auxiliary_g04_evidence(
    *,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    static_record = tests.get("static_validation")
    instruction_record = tests.get("instruction_package")
    _require(
        isinstance(static_record, Mapping)
        and static_record.get("status") == "pass",
        "G04 static-validation record is absent or failed",
    )
    _, static_payload = _required_reference(
        record=static_record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 static validation",
    )
    static_text = _text(static_payload, "G04 static-validation log")
    _require(
        "Traceback (most recent call last)" not in static_text
        and "SyntaxError:" not in static_text,
        "G04 static-validation log reports a Python failure",
    )
    _require(
        isinstance(instruction_record, Mapping)
        and instruction_record.get("status") == "pass",
        "G04 instruction-package record is absent or failed",
    )
    _, instruction_payload = _required_reference(
        record=instruction_record,
        key="log",
        root=root,
        files=files,
        required=required,
        label="G04 instruction package",
    )
    instruction_lines = _text(
        instruction_payload,
        "G04 instruction-package log",
    ).splitlines()
    _require(
        bool(instruction_lines)
        and instruction_lines[0] == "PASS"
        and sum(line.startswith("total_files=") for line in instruction_lines) == 1
        and sum(line.startswith("payload_files=") for line in instruction_lines) == 1
        and sum(line.startswith("checksum_entries=") for line in instruction_lines)
        == 1,
        "G04 instruction-package log is not a passing closure report",
    )


def _validate_quality_rebuilds(
    *,
    repository_root: Path,
    tests: Mapping[str, Any],
    root: Path,
    files: set[str],
    required: set[str],
) -> None:
    record = tests.get("quality_harness_manifest")
    _require(isinstance(record, Mapping), "G04 quality-manifest record is absent")
    installed_internal_sha256 = _validate_quality_manifest(repository_root)
    installed_payload = g05._read_regular(
        repository_root / g05.QUALITY_MANIFEST_RELATIVE,
        "installed quality-harness implementation lock",
    )
    rebuild_payloads: list[bytes] = []
    for key, expected_relative in zip(
        ("rebuild_a", "rebuild_b"),
        QUALITY_REBUILD_RELATIVES,
    ):
        relative, payload = _required_binding(
            value=record.get(key),
            root=root,
            files=files,
            required=required,
            label=f"G04 quality-manifest {key}",
        )
        _require(
            relative == expected_relative,
            f"G04 quality-manifest {key} path differs from the canonical closure",
        )
        rebuild_payloads.append(payload)
    installed_file_sha256 = hashlib.sha256(installed_payload).hexdigest()
    _require(
        record.get("status") == "pass"
        and record.get("deterministic_rebuild_count") == 2
        and record.get("manifest_sha256") == installed_internal_sha256
        and record.get("installed_file_sha256") == installed_file_sha256
        and rebuild_payloads[0] == rebuild_payloads[1] == installed_payload,
        "G04 quality-manifest rebuilds are not two byte-identical installed-lock rebuilds",
    )


def _validate_mandatory_evidence(
    *,
    repository_root: Path,
    root: Path,
    source_commit: str,
    assessment: Mapping[str, Any],
    tests: Mapping[str, Any],
    files: set[str],
    directories: set[str],
) -> tuple[set[str], tuple[BundleClosureSnapshot, ...]]:
    manifest_rows = {relative: {} for relative in files}
    g05_gate._validate_g04_test_evidence(
        tests,
        manifest_rows,
        sorted(directories),
    )
    required = {TEST_RESULTS_RELATIVE}
    bundles = (
        _validate_xcode_evidence(
            tests=tests,
            root=root,
            files=files,
            directories=directories,
            required=required,
        ),
        _validate_release_evidence(
            tests=tests,
            root=root,
            files=files,
            directories=directories,
            required=required,
        ),
    )
    _validate_python_evidence(
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _validate_production_evidence(
        repository_root=repository_root,
        source_commit=source_commit,
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _validate_actual_codec_evidence(
        repository_root=repository_root,
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _validate_attribution_evidence(
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _validate_metric_oracle_evidence(
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _validate_swiftlint_evidence(
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _validate_auxiliary_g04_evidence(
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _validate_quality_rebuilds(
        repository_root=repository_root,
        tests=tests,
        root=root,
        files=files,
        required=required,
    )
    _require(
        assessment.get("evidence") == sorted(required),
        "G04 assessment does not enumerate the exact mandatory evidence closure",
    )
    g05_gate._validate_g04_assessment(
        assessment,
        source_commit=source_commit,
        manifest_rows=manifest_rows,
        manifest_directories=sorted(directories),
    )
    return required, bundles


def _snapshot_validated_evidence(
    *,
    root: Path,
    required: set[str],
    bundles: Sequence[BundleClosureSnapshot],
) -> tuple[FileBindingSnapshot, ...]:
    paths = {ASSESSMENT_RELATIVE, *required}
    for bundle in bundles:
        paths.update(bundle.files)
    snapshots = []
    for relative in sorted(paths):
        payload = g05._read_regular(root / relative, f"validated G04 file {relative}")
        snapshots.append(
            FileBindingSnapshot(
                path=relative,
                sha256=hashlib.sha256(payload).hexdigest(),
                size_bytes=len(payload),
            )
        )
    return tuple(snapshots)


def _validate_published_snapshot(
    *,
    evidence: ValidatedG04Evidence,
    manifest_rows: Mapping[str, Mapping[str, Any]],
    manifest_directories: Sequence[str],
) -> None:
    for snapshot in evidence.files:
        row = manifest_rows.get(snapshot.path)
        _require(
            isinstance(row, Mapping)
            and row.get("sha256") == snapshot.sha256
            and row.get("size_bytes") == snapshot.size_bytes,
            f"published mandatory G04 evidence changed: {snapshot.path}",
        )
    row_paths = set(manifest_rows)
    directory_paths = set(manifest_directories)
    for bundle in evidence.result_bundles:
        prefix = f"{bundle.root}/"
        published_files = {
            path for path in row_paths if path.startswith(prefix)
        }
        published_directories = {
            path
            for path in directory_paths
            if path == bundle.root or path.startswith(prefix)
        }
        _require(
            published_files == set(bundle.files)
            and published_directories == set(bundle.directories),
            f"published G04 result-bundle closure changed: {bundle.root}",
        )


def _require_reference(
    *,
    value: object,
    label: str,
    files: set[str],
    directories: set[str],
) -> None:
    parsed = _safe_relative(value, label).as_posix()
    _require(
        parsed in files or parsed in directories,
        f"{label} is not present in the staged G04 closure: {parsed}",
    )


def _validate_embedded_bindings(
    value: object,
    *,
    root: Path,
    files: set[str],
    directories: set[str],
    label: str,
) -> None:
    if isinstance(value, Mapping):
        if {"path", "sha256", "size_bytes"}.issubset(value):
            parsed = _safe_relative(value.get("path"), f"{label} binding path")
            relative = parsed.as_posix()
            _require(relative in files, f"{label} binding file is absent: {relative}")
            payload = g05._read_regular(root.joinpath(*parsed.parts), label)
            _require(
                value.get("sha256") == hashlib.sha256(payload).hexdigest()
                and value.get("size_bytes") == len(payload),
                f"{label} binding differs from its staged file",
            )
        for key, child in value.items():
            if key in REFERENCE_KEYS and isinstance(child, str):
                _require_reference(
                    value=child,
                    label=f"{label}.{key}",
                    files=files,
                    directories=directories,
                )
            _validate_embedded_bindings(
                child,
                root=root,
                files=files,
                directories=directories,
                label=f"{label}.{key}",
            )
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _validate_embedded_bindings(
                child,
                root=root,
                files=files,
                directories=directories,
                label=f"{label}[{index}]",
            )


def _validate_quality_manifest(repository_root: Path) -> str:
    path = repository_root / g05.QUALITY_MANIFEST_RELATIVE
    payload, document = _strict_document(path, "quality-harness implementation lock")
    validated = validate_quality_harness_implementation_manifest(
        document,
        repository_root,
    )
    rebuilt = create_quality_harness_implementation_manifest(repository_root)
    _require(
        payload == canonical_json_bytes(rebuilt) + b"\n",
        "quality-harness implementation lock is stale",
    )
    return validated


def validate_staged_g04(
    *,
    repository_root: Path,
    partial_root: Path,
    expected_source_commit: str,
) -> ValidatedG04Evidence:
    """Validate the caller-staged wrapper without publishing it."""

    _require(
        COMMIT_PATTERN.fullmatch(expected_source_commit) is not None,
        "expected source commit is not a lowercase 40-character Git object ID",
    )
    repository_root = _canonical_directory(repository_root, "repository root")
    partial_root = _canonical_directory(partial_root, "G04 partial root")
    state = _repository_state(repository_root)
    _require(
        state.project_commit == expected_source_commit,
        "repository HEAD differs from the expected G04 source commit",
    )
    files, directories = _tree_paths(partial_root)
    _require(
        not files.intersection(RESERVED_RELATIVES),
        "staged G04 wrapper contains a finalizer-reserved file",
    )
    _require(
        {ASSESSMENT_RELATIVE, TEST_RESULTS_RELATIVE}.issubset(files),
        "staged G04 wrapper lacks its canonical assessment or test results",
    )

    _, assessment = _strict_document(
        partial_root / ASSESSMENT_RELATIVE,
        "G04 gate assessment",
    )
    _, tests = _strict_document(
        partial_root / TEST_RESULTS_RELATIVE,
        "G04 test results",
    )
    _require(
        assessment.get("schema_version") == "1.0.0"
        and assessment.get("gate") == "G04"
        and assessment.get("status") == "pass"
        and assessment.get("project_commit") == expected_source_commit
        and assessment.get("holdout_accessed") is False
        and assessment.get("algorithm_quality_claimed") is False
        and assessment.get("test_results") == TEST_RESULTS_RELATIVE,
        "G04 assessment is not an explicit same-source no-holdout pass",
    )
    _require(
        tests.get("schema_version") == "1.0.0"
        and tests.get("status") == "pass"
        and tests.get("source_commit") == expected_source_commit,
        "G04 test results are not a same-source pass",
    )
    required, bundles = _validate_mandatory_evidence(
        repository_root=repository_root,
        root=partial_root,
        source_commit=expected_source_commit,
        assessment=assessment,
        tests=tests,
        files=files,
        directories=directories,
    )
    _validate_embedded_bindings(
        assessment,
        root=partial_root,
        files=files,
        directories=directories,
        label="assessment",
    )
    _validate_embedded_bindings(
        tests,
        root=partial_root,
        files=files,
        directories=directories,
        label="test_results",
    )
    snapshots = _snapshot_validated_evidence(
        root=partial_root,
        required=required,
        bundles=bundles,
    )
    _require(
        _repository_state(repository_root) == state,
        "repository state changed during staged G04 validation",
    )
    return ValidatedG04Evidence(
        assessment=assessment,
        tests=tests,
        files=snapshots,
        result_bundles=bundles,
    )


def finalize_g04_current_source(
    *,
    repository_root: Path,
    partial_root: Path,
    final_root: Path,
    expected_source_commit: str,
) -> Path:
    """Validate, publish, and strict-reopen one current-source G04 wrapper."""

    repository_root = _canonical_directory(repository_root, "repository root")
    partial_root = _canonical_directory(partial_root, "G04 partial root")
    final_root = _canonical_absent(final_root, "G04 final root")
    _require(
        partial_root == final_root.parent / f".{final_root.name}.partial",
        "G04 partial root is not the deterministic hidden final sibling",
    )
    try:
        relative_final = final_root.relative_to(repository_root)
    except ValueError as error:
        raise G04CurrentSourceError("G04 final root is outside the repository") from error
    _require(
        relative_final.parts[:2] == ("Artifacts", "ASH")
        and len(relative_final.parts) == 3,
        "G04 final root is not a direct Artifacts/ASH child",
    )
    evidence = validate_staged_g04(
        repository_root=repository_root,
        partial_root=partial_root,
        expected_source_commit=expected_source_commit,
    )
    published = finalize_evidence_wrapper(
        partial=partial_root,
        final=final_root,
        gate_ids=("G04",),
        project_root=repository_root,
        producer="Mirmir G04 current-source wrapper",
        command="finalize_g04_current_source.py validated caller-staged evidence",
        platform=platform.platform() or "unknown",
        machine=platform.machine() or "unknown",
    )
    _require(
        published == final_root,
        "shared finalizer returned a noncanonical G04 publication root",
    )
    manifest_payload = g05._read_regular(
        published / "artifact-manifest.json",
        "published G04 artifact manifest",
    )
    manifest = g05._json_object(manifest_payload, "published G04 artifact manifest")
    _require(
        manifest.get("project_commit") == expected_source_commit
        and manifest.get("working_tree_clean") is True,
        "published G04 manifest source binding differs",
    )
    g05._validate_finalized_g04_closure(
        root=published,
        manifest=manifest,
        manifest_payload=manifest_payload,
        source_commit=expected_source_commit,
    )
    rows = g05._manifest_rows(manifest, "published G04 artifact manifest")
    _, reopened_assessment = _strict_document(
        published / ASSESSMENT_RELATIVE,
        "published G04 gate assessment",
    )
    _, reopened_tests = _strict_document(
        published / TEST_RESULTS_RELATIVE,
        "published G04 test results",
    )
    _require(
        reopened_assessment == evidence.assessment
        and reopened_tests == evidence.tests,
        "published G04 decision evidence changed during finalization",
    )
    published_directories = manifest.get("directories")
    _require(
        isinstance(published_directories, list)
        and all(isinstance(value, str) for value in published_directories),
        "published G04 manifest directory closure is absent",
    )
    published_files = set(rows)
    published_directory_set = set(published_directories)
    _validate_published_snapshot(
        evidence=evidence,
        manifest_rows=rows,
        manifest_directories=published_directories,
    )
    _validate_embedded_bindings(
        reopened_assessment,
        root=published,
        files=published_files,
        directories=published_directory_set,
        label="published_assessment",
    )
    _validate_embedded_bindings(
        reopened_tests,
        root=published,
        files=published_files,
        directories=published_directory_set,
        label="published_test_results",
    )
    g05_gate._validate_g04_assessment(
        reopened_assessment,
        source_commit=expected_source_commit,
        manifest_rows=rows,
        manifest_directories=published_directories,
    )
    g05_gate._validate_g04_test_evidence(
        reopened_tests,
        rows,
        published_directories,
    )
    _require(
        reopened_assessment.get("holdout_accessed") is False,
        "published G04 assessment lost its no-holdout claim",
    )
    return published


def _arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--partial-root", required=True, type=Path)
    parser.add_argument("--final-root", required=True, type=Path)
    parser.add_argument("--expected-source-commit", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(argv)
    try:
        published = finalize_g04_current_source(
            repository_root=arguments.repository_root,
            partial_root=arguments.partial_root,
            final_root=arguments.final_root,
            expected_source_commit=arguments.expected_source_commit,
        )
    except (
        EvidenceWrapperError,
        G04CurrentSourceError,
        G06VerificationError,
        QualityHarnessManifestError,
        g05_gate.G05GateError,
        g05.G05CurrentSourceError,
        OSError,
        ValueError,
    ) as error:
        print(f"G04 current-source finalization failed: {error}", file=sys.stderr)
        return 2
    print(published)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
