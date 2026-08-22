#!/usr/bin/env python3
"""Fail-closed qualification for the deterministic-engine v4 time target.

The capture runner deliberately lives in a separate shell script.  This module
owns evidence validation, statistics, report sealing, and verification so the
same rules can be exercised without invoking Xcode.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
from pathlib import PurePosixPath
import random
import re
import shlex
import shutil
import stat
import statistics
import subprocess
import sys
from typing import Any, Callable, Iterable, Sequence


CONTRACT_SCHEMA = "mirmir-v4-performance-gate-contract-v1"
CAPTURE_SCHEMA = "mirmir-v4-performance-capture-v1"
SOURCE_IDENTITY_SCHEMA = "mirmir-v4-performance-source-identity-v1"
ENVIRONMENT_SCHEMA = "mirmir-v4-performance-environment-v1"
ARTIFACT_MANIFEST_SCHEMA = "mirmir-v4-performance-capture-artifacts-v1"
REPORT_SCHEMA = "mirmir-v4-performance-gate-report-v1"
EVIDENCE_MANIFEST_SCHEMA = "mirmir-v4-performance-evidence-manifest-v1"
PRODUCER_RECEIPT_SCHEMA = "mirmir-v4-performance-producer-receipt-v2"
RESULT_BUNDLE_MANIFEST_SCHEMA = "mirmir-v4-performance-xcresult-tree-v2"
SAMPLE_TRANSCRIPT_SCHEMA = "mirmir-v4-performance-sample-transcripts-v2"
SAMPLE_ROW_DOMAIN = b"mirmir-v4-performance-sample-transcript-v2\0"
SAMPLE_SET_DOMAIN = b"mirmir-v4-performance-sample-transcript-set-v2\0"
SAMPLE_MEASUREMENT_DOMAIN = b"mirmir-v4-performance-sample-measurement-set-v2\0"
SAMPLE_WORKLOAD_DOMAIN = b"mirmir-v4-performance-sample-workload-v2\0"
RESULT_BUNDLE_TREE_DOMAIN = b"mirmir-v4-performance-xcresult-tree-v2\0"
PRODUCER_CAUSAL_DOMAIN = b"mirmir-v4-performance-producer-causal-v2\0"
STABLE_PRODUCER_DOMAIN = b"mirmir-v4-performance-stable-producer-v2\0"
TEST_SUMMARY_SCHEMA = "mirmir-v4-performance-normalized-test-summary-v2"
STABLE_PRODUCER_FACTS_SCHEMA = "mirmir-v4-performance-stable-producer-facts-v2"
COMPILER_CONTROL_AUDIT_SCHEMA = "mirmir-v4-performance-compiler-control-audit-v2"
SWIFT_DRIVER_WRAPPER_SCHEMA = "mirmir-v4-performance-swift-driver-wrapper-v2"
SWIFT_DRIVER_JOB_AUDIT_SCHEMA = "mirmir-v4-performance-swift-driver-job-audit-v2"
SWIFT_FRONTEND_SHIM_SCHEMA = "mirmir-v4-performance-swift-frontend-shim-v1"
SWIFT_FRONTEND_JOB_AUDIT_SCHEMA = (
    "mirmir-v4-performance-swift-frontend-job-audit-v1"
)
SWIFT_DRIVER_WRAPPER_DOMAIN = b"mirmir-v4-performance-swift-driver-wrapper-v2\0"
SWIFT_DRIVER_JOB_AUDIT_DOMAIN = b"mirmir-v4-performance-swift-driver-job-audit-v2\0"
SWIFT_FRONTEND_SHIM_DOMAIN = b"mirmir-v4-performance-swift-frontend-shim-v1\0"
SWIFT_FRONTEND_JOB_AUDIT_DOMAIN = (
    b"mirmir-v4-performance-swift-frontend-job-audit-v1\0"
)
SWIFT_DRIVER_JOB_AUDIT_PREFIX = "MIRMIR_V4_PERFORMANCE_SWIFT_DRIVER_EFFECTIVE_ARGV"
CANONICAL_PRODUCER_ROOT = "/private/tmp/mirmir-v4-performance-producer-v2"
CANONICAL_SOURCE_ROOT = CANONICAL_PRODUCER_ROOT + "/baseline-project"
CANONICAL_DERIVED_DATA = CANONICAL_PRODUCER_ROOT + "/DerivedData/baseline"
CANONICAL_MODULE_CACHE = CANONICAL_PRODUCER_ROOT + "/ModuleCache.noindex"
CANONICAL_SWIFT_WRAPPER = CANONICAL_PRODUCER_ROOT + "/swiftc"
CANONICAL_SWIFT_AUDIT = CANONICAL_PRODUCER_ROOT + "/swift-driver-effective-argv.log"
CANONICAL_SWIFT_FRONTEND_SHIM = CANONICAL_PRODUCER_ROOT + "/swift-frontend"
CANONICAL_SWIFT_FRONTEND_AUDIT = (
    CANONICAL_PRODUCER_ROOT + "/swift-frontend-effective-argv.jsonl"
)
CANONICAL_SWIFT_TEMPORARY = CANONICAL_PRODUCER_ROOT + "/Temporary"
CANONICAL_SWIFT_SUPPLEMENTARY_MAPS = (
    CANONICAL_PRODUCER_ROOT + "/SupplementaryOutputMaps"
)
SWIFT_DRIVER_REQUIRED_MODULES = ("Mirmir", "MirmirTests")
SWIFT_DRIVER_REQUIRED_TARGET = "arm64-apple-macos15.4"
SHA256_LENGTH = 64
PACKAGED_CAPTURE_FIELDS = {
    "evidenceRequestSHA256",
    "observerSourceSHA256",
    "packagedCandidateIdentity",
}
PERFORMANCE_REQUEST_FIELDS = (
    "codec",
    "fileType",
    "preserveAudio",
    "overwriteExistingFile",
)
VERIFICATION_BOOLEAN_FIELDS = (
    "requestedBackendExecutedWithoutFallback",
    "allInputTracksAccounted",
    "exactEnabledVideoTrackCount",
    "exactEncodedDimensions",
    "exactCodec",
    "exactFrameCount",
    "exactPresentationTimestamps",
    "exactDuration",
    "bt709ColorContract",
    "allRequiredChecksPassed",
)
VERIFICATION_HASH_FIELDS = (
    "decodedVisiblePixelSHA256",
    "semanticTrackManifestSHA256",
)


class EvidenceError(ValueError):
    """Raised whenever evidence is missing, ambiguous, or not identity-bound."""


def packaged_evidence_module():
    path = Path(__file__).resolve().with_name("packaged_candidate_evidence_v4.py")
    spec = importlib.util.spec_from_file_location(
        "performance_packaged_candidate_evidence_v4", path
    )
    if spec is None or spec.loader is None:
        raise EvidenceError("cannot load packaged-candidate evidence verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise EvidenceError(f"duplicate JSON key: {key}")
        value[key] = child
    return value


def _reject_nonfinite(token: str) -> Any:
    raise EvidenceError(f"non-finite JSON number: {token}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot read canonical JSON {path}: {error}") from error


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise EvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_bytes(
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ).encode()
        + b"\n"
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def require_object(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be text")
    return value


def require_bool(value: Any, label: str) -> bool:
    require(type(value) is bool, f"{label} must be boolean")
    return value


def require_integer(value: Any, label: str, minimum: int | None = None) -> int:
    require(type(value) is int, f"{label} must be an integer")
    if minimum is not None:
        require(value >= minimum, f"{label} must be at least {minimum}")
    return value


def require_number(value: Any, label: str, minimum: float = 0.0) -> float:
    require(type(value) in (int, float), f"{label} must be numeric")
    number = float(value)
    require(math.isfinite(number), f"{label} must be finite")
    require(number >= minimum, f"{label} must be at least {minimum}")
    return number


def require_sha256(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(
        len(text) == SHA256_LENGTH
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a lowercase SHA-256",
    )
    return text


def require_safe_relative(value: Any, label: str) -> str:
    text = require_string(value, label)
    relative = PurePosixPath(text)
    require(
        not relative.is_absolute()
        and ".." not in relative.parts
        and text == relative.as_posix(),
        f"{label} must be a safe canonical relative path",
    )
    return text


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    resolved_root = root.resolve(strict=True)
    resolved = path.resolve(strict=True)
    require(
        resolved.is_file() and resolved_root in resolved.parents,
        f"artifact is outside the evidence root: {path}",
    )
    return {
        "path": resolved.relative_to(resolved_root).as_posix(),
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def validate_descriptor(
    root: Path,
    value: Any,
    label: str,
) -> tuple[Path, str]:
    artifact = require_object(value, label)
    require_exact_keys(artifact, ("path", "byteCount", "sha256"), label)
    relative = require_safe_relative(artifact["path"], f"{label}.path")
    path = root / relative
    require(
        path.is_file() and not path.is_symlink(),
        f"{label} is missing or unsafe",
    )
    resolved_root = root.resolve(strict=True)
    resolved = path.resolve(strict=True)
    require(
        resolved_root in resolved.parents,
        f"{label} escapes the evidence root",
    )
    require_integer(artifact["byteCount"], f"{label}.byteCount", 0)
    identity = require_sha256(artifact["sha256"], f"{label}.sha256")
    require(path.stat().st_size == artifact["byteCount"], f"{label} byte count changed")
    require(sha256_file(path) == identity, f"{label} SHA-256 changed")
    return resolved, identity


def regular_files(root: Path, *, excluded: Iterable[str] = ()) -> list[Path]:
    resolved_root = root.resolve(strict=True)
    excluded_set = set(excluded)
    files: list[Path] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        require(not path.is_symlink(), f"symbolic links are forbidden: {relative}")
        require(
            path.is_dir() or path.is_file(),
            f"unsupported artifact type: {relative}",
        )
        if path.is_file() and relative not in excluded_set:
            resolved = path.resolve(strict=True)
            require(
                resolved_root in resolved.parents,
                f"artifact escapes the evidence root: {relative}",
            )
            files.append(path)
    return files


def require_revision(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(
        len(text) == 40
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a full lowercase Git revision",
    )
    return text


def require_provenance_revision(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(
        len(text) in (40, 64)
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a 40- or 64-character lowercase hexadecimal identity",
    )
    return text


def require_exact_keys(value: dict[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    missing = sorted(expected_set - actual)
    extra = sorted(actual - expected_set)
    require(not missing and not extra, f"{label} keys differ; missing={missing}, extra={extra}")


def load_contract(path: Path) -> tuple[dict[str, Any], str]:
    contract = require_object(load_json(path), "contract")
    require(contract.get("schemaVersion") == CONTRACT_SCHEMA, "unsupported contract schema")
    require_string(contract.get("gateID"), "contract.gateID")
    baseline = require_object(contract.get("baseline"), "contract.baseline")
    require_revision(baseline.get("sourceRevision"), "contract.baseline.sourceRevision")
    versions = require_list(
        baseline.get("implementationVersions"),
        "contract.baseline.implementationVersions",
    )
    require(len(versions) == 2 and len(set(versions)) == 2, "baseline requires two unique implementation identities")
    for index, version in enumerate(versions):
        require("p05" in require_string(version, f"baseline implementation {index}").lower(), "baseline identity must remain P05")
    capture = require_object(contract.get("capture"), "contract.capture")
    require(capture.get("buildConfiguration") == "Release", "performance capture must use Release")
    require_integer(capture.get("minimumWarmupRuns"), "minimum warmups", 5)
    require_integer(capture.get("minimumMeasuredRuns"), "minimum measured runs", 10)
    for field in (
        "captureSourceSHA256",
        "evaluatorSourceSHA256",
        "runnerSourceSHA256",
    ):
        require_sha256(capture.get(field), f"contract.capture.{field}")
    producer = require_object(
        contract.get("producerEvidence"), "contract.producerEvidence"
    )
    require_exact_keys(
        producer,
        (
            "baselineProducerReceiptRequired",
            "buildRequestArtifactRequired",
            "compilerControlAuditRequired",
            "compilerControlAuditSchema",
            "producerReceiptSchema",
            "sealedInputArtifactRequired",
            "sampleTranscriptSchema",
            "sampleTranscriptsRequired",
            "sampleWorkloadIdentityRequired",
            "stableProducerFactsSchema",
            "stableProducerIdentityRequired",
            "swiftDriverAuditRequired",
            "swiftDriverAuditSchema",
            "swiftDriverWrapperRequired",
            "swiftDriverWrapperSchema",
            "swiftFrontendAuditRequired",
            "swiftFrontendAuditSchema",
            "swiftFrontendShimRequired",
            "swiftFrontendShimSchema",
            "supplementaryOutputMapsRequired",
            "testSummarySchema",
            "xcresultTreeRequired",
        ),
        "contract.producerEvidence",
    )
    require(
        producer["producerReceiptSchema"] == PRODUCER_RECEIPT_SCHEMA,
        "performance producer receipt schema differs",
    )
    require(
        producer["sampleTranscriptSchema"] == SAMPLE_TRANSCRIPT_SCHEMA,
        "performance sample transcript schema differs",
    )
    require(
        producer["compilerControlAuditSchema"] == COMPILER_CONTROL_AUDIT_SCHEMA,
        "performance compiler-control audit schema differs",
    )
    require(
        producer["stableProducerFactsSchema"] == STABLE_PRODUCER_FACTS_SCHEMA,
        "performance stable producer facts schema differs",
    )
    require(
        producer["swiftDriverWrapperSchema"] == SWIFT_DRIVER_WRAPPER_SCHEMA,
        "performance Swift driver wrapper schema differs",
    )
    require(
        producer["swiftDriverAuditSchema"] == SWIFT_DRIVER_JOB_AUDIT_SCHEMA,
        "performance Swift driver audit schema differs",
    )
    require(
        producer["swiftFrontendShimSchema"] == SWIFT_FRONTEND_SHIM_SCHEMA,
        "performance Swift frontend shim schema differs",
    )
    require(
        producer["swiftFrontendAuditSchema"] == SWIFT_FRONTEND_JOB_AUDIT_SCHEMA,
        "performance Swift frontend audit schema differs",
    )
    require(
        producer["testSummarySchema"] == TEST_SUMMARY_SCHEMA,
        "performance test summary schema differs",
    )
    for field in (
        "baselineProducerReceiptRequired",
        "buildRequestArtifactRequired",
        "compilerControlAuditRequired",
        "sealedInputArtifactRequired",
        "sampleTranscriptsRequired",
        "sampleWorkloadIdentityRequired",
        "stableProducerIdentityRequired",
        "swiftDriverAuditRequired",
        "swiftDriverWrapperRequired",
        "swiftFrontendAuditRequired",
        "swiftFrontendShimRequired",
        "supplementaryOutputMapsRequired",
        "xcresultTreeRequired",
    ):
        require_bool(producer[field], f"contract.producerEvidence.{field}")
        require(producer[field], f"contract.producerEvidence.{field} must be true")
    threshold = require_number(
        require_object(contract.get("thresholds"), "contract.thresholds").get(
            "maximumProcessingTimeRatio"
        ),
        "maximum processing-time ratio",
    )
    require(0.0 < threshold <= 0.8, "performance threshold may not exceed 0.80")
    require_integer(
        contract["thresholds"].get("temporalHistoryResidentBudgetBytes"),
        "temporal-history resident budget",
        0,
    )
    measurement = require_object(contract.get("measurement"), "contract.measurement")
    require_integer(measurement.get("bootstrapIterations"), "bootstrap iterations", 1000)
    require_integer(measurement.get("bootstrapSeed"), "bootstrap seed", 0)
    confidence = require_number(measurement.get("confidenceLevel"), "confidence level")
    require(0.5 < confidence < 1.0, "confidence level must be between 0.5 and 1")
    require_bool(
        measurement.get("requireUpperConfidenceBoundAtOrBelowThreshold"),
        "upper-confidence-bound rule",
    )
    workload = require_object(contract.get("workload"), "contract.workload")
    cases = require_list(workload.get("cases"), "contract.workload.cases")
    require(len(cases) >= 4, "the mandatory matrix must contain at least four cases")
    identifiers: list[str] = []
    for index, raw_case in enumerate(cases):
        case = require_object(raw_case, f"workload case {index}")
        require_exact_keys(
            case,
            ("id", "backendID", "targetWidth", "targetHeight"),
            f"workload case {index}",
        )
        identifiers.append(require_string(case["id"], f"workload case {index} id"))
        require_string(case["backendID"], f"workload case {index} backend")
        require_integer(case["targetWidth"], f"workload case {index} width", 1)
        require_integer(case["targetHeight"], f"workload case {index} height", 1)
    require(len(identifiers) == len(set(identifiers)), "workload case IDs must be unique")
    input_contract = require_object(workload.get("input"), "contract.workload.input")
    require_sha256(input_contract.get("sha256"), "input SHA-256")
    require_integer(input_contract.get("byteCount"), "input byte count", 1)
    require_integer(input_contract.get("frameCount"), "input frame count", 1)
    return contract, sha256_file(path)


def verify_artifact_manifest(
    directory: Path, variant: str | None = None
) -> tuple[dict[str, Any], str]:
    manifest_path = directory / "artifact-manifest.json"
    manifest = require_object(load_json(manifest_path), "artifact manifest")
    require(manifest.get("schemaVersion") == ARTIFACT_MANIFEST_SCHEMA, "unsupported artifact-manifest schema")
    entries = require_list(manifest.get("artifacts"), "artifact manifest entries")
    require(len(entries) >= 5, "capture artifact manifest is incomplete")
    seen: set[str] = set()
    for index, raw_entry in enumerate(entries):
        entry = require_object(raw_entry, f"artifact {index}")
        require_exact_keys(entry, ("path", "byteCount", "sha256"), f"artifact {index}")
        relative = require_safe_relative(entry["path"], f"artifact {index} path")
        require(
            relative != "artifact-manifest.json",
            "the artifact manifest may not seal itself",
        )
        require(relative not in seen, f"duplicate artifact path: {relative}")
        seen.add(relative)
        artifact = directory / relative
        require(artifact.is_file() and not artifact.is_symlink(), f"artifact is missing or unsafe: {relative}")
        require_integer(entry["byteCount"], f"artifact {relative} byte count", 0)
        require(artifact.stat().st_size == entry["byteCount"], f"artifact byte count changed: {relative}")
        require_sha256(entry["sha256"], f"artifact {relative} SHA-256")
        require(sha256_file(artifact) == entry["sha256"], f"artifact SHA-256 changed: {relative}")
    required = {
        "capture.json",
        "environment-after.json",
        "environment-before.json",
        "sample-transcripts.json",
        "source-identity.json",
    }
    if variant == "baseline_p05":
        required.update({
            "producer/application-executable",
            "producer/build-request.json",
            "producer/locked-input.mov",
            "producer/producer-receipt.json",
            "producer/result-bundle-manifest.json",
            "producer/swift-driver-effective-argv.log",
            "producer/swiftc",
            "producer/test-summary.json",
            "producer/test-executable",
            "xcodebuild.log",
        })
        require(
            any(path.startswith("producer/baseline.xcresult/") for path in seen),
            "baseline result bundle is empty",
        )
    elif variant == "candidate_p06":
        required.add("packaged-observer.log")
    else:
        require(
            {"xcodebuild.log", "packaged-observer.log"} & seen,
            "capture artifacts omit their capture producer log",
        )
    require(required.issubset(seen), f"capture artifacts are missing: {sorted(required - seen)}")
    actual_files = {
        path.relative_to(directory).as_posix()
        for path in regular_files(directory, excluded=("artifact-manifest.json",))
    }
    require(actual_files == seen, "capture directory has unsealed or missing files")
    return manifest, sha256_file(manifest_path)


def _sample_context(capture: dict[str, Any]) -> dict[str, Any]:
    variant = require_string(capture.get("variant"), "sample transcript variant")
    common = {
        "variant": variant,
        "contractSHA256": require_sha256(
            capture.get("contractSHA256"), "sample transcript contract"
        ),
        "captureSourceSHA256": require_sha256(
            capture.get("captureSourceSHA256"), "sample transcript capture source"
        ),
        "sourceRevision": require_revision(
            capture.get("sourceRevision"), "sample transcript source revision"
        ),
        "sourceTreeSHA256": require_sha256(
            capture.get("sourceTreeSHA256"), "sample transcript source tree"
        ),
    }
    if variant == "baseline_p05":
        common["producerInvocationNonce"] = require_sha256(
            capture.get("producerInvocationNonce"),
            "sample transcript producer nonce",
        )
        common["producerChallenge"] = require_sha256(
            capture.get("producerChallenge"),
            "sample transcript producer challenge",
        )
        common["producerRequestSHA256"] = require_sha256(
            capture.get("producerRequestSHA256"),
            "sample transcript producer request",
        )
    elif variant == "candidate_p06":
        if PACKAGED_CAPTURE_FIELDS.issubset(capture):
            common["evidenceRequestSHA256"] = require_sha256(
                capture.get("evidenceRequestSHA256"),
                "sample transcript evidence request",
            )
            common["observerSourceSHA256"] = require_sha256(
                capture.get("observerSourceSHA256"),
                "sample transcript observer source",
            )
            package = require_object(
                capture.get("packagedCandidateIdentity"),
                "sample transcript packaged candidate identity",
            )
            for field in (
                "applicationArchiveSHA256",
                "applicationExecutableSHA256",
                "runtimeManifestSHA256",
                "runtimeArtifactSetSHA256",
                "sourceTreeIdentitySHA256",
            ):
                common[field] = require_sha256(
                    package.get(field), f"sample transcript package {field}"
                )
        else:
            common["diagnosticFixture"] = True
    else:
        raise EvidenceError(f"unsupported sample transcript variant: {variant}")
    return common


def make_sample_transcript_document(capture: dict[str, Any]) -> dict[str, Any]:
    context = _sample_context(capture)
    capture_semantic_sha = sha256_bytes(canonical_json(capture))
    context_sha = sha256_bytes(canonical_json(context))
    predecessor = "0" * SHA256_LENGTH
    rows: list[dict[str, Any]] = []
    cases = sorted(
        require_list(capture.get("cases"), "sample transcript cases"),
        key=lambda value: require_string(
            require_object(value, "sample transcript case").get("id"),
            "sample transcript case ID",
        ),
    )
    for raw_case in cases:
        case = require_object(raw_case, "sample transcript case")
        case_identity = {
            "caseID": require_string(case.get("id"), "sample transcript case ID"),
            "backendID": require_string(
                case.get("backendID"), "sample transcript backend"
            ),
            "targetWidth": require_integer(
                case.get("targetWidth"), "sample transcript target width", 1
            ),
            "targetHeight": require_integer(
                case.get("targetHeight"), "sample transcript target height", 1
            ),
        }
        for sample_kind, field in (
            ("engine", "engineRuns"),
            ("end_to_end", "endToEndRuns"),
        ):
            samples = sorted(
                require_list(case.get(field), f"sample transcript {field}"),
                key=lambda value: require_integer(
                    require_object(value, f"sample transcript {field} row").get(
                        "sampleIndex"
                    ),
                    f"sample transcript {field} sample index",
                    0,
                ),
            )
            for raw_sample in samples:
                sample = require_object(
                    raw_sample, f"sample transcript {sample_kind} row"
                )
                payload = {
                    **case_identity,
                    "sampleKind": sample_kind,
                    "sampleIndex": require_integer(
                        sample.get("sampleIndex"),
                        f"sample transcript {sample_kind} index",
                        0,
                    ),
                    "sample": sample,
                    "captureSemanticSHA256": capture_semantic_sha,
                    "producerContextSHA256": context_sha,
                    "predecessorSHA256": predecessor,
                }
                transcript_sha = sha256_bytes(
                    SAMPLE_ROW_DOMAIN + canonical_json(payload)
                )
                rows.append({**payload, "transcriptSHA256": transcript_sha})
                predecessor = transcript_sha
    measurement_unsigned = {
        "variant": context["variant"],
        "contractSHA256": context["contractSHA256"],
        "captureSourceSHA256": context["captureSourceSHA256"],
        "sourceRevision": context["sourceRevision"],
        "sourceTreeSHA256": context["sourceTreeSHA256"],
        "warmupCount": require_integer(
            capture.get("warmupCount"), "sample measurement warmup count", 1
        ),
        "sampleCount": require_integer(
            capture.get("sampleCount"), "sample measurement sample count", 1
        ),
        "input": require_object(capture.get("input"), "sample measurement input"),
        "cases": cases,
    }
    measurement_set_sha = sha256_bytes(
        SAMPLE_MEASUREMENT_DOMAIN + canonical_json(measurement_unsigned)
    )
    unsigned = {
        "schemaVersion": SAMPLE_TRANSCRIPT_SCHEMA,
        "variant": context["variant"],
        "captureSemanticSHA256": capture_semantic_sha,
        "producerContext": context,
        "producerContextSHA256": context_sha,
        "sampleMeasurementSetSHA256": measurement_set_sha,
        "transcriptCount": len(rows),
        "finalTranscriptSHA256": predecessor,
        "transcripts": rows,
    }
    return {
        **unsigned,
        "sampleTranscriptSetSHA256": sha256_bytes(
            SAMPLE_SET_DOMAIN + canonical_json(unsigned)
        ),
    }


def sample_measurement_set_sha256(capture: dict[str, Any]) -> str:
    return require_sha256(
        make_sample_transcript_document(capture)["sampleMeasurementSetSHA256"],
        "sample measurement set SHA-256",
    )


def sample_workload_identity_sha256(capture: dict[str, Any]) -> str:
    workload_cases: list[dict[str, Any]] = []
    for case_index, raw_case in enumerate(
        require_list(capture.get("cases"), "sample workload cases")
    ):
        case = require_object(raw_case, f"sample workload case {case_index}")
        require_exact_keys(
            case,
            (
                "id",
                "backendID",
                "targetWidth",
                "targetHeight",
                "request",
                "engineRuns",
                "endToEndRuns",
            ),
            f"sample workload case {case_index}",
        )
        request = require_object(
            case["request"], f"sample workload case {case_index} request"
        )
        require_exact_keys(
            request,
            PERFORMANCE_REQUEST_FIELDS,
            f"sample workload case {case_index} request",
        )
        normalized_request = {
            "codec": require_string(
                request["codec"], f"sample workload case {case_index} codec"
            ),
            "fileType": require_string(
                request["fileType"], f"sample workload case {case_index} file type"
            ),
            "preserveAudio": require_bool(
                request["preserveAudio"],
                f"sample workload case {case_index} preserve audio",
            ),
            "overwriteExistingFile": require_bool(
                request["overwriteExistingFile"],
                f"sample workload case {case_index} overwrite output",
            ),
        }
        topology: list[dict[str, Any]] = []
        for sample_index, raw_sample in enumerate(
            require_list(
                case["engineRuns"],
                f"sample workload case {case_index} engine samples",
            )
        ):
            sample = require_object(
                raw_sample,
                f"sample workload case {case_index} engine sample {sample_index}",
            )
            require_exact_keys(
                sample,
                ("sampleIndex", "frameMilliseconds", "processedFrameCount"),
                f"sample workload case {case_index} engine sample {sample_index}",
            )
            topology.append({
                "sampleKind": "engine",
                "sampleIndex": require_integer(
                    sample["sampleIndex"],
                    f"sample workload case {case_index} engine sample index",
                    0,
                ),
                "processedFrameCount": require_integer(
                    sample["processedFrameCount"],
                    f"sample workload case {case_index} engine processed frames",
                    0,
                ),
                "frameCount": len(require_list(
                    sample["frameMilliseconds"],
                    f"sample workload case {case_index} engine frame topology",
                )),
            })
        for sample_index, raw_sample in enumerate(
            require_list(
                case["endToEndRuns"],
                f"sample workload case {case_index} end-to-end samples",
            )
        ):
            sample = require_object(
                raw_sample,
                f"sample workload case {case_index} end-to-end sample {sample_index}",
            )
            require_exact_keys(
                sample,
                (
                    "sampleIndex",
                    "wallMilliseconds",
                    "peakResidentBytes",
                    "processedFrameCount",
                    "verification",
                ),
                f"sample workload case {case_index} end-to-end sample {sample_index}",
            )
            verification = require_object(
                sample["verification"],
                f"sample workload case {case_index} verification {sample_index}",
            )
            require_exact_keys(
                verification,
                VERIFICATION_BOOLEAN_FIELDS + VERIFICATION_HASH_FIELDS,
                f"sample workload case {case_index} verification {sample_index}",
            )
            topology.append({
                "sampleKind": "end_to_end",
                "sampleIndex": require_integer(
                    sample["sampleIndex"],
                    f"sample workload case {case_index} end-to-end sample index",
                    0,
                ),
                "processedFrameCount": require_integer(
                    sample["processedFrameCount"],
                    f"sample workload case {case_index} end-to-end processed frames",
                    0,
                ),
                "verification": {
                    **{
                        field: require_bool(
                            verification[field],
                            f"sample workload case {case_index} verification {field}",
                        )
                        for field in VERIFICATION_BOOLEAN_FIELDS
                    },
                    **{
                        field: require_sha256(
                            verification[field],
                            f"sample workload case {case_index} verification {field}",
                        )
                        for field in VERIFICATION_HASH_FIELDS
                    },
                },
            })
        workload_cases.append({
            "id": require_string(case["id"], f"sample workload case {case_index} ID"),
            "backendID": require_string(
                case["backendID"], f"sample workload case {case_index} backend"
            ),
            "targetWidth": require_integer(
                case["targetWidth"], f"sample workload case {case_index} width", 1
            ),
            "targetHeight": require_integer(
                case["targetHeight"], f"sample workload case {case_index} height", 1
            ),
            "request": normalized_request,
            "sampleTopology": topology,
        })
    workload = {
        "variant": require_string(capture.get("variant"), "sample workload variant"),
        "warmupCount": require_integer(
            capture.get("warmupCount"), "sample workload warmup count", 1
        ),
        "sampleCount": require_integer(
            capture.get("sampleCount"), "sample workload sample count", 1
        ),
        "input": require_object(capture.get("input"), "sample workload input"),
        "cases": workload_cases,
    }
    return sha256_bytes(SAMPLE_WORKLOAD_DOMAIN + canonical_json(workload))


def write_sample_transcripts(capture_path: Path, output_path: Path) -> dict[str, Any]:
    capture = require_object(load_json(capture_path), "performance capture")
    document = make_sample_transcript_document(capture)
    write_json(output_path, document)
    return document


def validate_sample_transcripts(
    directory: Path, capture: dict[str, Any]
) -> tuple[str, int]:
    path = directory / "sample-transcripts.json"
    observed = require_object(load_json(path), "sample transcripts")
    expected = make_sample_transcript_document(capture)
    require(
        canonical_json(observed) == canonical_json(expected),
        "sample transcripts differ from the exact captured samples",
    )
    return (
        require_sha256(
            observed.get("sampleTranscriptSetSHA256"),
            "sample transcript set SHA-256",
        ),
        require_integer(
            observed.get("transcriptCount"), "sample transcript count", 1
        ),
    )


def _result_bundle_manifest(directory: Path, bundle: Path) -> dict[str, Any]:
    expected = directory / "producer" / "baseline.xcresult"
    require(
        bundle.resolve(strict=True) == expected.resolve(strict=True),
        "result bundle is not in the canonical evidence location",
    )
    files = [descriptor(path, directory) for path in regular_files(bundle)]
    require(files, "result bundle is empty")
    unsigned = {
        "schemaVersion": RESULT_BUNDLE_MANIFEST_SCHEMA,
        "rootPath": "producer/baseline.xcresult",
        "fileCount": len(files),
        "byteCount": sum(entry["byteCount"] for entry in files),
        "artifacts": files,
    }
    return {
        **unsigned,
        "treeSHA256": sha256_bytes(
            RESULT_BUNDLE_TREE_DOMAIN + canonical_json(unsigned)
        ),
    }


def _validate_result_bundle(
    directory: Path, value: Any
) -> tuple[str, int, int]:
    result = require_object(value, "producer result bundle")
    require_exact_keys(
        result,
        (
            "path",
            "originalPath",
            "fileCount",
            "byteCount",
            "treeSHA256",
            "manifestArtifact",
        ),
        "producer result bundle",
    )
    require(
        require_safe_relative(result["path"], "producer result bundle path")
        == "producer/baseline.xcresult",
        "producer result bundle path differs",
    )
    require(
        Path(require_string(
            result["originalPath"], "producer result bundle original path"
        )).is_absolute(),
        "producer result bundle original path must be absolute",
    )
    manifest_path, _ = validate_descriptor(
        directory, result["manifestArtifact"], "producer result bundle manifest"
    )
    require(
        manifest_path == (directory / "producer/result-bundle-manifest.json").resolve(),
        "producer result-bundle manifest path differs",
    )
    observed = require_object(load_json(manifest_path), "result-bundle manifest")
    expected = _result_bundle_manifest(
        directory, directory / "producer/baseline.xcresult"
    )
    require(
        canonical_json(observed) == canonical_json(expected),
        "result-bundle tree differs from its manifest",
    )
    count = require_integer(result["fileCount"], "result-bundle file count", 1)
    byte_count = require_integer(
        result["byteCount"], "result-bundle byte count", 1
    )
    tree_sha = require_sha256(result["treeSHA256"], "result-bundle tree SHA-256")
    require(count == expected["fileCount"], "result-bundle file count differs")
    require(byte_count == expected["byteCount"], "result-bundle byte count differs")
    require(tree_sha == expected["treeSHA256"], "result-bundle tree identity differs")
    return tree_sha, count, byte_count


BASELINE_BUILD_ENVIRONMENT_KEYS = (
    "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR",
    "MIRMIR_V4_PERFORMANCE_INPUT",
    "MIRMIR_V4_PERFORMANCE_VARIANT",
    "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256",
    "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256",
    "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256",
    "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION",
    "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256",
    "MIRMIR_V4_PERFORMANCE_WARMUPS",
    "MIRMIR_V4_PERFORMANCE_SAMPLES",
    "MIRMIR_V4_PERFORMANCE_PRODUCER_NONCE",
    "MIRMIR_V4_PERFORMANCE_PRODUCER_CHALLENGE",
    "SWIFT_DETERMINISTIC_HASHING",
    "SWIFTC_MAXIMUM_DETERMINISM",
    "TMPDIR",
)
BASELINE_TEST_IDENTIFIER = (
    "MirmirTests/DeterministicEngineV4PerformanceCaptureTests/"
    "testCaptureSameScopePerformanceWhenRequested"
)


def _expected_baseline_build_command(receipt: dict[str, Any]) -> list[str]:
    environment = require_object(
        receipt.get("buildEnvironment"), "producer build environment"
    )
    require_exact_keys(
        environment, BASELINE_BUILD_ENVIRONMENT_KEYS, "producer build environment"
    )
    for key in BASELINE_BUILD_ENVIRONMENT_KEYS:
        require_string(environment[key], f"producer build environment {key}")
    working_directory = require_string(
        receipt.get("workingDirectory"), "producer working directory"
    )
    derived_data = require_string(
        receipt.get("derivedDataPath"), "producer derived-data path"
    )
    require(
        working_directory == CANONICAL_SOURCE_ROOT,
        "producer working directory is not the fixed canonical source root",
    )
    require(
        derived_data == CANONICAL_DERIVED_DATA,
        "producer derived-data path is not the fixed canonical build root",
    )
    require(
        environment["TMPDIR"] == CANONICAL_SWIFT_TEMPORARY,
        "producer temporary directory is not the fixed canonical root",
    )
    source_alias = working_directory.replace("/private/tmp/", "/tmp/", 1)
    derived_alias = derived_data.replace("/private/tmp/", "/tmp/", 1)
    return [
        "xcodebuild",
        "-jobs",
        "1",
        "-project",
        "Mirmir.xcodeproj",
        "-scheme",
        "Mirmir",
        "-configuration",
        "Release",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        derived_data,
        "-resultBundlePath",
        require_string(
            receipt.get("captureDirectory"), "producer capture directory"
        ) + "/producer/baseline.xcresult",
        "-parallel-testing-enabled",
        "NO",
        "test",
        f"-only-testing:{BASELINE_TEST_IDENTIFIER}",
        "CODE_SIGNING_ALLOWED=NO",
        "ENABLE_TESTABILITY=YES",
        "ONLY_ACTIVE_ARCH=YES",
        f"SWIFT_EXEC={CANONICAL_SWIFT_WRAPPER}",
        "SWIFT_USE_INTEGRATED_DRIVER=NO",
        "SWIFT_COMPILATION_MODE=wholemodule",
        "SWIFT_ENABLE_BATCH_MODE=NO",
        "SWIFT_ENABLE_EXPLICIT_MODULES=NO",
        "SWIFT_EAGER_MODULE_EMISSION_IN_WMO=NO",
        "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO",
        "SWIFT_USE_PARALLEL_WMO_TARGETS=NO",
        "SWIFT_WHOLE_MODULE_OPTIMIZATION=YES",
        "SWIFT_NUM_THREADS=1",
        f"CLANG_MODULE_CACHE_PATH={CANONICAL_MODULE_CACHE}",
        f"SWIFT_MODULE_CACHE_PATH={CANONICAL_MODULE_CACHE}",
        f"MODULE_CACHE_DIR={CANONICAL_MODULE_CACHE}",
        "OTHER_SWIFT_FLAGS=$(inherited) -j 1 -num-threads 1 -file-prefix-map "
        + working_directory
        + "=/mirmir-performance-p05 -debug-prefix-map "
        + working_directory
        + "=/mirmir-performance-p05 -file-prefix-map "
        + source_alias
        + "=/mirmir-performance-p05 -debug-prefix-map "
        + source_alias
        + "=/mirmir-performance-p05 -file-prefix-map "
        + derived_data
        + "=/mirmir-performance-derived -debug-prefix-map "
        + derived_data
        + "=/mirmir-performance-derived -file-prefix-map "
        + derived_alias
        + "=/mirmir-performance-derived -debug-prefix-map "
        + derived_alias
        + "=/mirmir-performance-derived -Xllvm -rng-seed=1",
        "OTHER_CFLAGS=$(inherited) -ffile-prefix-map="
        + working_directory
        + "=/mirmir-performance-p05 -fdebug-prefix-map="
        + working_directory
        + "=/mirmir-performance-p05 -ffile-prefix-map="
        + source_alias
        + "=/mirmir-performance-p05 -fdebug-prefix-map="
        + source_alias
        + "=/mirmir-performance-p05 -ffile-prefix-map="
        + derived_data
        + "=/mirmir-performance-derived -fdebug-prefix-map="
        + derived_data
        + "=/mirmir-performance-derived -ffile-prefix-map="
        + derived_alias
        + "=/mirmir-performance-derived -fdebug-prefix-map="
        + derived_alias
        + "=/mirmir-performance-derived",
        *[f"{key}={environment[key]}" for key in BASELINE_BUILD_ENVIRONMENT_KEYS],
    ]


def _private_tmp_alias(path: str) -> str:
    require(path.startswith("/private/tmp/"), "canonical path is outside /private/tmp")
    return path.removeprefix("/private")


def _swift_driver_job_marker(module_name: str) -> str:
    require(
        module_name in SWIFT_DRIVER_REQUIRED_MODULES,
        "Swift driver audit module is outside policy",
    )
    return (
        f"{SWIFT_DRIVER_JOB_AUDIT_PREFIX} module={module_name} "
        f"target={SWIFT_DRIVER_REQUIRED_TARGET} "
        "jobOptionCount=1 terminal=-j,1 "
        "numThreadsCount=1 numThreads=1 "
        "llvmRNGSeedCount=1 llvmRNGSeed=1 "
        "projectedFrontendJobCount=1 "
        "projectedNumThreadsCount=1 projectedNumThreads=1 "
        "projectedLLVMRNGSeedCount=1 projectedLLVMRNGSeed=1 "
        "prefixMapsVerified=1 moduleCachePathCount=1 "
        "scannerModuleCachePathCount=0 sdkModuleCachePathCount=0 "
        "driverWorkingDirectoryCount=1 frontendWorkingDirectoryCount=0 "
        "frontendFileCompilationDirectoryCount=1 "
        "frontendXCCWorkingDirectoryCount=1 "
        "frontendShimCount=1 saveTempsCount=1 "
        "projectedSupplementaryMapCount=1 projectedOutputPathsVerified=1 "
        "explicitModulesDisabled=1 moduleCachesVerified=1 environmentForced=1"
    )


SWIFT_DRIVER_JOB_AUDIT_MARKERS = tuple(
    _swift_driver_job_marker(module_name)
    for module_name in SWIFT_DRIVER_REQUIRED_MODULES
)


def swift_driver_wrapper_bytes(
    underlying_swiftc: Path,
    audit_path: Path,
    frontend_shim_path: Path = Path(CANONICAL_SWIFT_FRONTEND_SHIM),
    temporary_directory: Path = Path(CANONICAL_SWIFT_TEMPORARY),
) -> bytes:
    require(
        underlying_swiftc.is_absolute()
        and audit_path.is_absolute()
        and frontend_shim_path.is_absolute()
        and temporary_directory.is_absolute(),
        "Swift driver wrapper paths must be absolute",
    )
    configuration = {
        "underlying": str(underlying_swiftc),
        "audit": str(audit_path),
        "frontendShim": str(frontend_shim_path),
        "temporaryDirectory": str(temporary_directory),
        "canonicalRoot": CANONICAL_PRODUCER_ROOT,
        "canonicalDerivedData": CANONICAL_DERIVED_DATA,
        "canonicalWorkingDirectory": _private_tmp_alias(CANONICAL_SOURCE_ROOT),
        "requiredModules": list(SWIFT_DRIVER_REQUIRED_MODULES),
        "requiredTarget": SWIFT_DRIVER_REQUIRED_TARGET,
        "markerPrefix": SWIFT_DRIVER_JOB_AUDIT_PREFIX,
        "filePrefixMaps": [
            CANONICAL_SOURCE_ROOT + "=/mirmir-performance-p05",
            _private_tmp_alias(CANONICAL_SOURCE_ROOT) + "=/mirmir-performance-p05",
            CANONICAL_DERIVED_DATA + "=/mirmir-performance-derived",
            _private_tmp_alias(CANONICAL_DERIVED_DATA)
            + "=/mirmir-performance-derived",
        ],
    }
    prefix = "#!/usr/bin/python3\n" + "CONFIG=" + repr(configuration) + "\n"
    body = r'''import fcntl
import os
import json
import shlex
import stat
import subprocess
import sys

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(64)

def pairs(arguments, flag):
    values = []
    index = 0
    while index < len(arguments):
        if arguments[index] == flag:
            if index + 1 >= len(arguments):
                fail(f"missing {flag} value")
            values.append(arguments[index + 1])
            index += 2
        else:
            index += 1
    return values

def direct_pairs(arguments, flag):
    values = []
    index = 0
    while index < len(arguments):
        if arguments[index] == "-Xcc":
            if index + 1 >= len(arguments):
                fail("missing -Xcc value")
            index += 2
        elif arguments[index] == flag:
            if index + 1 >= len(arguments):
                fail(f"missing {flag} value")
            values.append(arguments[index + 1])
            index += 2
        else:
            index += 1
    return values

def under_root(path, roots):
    if not isinstance(path, str) or not path.startswith("/") or ".." in path.split("/"):
        return False
    normalized = os.path.normpath(path)
    return any(normalized == root or normalized.startswith(root + "/") for root in roots)

def validate_common_controls(arguments, projected):
    pair_reader = direct_pairs if projected else pairs
    threads = pair_reader(arguments, "-num-threads")
    if threads != ["1"] or any(value.startswith("-num-threads=") for value in arguments):
        fail("Swift frontend thread-count control is missing, duplicated, or substituted")
    rng = []
    index = 0
    while index < len(arguments):
        if arguments[index] == "-Xllvm":
            if index + 1 >= len(arguments):
                fail("missing Swift LLVM option value")
            if arguments[index + 1].startswith("-rng-seed"):
                rng.extend(arguments[index:index + 2])
            index += 2
        else:
            if arguments[index].startswith("-rng-seed"):
                fail("Swift RNG seed lacks -Xllvm")
            index += 1
    if rng != ["-Xllvm", "-rng-seed=1"]:
        fail("Swift LLVM RNG-seed control is missing, duplicated, or substituted")
    targets = pair_reader(arguments, "-target")
    modules = pair_reader(arguments, "-module-name")
    if targets != [CONFIG["requiredTarget"]]:
        fail("Swift target control is missing, duplicated, or substituted")
    if len(modules) != 1 or modules[0] not in CONFIG["requiredModules"]:
        fail("Swift module control is missing, duplicated, or substituted")
    if pair_reader(arguments, "-file-prefix-map") != CONFIG["filePrefixMaps"]:
        fail("Swift file-prefix maps differ")
    if pair_reader(arguments, "-debug-prefix-map") != CONFIG["filePrefixMaps"]:
        fail("Swift debug-prefix maps differ")
    expected_cache_flags = {
        "-module-cache-path": [CONFIG["canonicalRoot"] + "/ModuleCache.noindex"],
        "-clang-scanner-module-cache-path": [],
        "-sdk-module-cache-path": [],
    }
    for flag, expected in expected_cache_flags.items():
        values = pair_reader(arguments, flag)
        if values != expected:
            fail(f"Swift explicit-modules-disabled cache policy differs for {flag}")
    return modules[0]

def validate_driver_controls(arguments):
    module_name = validate_common_controls(arguments, False)
    if pairs(arguments, "-working-directory") != [CONFIG["canonicalWorkingDirectory"]]:
        fail("Swift driver working-directory control is missing, duplicated, or substituted")
    if pairs(arguments, "-driver-use-frontend-path") != [CONFIG["frontendShim"]]:
        fail("Swift fixed frontend shim control is missing, duplicated, or substituted")
    if arguments.count("-save-temps") != 1:
        fail("Swift save-temps control is missing or duplicated")
    derived_roots = [
        CONFIG["canonicalDerivedData"],
        CONFIG["canonicalDerivedData"].replace("/private/tmp/", "/tmp/", 1),
    ]
    for flag in ("-output-file-map", "-emit-module-path", "-emit-objc-header-path"):
        values = pairs(arguments, flag)
        if len(values) > 1 or any(not under_root(value, derived_roots) for value in values):
            fail(f"Swift driver output path policy differs for {flag}")
    response_files = [value[1:] for value in arguments if value.startswith("@")]
    if len(response_files) != 1 or not under_root(response_files[0], derived_roots):
        fail("Swift driver source file-list path differs")
    return module_name

def validate_projected_controls(arguments):
    module_name = validate_common_controls(arguments, True)
    if direct_pairs(arguments, "-working-directory"):
        fail("projected Swift frontend retained a direct working-directory control")
    if direct_pairs(arguments, "-file-compilation-dir") != [CONFIG["canonicalWorkingDirectory"]]:
        fail("projected Swift frontend file-compilation-dir differs")
    xcc = [arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value == "-Xcc"]
    expected_xcc_cwd = ["-working-directory", CONFIG["canonicalWorkingDirectory"]]
    if sum(xcc[index:index + 2] == expected_xcc_cwd for index in range(len(xcc) - 1)) != 1:
        fail("projected Swift frontend Xcc working directory differs")
    if any(value == "-j" or value.startswith("-j") for value in arguments):
        fail("projected Swift frontend retains a driver job option")
    if direct_pairs(arguments, "-driver-use-frontend-path") or "-save-temps" in arguments:
        fail("projected Swift frontend retained a driver-only control")
    maps = direct_pairs(arguments, "-supplementary-output-file-map")
    if len(maps) != 1 or not under_root(maps[0], [CONFIG["temporaryDirectory"]]):
        fail("projected Swift supplementary-output map path differs")
    try:
        metadata = os.lstat(maps[0])
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            fail("projected Swift supplementary-output map is unsafe")
        with open(maps[0], "rb") as stream:
            map_bytes = stream.read()
        parsed = json.loads(map_bytes)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"projected Swift supplementary-output map is unreadable: {error}")
    if not isinstance(parsed, dict) or len(parsed) != 1:
        fail("projected Swift supplementary-output map shape differs")
    derived_roots = [
        CONFIG["canonicalDerivedData"],
        CONFIG["canonicalDerivedData"].replace("/private/tmp/", "/tmp/", 1),
    ]
    for outputs in parsed.values():
        if not isinstance(outputs, dict) or not outputs:
            fail("projected Swift supplementary outputs are empty")
        if any(not under_root(path, derived_roots) for path in outputs.values()):
            fail("projected Swift supplementary output escapes fixed DerivedData")
    object_outputs = direct_pairs(arguments, "-o")
    if not object_outputs or any(not under_root(path, derived_roots) for path in object_outputs):
        fail("projected Swift object output paths differ")
    return module_name

environment = dict(os.environ)
environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
environment["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
environment["TMPDIR"] = CONFIG["temporaryDirectory"]
arguments = sys.argv[1:]
effective = []
saw_job = False
module_values = pairs(arguments, "-module-name")
is_compile_driver = (
    len(module_values) == 1
    and module_values[0] in CONFIG["requiredModules"]
    and any(
        action in arguments
        for action in ("-c", "-emit-module", "-emit-library", "-emit-executable")
    )
)
index = 0
while index < len(arguments):
    argument = arguments[index]
    if argument == "-j":
        if index + 1 >= len(arguments) or not arguments[index + 1].isdigit():
            fail("invalid separated Swift driver -j value")
        saw_job = True
        index += 2
    elif argument.startswith("-j"):
        if len(argument) == 2 or not argument[2:].isdigit():
            fail("invalid joined Swift driver -j value")
        saw_job = True
        index += 1
    else:
        effective.append(argument)
        index += 1

if is_compile_driver and not saw_job:
    fail("Swift compile driver omitted its incoming job-count control")
if saw_job:
    if pairs(effective, "-driver-use-frontend-path"):
        fail("incoming Swift driver supplied a frontend override")
    if "-save-temps" in effective:
        fail("incoming Swift driver supplied save-temps")
    effective.extend([
        "-driver-use-frontend-path", CONFIG["frontendShim"], "-save-temps"
    ])
    effective.extend(["-j", "1"])
    if effective[-2:] != ["-j", "1"]:
        fail("terminal Swift driver job control differs")
    module_name = validate_driver_controls(effective)
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    environment["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
    try:
        projection = subprocess.run(
            ["swiftc", *effective, "-driver-print-jobs"],
            executable=CONFIG["underlying"],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except OSError as error:
        fail(f"Swift driver job projection failed: {error}")
    if projection.returncode != 0:
        fail("Swift driver job projection failed: " + projection.stderr[-2000:])
    lines = [line for line in projection.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        fail("Swift driver projected an unsupported frontend job count")
    try:
        projected = shlex.split(lines[0])
    except ValueError as error:
        fail(f"projected Swift frontend command is invalid: {error}")
    if len(projected) < 2 or projected[0] != CONFIG["frontendShim"] or projected[1] != "-frontend":
        fail("Swift driver projected another frontend executable")
    projected_module = validate_projected_controls(projected[1:])
    if projected_module != module_name:
        fail("projected Swift module differs from the driver module")
    marker = (
        f'{CONFIG["markerPrefix"]} module={module_name} '
        f'target={CONFIG["requiredTarget"]} '
        'jobOptionCount=1 terminal=-j,1 '
        'numThreadsCount=1 numThreads=1 '
        'llvmRNGSeedCount=1 llvmRNGSeed=1 '
        'projectedFrontendJobCount=1 '
        'projectedNumThreadsCount=1 projectedNumThreads=1 '
        'projectedLLVMRNGSeedCount=1 projectedLLVMRNGSeed=1 '
        'prefixMapsVerified=1 moduleCachePathCount=1 '
        'scannerModuleCachePathCount=0 sdkModuleCachePathCount=0 '
        'driverWorkingDirectoryCount=1 frontendWorkingDirectoryCount=0 '
        'frontendFileCompilationDirectoryCount=1 '
        'frontendXCCWorkingDirectoryCount=1 '
        'frontendShimCount=1 saveTempsCount=1 '
        'projectedSupplementaryMapCount=1 projectedOutputPathsVerified=1 '
        'explicitModulesDisabled=1 moduleCachesVerified=1 environmentForced=1\n'
    ).encode("utf-8")
    try:
        metadata = os.lstat(CONFIG["audit"])
        if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
            fail("Swift driver audit file has an unsupported kind or mode")
        flags = os.O_WRONLY | os.O_APPEND
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(CONFIG["audit"], flags)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            if os.write(descriptor, marker) != len(marker):
                fail("Swift driver audit marker write was incomplete")
        finally:
            os.close(descriptor)
    except OSError as error:
        fail(f"Swift driver audit write failed: {error}")

environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
environment["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
environment["TMPDIR"] = CONFIG["temporaryDirectory"]
try:
    os.execve(CONFIG["underlying"], ["swiftc", *effective], environment)
except OSError as error:
    fail(f"Swift compiler launch failed: {error}")
'''
    return (prefix + body).encode("utf-8")


def swift_frontend_shim_bytes(
    underlying_frontend: Path,
    audit_path: Path,
    temporary_directory: Path = Path(CANONICAL_SWIFT_TEMPORARY),
    supplementary_directory: Path = Path(CANONICAL_SWIFT_SUPPLEMENTARY_MAPS),
) -> bytes:
    require(
        underlying_frontend.is_absolute()
        and audit_path.is_absolute()
        and temporary_directory.is_absolute()
        and supplementary_directory.is_absolute(),
        "Swift frontend shim paths must be absolute",
    )
    configuration = {
        "underlying": str(underlying_frontend),
        "audit": str(audit_path),
        "temporaryDirectory": str(temporary_directory),
        "supplementaryDirectory": str(supplementary_directory),
        "canonicalSource": CANONICAL_SOURCE_ROOT,
        "canonicalDerivedData": CANONICAL_DERIVED_DATA,
        "canonicalModuleCache": CANONICAL_MODULE_CACHE,
        "canonicalWorkingDirectory": _private_tmp_alias(CANONICAL_SOURCE_ROOT),
        "requiredModules": list(SWIFT_DRIVER_REQUIRED_MODULES),
        "requiredTarget": SWIFT_DRIVER_REQUIRED_TARGET,
        "auditSchema": SWIFT_FRONTEND_JOB_AUDIT_SCHEMA,
        "auditDomain": SWIFT_FRONTEND_JOB_AUDIT_DOMAIN.decode("utf-8"),
        "filePrefixMaps": [
            CANONICAL_SOURCE_ROOT + "=/mirmir-performance-p05",
            _private_tmp_alias(CANONICAL_SOURCE_ROOT) + "=/mirmir-performance-p05",
            CANONICAL_DERIVED_DATA + "=/mirmir-performance-derived",
            _private_tmp_alias(CANONICAL_DERIVED_DATA)
            + "=/mirmir-performance-derived",
        ],
    }
    prefix = "#!/usr/bin/python3\n" + "CONFIG=" + repr(configuration) + "\n"
    body = r'''import fcntl
import hashlib
import json
import os
import re
import stat
import sys

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(64)

def direct_pairs(arguments, flag):
    values = []
    index = 0
    while index < len(arguments):
        if arguments[index] == "-Xcc":
            if index + 1 >= len(arguments):
                fail("missing -Xcc value")
            index += 2
        elif arguments[index] == flag:
            if index + 1 >= len(arguments):
                fail(f"missing {flag} value")
            values.append(arguments[index + 1])
            index += 2
        else:
            index += 1
    return values

def under_root(path, roots):
    if not isinstance(path, str) or not path.startswith("/") or ".." in path.split("/"):
        return False
    normalized = os.path.normpath(path)
    return any(normalized == root or normalized.startswith(root + "/") for root in roots)

def reject_duplicate_pairs(pairs):
    value = {}
    for key, child in pairs:
        if key in value:
            fail(f"duplicate supplementary-output map key: {key}")
        value[key] = child
    return value

def canonical_json(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")

def sha256_bytes(raw):
    return hashlib.sha256(raw).hexdigest()

def read_owned_regular(path):
    try:
        path_metadata = os.lstat(path)
    except OSError as error:
        fail(f"cannot inspect Swift supplementary-output map: {error}")
    expected_identity = (
        path_metadata.st_dev,
        path_metadata.st_ino,
        path_metadata.st_uid,
        path_metadata.st_nlink,
        stat.S_IMODE(path_metadata.st_mode),
        path_metadata.st_size,
    )
    if (
        not stat.S_ISREG(path_metadata.st_mode)
        or stat.S_ISLNK(path_metadata.st_mode)
        or path_metadata.st_uid != os.getuid()
        or path_metadata.st_nlink != 1
        or stat.S_IMODE(path_metadata.st_mode) != 0o644
    ):
        fail("Swift supplementary-output map owner, mode, or link count differs")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        try:
            metadata = os.fstat(descriptor)
            opened_identity = (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_uid,
                metadata.st_nlink,
                stat.S_IMODE(metadata.st_mode),
                metadata.st_size,
            )
            if opened_identity != expected_identity:
                fail("Swift supplementary-output map changed before open")
            if metadata.st_size <= 0 or metadata.st_size > 1024 * 1024:
                fail("Swift supplementary-output map size is outside policy")
            chunks = []
            while True:
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            post_metadata = os.fstat(descriptor)
            post_identity = (
                post_metadata.st_dev,
                post_metadata.st_ino,
                post_metadata.st_uid,
                post_metadata.st_nlink,
                stat.S_IMODE(post_metadata.st_mode),
                post_metadata.st_size,
            )
            if post_identity != expected_identity:
                fail("Swift supplementary-output map changed during read")
            try:
                final_metadata = os.lstat(path)
            except OSError as error:
                fail(f"cannot re-inspect Swift supplementary-output map: {error}")
            final_identity = (
                final_metadata.st_dev,
                final_metadata.st_ino,
                final_metadata.st_uid,
                final_metadata.st_nlink,
                stat.S_IMODE(final_metadata.st_mode),
                final_metadata.st_size,
            )
            if final_identity != expected_identity:
                fail("Swift supplementary-output map path changed during read")
            return b"".join(chunks), {
                "ownerUID": metadata.st_uid,
                "unixMode": stat.S_IMODE(metadata.st_mode),
                "linkCount": metadata.st_nlink,
            }
        finally:
            os.close(descriptor)
    except OSError as error:
        fail(f"cannot read Swift supplementary-output map: {error}")

def write_locked(path, raw):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            written = 0
            while written < len(raw):
                count = os.write(descriptor, raw[written:])
                if count <= 0:
                    fail("canonical supplementary-output map write was incomplete")
                written += count
            os.fsync(descriptor)
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_size != len(raw):
                fail("canonical supplementary-output map kind, mode, or size differs")
        finally:
            os.close(descriptor)
    except OSError as error:
        fail(f"cannot create canonical supplementary-output map: {error}")

arguments = sys.argv[1:]
if not arguments or arguments[0] != "-frontend":
    fail("Swift frontend shim received a non-frontend invocation")
if os.environ.get("SWIFT_DETERMINISTIC_HASHING") != "1" or os.environ.get("SWIFTC_MAXIMUM_DETERMINISM") != "1":
    fail("Swift frontend deterministic environment differs")
if os.environ.get("TMPDIR") != CONFIG["temporaryDirectory"]:
    fail("Swift frontend temporary directory differs")
if any(value == "-j" or value.startswith("-j") for value in arguments):
    fail("Swift frontend retained a driver job option")
threads = direct_pairs(arguments, "-num-threads")
if threads != ["1"] or any(value.startswith("-num-threads=") for value in arguments):
    fail("Swift frontend thread-count control is missing, duplicated, or substituted")
rng = []
index = 0
while index < len(arguments):
    if arguments[index] == "-Xllvm":
        if index + 1 >= len(arguments):
            fail("missing Swift frontend LLVM option value")
        if arguments[index + 1].startswith("-rng-seed"):
            rng.extend(arguments[index:index + 2])
        index += 2
    else:
        if arguments[index].startswith("-rng-seed"):
            fail("Swift frontend RNG seed lacks -Xllvm")
        index += 1
if rng != ["-Xllvm", "-rng-seed=1"]:
    fail("Swift frontend RNG-seed control is missing, duplicated, or substituted")
modules = direct_pairs(arguments, "-module-name")
targets = direct_pairs(arguments, "-target")
if len(modules) != 1 or modules[0] not in CONFIG["requiredModules"]:
    fail("Swift frontend module control is missing, duplicated, or substituted")
if targets != [CONFIG["requiredTarget"]]:
    fail("Swift frontend target control is missing, duplicated, or substituted")
module_name = modules[0]
if direct_pairs(arguments, "-file-prefix-map") != CONFIG["filePrefixMaps"]:
    fail("Swift frontend file-prefix maps differ")
if direct_pairs(arguments, "-debug-prefix-map") != CONFIG["filePrefixMaps"]:
    fail("Swift frontend debug-prefix maps differ")
if direct_pairs(arguments, "-working-directory"):
    fail("Swift frontend retained a direct working-directory control")
if direct_pairs(arguments, "-file-compilation-dir") != [CONFIG["canonicalWorkingDirectory"]]:
    fail("Swift frontend file-compilation-dir differs")
xcc = [arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value == "-Xcc"]
expected_xcc_cwd = ["-working-directory", CONFIG["canonicalWorkingDirectory"]]
if sum(xcc[index:index + 2] == expected_xcc_cwd for index in range(len(xcc) - 1)) != 1:
    fail("Swift frontend Xcc working directory differs")
expected_cache_flags = {
    "-module-cache-path": [CONFIG["canonicalModuleCache"]],
    "-clang-scanner-module-cache-path": [],
    "-sdk-module-cache-path": [],
}
for flag, expected in expected_cache_flags.items():
    if direct_pairs(arguments, flag) != expected:
        fail(f"Swift frontend cache policy differs for {flag}")
derived_roots = [
    CONFIG["canonicalDerivedData"],
    CONFIG["canonicalDerivedData"].replace("/private/tmp/", "/tmp/", 1),
]
object_outputs = direct_pairs(arguments, "-o")
if not object_outputs or any(not under_root(path, derived_roots) for path in object_outputs):
    fail("Swift frontend object output paths differ")
raw_maps = direct_pairs(arguments, "-supplementary-output-file-map")
if len(raw_maps) != 1:
    fail("Swift frontend supplementary-output map is missing or duplicated")
raw_map = raw_maps[0]
raw_path = os.path.normpath(raw_map)
temporary = os.path.normpath(CONFIG["temporaryDirectory"])
parent = os.path.dirname(raw_path)
if (
    os.path.dirname(parent) != temporary
    or os.path.basename(raw_path) != "supplementaryOutputs-1"
    or re.fullmatch(r"TemporaryDirectory\.[A-Za-z0-9]{6}", os.path.basename(parent)) is None
):
    fail("Swift frontend raw supplementary-output map path differs")
for directory, label in (
    (temporary, "fixed temporary"),
    (parent, "raw supplementary-output parent"),
):
    try:
        directory_metadata = os.lstat(directory)
    except OSError as error:
        fail(f"cannot inspect {label} directory: {error}")
    if (
        not stat.S_ISDIR(directory_metadata.st_mode)
        or stat.S_ISLNK(directory_metadata.st_mode)
        or stat.S_IMODE(directory_metadata.st_mode) != 0o700
        or directory_metadata.st_uid != os.getuid()
        or directory_metadata.st_nlink < 2
    ):
        fail(f"{label} directory owner, mode, or link count differs")
map_bytes, raw_map_metadata = read_owned_regular(raw_path)
try:
    parsed_map = json.loads(
        map_bytes,
        object_pairs_hook=reject_duplicate_pairs,
        parse_constant=lambda value: fail(f"non-finite supplementary-output map value: {value}"),
    )
except (UnicodeError, json.JSONDecodeError) as error:
    fail(f"Swift supplementary-output map JSON is invalid: {error}")
source_roots = [
    CONFIG["canonicalSource"],
    CONFIG["canonicalSource"].replace("/private/tmp/", "/tmp/", 1),
    CONFIG["canonicalDerivedData"],
    CONFIG["canonicalDerivedData"].replace("/private/tmp/", "/tmp/", 1),
]
if not isinstance(parsed_map, dict) or len(parsed_map) != 1:
    fail("Swift supplementary-output map shape differs")
for source, outputs in parsed_map.items():
    if not under_root(source, source_roots) or not isinstance(outputs, dict) or not outputs:
        fail("Swift supplementary-output map source/shape differs")
    if module_name not in source.split("/"):
        fail("Swift supplementary-output map source is not module-bound")
    if any(not under_root(path, derived_roots) for path in outputs.values()):
        fail("Swift supplementary output escapes fixed DerivedData")
    if any(module_name not in os.path.basename(path) for path in outputs.values()):
        fail("Swift supplementary output is not module-bound")
supplementary_metadata = os.lstat(CONFIG["supplementaryDirectory"])
if (
    not stat.S_ISDIR(supplementary_metadata.st_mode)
    or stat.S_IMODE(supplementary_metadata.st_mode) != 0o700
    or supplementary_metadata.st_uid != os.getuid()
):
    fail("canonical supplementary-output directory ownership or mode differs")
canonical_map = CONFIG["supplementaryDirectory"] + "/" + module_name + ".json"
write_locked(canonical_map, map_bytes)
effective = list(arguments)
map_index = effective.index("-supplementary-output-file-map") + 1
if effective[map_index] != raw_map:
    fail("Swift supplementary-output map replacement target differs")
effective[map_index] = canonical_map
replacements = [
    (CONFIG["canonicalSource"], "$SOURCE_ROOT"),
    (CONFIG["canonicalSource"].replace("/private/tmp/", "/tmp/", 1), "$SOURCE_ROOT"),
    (CONFIG["canonicalDerivedData"], "$DERIVED_DATA"),
    (CONFIG["canonicalDerivedData"].replace("/private/tmp/", "/tmp/", 1), "$DERIVED_DATA"),
    (CONFIG["canonicalModuleCache"], "$MODULE_CACHE"),
    (CONFIG["supplementaryDirectory"], "$SUPPLEMENTARY_OUTPUT_MAPS"),
]
normalized = []
for token in effective:
    value = token
    for source, destination in replacements:
        value = value.replace(source, destination)
    normalized.append(value)
normalized_sha = sha256_bytes(CONFIG["auditDomain"].encode("utf-8") + canonical_json(normalized))
effective_sha = sha256_bytes(
    CONFIG["auditDomain"].encode("utf-8") + b"effective\0" + canonical_json(effective)
)
record = {
    "schemaVersion": CONFIG["auditSchema"],
    "moduleName": module_name,
    "target": CONFIG["requiredTarget"],
    "rawSupplementaryOutputFileMapPath": raw_map,
    "canonicalSupplementaryOutputFileMapPath": canonical_map,
    "supplementaryOutputFileMapByteCount": len(map_bytes),
    "supplementaryOutputFileMapSHA256": sha256_bytes(map_bytes),
    "rawSupplementaryOutputFileMapOwnerUID": raw_map_metadata["ownerUID"],
    "rawSupplementaryOutputFileMapUnixMode": raw_map_metadata["unixMode"],
    "rawSupplementaryOutputFileMapLinkCount": raw_map_metadata["linkCount"],
    "effectiveArgv": effective,
    "effectiveArgvSHA256": effective_sha,
    "normalizedEffectiveArgv": normalized,
    "normalizedEffectiveArgvSHA256": normalized_sha,
    "objectOutputPathCount": len(object_outputs),
    "forcedEnvironment": {
        "SWIFT_DETERMINISTIC_HASHING": "1",
        "SWIFTC_MAXIMUM_DETERMINISM": "1",
        "TMPDIR": CONFIG["temporaryDirectory"],
    },
}
marker = canonical_json(record)
try:
    metadata = os.lstat(CONFIG["audit"])
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
        fail("Swift frontend audit file has an unsupported kind or mode")
    flags = os.O_WRONLY | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(CONFIG["audit"], flags)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        if os.write(descriptor, marker) != len(marker):
            fail("Swift frontend audit marker write was incomplete")
    finally:
        os.close(descriptor)
except OSError as error:
    fail(f"Swift frontend audit write failed: {error}")
environment = dict(os.environ)
environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
environment["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
environment["TMPDIR"] = CONFIG["temporaryDirectory"]
try:
    os.execve(CONFIG["underlying"], ["swift-frontend", *effective], environment)
except OSError as error:
    fail(f"Swift frontend launch failed: {error}")
'''
    return (prefix + body).encode("utf-8")


def _write_locked_file(path: Path, raw: bytes, mode: int) -> None:
    require(path.is_absolute() and path.parent.is_dir(), "locked helper path differs")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor_number = os.open(path, flags, mode)
    except OSError as error:
        raise EvidenceError(f"cannot create locked compiler helper {path}: {error}") from error
    try:
        os.fchmod(descriptor_number, mode)
        with os.fdopen(descriptor_number, "wb", closefd=False) as output:
            output.write(raw)
            output.flush()
        metadata = os.fstat(descriptor_number)
    finally:
        os.close(descriptor_number)
    require(
        stat.S_ISREG(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == mode
        and metadata.st_size == len(raw),
        "locked compiler helper kind, mode, or byte count differs",
    )


def write_swift_compiler_helpers(
    underlying_swiftc: Path,
    wrapper_path: Path,
    driver_audit_path: Path,
    frontend_shim_path: Path,
    frontend_audit_path: Path,
    temporary_directory: Path,
    supplementary_directory: Path,
) -> None:
    underlying = underlying_swiftc.resolve(strict=True)
    require(
        underlying.is_file() and os.access(underlying, os.X_OK),
        "underlying Swift compiler is absent or not executable",
    )
    require(
        wrapper_path == Path(CANONICAL_SWIFT_WRAPPER)
        and driver_audit_path == Path(CANONICAL_SWIFT_AUDIT)
        and frontend_shim_path == Path(CANONICAL_SWIFT_FRONTEND_SHIM)
        and frontend_audit_path == Path(CANONICAL_SWIFT_FRONTEND_AUDIT)
        and temporary_directory == Path(CANONICAL_SWIFT_TEMPORARY)
        and supplementary_directory == Path(CANONICAL_SWIFT_SUPPLEMENTARY_MAPS),
        "performance Swift helpers do not use canonical paths",
    )
    for directory in (temporary_directory, supplementary_directory):
        require(not directory.exists(), "performance Swift helper directory already exists")
        try:
            directory.mkdir(mode=0o700)
        except OSError as error:
            raise EvidenceError(
                f"cannot create performance Swift helper directory {directory}: {error}"
            ) from error
        metadata = os.lstat(directory)
        require(
            stat.S_ISDIR(metadata.st_mode)
            and stat.S_IMODE(metadata.st_mode) == 0o700
            and metadata.st_uid == os.getuid(),
            "performance Swift helper directory ownership or mode differs",
        )
    _write_locked_file(driver_audit_path, b"", 0o600)
    _write_locked_file(frontend_audit_path, b"", 0o600)
    _write_locked_file(
        frontend_shim_path,
        swift_frontend_shim_bytes(
            underlying,
            frontend_audit_path,
            temporary_directory,
            supplementary_directory,
        ),
        0o755,
    )
    _write_locked_file(
        wrapper_path,
        swift_driver_wrapper_bytes(
            underlying,
            driver_audit_path,
            frontend_shim_path,
            temporary_directory,
        ),
        0o755,
    )


def _executable_identity(path: Path, label: str) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    metadata = os.lstat(resolved)
    require(
        stat.S_ISREG(metadata.st_mode) and os.access(resolved, os.X_OK),
        f"{label} is absent or not executable",
    )
    environment = dict(os.environ)
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    environment["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
    process = subprocess.run(
        [str(resolved), "--version"],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    require(process.returncode == 0, f"{label} version inspection failed")
    version = process.stdout.strip().splitlines()
    require(version, f"{label} version output is empty")
    return {
        "path": str(resolved),
        "byteCount": metadata.st_size,
        "sha256": sha256_file(resolved),
        "unixMode": stat.S_IMODE(metadata.st_mode),
        "version": version,
    }


def _swift_wrapper_identity(
    wrapper_path: Path, underlying_swiftc: Path
) -> dict[str, Any]:
    metadata = os.lstat(wrapper_path)
    underlying = _executable_identity(underlying_swiftc, "underlying Swift compiler")
    interpreter = _executable_identity(Path("/usr/bin/python3"), "Swift wrapper interpreter")
    expected = swift_driver_wrapper_bytes(
        Path(underlying["path"]),
        Path(CANONICAL_SWIFT_AUDIT),
        Path(CANONICAL_SWIFT_FRONTEND_SHIM),
        Path(CANONICAL_SWIFT_TEMPORARY),
    )
    require(
        stat.S_ISREG(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == 0o755
        and wrapper_path.read_bytes() == expected,
        "Swift driver wrapper bytes or mode differ",
    )
    records = {
        "schemaVersion": SWIFT_DRIVER_WRAPPER_SCHEMA,
        "canonicalPath": CANONICAL_SWIFT_WRAPPER,
        "byteCount": len(expected),
        "sha256": sha256_bytes(expected),
        "unixMode": 0o755,
        "frontendShimPath": CANONICAL_SWIFT_FRONTEND_SHIM,
        "temporaryDirectory": CANONICAL_SWIFT_TEMPORARY,
        "underlyingSwiftc": underlying,
        "interpreter": interpreter,
    }
    return {
        **records,
        "identitySHA256": sha256_bytes(
            SWIFT_DRIVER_WRAPPER_DOMAIN + canonical_json(records)
        ),
    }


def _swift_frontend_shim_identity(
    shim_path: Path, underlying_frontend: Path
) -> dict[str, Any]:
    metadata = os.lstat(shim_path)
    underlying = _executable_identity(
        underlying_frontend, "underlying Swift frontend"
    )
    interpreter = _executable_identity(
        Path("/usr/bin/python3"), "Swift frontend shim interpreter"
    )
    expected = swift_frontend_shim_bytes(
        Path(underlying["path"]),
        Path(CANONICAL_SWIFT_FRONTEND_AUDIT),
        Path(CANONICAL_SWIFT_TEMPORARY),
        Path(CANONICAL_SWIFT_SUPPLEMENTARY_MAPS),
    )
    require(
        stat.S_ISREG(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == 0o755
        and shim_path.read_bytes() == expected,
        "Swift frontend shim bytes or mode differ",
    )
    records = {
        "schemaVersion": SWIFT_FRONTEND_SHIM_SCHEMA,
        "canonicalPath": CANONICAL_SWIFT_FRONTEND_SHIM,
        "byteCount": len(expected),
        "sha256": sha256_bytes(expected),
        "unixMode": 0o755,
        "auditPath": CANONICAL_SWIFT_FRONTEND_AUDIT,
        "temporaryDirectory": CANONICAL_SWIFT_TEMPORARY,
        "supplementaryOutputMapDirectory": CANONICAL_SWIFT_SUPPLEMENTARY_MAPS,
        "underlyingSwiftFrontend": underlying,
        "interpreter": interpreter,
    }
    return {
        **records,
        "identitySHA256": sha256_bytes(
            SWIFT_FRONTEND_SHIM_DOMAIN + canonical_json(records)
        ),
    }


def _direct_argument_pairs(arguments: Sequence[str], flag: str) -> list[str]:
    values: list[str] = []
    index = 0
    while index < len(arguments):
        if arguments[index] == "-Xcc":
            require(index + 1 < len(arguments), "Swift frontend -Xcc lacks a value")
            index += 2
        elif arguments[index] == flag:
            require(index + 1 < len(arguments), f"Swift frontend {flag} lacks a value")
            values.append(arguments[index + 1])
            index += 2
        else:
            index += 1
    return values


def _path_under_roots(value: str, roots: Sequence[str]) -> bool:
    path = PurePosixPath(value)
    if not path.is_absolute() or ".." in path.parts:
        return False
    normalized = path.as_posix()
    return any(
        normalized == root or normalized.startswith(root + "/") for root in roots
    )


def _frontend_prefix_maps() -> list[str]:
    return [
        CANONICAL_SOURCE_ROOT + "=/mirmir-performance-p05",
        _private_tmp_alias(CANONICAL_SOURCE_ROOT) + "=/mirmir-performance-p05",
        CANONICAL_DERIVED_DATA + "=/mirmir-performance-derived",
        _private_tmp_alias(CANONICAL_DERIVED_DATA)
        + "=/mirmir-performance-derived",
    ]


def _normalize_frontend_argv(
    arguments: Sequence[str],
    supplementary_directory: str = CANONICAL_SWIFT_SUPPLEMENTARY_MAPS,
) -> list[str]:
    replacements = (
        (CANONICAL_SOURCE_ROOT, "$SOURCE_ROOT"),
        (_private_tmp_alias(CANONICAL_SOURCE_ROOT), "$SOURCE_ROOT"),
        (CANONICAL_DERIVED_DATA, "$DERIVED_DATA"),
        (_private_tmp_alias(CANONICAL_DERIVED_DATA), "$DERIVED_DATA"),
        (CANONICAL_MODULE_CACHE, "$MODULE_CACHE"),
        (supplementary_directory, "$SUPPLEMENTARY_OUTPUT_MAPS"),
    )
    normalized: list[str] = []
    for token in arguments:
        value = token
        for source, destination in replacements:
            value = value.replace(source, destination)
        normalized.append(value)
    return normalized


def _validate_supplementary_output_map(
    path: Path, module_name: str
) -> tuple[int, str]:
    metadata = os.lstat(path)
    require(
        stat.S_ISREG(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == 0o600
        and metadata.st_nlink == 1,
        f"Swift {module_name} canonical supplementary map mode/link differs",
    )
    raw = path.read_bytes()
    try:
        value = json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(
            f"Swift {module_name} supplementary-output map is invalid: {error}"
        ) from error
    mapping = require_object(value, f"Swift {module_name} supplementary-output map")
    require(
        len(mapping) == 1,
        f"Swift {module_name} supplementary-output map source count differs",
    )
    source_roots = (
        CANONICAL_SOURCE_ROOT,
        _private_tmp_alias(CANONICAL_SOURCE_ROOT),
        CANONICAL_DERIVED_DATA,
        _private_tmp_alias(CANONICAL_DERIVED_DATA),
    )
    derived_roots = (
        CANONICAL_DERIVED_DATA,
        _private_tmp_alias(CANONICAL_DERIVED_DATA),
    )
    for source, outputs_value in mapping.items():
        require(
            _path_under_roots(source, source_roots),
            f"Swift {module_name} supplementary source escapes the fixed roots",
        )
        require(
            module_name in PurePosixPath(source).parts,
            f"Swift {module_name} supplementary source is not module-bound",
        )
        outputs = require_object(
            outputs_value, f"Swift {module_name} supplementary outputs"
        )
        require(outputs, f"Swift {module_name} supplementary outputs are empty")
        for output_kind, output_path in outputs.items():
            require_string(
                output_kind, f"Swift {module_name} supplementary output kind"
            )
            require(
                _path_under_roots(
                    require_string(
                        output_path,
                        f"Swift {module_name} supplementary output path",
                    ),
                    derived_roots,
                ),
                f"Swift {module_name} supplementary output escapes fixed DerivedData",
            )
            require(
                module_name in PurePosixPath(output_path).name,
                f"Swift {module_name} supplementary output is not module-bound",
            )
    return len(raw), sha256_bytes(raw)


def _validate_frontend_effective_argv(
    arguments: Sequence[str], module_name: str
) -> int:
    require(arguments and arguments[0] == "-frontend", "Swift frontend argv lacks -frontend")
    require(
        _direct_argument_pairs(arguments, "-module-name") == [module_name],
        f"Swift {module_name} frontend module differs",
    )
    require(
        _direct_argument_pairs(arguments, "-target") == [SWIFT_DRIVER_REQUIRED_TARGET],
        f"Swift {module_name} frontend target differs",
    )
    require(
        _direct_argument_pairs(arguments, "-num-threads") == ["1"]
        and not any(token.startswith("-num-threads=") for token in arguments),
        f"Swift {module_name} frontend thread control differs",
    )
    rng: list[str] = []
    index = 0
    while index < len(arguments):
        if arguments[index] == "-Xllvm":
            require(index + 1 < len(arguments), "Swift frontend -Xllvm lacks a value")
            if arguments[index + 1].startswith("-rng-seed"):
                rng.extend(arguments[index : index + 2])
            index += 2
        else:
            require(
                not arguments[index].startswith("-rng-seed"),
                "Swift frontend RNG seed lacks -Xllvm",
            )
            index += 1
    require(
        rng == ["-Xllvm", "-rng-seed=1"],
        f"Swift {module_name} frontend RNG seed differs",
    )
    require(
        _direct_argument_pairs(arguments, "-file-prefix-map")
        == _frontend_prefix_maps(),
        f"Swift {module_name} frontend file-prefix maps differ",
    )
    require(
        _direct_argument_pairs(arguments, "-debug-prefix-map")
        == _frontend_prefix_maps(),
        f"Swift {module_name} frontend debug-prefix maps differ",
    )
    require(
        not _direct_argument_pairs(arguments, "-working-directory"),
        f"Swift {module_name} frontend retained direct working-directory",
    )
    expected_working = _private_tmp_alias(CANONICAL_SOURCE_ROOT)
    require(
        _direct_argument_pairs(arguments, "-file-compilation-dir")
        == [expected_working],
        f"Swift {module_name} frontend file-compilation-dir differs",
    )
    xcc = [
        arguments[index + 1]
        for index, token in enumerate(arguments[:-1])
        if token == "-Xcc"
    ]
    require(
        sum(
            xcc[index : index + 2] == ["-working-directory", expected_working]
            for index in range(len(xcc) - 1)
        )
        == 1,
        f"Swift {module_name} frontend Xcc working directory differs",
    )
    expected_caches = {
        "-module-cache-path": [CANONICAL_MODULE_CACHE],
        "-clang-scanner-module-cache-path": [],
        "-sdk-module-cache-path": [],
    }
    for flag, expected in expected_caches.items():
        require(
            _direct_argument_pairs(arguments, flag) == expected,
            f"Swift {module_name} frontend cache policy differs for {flag}",
        )
    require(
        not any(token == "-j" or token.startswith("-j") for token in arguments),
        f"Swift {module_name} frontend retained driver job control",
    )
    require(
        not _direct_argument_pairs(arguments, "-driver-use-frontend-path")
        and "-save-temps" not in arguments,
        f"Swift {module_name} frontend retained driver-only controls",
    )
    canonical_map = f"{CANONICAL_SWIFT_SUPPLEMENTARY_MAPS}/{module_name}.json"
    require(
        _direct_argument_pairs(arguments, "-supplementary-output-file-map")
        == [canonical_map],
        f"Swift {module_name} frontend did not consume the canonical map",
    )
    derived_roots = (
        CANONICAL_DERIVED_DATA,
        _private_tmp_alias(CANONICAL_DERIVED_DATA),
    )
    outputs = _direct_argument_pairs(arguments, "-o")
    require(
        outputs and all(_path_under_roots(path, derived_roots) for path in outputs),
        f"Swift {module_name} frontend object outputs escape fixed DerivedData",
    )
    require(
        not any(CANONICAL_SWIFT_TEMPORARY in token for token in arguments),
        f"Swift {module_name} frontend retained a random transport path",
    )
    return len(outputs)


def _validate_frontend_audit(
    directory: Path,
    audit_path: Path,
    map_artifacts: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    require_exact_keys(
        map_artifacts,
        SWIFT_DRIVER_REQUIRED_MODULES,
        "producer Swift supplementary-output map artifacts",
    )
    try:
        raw_lines = audit_path.read_text(errors="strict").splitlines()
    except (OSError, UnicodeError) as error:
        raise EvidenceError(f"cannot read Swift frontend audit: {error}") from error
    require(
        len(raw_lines) == len(SWIFT_DRIVER_REQUIRED_MODULES),
        "Swift frontend audit invocation count differs",
    )
    records: dict[str, dict[str, Any]] = {}
    for line in raw_lines:
        try:
            value = json.loads(
                line,
                object_pairs_hook=_reject_duplicate_pairs,
                parse_constant=_reject_nonfinite,
            )
        except (UnicodeError, json.JSONDecodeError) as error:
            raise EvidenceError(f"Swift frontend audit line is invalid: {error}") from error
        record = require_object(value, "Swift frontend audit record")
        require_exact_keys(
            record,
            (
                "schemaVersion",
                "moduleName",
                "target",
                "rawSupplementaryOutputFileMapPath",
                "canonicalSupplementaryOutputFileMapPath",
                "supplementaryOutputFileMapByteCount",
                "supplementaryOutputFileMapSHA256",
                "rawSupplementaryOutputFileMapOwnerUID",
                "rawSupplementaryOutputFileMapUnixMode",
                "rawSupplementaryOutputFileMapLinkCount",
                "effectiveArgv",
                "effectiveArgvSHA256",
                "normalizedEffectiveArgv",
                "normalizedEffectiveArgvSHA256",
                "objectOutputPathCount",
                "forcedEnvironment",
            ),
            "Swift frontend audit record",
        )
        require(
            record["schemaVersion"] == SWIFT_FRONTEND_JOB_AUDIT_SCHEMA,
            "Swift frontend audit schema differs",
        )
        module_name = require_string(record["moduleName"], "Swift frontend module")
        require(
            module_name in SWIFT_DRIVER_REQUIRED_MODULES and module_name not in records,
            "Swift frontend audit module is missing, duplicated, or substituted",
        )
        require(
            record["target"] == SWIFT_DRIVER_REQUIRED_TARGET,
            f"Swift {module_name} frontend audit target differs",
        )
        raw_map = PurePosixPath(
            require_string(
                record["rawSupplementaryOutputFileMapPath"],
                f"Swift {module_name} raw supplementary map path",
            )
        )
        require(
            raw_map.name == "supplementaryOutputs-1"
            and raw_map.parent.parent.as_posix() == CANONICAL_SWIFT_TEMPORARY
            and re.fullmatch(r"TemporaryDirectory\.[A-Za-z0-9]{6}", raw_map.parent.name)
            is not None,
            f"Swift {module_name} raw supplementary map path differs",
        )
        canonical_map = f"{CANONICAL_SWIFT_SUPPLEMENTARY_MAPS}/{module_name}.json"
        require(
            record["canonicalSupplementaryOutputFileMapPath"] == canonical_map,
            f"Swift {module_name} canonical supplementary map path differs",
        )
        map_path, map_sha = validate_descriptor(
            directory,
            map_artifacts[module_name],
            f"Swift {module_name} supplementary-output map",
        )
        require(
            map_path
            == (
                directory
                / f"producer/supplementary-output-maps/{module_name}.json"
            ).resolve(),
            f"Swift {module_name} supplementary evidence path differs",
        )
        map_byte_count, recomputed_map_sha = _validate_supplementary_output_map(
            map_path, module_name
        )
        require(
            map_sha == recomputed_map_sha
            and record["supplementaryOutputFileMapSHA256"] == map_sha
            and record["supplementaryOutputFileMapByteCount"] == map_byte_count,
            f"Swift {module_name} supplementary map identity differs",
        )
        require(
            require_integer(
                record["rawSupplementaryOutputFileMapOwnerUID"],
                f"Swift {module_name} raw map owner UID",
                0,
            )
            == os.getuid()
            and require_integer(
                record["rawSupplementaryOutputFileMapUnixMode"],
                f"Swift {module_name} raw map mode",
                0,
            )
            == 0o644
            and require_integer(
                record["rawSupplementaryOutputFileMapLinkCount"],
                f"Swift {module_name} raw map link count",
                1,
            )
            == 1,
            f"Swift {module_name} raw map owner, mode, or link count differs",
        )
        effective = [
            require_string(token, f"Swift {module_name} effective argv token")
            for token in require_list(
                record["effectiveArgv"], f"Swift {module_name} effective argv"
            )
        ]
        output_count = _validate_frontend_effective_argv(effective, module_name)
        require(
            record["objectOutputPathCount"] == output_count,
            f"Swift {module_name} frontend output count differs",
        )
        require(
            record["effectiveArgvSHA256"]
            == sha256_bytes(
                SWIFT_FRONTEND_JOB_AUDIT_DOMAIN
                + b"effective\0"
                + canonical_json(effective)
            ),
            f"Swift {module_name} effective argv identity differs",
        )
        normalized = _normalize_frontend_argv(effective)
        require(
            canonical_json(record["normalizedEffectiveArgv"])
            == canonical_json(normalized),
            f"Swift {module_name} normalized frontend argv differs",
        )
        normalized_sha = sha256_bytes(
            SWIFT_FRONTEND_JOB_AUDIT_DOMAIN + canonical_json(normalized)
        )
        require(
            record["normalizedEffectiveArgvSHA256"] == normalized_sha,
            f"Swift {module_name} normalized frontend argv identity differs",
        )
        forced = require_object(
            record["forcedEnvironment"], f"Swift {module_name} forced environment"
        )
        expected_forced = {
            "SWIFT_DETERMINISTIC_HASHING": "1",
            "SWIFTC_MAXIMUM_DETERMINISM": "1",
            "TMPDIR": CANONICAL_SWIFT_TEMPORARY,
        }
        require_exact_keys(
            forced, expected_forced, f"Swift {module_name} forced environment"
        )
        require(
            forced == expected_forced,
            f"Swift {module_name} forced environment differs",
        )
        stable_forced = {
            **expected_forced,
            "TMPDIR": "$SWIFT_TEMPORARY",
        }
        records[module_name] = {
            "moduleName": module_name,
            "target": SWIFT_DRIVER_REQUIRED_TARGET,
            "supplementaryOutputFileMapByteCount": map_byte_count,
            "supplementaryOutputFileMapSHA256": map_sha,
            "normalizedEffectiveArgv": normalized,
            "normalizedEffectiveArgvSHA256": normalized_sha,
            "objectOutputPathCount": output_count,
            "forcedEnvironment": stable_forced,
        }
    stable_records = [records[module] for module in SWIFT_DRIVER_REQUIRED_MODULES]
    audit_records = {
        "schemaVersion": SWIFT_FRONTEND_JOB_AUDIT_SCHEMA,
        "invocationCount": len(stable_records),
        "jobs": stable_records,
    }
    return {
        **audit_records,
        "identitySHA256": sha256_bytes(
            SWIFT_FRONTEND_JOB_AUDIT_DOMAIN + canonical_json(audit_records)
        ),
    }, stable_records


def _compiler_control_audit(
    directory: Path, receipt: dict[str, Any], underlying_swiftc: Path
) -> dict[str, Any]:
    environment = require_object(
        receipt.get("buildEnvironment"), "producer build environment"
    )
    require(
        environment.get("SWIFT_DETERMINISTIC_HASHING") == "1",
        "producer omitted SWIFT_DETERMINISTIC_HASHING=1",
    )
    require(
        environment.get("SWIFTC_MAXIMUM_DETERMINISM") == "1",
        "producer omitted SWIFTC_MAXIMUM_DETERMINISM=1",
    )
    require(
        environment.get("TMPDIR") == CANONICAL_SWIFT_TEMPORARY,
        "producer omitted the fixed Swift temporary directory",
    )
    require(
        require_list(receipt.get("buildCommand"), "producer build command")
        == _expected_baseline_build_command(receipt),
        "producer build command/configuration differs",
    )
    wrapper_path, _ = validate_descriptor(
        directory,
        receipt["swiftDriverWrapperArtifact"],
        "producer Swift driver wrapper",
    )
    driver_audit_path, _ = validate_descriptor(
        directory,
        receipt["swiftDriverAuditArtifact"],
        "producer Swift driver audit",
    )
    frontend_shim_path, _ = validate_descriptor(
        directory,
        receipt["swiftFrontendShimArtifact"],
        "producer Swift frontend shim",
    )
    frontend_audit_path, _ = validate_descriptor(
        directory,
        receipt["swiftFrontendAuditArtifact"],
        "producer Swift frontend audit",
    )
    require(
        wrapper_path == (directory / "producer/swiftc").resolve(),
        "producer Swift wrapper artifact path differs",
    )
    require(
        driver_audit_path
        == (directory / "producer/swift-driver-effective-argv.log").resolve(),
        "producer Swift audit artifact path differs",
    )
    require(
        frontend_shim_path == (directory / "producer/swift-frontend").resolve(),
        "producer Swift frontend shim artifact path differs",
    )
    require(
        frontend_audit_path
        == (directory / "producer/swift-frontend-effective-argv.jsonl").resolve(),
        "producer Swift frontend audit artifact path differs",
    )
    wrapper_identity = _swift_wrapper_identity(wrapper_path, underlying_swiftc)
    require(
        canonical_json(receipt["swiftDriverWrapperIdentity"])
        == canonical_json(wrapper_identity),
        "producer Swift wrapper identity differs",
    )
    frontend_shim_identity = _swift_frontend_shim_identity(
        frontend_shim_path, underlying_swiftc
    )
    require(
        canonical_json(receipt["swiftFrontendShimIdentity"])
        == canonical_json(frontend_shim_identity),
        "producer Swift frontend shim identity differs",
    )
    audit_metadata = os.lstat(driver_audit_path)
    require(
        stat.S_ISREG(audit_metadata.st_mode)
        and stat.S_IMODE(audit_metadata.st_mode) == 0o600,
        "producer Swift audit kind or mode differs",
    )
    try:
        lines = driver_audit_path.read_text(errors="strict").splitlines()
    except (OSError, UnicodeError) as error:
        raise EvidenceError(f"cannot read Swift driver audit: {error}") from error
    expected_markers = sorted(SWIFT_DRIVER_JOB_AUDIT_MARKERS)
    require(
        sorted(lines) == expected_markers,
        "Swift driver audit markers are missing, duplicated, or substituted",
    )
    normalized_audit = ("\n".join(expected_markers) + "\n").encode("utf-8")
    audit_records = {
        "schemaVersion": SWIFT_DRIVER_JOB_AUDIT_SCHEMA,
        "invocationCount": len(expected_markers),
        "markers": expected_markers,
        "byteCount": len(normalized_audit),
        "sha256": sha256_bytes(normalized_audit),
    }
    audit_identity = sha256_bytes(
        SWIFT_DRIVER_JOB_AUDIT_DOMAIN + canonical_json(audit_records)
    )
    frontend_audit_metadata = os.lstat(frontend_audit_path)
    require(
        stat.S_ISREG(frontend_audit_metadata.st_mode)
        and stat.S_IMODE(frontend_audit_metadata.st_mode) == 0o600,
        "producer Swift frontend audit kind or mode differs",
    )
    frontend_audit, frontend_jobs = _validate_frontend_audit(
        directory,
        frontend_audit_path,
        require_object(
            receipt["swiftFrontendSupplementaryMapArtifacts"],
            "producer Swift supplementary-output map artifacts",
        ),
    )
    frontend_jobs_by_module = {
        require_string(job["moduleName"], "Swift frontend job module"): job
        for job in frontend_jobs
    }
    driver_jobs = [
        {
            "moduleName": module_name,
            "target": SWIFT_DRIVER_REQUIRED_TARGET,
            "numThreadsValues": [1],
            "effectiveNumThreads": 1,
            "rngSeedArguments": ["-rng-seed=1"],
            "moduleCacheArgumentCounts": {
                "-clang-scanner-module-cache-path": 0,
                "-module-cache-path": 1,
                "-sdk-module-cache-path": 0,
            },
            "explicitModulesDisabled": True,
            "allModuleCachesUnderCanonicalRoot": True,
            "sourceAndDerivedPrefixMapsVerified": True,
            "driverWorkingDirectoryCount": 1,
            "frontendWorkingDirectoryCount": 0,
            "frontendFileCompilationDirectoryCount": 1,
            "frontendXCCWorkingDirectoryCount": 1,
            "frontendShimArgumentCount": 1,
            "saveTempsArgumentCount": 1,
            "supplementaryOutputFileMapSHA256": frontend_jobs_by_module[
                module_name
            ]["supplementaryOutputFileMapSHA256"],
            "supplementaryOutputFileMapByteCount": frontend_jobs_by_module[
                module_name
            ]["supplementaryOutputFileMapByteCount"],
            "normalizedFrontendArgvSHA256": frontend_jobs_by_module[module_name][
                "normalizedEffectiveArgvSHA256"
            ],
            "frontendObjectOutputPathCount": frontend_jobs_by_module[module_name][
                "objectOutputPathCount"
            ],
            "projectedFrontendJobCount": 1,
        }
        for module_name in SWIFT_DRIVER_REQUIRED_MODULES
    ]
    return {
        "schemaVersion": COMPILER_CONTROL_AUDIT_SCHEMA,
        "forcedEnvironment": {
            "SWIFT_DETERMINISTIC_HASHING": "1",
            "SWIFTC_MAXIMUM_DETERMINISM": "1",
            "TMPDIR": "$SWIFT_TEMPORARY",
        },
        "xcodebuildJobCount": 1,
        "swiftDriverWrapperIdentitySHA256": wrapper_identity["identitySHA256"],
        "swiftFrontendShimIdentitySHA256": frontend_shim_identity[
            "identitySHA256"
        ],
        "swiftDriverAudit": {
            **audit_records,
            "identitySHA256": audit_identity,
        },
        "swiftFrontendAudit": frontend_audit,
        "swiftDriverJobs": driver_jobs,
        "swiftFrontendJobs": frontend_jobs,
    }


def normalized_test_summary(result_bundle: Path) -> dict[str, Any]:
    process = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(result_bundle),
            "--compact",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    require(
        process.returncode == 0,
        "cannot read the baseline xcresult summary: "
        + process.stderr.decode("utf-8", errors="replace")[-2000:],
    )
    try:
        raw = json.loads(
            process.stdout,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"baseline xcresult summary is invalid: {error}") from error
    summary = require_object(raw, "baseline xcresult summary")
    passed = require_integer(summary.get("passedTests"), "xcresult passed tests", 0)
    failed = require_integer(summary.get("failedTests"), "xcresult failed tests", 0)
    skipped = require_integer(summary.get("skippedTests"), "xcresult skipped tests", 0)
    result = require_string(summary.get("result"), "xcresult result")
    require(
        (passed, failed, skipped, result) == (1, 0, 0, "Passed"),
        "baseline xcresult did not record exactly one successful test",
    )
    return {
        "schemaVersion": TEST_SUMMARY_SCHEMA,
        "testIdentifier": BASELINE_TEST_IDENTIFIER,
        "result": result,
        "passedTests": passed,
        "failedTests": failed,
        "skippedTests": skipped,
    }


def write_normalized_test_summary(result_bundle: Path, output: Path) -> dict[str, Any]:
    value = normalized_test_summary(result_bundle)
    write_json(output, value)
    return value


def _validate_test_summary(
    directory: Path, value: Any, allow_fixture_runtime: bool
) -> tuple[dict[str, Any], str]:
    path, identity = validate_descriptor(
        directory, value, "producer normalized test summary"
    )
    require(
        path == (directory / "producer/test-summary.json").resolve(),
        "producer normalized test-summary path differs",
    )
    observed = require_object(load_json(path), "producer normalized test summary")
    require_exact_keys(
        observed,
        (
            "schemaVersion",
            "testIdentifier",
            "result",
            "passedTests",
            "failedTests",
            "skippedTests",
        ),
        "producer normalized test summary",
    )
    require(observed["schemaVersion"] == TEST_SUMMARY_SCHEMA, "test summary schema differs")
    require(observed["testIdentifier"] == BASELINE_TEST_IDENTIFIER, "test summary identifier differs")
    passed = require_integer(
        observed["passedTests"], "normalized test summary passedTests", 0
    )
    failed = require_integer(
        observed["failedTests"], "normalized test summary failedTests", 0
    )
    skipped = require_integer(
        observed["skippedTests"], "normalized test summary skippedTests", 0
    )
    result = require_string(
        observed["result"], "normalized test summary result"
    )
    require(
        (passed, failed, skipped, result) == (1, 0, 0, "Passed"),
        "normalized test summary did not record exactly one successful test",
    )
    if not allow_fixture_runtime:
        expected = normalized_test_summary(
            directory / "producer/baseline.xcresult"
        )
        require(
            canonical_json(observed) == canonical_json(expected),
            "normalized test summary differs from the xcresult",
        )
    return observed, identity


def _normalized_build_environment(receipt: dict[str, Any]) -> dict[str, str]:
    environment = require_object(receipt["buildEnvironment"], "producer build environment")
    replacements = {
        "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR": "$CAPTURE_DIR",
        "MIRMIR_V4_PERFORMANCE_INPUT": "$LOCKED_INPUT",
        "MIRMIR_V4_PERFORMANCE_PRODUCER_NONCE": "$INVOCATION_NONCE",
        "MIRMIR_V4_PERFORMANCE_PRODUCER_CHALLENGE": "$PRODUCER_CHALLENGE",
        "TMPDIR": "$SWIFT_TEMPORARY",
    }
    return {
        key: replacements.get(key, require_string(value, f"producer environment {key}"))
        for key, value in sorted(environment.items())
    }


def _normalized_build_command(receipt: dict[str, Any]) -> list[str]:
    command = _expected_baseline_build_command(receipt)
    environment = require_object(receipt["buildEnvironment"], "producer build environment")
    normalized_environment = _normalized_build_environment(receipt)
    replacements = {
        require_string(receipt["derivedDataPath"], "producer derived-data path"):
            "$DERIVED_DATA",
        require_string(receipt["captureDirectory"], "producer capture directory")
            + "/producer/baseline.xcresult": "$CAPTURE_DIR/producer/baseline.xcresult",
    }
    for key, value in environment.items():
        replacements[f"{key}={value}"] = f"{key}={normalized_environment[key]}"
    working_directory = require_string(
        receipt["workingDirectory"], "producer working directory"
    )
    path_replacements = (
        (CANONICAL_SOURCE_ROOT, "$SOURCE_ROOT"),
        (
            CANONICAL_SOURCE_ROOT.replace("/private/tmp/", "/tmp/", 1),
            "$SOURCE_ROOT",
        ),
        (CANONICAL_DERIVED_DATA, "$DERIVED_DATA"),
        (
            CANONICAL_DERIVED_DATA.replace("/private/tmp/", "/tmp/", 1),
            "$DERIVED_DATA",
        ),
        (CANONICAL_MODULE_CACHE, "$MODULE_CACHE"),
        (
            CANONICAL_MODULE_CACHE.replace("/private/tmp/", "/tmp/", 1),
            "$MODULE_CACHE",
        ),
        (working_directory, "$SOURCE_ROOT"),
    )
    normalized: list[str] = []
    for raw_token in command:
        token = replacements.get(raw_token, raw_token)
        for source, destination in path_replacements:
            token = token.replace(source, destination)
        normalized.append(token)
    return normalized


def _stable_producer_facts(
    *,
    receipt: dict[str, Any],
    capture: dict[str, Any],
    application_sha256: str,
    test_sha256: str,
    input_sha256: str,
    workload_identity_sha256: str,
    test_summary: dict[str, Any],
    toolchain_identity: dict[str, Any],
    compiler_control_audit: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schemaVersion": STABLE_PRODUCER_FACTS_SCHEMA,
        "variant": "baseline_p05",
        "buildConfiguration": "Release",
        "sourceRevision": capture["sourceRevision"],
        "sourceTreeSHA256": capture["sourceTreeSHA256"],
        "sourceIdentitySHA256": capture["sourceIdentitySHA256"],
        "contractSHA256": capture["contractSHA256"],
        "captureSourceSHA256": capture["captureSourceSHA256"],
        "runnerSourceSHA256": receipt["runnerSourceSHA256"],
        "warmupCount": capture["warmupCount"],
        "sampleCount": capture["sampleCount"],
        "inputIdentity": capture["input"],
        "inputArtifactSHA256": input_sha256,
        "normalizedBuildCommand": _normalized_build_command(receipt),
        "normalizedBuildEnvironment": _normalized_build_environment(receipt),
        "normalizedBuildRequestSHA256": sha256_bytes(
            canonical_json(_normalized_build_environment(receipt))
        ),
        "toolchainIdentity": toolchain_identity,
        "compilerControlAudit": compiler_control_audit,
        "testIdentifier": BASELINE_TEST_IDENTIFIER,
        "normalizedTestSummary": test_summary,
        "normalizedTestSummarySHA256": sha256_bytes(canonical_json(test_summary)),
        "applicationExecutableSHA256": application_sha256,
        "testExecutableSHA256": test_sha256,
        "sampleWorkloadIdentitySHA256": workload_identity_sha256,
    }


def _stable_producer_identity(facts: dict[str, Any]) -> str:
    return sha256_bytes(STABLE_PRODUCER_DOMAIN + canonical_json(facts))


def _stable_toolchain_identity(directory: Path) -> dict[str, Any]:
    environment = validate_environment(
        load_json(directory / "environment-before.json"),
        "baseline producer environment before",
    )
    stable = require_object(
        environment["stableIdentity"], "baseline producer stable environment"
    )
    return {
        "macOSBuild": require_string(stable["macOSBuild"], "stable macOS build"),
        "xcodeBuild": require_string(stable["xcodeBuild"], "stable Xcode build"),
        "swiftCompiler": require_string(
            stable["swiftCompiler"], "stable Swift compiler"
        ),
    }


def _producer_causal_binding(receipt: dict[str, Any]) -> str:
    unsigned = dict(receipt)
    unsigned.pop("causalBindingSHA256", None)
    return sha256_bytes(PRODUCER_CAUSAL_DOMAIN + canonical_json(unsigned))


def validate_baseline_producer_receipt(
    directory: Path,
    capture: dict[str, Any],
    contract: dict[str, Any],
    contract_sha256: str,
    allow_fixture_runtime: bool = False,
) -> dict[str, Any]:
    receipt_path = directory / "producer/producer-receipt.json"
    receipt = require_object(load_json(receipt_path), "baseline producer receipt")
    require_exact_keys(
        receipt,
        (
            "schemaVersion",
            "variant",
            "invocationNonce",
            "challenge",
            "startedAtUnixNanoseconds",
            "finishedAtUnixNanoseconds",
            "durationNanoseconds",
            "exitStatus",
            "buildConfiguration",
            "sourceRevision",
            "sourceTreeSHA256",
            "contractSHA256",
            "captureSourceSHA256",
            "runnerSourceSHA256",
            "workingDirectory",
            "captureDirectory",
            "derivedDataPath",
            "buildCommand",
            "buildEnvironment",
            "buildRequestArtifact",
            "captureArtifact",
            "sampleTranscriptArtifact",
            "sampleTranscriptSetSHA256",
            "sampleMeasurementSetSHA256",
            "sampleWorkloadIdentitySHA256",
            "sampleTranscriptCount",
            "inputArtifact",
            "applicationExecutableArtifact",
            "testExecutableArtifact",
            "resultBundle",
            "normalizedTestSummaryArtifact",
            "buildLogArtifact",
            "swiftDriverWrapperArtifact",
            "swiftDriverAuditArtifact",
            "swiftDriverWrapperIdentity",
            "swiftFrontendShimArtifact",
            "swiftFrontendAuditArtifact",
            "swiftFrontendSupplementaryMapArtifacts",
            "swiftFrontendShimIdentity",
            "compilerControlAudit",
            "stableProducerFacts",
            "stableProducerIdentitySHA256",
            "causalBindingSHA256",
        ),
        "baseline producer receipt",
    )
    require(receipt["schemaVersion"] == PRODUCER_RECEIPT_SCHEMA, "producer receipt schema differs")
    require(receipt["variant"] == "baseline_p05", "producer receipt variant differs")
    nonce = require_sha256(receipt["invocationNonce"], "producer invocation nonce")
    challenge = require_sha256(receipt["challenge"], "producer challenge")
    require(nonce == capture.get("producerInvocationNonce"), "producer nonce is not capture-bound")
    require(challenge == capture.get("producerChallenge"), "producer challenge is not capture-bound")
    started = require_integer(
        receipt["startedAtUnixNanoseconds"], "producer start time", 1
    )
    finished = require_integer(
        receipt["finishedAtUnixNanoseconds"], "producer finish time", started
    )
    duration = require_integer(
        receipt["durationNanoseconds"], "producer duration", 1
    )
    require(finished - started == duration, "producer duration is inconsistent")
    require(
        require_integer(receipt["exitStatus"], "producer exit status", 0) == 0,
        "baseline producer did not exit successfully",
    )
    require(receipt["buildConfiguration"] == "Release", "producer build was not Release")
    require(receipt["sourceRevision"] == capture["sourceRevision"], "producer source revision differs")
    require(receipt["sourceTreeSHA256"] == capture["sourceTreeSHA256"], "producer source tree differs")
    require(receipt["contractSHA256"] == contract_sha256, "producer contract identity differs")
    require(
        receipt["captureSourceSHA256"] == contract["capture"]["captureSourceSHA256"],
        "producer capture source is not contract-locked",
    )
    require(
        receipt["runnerSourceSHA256"] == contract["capture"]["runnerSourceSHA256"],
        "producer runner source is not contract-locked",
    )
    for field in ("workingDirectory", "captureDirectory", "derivedDataPath"):
        require(
            Path(require_string(receipt[field], f"producer {field}")).is_absolute(),
            f"producer {field} must be absolute",
        )
    require(
        receipt["workingDirectory"] == CANONICAL_SOURCE_ROOT,
        "producer working directory is not the fixed canonical source root",
    )
    require(
        receipt["derivedDataPath"] == CANONICAL_DERIVED_DATA,
        "producer derived-data path is not the fixed canonical build root",
    )
    environment = require_object(receipt["buildEnvironment"], "producer build environment")
    require(environment["MIRMIR_V4_PERFORMANCE_VARIANT"] == "baseline_p05", "producer environment variant differs")
    require(environment["MIRMIR_V4_PERFORMANCE_PRODUCER_NONCE"] == nonce, "producer environment nonce differs")
    require(environment["MIRMIR_V4_PERFORMANCE_PRODUCER_CHALLENGE"] == challenge, "producer environment challenge differs")
    require(environment["MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256"] == contract_sha256, "producer environment contract differs")
    require(environment["MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256"] == receipt["captureSourceSHA256"], "producer environment capture source differs")
    require(environment["MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256"] == capture["sourceIdentitySHA256"], "producer environment source identity differs")
    require(environment["MIRMIR_V4_PERFORMANCE_SOURCE_REVISION"] == receipt["sourceRevision"], "producer environment revision differs")
    require(environment["MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256"] == receipt["sourceTreeSHA256"], "producer environment source tree differs")
    require(environment["MIRMIR_V4_PERFORMANCE_CAPTURE_DIR"] == receipt["captureDirectory"], "producer environment capture directory differs")
    require(environment["MIRMIR_V4_PERFORMANCE_WARMUPS"] == str(capture["warmupCount"]), "producer environment warmup count differs")
    require(environment["MIRMIR_V4_PERFORMANCE_SAMPLES"] == str(capture["sampleCount"]), "producer environment sample count differs")
    input_path = Path(require_string(
        environment["MIRMIR_V4_PERFORMANCE_INPUT"], "producer environment input"
    ))
    require(input_path.is_absolute(), "producer environment input must be absolute")
    repository_input = contract["workload"]["input"]["repositoryPath"]
    require(
        input_path.as_posix().endswith("/" + repository_input),
        "producer environment input path differs from the locked workload",
    )
    command = require_list(receipt["buildCommand"], "producer build command")
    require(
        command == _expected_baseline_build_command(receipt),
        "producer build command/configuration differs",
    )
    build_request_path, build_request_sha = validate_descriptor(
        directory, receipt["buildRequestArtifact"], "producer build request"
    )
    require(
        build_request_path == (directory / "producer/build-request.json").resolve(),
        "producer build-request path differs",
    )
    require(
        build_request_sha == capture["producerRequestSHA256"],
        "producer build request is not capture-bound",
    )
    require(
        canonical_json(load_json(build_request_path)) == canonical_json(environment),
        "producer build request differs from the exact build environment",
    )
    capture_path, capture_sha = validate_descriptor(
        directory, receipt["captureArtifact"], "producer capture artifact"
    )
    require(capture_path == (directory / "capture.json").resolve(), "producer capture path differs")
    sample_path, sample_artifact_sha = validate_descriptor(
        directory,
        receipt["sampleTranscriptArtifact"],
        "producer sample transcript artifact",
    )
    require(sample_path == (directory / "sample-transcripts.json").resolve(), "producer sample transcript path differs")
    sample_set, sample_count = validate_sample_transcripts(directory, capture)
    measurement_set = sample_measurement_set_sha256(capture)
    workload_identity = sample_workload_identity_sha256(capture)
    require(receipt["sampleTranscriptSetSHA256"] == sample_set, "producer sample transcript set differs")
    require(receipt["sampleMeasurementSetSHA256"] == measurement_set, "producer sample measurement set differs")
    require(
        receipt["sampleWorkloadIdentitySHA256"] == workload_identity,
        "producer sample workload identity differs",
    )
    require(receipt["sampleTranscriptCount"] == sample_count, "producer sample transcript count differs")
    input_artifact_path, input_artifact_sha = validate_descriptor(
        directory, receipt["inputArtifact"], "producer locked input artifact"
    )
    require(input_artifact_path == (directory / "producer/locked-input.mov").resolve(), "producer locked input artifact path differs")
    require(input_artifact_sha == contract["workload"]["input"]["sha256"], "producer locked input SHA-256 differs")
    require(input_artifact_path.stat().st_size == contract["workload"]["input"]["byteCount"], "producer locked input byte count differs")
    application_path, application_sha = validate_descriptor(
        directory,
        receipt["applicationExecutableArtifact"],
        "producer application executable",
    )
    test_path, test_sha = validate_descriptor(
        directory,
        receipt["testExecutableArtifact"],
        "producer test executable",
    )
    require(application_path == (directory / "producer/application-executable").resolve(), "producer application executable path differs")
    require(test_path == (directory / "producer/test-executable").resolve(), "producer test executable path differs")
    require(application_sha != test_sha, "producer application and test executables are identical")
    macho_magics = {
        b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
        b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
    }
    require(application_path.read_bytes()[:4] in macho_magics, "producer application executable is not Mach-O")
    require(test_path.read_bytes()[:4] in macho_magics, "producer test executable is not Mach-O")
    tree_sha, result_count, result_bytes = _validate_result_bundle(
        directory, receipt["resultBundle"]
    )
    require(
        receipt["resultBundle"]["originalPath"]
        == receipt["captureDirectory"] + "/producer/baseline.xcresult",
        "producer result-bundle original path differs from the capture",
    )
    test_summary, test_summary_sha = _validate_test_summary(
        directory,
        receipt["normalizedTestSummaryArtifact"],
        allow_fixture_runtime,
    )
    log_path, log_sha = validate_descriptor(
        directory, receipt["buildLogArtifact"], "producer build log"
    )
    require(log_path == (directory / "xcodebuild.log").resolve(), "producer build log path differs")
    require(log_path.stat().st_size > 0, "producer build log is empty")
    supplied_wrapper_identity = require_object(
        receipt["swiftDriverWrapperIdentity"],
        "producer Swift driver wrapper identity",
    )
    supplied_underlying = require_object(
        supplied_wrapper_identity.get("underlyingSwiftc"),
        "producer underlying Swift compiler identity",
    )
    underlying_swiftc = Path(
        require_string(
            supplied_underlying.get("path"),
            "producer underlying Swift compiler path",
        )
    )
    require(
        underlying_swiftc.is_absolute(),
        "producer underlying Swift compiler path must be absolute",
    )
    expected_compiler_audit = _compiler_control_audit(
        directory, receipt, underlying_swiftc
    )
    supplied_compiler_audit = require_object(
        receipt["compilerControlAudit"], "producer compiler-control audit"
    )
    require(
        canonical_json(supplied_compiler_audit)
        == canonical_json(expected_compiler_audit),
        "producer compiler-control audit differs from the sealed wrapper transcript",
    )
    expected_stable_facts = _stable_producer_facts(
        receipt=receipt,
        capture=capture,
        application_sha256=application_sha,
        test_sha256=test_sha,
        input_sha256=input_artifact_sha,
        workload_identity_sha256=workload_identity,
        test_summary=test_summary,
        toolchain_identity=_stable_toolchain_identity(directory),
        compiler_control_audit=expected_compiler_audit,
    )
    supplied_stable_facts = require_object(
        receipt["stableProducerFacts"], "producer stable facts"
    )
    require(
        canonical_json(supplied_stable_facts) == canonical_json(expected_stable_facts),
        "producer stable facts differ from recomputed path-neutral facts",
    )
    stable_identity = require_sha256(
        receipt["stableProducerIdentitySHA256"], "stable producer identity"
    )
    require(
        stable_identity == _stable_producer_identity(expected_stable_facts),
        "stable producer identity differs",
    )
    supplied_binding = require_sha256(
        receipt["causalBindingSHA256"], "producer causal binding"
    )
    require(
        supplied_binding == _producer_causal_binding(receipt),
        "producer causal binding differs",
    )
    return {
        "producerReceiptSHA256": sha256_file(receipt_path),
        "producerInvocationNonce": nonce,
        "producerChallenge": challenge,
        "buildRequestSHA256": build_request_sha,
        "captureSHA256": capture_sha,
        "sampleTranscriptArtifactSHA256": sample_artifact_sha,
        "sampleTranscriptSetSHA256": sample_set,
        "sampleMeasurementSetSHA256": measurement_set,
        "sampleWorkloadIdentitySHA256": workload_identity,
        "sampleTranscriptCount": sample_count,
        "inputArtifactSHA256": input_artifact_sha,
        "applicationExecutableSHA256": application_sha,
        "testExecutableSHA256": test_sha,
        "resultBundleTreeSHA256": tree_sha,
        "resultBundleFileCount": result_count,
        "resultBundleByteCount": result_bytes,
        "normalizedTestSummarySHA256": test_summary_sha,
        "buildLogSHA256": log_sha,
        "compilerControlAudit": expected_compiler_audit,
        "producerStableFacts": expected_stable_facts,
        "producerStableIdentitySHA256": stable_identity,
    }


def seal_baseline_producer_receipt(
    *,
    directory: Path,
    contract_path: Path,
    runner_path: Path,
    invocation_nonce: str,
    challenge: str,
    started_ns: int,
    finished_ns: int,
    working_directory: str,
    capture_directory: str,
    derived_data_path: str,
    command_path: Path,
    environment_path: Path,
    build_request_path: Path,
    application_executable: Path,
    test_executable: Path,
    locked_input: Path,
    result_bundle: Path,
    swift_driver_wrapper: Path,
    swift_driver_audit: Path,
    swift_frontend_shim: Path,
    swift_frontend_audit: Path,
    swift_supplementary_maps: Path,
    underlying_swiftc: Path,
    allow_fixture_runtime: bool = False,
) -> dict[str, Any]:
    contract, contract_sha = load_contract(contract_path)
    producer = directory / "producer"
    producer.mkdir(parents=True, exist_ok=True)
    application_destination = producer / "application-executable"
    test_destination = producer / "test-executable"
    input_destination = producer / "locked-input.mov"
    request_destination = producer / "build-request.json"
    wrapper_destination = producer / "swiftc"
    audit_destination = producer / "swift-driver-effective-argv.log"
    frontend_shim_destination = producer / "swift-frontend"
    frontend_audit_destination = producer / "swift-frontend-effective-argv.jsonl"
    supplementary_destination = producer / "supplementary-output-maps"
    require(not application_destination.exists(), "producer application executable already exists")
    require(not test_destination.exists(), "producer test executable already exists")
    require(not input_destination.exists(), "producer locked input already exists")
    require(not request_destination.exists(), "producer build request already exists")
    require(not wrapper_destination.exists(), "producer Swift wrapper already exists")
    require(not audit_destination.exists(), "producer Swift audit already exists")
    require(not frontend_shim_destination.exists(), "producer Swift frontend shim already exists")
    require(not frontend_audit_destination.exists(), "producer Swift frontend audit already exists")
    require(not supplementary_destination.exists(), "producer Swift supplementary maps already exist")
    shutil.copy2(application_executable, application_destination)
    shutil.copy2(test_executable, test_destination)
    shutil.copy2(locked_input, input_destination)
    shutil.copy2(build_request_path, request_destination)
    shutil.copy2(swift_driver_wrapper, wrapper_destination)
    shutil.copy2(swift_driver_audit, audit_destination)
    shutil.copy2(swift_frontend_shim, frontend_shim_destination)
    shutil.copy2(swift_frontend_audit, frontend_audit_destination)
    supplementary_destination.mkdir(mode=0o700)
    supplementary_artifacts: dict[str, Any] = {}
    for module_name in SWIFT_DRIVER_REQUIRED_MODULES:
        source_map = swift_supplementary_maps / f"{module_name}.json"
        destination_map = supplementary_destination / f"{module_name}.json"
        require(
            source_map.is_file() and not source_map.is_symlink(),
            f"producer Swift {module_name} supplementary map is absent or unsafe",
        )
        shutil.copy2(source_map, destination_map)
        supplementary_artifacts[module_name] = descriptor(destination_map, directory)
    result_manifest = _result_bundle_manifest(directory, result_bundle)
    result_manifest_path = producer / "result-bundle-manifest.json"
    write_json(result_manifest_path, result_manifest)
    capture = require_object(load_json(directory / "capture.json"), "baseline capture")
    sample_set, sample_count = validate_sample_transcripts(directory, capture)
    measurement_set = sample_measurement_set_sha256(capture)
    workload_identity = sample_workload_identity_sha256(capture)
    command = require_list(load_json(command_path), "producer build command")
    environment = require_object(
        load_json(environment_path), "producer build environment"
    )
    receipt: dict[str, Any] = {
        "schemaVersion": PRODUCER_RECEIPT_SCHEMA,
        "variant": "baseline_p05",
        "invocationNonce": invocation_nonce,
        "challenge": challenge,
        "startedAtUnixNanoseconds": started_ns,
        "finishedAtUnixNanoseconds": finished_ns,
        "durationNanoseconds": finished_ns - started_ns,
        "exitStatus": 0,
        "buildConfiguration": "Release",
        "sourceRevision": capture["sourceRevision"],
        "sourceTreeSHA256": capture["sourceTreeSHA256"],
        "contractSHA256": contract_sha,
        "captureSourceSHA256": contract["capture"]["captureSourceSHA256"],
        "runnerSourceSHA256": sha256_file(runner_path),
        "workingDirectory": working_directory,
        "captureDirectory": capture_directory,
        "derivedDataPath": derived_data_path,
        "buildCommand": command,
        "buildEnvironment": environment,
        "buildRequestArtifact": descriptor(request_destination, directory),
        "captureArtifact": descriptor(directory / "capture.json", directory),
        "sampleTranscriptArtifact": descriptor(
            directory / "sample-transcripts.json", directory
        ),
        "sampleTranscriptSetSHA256": sample_set,
        "sampleMeasurementSetSHA256": measurement_set,
        "sampleWorkloadIdentitySHA256": workload_identity,
        "sampleTranscriptCount": sample_count,
        "inputArtifact": descriptor(input_destination, directory),
        "applicationExecutableArtifact": descriptor(
            application_destination, directory
        ),
        "testExecutableArtifact": descriptor(test_destination, directory),
        "resultBundle": {
            "path": "producer/baseline.xcresult",
            "originalPath": str(result_bundle.resolve(strict=True)),
            "fileCount": result_manifest["fileCount"],
            "byteCount": result_manifest["byteCount"],
            "treeSHA256": result_manifest["treeSHA256"],
            "manifestArtifact": descriptor(result_manifest_path, directory),
        },
        "normalizedTestSummaryArtifact": descriptor(
            producer / "test-summary.json", directory
        ),
        "buildLogArtifact": descriptor(directory / "xcodebuild.log", directory),
        "swiftDriverWrapperArtifact": descriptor(wrapper_destination, directory),
        "swiftDriverAuditArtifact": descriptor(audit_destination, directory),
        "swiftFrontendShimArtifact": descriptor(
            frontend_shim_destination, directory
        ),
        "swiftFrontendAuditArtifact": descriptor(
            frontend_audit_destination, directory
        ),
        "swiftFrontendSupplementaryMapArtifacts": supplementary_artifacts,
    }
    receipt["swiftDriverWrapperIdentity"] = _swift_wrapper_identity(
        wrapper_destination, underlying_swiftc
    )
    receipt["swiftFrontendShimIdentity"] = _swift_frontend_shim_identity(
        frontend_shim_destination, underlying_swiftc
    )
    receipt["compilerControlAudit"] = _compiler_control_audit(
        directory, receipt, underlying_swiftc
    )
    test_summary = require_object(
        load_json(producer / "test-summary.json"), "producer normalized test summary"
    )
    receipt["stableProducerFacts"] = _stable_producer_facts(
        receipt=receipt,
        capture=capture,
        application_sha256=receipt["applicationExecutableArtifact"]["sha256"],
        test_sha256=receipt["testExecutableArtifact"]["sha256"],
        input_sha256=receipt["inputArtifact"]["sha256"],
        workload_identity_sha256=workload_identity,
        test_summary=test_summary,
        toolchain_identity=_stable_toolchain_identity(directory),
        compiler_control_audit=receipt["compilerControlAudit"],
    )
    receipt["stableProducerIdentitySHA256"] = _stable_producer_identity(
        receipt["stableProducerFacts"]
    )
    receipt["causalBindingSHA256"] = _producer_causal_binding(receipt)
    receipt_path = producer / "producer-receipt.json"
    write_json(receipt_path, receipt)
    validate_baseline_producer_receipt(
        directory,
        capture,
        contract,
        contract_sha,
        allow_fixture_runtime,
    )
    return receipt


def validate_environment(value: Any, label: str) -> dict[str, Any]:
    environment = require_object(value, label)
    require(environment.get("schemaVersion") == ENVIRONMENT_SCHEMA, f"{label} schema differs")
    stable = require_object(environment.get("stableIdentity"), f"{label}.stableIdentity")
    for field in (
        "hardwareModel",
        "memoryBytes",
        "processor",
        "gpuIdentity",
        "macOSBuild",
        "xcodeBuild",
        "swiftCompiler",
    ):
        require(field in stable, f"{label} lacks stable identity {field}")
    require_bool(
        require_object(environment.get("thermal"), f"{label}.thermal").get("accepted"),
        f"{label}.thermal.accepted",
    )
    require_string(
        require_object(environment.get("power"), f"{label}.power").get("identity"),
        f"{label}.power.identity",
    )
    return environment


def validate_source_identity(
    value: Any,
    variant: str,
    contract: dict[str, Any],
) -> dict[str, Any]:
    identity = require_object(value, f"{variant} source identity")
    require(identity.get("schemaVersion") == SOURCE_IDENTITY_SCHEMA, "source identity schema differs")
    require(identity.get("variant") == variant, "source identity variant differs")
    revision = require_revision(identity.get("sourceRevision"), "source identity revision")
    require_sha256(identity.get("sourceTreeSHA256"), "source tree SHA-256")
    runtime = require_object(identity.get("runtime"), "source runtime identity")
    require(
        require_bool(runtime.get("artifactsVerified"), "runtime artifactsVerified"),
        "runtime artifacts are not verified",
    )
    if variant == "baseline_p05":
        baseline = contract["baseline"]
        require(revision == baseline["sourceRevision"], "baseline revision is not frozen")
        require(runtime.get("status") == baseline["runtimeStatus"], "baseline runtime status differs")
        require(
            runtime.get("implementationVersions") == baseline["implementationVersions"],
            "baseline implementation identities differ",
        )
        require(runtime.get("releaseQualified") is False, "P05 baseline may not claim release qualification")
        require(runtime.get("manifestSHA256") is None, "P05 baseline must not invent a runtime manifest")
    else:
        candidate = contract["candidate"]
        require(runtime.get("status") == candidate["requiredRuntimeStatus"], "candidate is not release-qualified")
        require(runtime.get("runtimeID") == candidate["requiredRuntimeID"], "candidate runtime ID differs")
        require(
            require_bool(runtime.get("releaseQualified"), "candidate release qualification"),
            "candidate release qualification failed",
        )
        require(
            require_bool(runtime.get("trustRootConfigured"), "candidate trust-root configuration"),
            "candidate trust-root configuration failed",
        )
        require_sha256(runtime.get("manifestSHA256"), "candidate manifest SHA-256")
        require_provenance_revision(
            runtime.get("manifestSourceRevision"),
            "candidate manifest source revision",
        )
        require_sha256(runtime.get("builderSourceSHA256"), "candidate builder source SHA-256")
        versions = require_list(runtime.get("implementationVersions"), "candidate implementation versions")
        require(versions == [candidate["requiredRuntimeID"]], "candidate implementation identity differs")
        require("p05" not in json.dumps(runtime).lower(), "candidate runtime identity contains P05")
        require("preview" not in json.dumps(runtime).lower(), "candidate runtime identity contains preview")
    return identity


def _validate_verification(value: Any, label: str) -> dict[str, Any]:
    verification = require_object(value, label)
    require_exact_keys(
        verification,
        VERIFICATION_BOOLEAN_FIELDS + VERIFICATION_HASH_FIELDS,
        label,
    )
    for flag in VERIFICATION_BOOLEAN_FIELDS:
        require_bool(verification.get(flag), f"{label}.{flag}")
        require(verification[flag], f"{label}.{flag} failed")
    require_sha256(verification.get("decodedVisiblePixelSHA256"), f"{label}.decoded pixels")
    require_sha256(verification.get("semanticTrackManifestSHA256"), f"{label}.track manifest")
    return verification


def validate_capture(
    directory: Path,
    variant: str,
    contract: dict[str, Any],
    contract_sha256: str,
    allow_unbound_fixture: bool = False,
) -> dict[str, Any]:
    _, artifact_manifest_sha = verify_artifact_manifest(directory, variant)
    source_path = directory / "source-identity.json"
    source_identity = validate_source_identity(load_json(source_path), variant, contract)
    before = validate_environment(load_json(directory / "environment-before.json"), f"{variant} environment before")
    after = validate_environment(load_json(directory / "environment-after.json"), f"{variant} environment after")
    capture = require_object(load_json(directory / "capture.json"), f"{variant} capture")
    base_fields = {
        "schemaVersion",
        "variant",
        "contractSHA256",
        "captureSourceSHA256",
        "sourceIdentitySHA256",
        "sourceRevision",
        "sourceTreeSHA256",
        "buildConfiguration",
        "warmupCount",
        "sampleCount",
        "input",
        "cases",
    }
    observed_fields = set(capture)
    if variant == "baseline_p05":
        require(
            observed_fields
            == base_fields | {
                "producerInvocationNonce",
                "producerChallenge",
                "producerRequestSHA256",
            },
            "baseline capture field set differs",
        )
        require_sha256(
            capture["producerInvocationNonce"], "baseline producer invocation nonce"
        )
        require_sha256(
            capture["producerChallenge"], "baseline producer challenge"
        )
        require_sha256(
            capture["producerRequestSHA256"], "baseline producer request"
        )
    else:
        require(
            observed_fields in (base_fields, base_fields | PACKAGED_CAPTURE_FIELDS),
            "candidate capture field set differs",
        )
        if observed_fields == base_fields | PACKAGED_CAPTURE_FIELDS:
            require_sha256(
                capture["evidenceRequestSHA256"],
                "candidate capture evidence request",
            )
            require_sha256(
                capture["observerSourceSHA256"],
                "candidate capture observer source",
            )
            require_object(
                capture["packagedCandidateIdentity"],
                "candidate capture packaged identity",
            )
        else:
            require(
                allow_unbound_fixture,
                "candidate capture omits exact packaged-candidate identities",
            )
    require(capture.get("schemaVersion") == CAPTURE_SCHEMA, "capture schema differs")
    require(capture.get("variant") == variant, "capture variant differs")
    require_sha256(capture.get("contractSHA256"), "capture contract SHA-256")
    require(capture["contractSHA256"] == contract_sha256, "capture contract identity differs")
    require_sha256(capture.get("captureSourceSHA256"), "capture source SHA-256")
    require(
        capture["captureSourceSHA256"] == contract["capture"]["captureSourceSHA256"],
        "capture source is not contract-locked",
    )
    require_sha256(capture.get("sourceIdentitySHA256"), "capture source-identity SHA-256")
    require(capture["sourceIdentitySHA256"] == sha256_file(source_path), "source identity is not capture-bound")
    require(capture.get("sourceRevision") == source_identity["sourceRevision"], "capture source revision differs")
    require(capture.get("sourceTreeSHA256") == source_identity["sourceTreeSHA256"], "capture source tree differs")
    warmups = require_integer(capture.get("warmupCount"), "capture warmup count")
    samples = require_integer(capture.get("sampleCount"), "capture sample count")
    require(warmups >= contract["capture"]["minimumWarmupRuns"], "capture has too few warmups")
    require(samples >= contract["capture"]["minimumMeasuredRuns"], "capture has too few measured runs")
    require(capture.get("buildConfiguration") == "Release", "capture was not a Release build")
    input_identity = require_object(capture.get("input"), "capture input")
    input_contract = contract["workload"]["input"]
    for field in (
        "sha256",
        "byteCount",
        "width",
        "height",
        "codecFourCC",
        "frameCount",
        "trackCount",
        "enabledVideoTrackCount",
        "durationNumerator",
        "durationTimescale",
    ):
        require(input_identity.get(field) == input_contract[field], f"capture input {field} differs")
    require_bool(input_identity.get("allRequiredChecksPassed"), "input verification")
    require(input_identity["allRequiredChecksPassed"], "input verification failed")
    requested = contract["workload"]["cases"]
    requested_by_id = {case["id"]: case for case in requested}
    cases = require_list(capture.get("cases"), "capture cases")
    require(len(cases) == len(requested), "capture case count differs")
    seen: set[str] = set()
    for raw_case in cases:
        case = require_object(raw_case, "capture case")
        case_id = require_string(case.get("id"), "capture case ID")
        require(case_id in requested_by_id and case_id not in seen, f"unexpected/duplicate case {case_id}")
        seen.add(case_id)
        expected = requested_by_id[case_id]
        for field in ("backendID", "targetWidth", "targetHeight"):
            require(case.get(field) == expected[field], f"case {case_id} {field} differs")
        output_contract = contract["workload"]["output"]
        request = require_object(case.get("request"), f"case {case_id} request")
        require_exact_keys(
            request, PERFORMANCE_REQUEST_FIELDS, f"case {case_id} request"
        )
        for field in PERFORMANCE_REQUEST_FIELDS:
            require(request.get(field) == output_contract[field], f"case {case_id} request {field} differs")
        engine_runs = require_list(case.get("engineRuns"), f"case {case_id} engine runs")
        wall_runs = require_list(case.get("endToEndRuns"), f"case {case_id} end-to-end runs")
        require(len(engine_runs) == samples and len(wall_runs) == samples, f"case {case_id} sample count differs")
        expected_indices = list(range(samples))
        require([run.get("sampleIndex") for run in engine_runs] == expected_indices, f"case {case_id} engine sample order differs")
        require([run.get("sampleIndex") for run in wall_runs] == expected_indices, f"case {case_id} wall sample order differs")
        frame_hashes: set[str] = set()
        track_hashes: set[str] = set()
        for run in engine_runs:
            frame_milliseconds = require_list(run.get("frameMilliseconds"), f"case {case_id} engine frame samples")
            require(len(frame_milliseconds) == input_contract["frameCount"], f"case {case_id} engine frame count differs")
            for index, value in enumerate(frame_milliseconds):
                require_number(value, f"case {case_id} engine frame {index}")
            require(run.get("processedFrameCount") == input_contract["frameCount"], f"case {case_id} engine processed count differs")
        for run in wall_runs:
            require_number(run.get("wallMilliseconds"), f"case {case_id} wall time")
            require_number(run.get("peakResidentBytes"), f"case {case_id} peak resident")
            require(run.get("processedFrameCount") == input_contract["frameCount"], f"case {case_id} output frame count differs")
            verification = _validate_verification(run.get("verification"), f"case {case_id} verification")
            frame_hashes.add(verification["decodedVisiblePixelSHA256"])
            track_hashes.add(verification["semanticTrackManifestSHA256"])
        require(len(frame_hashes) == 1, f"case {case_id} decoded pixels changed across runs")
        require(len(track_hashes) == 1, f"case {case_id} track semantics changed across runs")
    require(seen == set(requested_by_id), "mandatory capture matrix is incomplete")
    sample_set_sha256, sample_transcript_count = validate_sample_transcripts(
        directory, capture
    )
    sample_measurement_sha256 = sample_measurement_set_sha256(capture)
    sample_workload_sha256 = sample_workload_identity_sha256(capture)
    producer_identity = None
    if variant == "baseline_p05":
        producer_identity = validate_baseline_producer_receipt(
            directory,
            capture,
            contract,
            contract_sha256,
            allow_unbound_fixture,
        )
    capture["_validated"] = {
        "artifactManifestSHA256": artifact_manifest_sha,
        "environmentBefore": before,
        "environmentAfter": after,
        "sourceIdentity": source_identity,
        "sampleTranscriptSetSHA256": sample_set_sha256,
        "sampleMeasurementSetSHA256": sample_measurement_sha256,
        "sampleWorkloadIdentitySHA256": sample_workload_sha256,
        "sampleTranscriptCount": sample_transcript_count,
        "producerReceipt": producer_identity,
    }
    return capture


def _percentile(values: Sequence[float], quantile: float) -> float:
    require(len(values) > 0, "cannot calculate a percentile of no samples")
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def _ratio(candidate: float, baseline: float, label: str) -> float:
    require(baseline > 0.0, f"baseline {label} must be positive")
    ratio = candidate / baseline
    require(math.isfinite(ratio), f"{label} ratio is not finite")
    return ratio


def _case_map(capture: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {case["id"]: case for case in capture["cases"]}


def _wall_samples(capture: dict[str, Any]) -> list[float]:
    sample_count = capture["sampleCount"]
    by_case = _case_map(capture)
    return [
        sum(by_case[case_id]["endToEndRuns"][index]["wallMilliseconds"] for case_id in sorted(by_case))
        for index in range(sample_count)
    ]


def _engine_samples(capture: dict[str, Any]) -> list[float]:
    values: list[float] = []
    for case_id, case in sorted(_case_map(capture).items()):
        del case_id
        for run in case["engineRuns"]:
            values.extend(float(value) for value in run["frameMilliseconds"])
    return values


def _bootstrap_interval(
    baseline: Sequence[float],
    candidate: Sequence[float],
    statistic: Callable[[Sequence[float]], float],
    iterations: int,
    confidence: float,
    seed: int,
) -> dict[str, float]:
    require(len(baseline) == len(candidate) and len(baseline) > 1, "paired bootstrap samples differ")
    generator = random.Random(seed)
    ratios: list[float] = []
    for _ in range(iterations):
        indices = [generator.randrange(len(baseline)) for _ in range(len(baseline))]
        before = [baseline[index] for index in indices]
        after = [candidate[index] for index in indices]
        baseline_value = statistic(before)
        if baseline_value <= 0.0:
            raise EvidenceError("bootstrap baseline statistic is not positive")
        ratios.append(statistic(after) / baseline_value)
    tail = (1.0 - confidence) / 2.0
    return {
        "confidenceLevel": confidence,
        "lower": _percentile(ratios, tail),
        "upper": _percentile(ratios, 1.0 - tail),
    }


def _stable_environment_identity(environment: dict[str, Any]) -> bytes:
    return canonical_json(environment["stableIdentity"])


def _power_identity(environment: dict[str, Any]) -> str:
    return environment["power"]["identity"]


def _environment_gate(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    contract: dict[str, Any],
) -> dict[str, Any]:
    environments = [
        baseline["_validated"]["environmentBefore"],
        baseline["_validated"]["environmentAfter"],
        candidate["_validated"]["environmentBefore"],
        candidate["_validated"]["environmentAfter"],
    ]
    stable_match = len({_stable_environment_identity(value) for value in environments}) == 1
    power_match = len({_power_identity(value) for value in environments}) == 1
    thermal_pass = all(value["thermal"]["accepted"] is True for value in environments)
    policy = contract["environment"]
    passed = (
        (stable_match or not policy["requireIdenticalHardwareAndSoftwareImage"])
        and (power_match or not policy["requireIdenticalPowerState"])
        and (thermal_pass or not policy["rejectThermalWarnings"])
    )
    return {
        "stableHardwareAndSoftwareImageMatch": stable_match,
        "powerStateMatch": power_match,
        "thermalEnvelopeAccepted": thermal_pass,
        "pass": passed,
    }


def validate_packaged_performance_capture(
    packaged_evidence_path: Path | None,
    repository: Path | None,
    runtime: Path | None,
    contract_sha256: str,
    candidate_directory: Path,
    candidate: dict[str, Any],
) -> dict[str, Any] | None:
    supplied = (
        packaged_evidence_path is not None,
        repository is not None,
        runtime is not None,
    )
    require(
        all(supplied) or not any(supplied),
        "packaged performance evidence requires --packaged-evidence, "
        "--repository, and --runtime together",
    )
    if not any(supplied):
        return None
    assert packaged_evidence_path is not None
    assert repository is not None
    assert runtime is not None
    verifier = packaged_evidence_module()
    try:
        binding = verifier.validate_capture_binding(
            packaged_evidence_path, repository, runtime
        )
    except verifier.PackagedEvidenceError as error:
        raise EvidenceError(
            f"packaged performance evidence failed: {error}"
        ) from error
    require(binding.get("lane") == "performance", "packaged evidence is not performance evidence")
    require(
        binding.get("contractSHA256") == contract_sha256,
        "packaged performance contract identity differs",
    )
    exact_capture = require_object(
        binding.get("captureManifest"), "packaged performance capture"
    )
    scored_capture = require_object(
        load_json(candidate_directory / "capture.json"),
        "candidate performance capture",
    )
    require(
        exact_capture == scored_capture,
        "evaluated performance capture differs from exact packaged observer output",
    )
    package = require_object(
        binding.get("packageIdentity"), "packaged candidate identity"
    )
    source_identity = candidate["_validated"]["sourceIdentity"]
    source_runtime = source_identity["runtime"]
    require(
        candidate.get("evidenceRequestSHA256") == binding.get("requestSHA256")
        and candidate.get("observerSourceSHA256")
            == binding.get("observerSourceSHA256")
        and candidate.get("packagedCandidateIdentity") == package,
        "performance capture packaged identities differ",
    )
    require(
        package.get("sourceCommit") == candidate.get("sourceRevision")
        and package.get("sourceTreeIdentitySHA256")
            == candidate.get("sourceTreeSHA256")
        and package.get("runtimeManifestSHA256")
            == source_runtime.get("manifestSHA256")
        and package.get("runtimeSourceRevision")
            == source_runtime.get("manifestSourceRevision"),
        "performance capture source/runtime differs from packaged candidate",
    )
    return binding


def evaluate(
    contract_path: Path,
    baseline_directory: Path,
    candidate_directory: Path,
    packaged_evidence_path: Path | None = None,
    repository: Path | None = None,
    runtime: Path | None = None,
    allow_fixture_runtime: bool = False,
) -> dict[str, Any]:
    contract, contract_sha = load_contract(contract_path)
    baseline = validate_capture(
        baseline_directory,
        "baseline_p05",
        contract,
        contract_sha,
        allow_fixture_runtime,
    )
    candidate = validate_capture(
        candidate_directory,
        "candidate_p06",
        contract,
        contract_sha,
        allow_fixture_runtime,
    )
    packaged_binding = validate_packaged_performance_capture(
        packaged_evidence_path,
        repository,
        runtime,
        contract_sha,
        candidate_directory,
        candidate,
    )
    require(
        packaged_binding is not None or allow_fixture_runtime,
        "final performance qualification requires exact packaged-candidate evidence",
    )
    require(baseline["warmupCount"] == candidate["warmupCount"], "paired warmup counts differ")
    require(baseline["sampleCount"] == candidate["sampleCount"], "paired sample counts differ")

    baseline_wall = _wall_samples(baseline)
    candidate_wall = _wall_samples(candidate)
    baseline_engine = _engine_samples(baseline)
    candidate_engine = _engine_samples(candidate)
    require(len(baseline_engine) == len(candidate_engine), "paired engine samples differ")
    wall_before = statistics.median(baseline_wall)
    wall_after = statistics.median(candidate_wall)
    engine_median_before = statistics.median(baseline_engine)
    engine_median_after = statistics.median(candidate_engine)
    engine_p95_before = _percentile(baseline_engine, 0.95)
    engine_p95_after = _percentile(candidate_engine, 0.95)
    wall_ratio = _ratio(wall_after, wall_before, "aggregate wall")
    engine_median_ratio = _ratio(engine_median_after, engine_median_before, "engine median")
    engine_p95_ratio = _ratio(engine_p95_after, engine_p95_before, "engine p95")

    measurement = contract["measurement"]
    iterations = measurement["bootstrapIterations"]
    confidence = measurement["confidenceLevel"]
    seed = measurement["bootstrapSeed"]
    wall_interval = _bootstrap_interval(
        baseline_wall,
        candidate_wall,
        statistics.median,
        iterations,
        confidence,
        seed,
    )
    median_interval = _bootstrap_interval(
        baseline_engine,
        candidate_engine,
        statistics.median,
        iterations,
        confidence,
        seed ^ 0x4D454449414E,
    )
    p95_interval = _bootstrap_interval(
        baseline_engine,
        candidate_engine,
        lambda values: _percentile(values, 0.95),
        iterations,
        confidence,
        seed ^ 0x503935,
    )

    case_ratios: list[dict[str, Any]] = []
    baseline_cases = _case_map(baseline)
    candidate_cases = _case_map(candidate)
    for case_id in sorted(baseline_cases):
        before_case = baseline_cases[case_id]
        after_case = candidate_cases[case_id]
        before_wall = [run["wallMilliseconds"] for run in before_case["endToEndRuns"]]
        after_wall = [run["wallMilliseconds"] for run in after_case["endToEndRuns"]]
        before_engine = [
            value for run in before_case["engineRuns"] for value in run["frameMilliseconds"]
        ]
        after_engine = [
            value for run in after_case["engineRuns"] for value in run["frameMilliseconds"]
        ]
        case_ratios.append(
            {
                "id": case_id,
                "wallMedianRatio": _ratio(statistics.median(after_wall), statistics.median(before_wall), f"{case_id} wall"),
                "engineMedianRatio": _ratio(statistics.median(after_engine), statistics.median(before_engine), f"{case_id} engine median"),
                "engineP95Ratio": _ratio(_percentile(after_engine, 0.95), _percentile(before_engine, 0.95), f"{case_id} engine p95"),
            }
        )

    baseline_peak = max(
        run["peakResidentBytes"]
        for case in baseline["cases"]
        for run in case["endToEndRuns"]
    )
    candidate_peak = max(
        run["peakResidentBytes"]
        for case in candidate["cases"]
        for run in case["endToEndRuns"]
    )
    memory_limit = baseline_peak + contract["thresholds"]["temporalHistoryResidentBudgetBytes"]
    memory_pass = candidate_peak <= memory_limit
    environment = _environment_gate(baseline, candidate, contract)
    threshold = contract["thresholds"]["maximumProcessingTimeRatio"]
    upper_required = measurement["requireUpperConfidenceBoundAtOrBelowThreshold"]
    metric_rows = (
        ("aggregateCorpusWall", wall_ratio, wall_interval),
        ("engineFrameMedian", engine_median_ratio, median_interval),
        ("engineFrameP95", engine_p95_ratio, p95_interval),
    )
    metric_gates = {
        name: {
            "ratio": ratio,
            "confidenceInterval": interval,
            "pointEstimatePass": ratio <= threshold,
            "upperConfidenceBoundPass": interval["upper"] <= threshold,
            "pass": ratio <= threshold and (
                interval["upper"] <= threshold if upper_required else True
            ),
        }
        for name, ratio, interval in metric_rows
    }
    measurement_pass = (
        all(row["pass"] for row in metric_gates.values())
        and memory_pass
        and environment["pass"]
    )
    exact_packaged = packaged_binding is not None
    gate_pass = measurement_pass and (exact_packaged or allow_fixture_runtime)
    report: dict[str, Any] = {
        "schemaVersion": REPORT_SCHEMA,
        "gateID": contract["gateID"],
        "contractSHA256": contract_sha,
        "baseline": {
            "sourceRevision": baseline["sourceRevision"],
            "sourceTreeSHA256": baseline["sourceTreeSHA256"],
            "sourceIdentitySHA256": baseline["sourceIdentitySHA256"],
            "artifactManifestSHA256": baseline["_validated"]["artifactManifestSHA256"],
            **baseline["_validated"]["producerReceipt"],
        },
        "candidate": {
            "sourceRevision": candidate["sourceRevision"],
            "sourceTreeSHA256": candidate["sourceTreeSHA256"],
            "sourceIdentitySHA256": candidate["sourceIdentitySHA256"],
            "runtimeManifestSHA256": candidate["_validated"]["sourceIdentity"]["runtime"]["manifestSHA256"],
            "artifactManifestSHA256": candidate["_validated"]["artifactManifestSHA256"],
            "sampleTranscriptSetSHA256": candidate["_validated"]["sampleTranscriptSetSHA256"],
            "sampleMeasurementSetSHA256": candidate["_validated"]["sampleMeasurementSetSHA256"],
            "sampleWorkloadIdentitySHA256": candidate["_validated"]["sampleWorkloadIdentitySHA256"],
            "sampleTranscriptCount": candidate["_validated"]["sampleTranscriptCount"],
            "evidenceRequestSHA256": candidate.get("evidenceRequestSHA256"),
            "observerSourceSHA256": candidate.get("observerSourceSHA256"),
            "packagedCaptureTreeSHA256": (
                packaged_binding["captureTree"]["sha256"]
                if packaged_binding is not None
                else None
            ),
            "packagedCandidateIdentity": candidate.get(
                "packagedCandidateIdentity"
            ),
        },
        "measurement": {
            "buildConfiguration": "Release",
            "warmupCount": baseline["warmupCount"],
            "measuredRunCount": baseline["sampleCount"],
            "engineFrameSampleCount": len(baseline_engine),
            "mandatoryCaseCount": len(baseline["cases"]),
            "bootstrapIterations": iterations,
            "confidenceLevel": confidence,
            "thresholdRatio": threshold,
            "upperConfidenceBoundRequired": upper_required,
        },
        "absoluteMilliseconds": {
            "baseline": {
                "aggregateCorpusWallMedian": wall_before,
                "engineFrameMedian": engine_median_before,
                "engineFrameP95": engine_p95_before,
            },
            "candidate": {
                "aggregateCorpusWallMedian": wall_after,
                "engineFrameMedian": engine_median_after,
                "engineFrameP95": engine_p95_after,
            },
        },
        "metricGates": metric_gates,
        "mandatoryCaseRatios": case_ratios,
        "memoryGate": {
            "baselinePeakResidentBytes": baseline_peak,
            "candidatePeakResidentBytes": candidate_peak,
            "temporalHistoryBudgetBytes": contract["thresholds"]["temporalHistoryResidentBudgetBytes"],
            "maximumCandidateResidentBytes": memory_limit,
            "pass": memory_pass,
        },
        "environmentGate": environment,
        "semanticVerificationPass": True,
        "exactPackagedCandidatePass": exact_packaged,
        "qualificationMode": (
            "release" if exact_packaged else "diagnostic_fixture"
        ),
        "releaseEligible": exact_packaged and measurement_pass,
        "gatePass": gate_pass,
    }
    report["reportSHA256"] = sha256_bytes(canonical_json(report))
    return report


def verify_report(
    report: Any,
    contract_path: Path,
    *,
    baseline_directory: Path | None = None,
    candidate_directory: Path | None = None,
    packaged_evidence_path: Path | None = None,
    repository: Path | None = None,
    runtime: Path | None = None,
    allow_fixture_runtime: bool = False,
) -> dict[str, Any]:
    contract, contract_sha = load_contract(contract_path)
    value = require_object(report, "performance report")
    require(value.get("schemaVersion") == REPORT_SCHEMA, "performance report schema differs")
    require(value.get("gateID") == contract["gateID"], "performance gate ID differs")
    require(value.get("contractSHA256") == contract_sha, "performance contract identity differs")
    supplied_hash = require_sha256(value.get("reportSHA256"), "performance report SHA-256")
    unsigned = dict(value)
    del unsigned["reportSHA256"]
    require(sha256_bytes(canonical_json(unsigned)) == supplied_hash, "performance report seal differs")
    threshold = contract["thresholds"]["maximumProcessingTimeRatio"]
    metric_gates = require_object(value.get("metricGates"), "performance metric gates")
    require(
        set(metric_gates)
        == {"aggregateCorpusWall", "engineFrameMedian", "engineFrameP95"},
        "performance metric gate set differs",
    )
    for name, raw_gate in metric_gates.items():
        gate = require_object(raw_gate, f"metric gate {name}")
        ratio = require_number(gate.get("ratio"), f"metric gate {name} ratio")
        interval = require_object(gate.get("confidenceInterval"), f"metric gate {name} confidence interval")
        upper = require_number(interval.get("upper"), f"metric gate {name} upper bound")
        expected_point = ratio <= threshold
        expected_upper = upper <= threshold
        require(gate.get("pointEstimatePass") is expected_point, f"metric gate {name} point result is inconsistent")
        require(gate.get("upperConfidenceBoundPass") is expected_upper, f"metric gate {name} confidence result is inconsistent")
        expected_pass = expected_point and (
            expected_upper
            if contract["measurement"]["requireUpperConfidenceBoundAtOrBelowThreshold"]
            else True
        )
        require(gate.get("pass") is expected_pass, f"metric gate {name} result is inconsistent")
    memory = require_object(value.get("memoryGate"), "memory gate")
    baseline_peak = require_integer(
        memory.get("baselinePeakResidentBytes"),
        "memory gate baseline peak",
        0,
    )
    candidate_peak = require_integer(
        memory.get("candidatePeakResidentBytes"),
        "memory gate candidate peak",
        0,
    )
    budget = require_integer(
        memory.get("temporalHistoryBudgetBytes"),
        "memory gate temporal-history budget",
        0,
    )
    maximum = require_integer(
        memory.get("maximumCandidateResidentBytes"),
        "memory gate maximum candidate resident bytes",
        0,
    )
    require(
        budget == contract["thresholds"]["temporalHistoryResidentBudgetBytes"],
        "memory gate budget differs from the contract",
    )
    require(maximum == baseline_peak + budget, "memory gate maximum is inconsistent")
    memory_pass = candidate_peak <= maximum
    require(memory.get("pass") is memory_pass, "memory gate result is inconsistent")

    environment = require_object(value.get("environmentGate"), "environment gate")
    stable_match = require_bool(
        environment.get("stableHardwareAndSoftwareImageMatch"),
        "environment stable-image result",
    )
    power_match = require_bool(
        environment.get("powerStateMatch"),
        "environment power-state result",
    )
    thermal_pass = require_bool(
        environment.get("thermalEnvelopeAccepted"),
        "environment thermal result",
    )
    policy = contract["environment"]
    environment_pass = (
        (stable_match or not policy["requireIdenticalHardwareAndSoftwareImage"])
        and (power_match or not policy["requireIdenticalPowerState"])
        and (thermal_pass or not policy["rejectThermalWarnings"])
    )
    require(
        environment.get("pass") is environment_pass,
        "environment gate result is inconsistent",
    )
    semantic_pass = require_bool(value.get("semanticVerificationPass"), "semantic verification result")
    measurement_pass = (
        all(raw["pass"] is True for raw in metric_gates.values())
        and memory_pass
        and environment_pass
        and semantic_pass
    )
    exact_packaged = require_bool(
        value.get("exactPackagedCandidatePass"),
        "exact packaged-candidate result",
    )
    baseline_identity = require_object(value.get("baseline"), "report baseline")
    require_exact_keys(
        baseline_identity,
        (
            "sourceRevision",
            "sourceTreeSHA256",
            "sourceIdentitySHA256",
            "artifactManifestSHA256",
            "producerReceiptSHA256",
            "producerInvocationNonce",
            "producerChallenge",
            "buildRequestSHA256",
            "captureSHA256",
            "sampleTranscriptArtifactSHA256",
            "sampleTranscriptSetSHA256",
            "sampleMeasurementSetSHA256",
            "sampleWorkloadIdentitySHA256",
            "sampleTranscriptCount",
            "inputArtifactSHA256",
            "applicationExecutableSHA256",
            "testExecutableSHA256",
            "resultBundleTreeSHA256",
            "resultBundleFileCount",
            "resultBundleByteCount",
            "normalizedTestSummarySHA256",
            "buildLogSHA256",
            "compilerControlAudit",
            "producerStableFacts",
            "producerStableIdentitySHA256",
        ),
        "report baseline",
    )
    require_revision(baseline_identity["sourceRevision"], "report baseline revision")
    for field in (
        "sourceTreeSHA256",
        "sourceIdentitySHA256",
        "artifactManifestSHA256",
        "producerReceiptSHA256",
        "producerInvocationNonce",
        "producerChallenge",
        "buildRequestSHA256",
        "captureSHA256",
        "sampleTranscriptArtifactSHA256",
        "sampleTranscriptSetSHA256",
        "sampleMeasurementSetSHA256",
        "sampleWorkloadIdentitySHA256",
        "inputArtifactSHA256",
        "applicationExecutableSHA256",
        "testExecutableSHA256",
        "resultBundleTreeSHA256",
        "normalizedTestSummarySHA256",
        "buildLogSHA256",
        "producerStableIdentitySHA256",
    ):
        require_sha256(baseline_identity[field], f"report baseline {field}")
    for field in (
        "sampleTranscriptCount",
        "resultBundleFileCount",
        "resultBundleByteCount",
    ):
        require_integer(baseline_identity[field], f"report baseline {field}", 1)
    stable_facts = require_object(
        baseline_identity["producerStableFacts"], "report baseline stable facts"
    )
    compiler_audit = require_object(
        baseline_identity["compilerControlAudit"],
        "report baseline compiler-control audit",
    )
    require(
        compiler_audit.get("schemaVersion") == COMPILER_CONTROL_AUDIT_SCHEMA,
        "report baseline compiler-control audit schema differs",
    )
    require(
        stable_facts.get("schemaVersion") == STABLE_PRODUCER_FACTS_SCHEMA,
        "report baseline stable facts schema differs",
    )
    require(
        _stable_producer_identity(stable_facts)
        == baseline_identity["producerStableIdentitySHA256"],
        "report baseline stable producer identity differs",
    )
    candidate_identity = require_object(value.get("candidate"), "report candidate")
    require_exact_keys(
        candidate_identity,
        (
            "sourceRevision",
            "sourceTreeSHA256",
            "sourceIdentitySHA256",
            "runtimeManifestSHA256",
            "artifactManifestSHA256",
            "sampleTranscriptSetSHA256",
            "sampleMeasurementSetSHA256",
            "sampleWorkloadIdentitySHA256",
            "sampleTranscriptCount",
            "evidenceRequestSHA256",
            "observerSourceSHA256",
            "packagedCaptureTreeSHA256",
            "packagedCandidateIdentity",
        ),
        "report candidate",
    )
    require_revision(candidate_identity["sourceRevision"], "report candidate revision")
    for field in (
        "sourceTreeSHA256",
        "sourceIdentitySHA256",
        "runtimeManifestSHA256",
        "artifactManifestSHA256",
        "sampleTranscriptSetSHA256",
        "sampleMeasurementSetSHA256",
        "sampleWorkloadIdentitySHA256",
    ):
        require_sha256(candidate_identity[field], f"report candidate {field}")
    require_integer(
        candidate_identity["sampleTranscriptCount"],
        "report candidate sampleTranscriptCount",
        1,
    )
    packaged_fields = (
        "evidenceRequestSHA256",
        "observerSourceSHA256",
        "packagedCaptureTreeSHA256",
        "packagedCandidateIdentity",
    )
    present = [candidate_identity.get(field) is not None for field in packaged_fields]
    require(
        all(present) == exact_packaged and not (any(present) and not all(present)),
        "performance packaged identity set is inconsistent",
    )
    if exact_packaged:
        for field in packaged_fields[:-1]:
            require_sha256(candidate_identity[field], f"candidate.{field}")
        require_object(
            candidate_identity["packagedCandidateIdentity"],
            "candidate.packagedCandidateIdentity",
        )
    else:
        require(
            allow_fixture_runtime,
            "final performance report omits exact packaged-candidate evidence",
        )
    require(
        value.get("qualificationMode")
            == ("release" if exact_packaged else "diagnostic_fixture"),
        "performance qualification mode is inconsistent",
    )
    require(
        value.get("releaseEligible") is (exact_packaged and measurement_pass),
        "performance release eligibility is inconsistent",
    )
    expected_gate = measurement_pass and (exact_packaged or allow_fixture_runtime)
    require(value.get("gatePass") is expected_gate, "overall performance result is inconsistent")
    require(expected_gate, "deterministic-engine v4 performance gate did not pass")
    if exact_packaged:
        supplied_replay = (
            baseline_directory is not None,
            candidate_directory is not None,
            packaged_evidence_path is not None,
            repository is not None,
            runtime is not None,
        )
        require(
            all(supplied_replay),
            "final performance report verification requires baseline, candidate, "
            "packaged evidence, repository, and runtime",
        )
        assert baseline_directory is not None
        assert candidate_directory is not None
        assert packaged_evidence_path is not None
        assert repository is not None
        assert runtime is not None
        replayed = evaluate(
            contract_path,
            baseline_directory,
            candidate_directory,
            packaged_evidence_path,
            repository,
            runtime,
            False,
        )
        require(
            canonical_json(replayed) == canonical_json(value),
            "performance report differs from replayed exact evidence",
        )
    return value


def make_evidence_manifest(directory: Path) -> dict[str, Any]:
    artifacts = [
        descriptor(path, directory)
        for path in regular_files(directory, excluded=("artifact-manifest.json",))
    ]
    return {"schemaVersion": EVIDENCE_MANIFEST_SCHEMA, "artifacts": artifacts}


def seal_capture_directory(directory: Path) -> dict[str, Any]:
    manifest = make_evidence_manifest(directory)
    manifest["schemaVersion"] = ARTIFACT_MANIFEST_SCHEMA
    write_json(directory / "artifact-manifest.json", manifest)
    return manifest


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    evaluate_parser = commands.add_parser("evaluate")
    evaluate_parser.add_argument("--contract", type=Path, required=True)
    evaluate_parser.add_argument("--baseline", type=Path, required=True)
    evaluate_parser.add_argument("--candidate", type=Path, required=True)
    evaluate_parser.add_argument("--packaged-evidence", type=Path, required=True)
    evaluate_parser.add_argument("--repository", type=Path, required=True)
    evaluate_parser.add_argument("--runtime", type=Path, required=True)
    evaluate_parser.add_argument("--output", type=Path, required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--contract", type=Path, required=True)
    verify_parser.add_argument("--report", type=Path, required=True)
    verify_parser.add_argument("--baseline", type=Path, required=True)
    verify_parser.add_argument("--candidate", type=Path, required=True)
    verify_parser.add_argument("--packaged-evidence", type=Path, required=True)
    verify_parser.add_argument("--repository", type=Path, required=True)
    verify_parser.add_argument("--runtime", type=Path, required=True)
    transcript_parser = commands.add_parser("transcribe")
    transcript_parser.add_argument("--capture", type=Path, required=True)
    transcript_parser.add_argument("--output", type=Path, required=True)
    summary_parser = commands.add_parser("summarize-result")
    summary_parser.add_argument("--result-bundle", type=Path, required=True)
    summary_parser.add_argument("--output", type=Path, required=True)
    baseline_verify_parser = commands.add_parser("verify-baseline-capture")
    baseline_verify_parser.add_argument("--contract", type=Path, required=True)
    baseline_verify_parser.add_argument("--directory", type=Path, required=True)
    producer_parser = commands.add_parser("seal-baseline-producer")
    producer_parser.add_argument("--directory", type=Path, required=True)
    producer_parser.add_argument("--contract", type=Path, required=True)
    producer_parser.add_argument("--runner", type=Path, required=True)
    producer_parser.add_argument("--invocation-nonce", required=True)
    producer_parser.add_argument("--challenge", required=True)
    producer_parser.add_argument("--started-ns", type=int, required=True)
    producer_parser.add_argument("--finished-ns", type=int, required=True)
    producer_parser.add_argument("--working-directory", required=True)
    producer_parser.add_argument("--capture-directory", required=True)
    producer_parser.add_argument("--derived-data", required=True)
    producer_parser.add_argument("--command-json", type=Path, required=True)
    producer_parser.add_argument("--environment-json", type=Path, required=True)
    producer_parser.add_argument("--build-request", type=Path, required=True)
    producer_parser.add_argument("--application-executable", type=Path, required=True)
    producer_parser.add_argument("--test-executable", type=Path, required=True)
    producer_parser.add_argument("--locked-input", type=Path, required=True)
    producer_parser.add_argument("--result-bundle", type=Path, required=True)
    producer_parser.add_argument("--swift-driver-wrapper", type=Path, required=True)
    producer_parser.add_argument("--swift-driver-audit", type=Path, required=True)
    producer_parser.add_argument("--swift-frontend-shim", type=Path, required=True)
    producer_parser.add_argument("--swift-frontend-audit", type=Path, required=True)
    producer_parser.add_argument("--swift-supplementary-maps", type=Path, required=True)
    producer_parser.add_argument("--underlying-swiftc", type=Path, required=True)
    wrapper_parser = commands.add_parser("write-swift-helpers")
    wrapper_parser.add_argument("--underlying-swiftc", type=Path, required=True)
    wrapper_parser.add_argument("--wrapper", type=Path, required=True)
    wrapper_parser.add_argument("--driver-audit", type=Path, required=True)
    wrapper_parser.add_argument("--frontend-shim", type=Path, required=True)
    wrapper_parser.add_argument("--frontend-audit", type=Path, required=True)
    wrapper_parser.add_argument("--temporary-directory", type=Path, required=True)
    wrapper_parser.add_argument("--supplementary-directory", type=Path, required=True)
    seal_parser = commands.add_parser("seal")
    seal_parser.add_argument("--directory", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "evaluate":
            report = evaluate(
                arguments.contract.resolve(),
                arguments.baseline.resolve(),
                arguments.candidate.resolve(),
                arguments.packaged_evidence.resolve(),
                arguments.repository.resolve(),
                arguments.runtime.resolve(),
                False,
            )
            write_json(arguments.output.resolve(), report)
            return 0
        if arguments.command == "verify":
            verify_report(
                load_json(arguments.report.resolve()),
                arguments.contract.resolve(),
                baseline_directory=arguments.baseline.resolve(),
                candidate_directory=arguments.candidate.resolve(),
                packaged_evidence_path=arguments.packaged_evidence.resolve(),
                repository=arguments.repository.resolve(),
                runtime=arguments.runtime.resolve(),
                allow_fixture_runtime=False,
            )
            return 0
        if arguments.command == "transcribe":
            write_sample_transcripts(
                arguments.capture.resolve(strict=True),
                arguments.output.resolve(),
            )
            return 0
        if arguments.command == "summarize-result":
            write_normalized_test_summary(
                arguments.result_bundle.resolve(strict=True),
                arguments.output.resolve(),
            )
            return 0
        if arguments.command == "verify-baseline-capture":
            contract, contract_sha = load_contract(
                arguments.contract.resolve(strict=True)
            )
            validate_capture(
                arguments.directory.resolve(strict=True),
                "baseline_p05",
                contract,
                contract_sha,
                False,
            )
            return 0
        if arguments.command == "write-swift-helpers":
            write_swift_compiler_helpers(
                arguments.underlying_swiftc.resolve(strict=True),
                arguments.wrapper,
                arguments.driver_audit,
                arguments.frontend_shim,
                arguments.frontend_audit,
                arguments.temporary_directory,
                arguments.supplementary_directory,
            )
            return 0
        if arguments.command == "seal-baseline-producer":
            seal_baseline_producer_receipt(
                directory=arguments.directory.resolve(strict=True),
                contract_path=arguments.contract.resolve(strict=True),
                runner_path=arguments.runner.resolve(strict=True),
                invocation_nonce=arguments.invocation_nonce,
                challenge=arguments.challenge,
                started_ns=arguments.started_ns,
                finished_ns=arguments.finished_ns,
                working_directory=arguments.working_directory,
                capture_directory=arguments.capture_directory,
                derived_data_path=arguments.derived_data,
                command_path=arguments.command_json.resolve(strict=True),
                environment_path=arguments.environment_json.resolve(strict=True),
                build_request_path=arguments.build_request.resolve(strict=True),
                application_executable=arguments.application_executable.resolve(strict=True),
                test_executable=arguments.test_executable.resolve(strict=True),
                locked_input=arguments.locked_input.resolve(strict=True),
                result_bundle=arguments.result_bundle.resolve(strict=True),
                swift_driver_wrapper=arguments.swift_driver_wrapper.resolve(strict=True),
                swift_driver_audit=arguments.swift_driver_audit.resolve(strict=True),
                swift_frontend_shim=arguments.swift_frontend_shim.resolve(strict=True),
                swift_frontend_audit=arguments.swift_frontend_audit.resolve(strict=True),
                swift_supplementary_maps=arguments.swift_supplementary_maps.resolve(strict=True),
                underlying_swiftc=arguments.underlying_swiftc.resolve(strict=True),
            )
            return 0
        if arguments.command == "seal":
            directory = arguments.directory.resolve()
            seal_capture_directory(directory)
            return 0
    except EvidenceError as error:
        print(f"performance evidence rejected: {error}", file=sys.stderr)
        return 2
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
