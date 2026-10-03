#!/usr/bin/env python3
"""Fail-closed evaluator for identical-scope production scaler captures."""

from __future__ import annotations

import hashlib
import json
import math
import pathlib
import re
import subprocess
import sys


SCHEMA = "mirmir-v4-pixel-buffer-hot-path-benchmark-v3"
REPORT_SCHEMA = "mirmir-v4-pixel-buffer-hot-path-evaluation-v3"
MAXIMUM_RATIO = 0.80
SCOPE = (
    "production FixedPointPixelBufferScalerV4 process plus ordered "
    "visible-byte SHA-256"
)
WARMUP_COUNT = 5
SAMPLE_COUNT = 15
TIMED_SETUP_EXCLUDED = (
    "scaler construction",
    "scale and coefficient preparation",
    "CPU workspace allocation",
    "Metal pipeline and reusable buffer allocation",
    "pixel-buffer allocation and source fill",
)
CANONICAL_CASES = (
    {
        "id": "nv12-full-arbitrary-853x481",
        "storage": "nv12_full_range_8_bit",
        "sourceWidth": 512,
        "sourceHeight": 288,
        "targetWidth": 853,
        "targetHeight": 481,
        "borderRule": "reflect101",
        "inputSeed": 0,
        "visiblePixelSHA256": (
            "2343ba64fa01b4dc50aaf72ab0718ea47d7e3ac399b8efaf375970c4bba7ba93"
        ),
    },
    {
        "id": "p010-video-exact-3-over-2",
        "storage": "p010_video_range_10_bit",
        "sourceWidth": 512,
        "sourceHeight": 288,
        "targetWidth": 768,
        "targetHeight": 432,
        "borderRule": "reflect101",
        "inputSeed": 0,
        "visiblePixelSHA256": (
            "3a04af52933190bd5ce47af8e5ffe69c36d52a7dfc67fe1485ac351eb917e61a"
        ),
    },
)
METRICS = (
    "cpuMedianMilliseconds",
    "cpuP95Milliseconds",
    "metalMedianMilliseconds",
    "metalP95Milliseconds",
)
SAMPLE_FIELDS = {
    "cpu": "cpuMilliseconds",
    "metal": "metalMilliseconds",
}
ENGINE_SOURCE_PATHS = (
    "Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift",
    "Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal",
    "Mirmir/Modules/UpscalerEngine/PixelLayoutV4.swift",
    "Mirmir/Modules/UpscalerEngine/HDRMetadataV4.swift",
    "Mirmir/Modules/UpscalerEngine/AVFoundationHDRMetadataAdapterV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointPixelBufferScalerV4.swift",
)
BASELINE_REVISION = "54d97e3"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIRECTORY.parent.parent
BENCHMARK_SOURCE = SCRIPT_DIRECTORY / "PixelBufferScalerHotPathBenchmarkMain.swift"
RUNNER_SOURCE = SCRIPT_DIRECTORY / "run_pixel_buffer_scaler_hot_path_benchmark.sh"
POWER_ENVELOPE_CONTRACT = (
    "nominal thermal state and low-power disabled before and after every "
    "iteration; AC power at capture start and end"
)
CAPTURE_KEYS = {
    "schemaVersion",
    "scope",
    "configuration",
    "environment",
    "compiler",
    "identities",
    "cases",
    "aggregate",
}
CONFIGURATION_KEYS = {
    "warmupCount",
    "sampleCountPerCase",
    "device",
    "powerEnvelope",
    "timedSetupExcluded",
}
ENVIRONMENT_KEYS = {
    "hardwareModel",
    "processor",
    "memoryBytes",
    "macOSVersion",
    "macOSBuild",
    "metalDevice",
    "thermalStateAtStart",
    "thermalStateAtEnd",
    "lowPowerModeEnabledAtStart",
    "lowPowerModeEnabledAtEnd",
    "powerSourceAtStart",
    "powerSourceAtEnd",
}
COMPILER_KEYS = {"xcodeVersion", "swiftVersion", "swiftFlags", "metalFlags"}
IDENTITY_KEYS = {
    "benchmarkSourceSHA256",
    "runnerSourceSHA256",
    "engineSourceSHA256",
    "engineSourceManifest",
    "executableSHA256",
    "metalLibrarySHA256",
}
CASE_KEYS = {
    "id",
    "storage",
    "sourceWidth",
    "sourceHeight",
    "targetWidth",
    "targetHeight",
    "borderRule",
    "inputSeed",
    "warmupCount",
    "sampleCount",
    "visiblePixelSHA256",
    "cpuMetalByteParity",
    "cpuMilliseconds",
    "cpuMedianMilliseconds",
    "cpuP95Milliseconds",
    "metalMilliseconds",
    "metalMedianMilliseconds",
    "metalP95Milliseconds",
}
AGGREGATE_KEYS = set(METRICS)


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256_file(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        fail(f"invalid SHA-256 identity: {label}")
    return value


def require_positive_number(value: object, label: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value <= 0
    ):
        fail(f"invalid positive timing value: {label}")
    return float(value)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def require_close(actual: object, expected: float, label: str) -> None:
    value = require_positive_number(actual, label)
    if not math.isclose(value, expected, rel_tol=1e-12, abs_tol=1e-12):
        fail(f"derived timing metric differs from raw samples: {label}")


def authoritative_engine_manifest(role: str) -> tuple[str, str]:
    lines: list[str] = []
    for source_path in ENGINE_SOURCE_PATHS:
        if role == "baseline":
            result = subprocess.run(
                ["git", "show", f"{BASELINE_REVISION}:{source_path}"],
                cwd=REPOSITORY_ROOT,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                fail(
                    "unable to read authoritative baseline source "
                    f"{BASELINE_REVISION}:{source_path}"
                )
            contents = result.stdout
        elif role == "candidate":
            path = REPOSITORY_ROOT / source_path
            try:
                contents = path.read_bytes()
            except OSError as error:
                fail(f"unable to read authoritative candidate source {path}: {error}")
        else:
            fail(f"invalid capture role: {role}")
        lines.append(f"{source_path} {hashlib.sha256(contents).hexdigest()}\n")
    manifest = "".join(lines)
    return manifest, hashlib.sha256(manifest.encode()).hexdigest()


def validate_engine_manifest(identities: dict, label: str, role: str) -> None:
    manifest = identities.get("engineSourceManifest")
    if not isinstance(manifest, str) or not manifest.endswith("\n"):
        fail(f"noncanonical engine source manifest: {label}")
    lines = manifest.splitlines()
    if len(lines) != len(ENGINE_SOURCE_PATHS):
        fail(f"incomplete engine source manifest: {label}")
    for line, expected_path in zip(lines, ENGINE_SOURCE_PATHS):
        fields = line.split(" ")
        if len(fields) != 2 or fields[0] != expected_path:
            fail(f"noncanonical engine source manifest path: {label}")
        require_sha256(fields[1], f"{label}.{expected_path}")
    expected = hashlib.sha256(manifest.encode()).hexdigest()
    actual = require_sha256(
        identities.get("engineSourceSHA256"),
        f"{label}.engineSourceSHA256",
    )
    if actual != expected:
        fail(f"engine source aggregate identity mismatch: {label}")

    authoritative_manifest, authoritative_aggregate = (
        authoritative_engine_manifest(role)
    )
    if manifest != authoritative_manifest:
        fail(
            f"{role} engine source manifest differs from authoritative source: "
            f"{label}"
        )
    if actual != authoritative_aggregate:
        fail(
            f"{role} engine source aggregate differs from authoritative source: "
            f"{label}"
        )


def validate_capture(path: pathlib.Path, role: str) -> dict:
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or value.get("schemaVersion") != SCHEMA:
        fail(f"unexpected benchmark schema in {path}")
    if set(value) != CAPTURE_KEYS:
        fail(f"benchmark document fields differ from the locked contract in {path}")
    if value.get("scope") != SCOPE:
        fail(f"benchmark scope differs from the locked contract in {path}")

    configuration = value.get("configuration")
    if not isinstance(configuration, dict) or set(configuration) != CONFIGURATION_KEYS:
        fail(f"benchmark configuration is missing in {path}")
    warmups = configuration.get("warmupCount")
    samples = configuration.get("sampleCountPerCase")
    if warmups != WARMUP_COUNT:
        fail(f"invalid warmup count in {path}")
    if samples != SAMPLE_COUNT:
        fail(f"invalid sample count in {path}")
    excluded = configuration.get("timedSetupExcluded")
    if excluded != list(TIMED_SETUP_EXCLUDED):
        fail(f"timing boundary differs from the locked contract in {path}")
    if not isinstance(configuration.get("device"), str) or not configuration["device"]:
        fail(f"benchmark device is missing in {path}")
    if configuration.get("powerEnvelope") != POWER_ENVELOPE_CONTRACT:
        fail(f"power-envelope contract is missing in {path}")

    environment = value.get("environment")
    required_environment = (
        "hardwareModel",
        "processor",
        "memoryBytes",
        "macOSVersion",
        "macOSBuild",
        "metalDevice",
    )
    if (
        not isinstance(environment, dict)
        or set(environment) != ENVIRONMENT_KEYS
        or any(
        not isinstance(environment.get(field), str) or not environment[field]
        for field in required_environment
        )
    ):
        fail(f"machine identity is incomplete in {path}")
    if not environment["memoryBytes"].isdigit():
        fail(f"machine memory identity is invalid in {path}")
    required_power_values = {
        "thermalStateAtStart": "nominal",
        "thermalStateAtEnd": "nominal",
        "lowPowerModeEnabledAtStart": False,
        "lowPowerModeEnabledAtEnd": False,
        "powerSourceAtStart": "AC Power",
        "powerSourceAtEnd": "AC Power",
    }
    for field, expected in required_power_values.items():
        if (
            type(environment.get(field)) is not type(expected)
            or environment.get(field) != expected
        ):
            fail(f"power envelope is outside the locked contract in {path}: {field}")
    if configuration.get("device") != environment.get("metalDevice"):
        fail(f"configured Metal device differs from machine identity in {path}")

    compiler = value.get("compiler")
    expected_flags = {
        "swiftFlags": "-O -whole-module-optimization -warnings-as-errors -strict-concurrency=complete",
        "metalFlags": "-O3 -mmacosx-version-min=15.4 -std=metal3.2",
    }
    if not isinstance(compiler, dict) or set(compiler) != COMPILER_KEYS:
        fail(f"compiler identity is missing in {path}")
    for field in ("xcodeVersion", "swiftVersion"):
        if not isinstance(compiler.get(field), str) or not compiler[field]:
            fail(f"compiler identity is incomplete in {path}")
    for field, expected in expected_flags.items():
        if compiler.get(field) != expected:
            fail(f"compiler flags differ from the locked contract in {path}")

    identities = value.get("identities")
    if not isinstance(identities, dict) or set(identities) != IDENTITY_KEYS:
        fail(f"source/binary identities are missing in {path}")
    for field in (
        "benchmarkSourceSHA256",
        "runnerSourceSHA256",
        "engineSourceSHA256",
        "executableSHA256",
        "metalLibrarySHA256",
    ):
        require_sha256(identities.get(field), f"{path}.{field}")
    if identities["benchmarkSourceSHA256"] != sha256_file(BENCHMARK_SOURCE):
        fail(f"benchmark source identity differs from the checked-in harness in {path}")
    if identities["runnerSourceSHA256"] != sha256_file(RUNNER_SOURCE):
        fail(f"runner source identity differs from the checked-in runner in {path}")
    validate_engine_manifest(identities, str(path), role)

    cases = value.get("cases")
    if not isinstance(cases, list) or len(cases) != len(CANONICAL_CASES):
        fail(f"benchmark case count differs from the locked contract in {path}")
    seen_ids: set[str] = set()
    all_samples = {executor: [] for executor in SAMPLE_FIELDS}
    for case, expected_case in zip(cases, CANONICAL_CASES):
        validate_case(
            case,
            expected_case,
            warmups,
            samples,
            path,
            all_samples,
        )
        case_id = case["id"]
        if case_id in seen_ids:
            fail(f"duplicate benchmark case: {case_id}")
        seen_ids.add(case_id)

    aggregate = value.get("aggregate")
    if not isinstance(aggregate, dict) or set(aggregate) != AGGREGATE_KEYS:
        fail(f"aggregate metrics are missing in {path}")
    for executor in SAMPLE_FIELDS:
        require_close(
            aggregate.get(f"{executor}MedianMilliseconds"),
            percentile(all_samples[executor], 0.5),
            f"{path}.aggregate.{executor}.median",
        )
        require_close(
            aggregate.get(f"{executor}P95Milliseconds"),
            percentile(all_samples[executor], 0.95),
            f"{path}.aggregate.{executor}.p95",
        )
    return value


def validate_case(
    case: object,
    expected_case: dict,
    warmups: int,
    sample_count: int,
    path: pathlib.Path,
    all_samples: dict[str, list[float]],
) -> None:
    if not isinstance(case, dict) or set(case) != CASE_KEYS:
        fail(f"invalid benchmark case in {path}")
    locked_fields = (
        "id",
        "storage",
        "sourceWidth",
        "sourceHeight",
        "targetWidth",
        "targetHeight",
        "borderRule",
        "inputSeed",
        "visiblePixelSHA256",
    )
    for field in locked_fields:
        if (
            type(case.get(field)) is not type(expected_case[field])
            or case.get(field) != expected_case[field]
        ):
            fail(
                "benchmark case differs from the locked contract: "
                f"{expected_case['id']}.{field}"
            )
    if case.get("warmupCount") != warmups or case.get("sampleCount") != sample_count:
        fail(f"benchmark case sample contract differs: {case.get('id')}")
    visible_sha256 = require_sha256(
        case.get("visiblePixelSHA256"),
        f"{path}.{case.get('id')}.visiblePixelSHA256",
    )
    if visible_sha256 != expected_case["visiblePixelSHA256"]:
        fail(f"canonical visible-pixel identity differs for {case.get('id')}")
    if case.get("cpuMetalByteParity") is not True:
        fail(f"CPU/Metal byte parity is not proven for {case.get('id')}")

    for executor, sample_field in SAMPLE_FIELDS.items():
        raw = case.get(sample_field)
        if not isinstance(raw, list) or len(raw) != sample_count:
            fail(f"raw sample count differs for {case.get('id')}.{executor}")
        validated = [
            require_positive_number(
                sample,
                f"{path}.{case.get('id')}.{executor}[{index}]",
            )
            for index, sample in enumerate(raw)
        ]
        all_samples[executor].extend(validated)
        require_close(
            case.get(f"{executor}MedianMilliseconds"),
            percentile(validated, 0.5),
            f"{path}.{case.get('id')}.{executor}.median",
        )
        require_close(
            case.get(f"{executor}P95Milliseconds"),
            percentile(validated, 0.95),
            f"{path}.{case.get('id')}.{executor}.p95",
        )


def case_identity(case: dict) -> tuple:
    return (
        case["id"],
        case["storage"],
        case["sourceWidth"],
        case["sourceHeight"],
        case["targetWidth"],
        case["targetHeight"],
        case["borderRule"],
        case["inputSeed"],
        case["warmupCount"],
        case["sampleCount"],
        case["visiblePixelSHA256"],
    )


def main() -> None:
    if len(sys.argv) != 3:
        fail(
            "usage: evaluate_pixel_buffer_scaler_hot_path.py "
            "BASELINE.json CANDIDATE.json"
        )
    baseline_path, candidate_path = map(pathlib.Path, sys.argv[1:])
    baseline = validate_capture(baseline_path, "baseline")
    candidate = validate_capture(candidate_path, "candidate")

    for field in ("scope", "configuration", "environment", "compiler"):
        if baseline.get(field) != candidate.get(field):
            fail(f"candidate {field} differs from baseline")
    baseline_identities = baseline["identities"]
    candidate_identities = candidate["identities"]
    for field in (
        "benchmarkSourceSHA256",
        "runnerSourceSHA256",
        "metalLibrarySHA256",
    ):
        if baseline_identities[field] != candidate_identities[field]:
            fail(f"candidate {field} differs from baseline")
    if (
        baseline_identities["engineSourceSHA256"]
        == candidate_identities["engineSourceSHA256"]
    ):
        fail("baseline and candidate engine source identities are equal")
    if (
        baseline_identities["executableSHA256"]
        == candidate_identities["executableSHA256"]
    ):
        fail("baseline and candidate executable identities are equal")

    baseline_cases = [case_identity(case) for case in baseline["cases"]]
    candidate_cases = [case_identity(case) for case in candidate["cases"]]
    if baseline_cases != candidate_cases:
        fail("candidate workload or visible-pixel SHA-256 differs from baseline")

    aggregate_ratios: dict[str, float] = {}
    case_ratios: dict[str, dict[str, float]] = {}
    failures: list[str] = []
    for metric in METRICS:
        ratio = candidate["aggregate"][metric] / baseline["aggregate"][metric]
        aggregate_ratios[metric] = ratio
        if ratio > MAXIMUM_RATIO:
            failures.append(f"aggregate.{metric}")
    for baseline_case, candidate_case in zip(
        baseline["cases"], candidate["cases"]
    ):
        case_id = baseline_case["id"]
        ratios: dict[str, float] = {}
        for metric in METRICS:
            ratio = candidate_case[metric] / baseline_case[metric]
            ratios[metric] = ratio
            if ratio > MAXIMUM_RATIO:
                failures.append(f"{case_id}.{metric}")
        case_ratios[case_id] = ratios

    report = {
        "schemaVersion": REPORT_SCHEMA,
        "threshold": {"maximumAfterToBeforeRatio": MAXIMUM_RATIO},
        "baseline": str(baseline_path),
        "candidate": str(candidate_path),
        "baselineCaptureSHA256": sha256_file(baseline_path),
        "candidateCaptureSHA256": sha256_file(candidate_path),
        "evaluatorSourceSHA256": sha256_file(pathlib.Path(__file__).resolve()),
        "benchmarkSourceSHA256": baseline_identities["benchmarkSourceSHA256"],
        "runnerSourceSHA256": baseline_identities["runnerSourceSHA256"],
        "baselineEngineSourceSHA256": baseline_identities["engineSourceSHA256"],
        "candidateEngineSourceSHA256": candidate_identities["engineSourceSHA256"],
        "baselineExecutableSHA256": baseline_identities["executableSHA256"],
        "candidateExecutableSHA256": candidate_identities["executableSHA256"],
        "metalLibrarySHA256": baseline_identities["metalLibrarySHA256"],
        "caseCount": len(baseline_cases),
        "sampleCountPerCapture": sum(
            len(case["cpuMilliseconds"]) + len(case["metalMilliseconds"])
            for case in baseline["cases"]
        ),
        "environmentIdentityPreserved": True,
        "compilerIdentityPreserved": True,
        "outputIdentityPreserved": True,
        "canonicalWorkloadLocked": True,
        "rawSamplesValidated": True,
        "aggregateRatios": aggregate_ratios,
        "caseRatios": case_ratios,
        "passed": not failures,
        "failedMetrics": failures,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
