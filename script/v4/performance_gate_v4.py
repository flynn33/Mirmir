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
from pathlib import Path
import random
import statistics
import sys
from typing import Any, Callable, Iterable, Sequence


CONTRACT_SCHEMA = "mirmir-v4-performance-gate-contract-v1"
CAPTURE_SCHEMA = "mirmir-v4-performance-capture-v1"
SOURCE_IDENTITY_SCHEMA = "mirmir-v4-performance-source-identity-v1"
ENVIRONMENT_SCHEMA = "mirmir-v4-performance-environment-v1"
ARTIFACT_MANIFEST_SCHEMA = "mirmir-v4-performance-capture-artifacts-v1"
REPORT_SCHEMA = "mirmir-v4-performance-gate-report-v1"
EVIDENCE_MANIFEST_SCHEMA = "mirmir-v4-performance-evidence-manifest-v1"
SHA256_LENGTH = 64
PACKAGED_CAPTURE_FIELDS = {
    "evidenceRequestSHA256",
    "observerSourceSHA256",
    "packagedCandidateIdentity",
}


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
        relative = require_string(entry["path"], f"artifact {index} path")
        require(
            relative == Path(relative).name
            and relative not in {".", "..", "artifact-manifest.json"},
            f"artifact path is not a contained file: {relative}",
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
        "source-identity.json",
    }
    if variant == "baseline_p05":
        required.add("xcodebuild.log")
    elif variant == "candidate_p06":
        required.add("packaged-observer.log")
    else:
        require(
            {"xcodebuild.log", "packaged-observer.log"} & seen,
            "capture artifacts omit their capture producer log",
        )
    require(required.issubset(seen), f"capture artifacts are missing: {sorted(required - seen)}")
    actual_files = {
        path.name
        for path in directory.iterdir()
        if path.is_file() and path.name != "artifact-manifest.json"
    }
    require(actual_files == seen, "capture directory has unsealed or missing files")
    return manifest, sha256_file(manifest_path)


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
    required_flags = (
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
    for flag in required_flags:
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
        require(observed_fields == base_fields, "baseline capture field set differs")
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
            capture["evidenceRequestSHA256"] = None
            capture["observerSourceSHA256"] = None
            capture["packagedCandidateIdentity"] = None
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
        for field in (
            "codec",
            "fileType",
            "preserveAudio",
            "overwriteExistingFile",
        ):
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
    capture["_validated"] = {
        "artifactManifestSHA256": artifact_manifest_sha,
        "environmentBefore": before,
        "environmentAfter": after,
        "sourceIdentity": source_identity,
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
        },
        "candidate": {
            "sourceRevision": candidate["sourceRevision"],
            "sourceTreeSHA256": candidate["sourceTreeSHA256"],
            "sourceIdentitySHA256": candidate["sourceIdentitySHA256"],
            "runtimeManifestSHA256": candidate["_validated"]["sourceIdentity"]["runtime"]["manifestSHA256"],
            "artifactManifestSHA256": candidate["_validated"]["artifactManifestSHA256"],
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
    candidate_identity = require_object(value.get("candidate"), "report candidate")
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
    artifacts = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name != "artifact-manifest.json":
            artifacts.append(
                {
                    "path": path.name,
                    "byteCount": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
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
