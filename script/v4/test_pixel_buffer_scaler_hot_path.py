#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import math
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
SCRIPT = SCRIPT_DIRECTORY / "evaluate_pixel_buffer_scaler_hot_path.py"
BENCHMARK_SOURCE = SCRIPT_DIRECTORY / "PixelBufferScalerHotPathBenchmarkMain.swift"
RUNNER_SOURCE = SCRIPT_DIRECTORY / "run_pixel_buffer_scaler_hot_path_benchmark.sh"
REPEATABILITY_VERIFIER = (
    SCRIPT_DIRECTORY / "verify_pixel_buffer_scaler_hot_path_repeatability.py"
)
SCHEMA = "mirmir-v4-pixel-buffer-hot-path-benchmark-v4"
SCOPE = (
    "production FixedPointPixelBufferScalerV4 process plus ordered "
    "visible-byte SHA-256"
)
POWER_ENVELOPE_CONTRACT = (
    "nominal thermal state and low-power disabled before and after every "
    "iteration; AC power at capture start and end"
)
TIMED_SETUP_EXCLUDED = [
    "scaler construction",
    "scale and coefficient preparation",
    "CPU workspace allocation",
    "Metal pipeline and reusable buffer allocation",
    "pixel-buffer allocation and source fill",
]
ROUTES = (
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
        "cpuBase": 10.0,
        "metalBase": 8.0,
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
        "cpuBase": 20.0,
        "metalBase": 12.0,
    },
)
ENGINE_SOURCE_PATHS = (
    "Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift",
    "Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal",
    "Mirmir/Modules/UpscalerEngine/PixelLayoutV4.swift",
    "Mirmir/Modules/UpscalerEngine/HDRMetadataV4.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift",
    "Mirmir/Modules/UpscalerEngine/AVFoundationHDRMetadataAdapterV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointPixelBufferScalerV4.swift",
)
BASELINE_REVISION = "54d97e3"
REPOSITORY_ROOT = SCRIPT_DIRECTORY.parent.parent


def sha256_bytes(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def engine_manifest(role: str) -> tuple[str, str]:
    lines: list[str] = []
    for source_path in ENGINE_SOURCE_PATHS:
        if role == "baseline":
            contents = subprocess.run(
                ["git", "show", f"{BASELINE_REVISION}:{source_path}"],
                cwd=REPOSITORY_ROOT,
                capture_output=True,
                check=True,
            ).stdout
        elif role == "candidate":
            contents = (REPOSITORY_ROOT / source_path).read_bytes()
        else:
            raise ValueError(f"unknown fixture role: {role}")
        lines.append(
            f"{source_path} {hashlib.sha256(contents).hexdigest()}\n"
        )
    manifest = "".join(lines)
    return manifest, hashlib.sha256(manifest.encode()).hexdigest()


def refresh_case(case: dict) -> None:
    for executor in ("cpu", "metal"):
        samples = case[f"{executor}Milliseconds"]
        case[f"{executor}MedianMilliseconds"] = percentile(samples, 0.5)
        case[f"{executor}P95Milliseconds"] = percentile(samples, 0.95)


def refresh_aggregate(value: dict) -> None:
    for case in value["cases"]:
        refresh_case(case)
    for executor in ("cpu", "metal"):
        samples = [
            sample
            for case in value["cases"]
            for sample in case[f"{executor}Milliseconds"]
        ]
        value["aggregate"][f"{executor}MedianMilliseconds"] = percentile(
            samples,
            0.5,
        )
        value["aggregate"][f"{executor}P95Milliseconds"] = percentile(
            samples,
            0.95,
        )


def capture(scale: float, identity: str, role: str) -> dict:
    manifest, engine_sha256 = engine_manifest(role)
    cases = []
    for route in ROUTES:
        cpu_base = route["cpuBase"]
        metal_base = route["metalBase"]
        cpu = [(cpu_base + index * 0.01) * scale for index in range(15)]
        metal = [(metal_base + index * 0.01) * scale for index in range(15)]
        case = {
            key: value
            for key, value in route.items()
            if key not in ("cpuBase", "metalBase")
        }
        case.update({
            "warmupCount": 5,
            "sampleCount": 15,
            "cpuMetalByteParity": True,
            "cpuMilliseconds": cpu,
            "metalMilliseconds": metal,
        })
        refresh_case(case)
        cases.append(case)
    value = {
        "schemaVersion": SCHEMA,
        "scope": SCOPE,
        "configuration": {
            "warmupCount": 5,
            "sampleCountPerCase": 15,
            "device": "Fixture GPU",
            "powerEnvelope": POWER_ENVELOPE_CONTRACT,
            "timedSetupExcluded": TIMED_SETUP_EXCLUDED,
        },
        "environment": {
            "hardwareModel": "FixtureMac1,1",
            "processor": "Fixture CPU",
            "memoryBytes": "34359738368",
            "macOSVersion": "15.6",
            "macOSBuild": "24G84",
            "metalDevice": "Fixture GPU",
            "thermalStateAtStart": "nominal",
            "thermalStateAtEnd": "nominal",
            "lowPowerModeEnabledAtStart": False,
            "lowPowerModeEnabledAtEnd": False,
            "powerSourceAtStart": "AC Power",
            "powerSourceAtEnd": "AC Power",
        },
        "compiler": {
            "xcodeVersion": "Xcode 16.4\nBuild version 16F6",
            "swiftVersion": "Apple Swift version 6.1.2",
            "swiftFlags": (
                "-O -whole-module-optimization -warnings-as-errors "
                "-strict-concurrency=complete"
            ),
            "metalFlags": "-O3 -mmacosx-version-min=15.4 -std=metal3.2",
        },
        "identities": {
            "benchmarkSourceSHA256": sha256_file(BENCHMARK_SOURCE),
            "runnerSourceSHA256": sha256_file(RUNNER_SOURCE),
            "engineSourceSHA256": engine_sha256,
            "engineSourceManifest": manifest,
            "executableSHA256": sha256_bytes(f"executable:{identity}"),
            "metalLibrarySHA256": sha256_bytes("shared-metal-library"),
        },
        "cases": cases,
        "aggregate": {},
    }
    refresh_aggregate(value)
    return value


class PixelBufferScalerHotPathEvaluatorTests(unittest.TestCase):
    def evaluate(
        self,
        baseline: dict,
        candidate: dict,
    ) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            baseline_path = root / "baseline.json"
            candidate_path = root / "candidate.json"
            baseline_path.write_text(json.dumps(baseline))
            candidate_path.write_text(json.dumps(candidate))
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(baseline_path), str(candidate_path)],
                text=True,
                capture_output=True,
                check=False,
            )

    def baseline_and_candidate(self) -> tuple[dict, dict]:
        return (
            capture(1.0, "baseline", "baseline"),
            capture(0.8, "candidate", "candidate"),
        )

    def test_accepts_identical_output_at_every_case_and_aggregate_budget(self) -> None:
        baseline, candidate = self.baseline_and_candidate()
        result = self.evaluate(baseline, candidate)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["passed"])
        self.assertEqual(report["failedMetrics"], [])
        self.assertTrue(report["outputIdentityPreserved"])
        self.assertTrue(report["rawSamplesValidated"])
        self.assertTrue(all(
            ratio <= 0.8
            for ratios in report["caseRatios"].values()
            for ratio in ratios.values()
        ))

    def test_rejects_a_single_case_above_the_budget(self) -> None:
        baseline, candidate = self.baseline_and_candidate()
        candidate["cases"][0]["cpuMilliseconds"] = [
            sample * 0.801 for sample in baseline["cases"][0]["cpuMilliseconds"]
        ]
        candidate["cases"][1]["cpuMilliseconds"] = [
            sample * 0.79 for sample in baseline["cases"][1]["cpuMilliseconds"]
        ]
        refresh_aggregate(candidate)
        result = self.evaluate(baseline, candidate)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertIn(
            "nv12-full-arbitrary-853x481.cpuMedianMilliseconds",
            report["failedMetrics"],
        )

    def test_rejects_output_or_workload_identity_changes(self) -> None:
        baseline, candidate = self.baseline_and_candidate()
        candidate["cases"][0]["visiblePixelSHA256"] = sha256_bytes("changed")
        result = self.evaluate(baseline, candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("locked contract", result.stderr)

    def test_rejects_forged_matching_scope_route_and_output_pair(self) -> None:
        baseline, candidate = self.baseline_and_candidate()
        for value in (baseline, candidate):
            value["scope"] = "noop outside production"
            value["configuration"]["timedSetupExcluded"] = [
                "the complete production operation"
            ]
            value["cases"] = value["cases"][:1]
            value["cases"][0].update({
                "id": "fake-1x1",
                "storage": "invented_storage",
                "sourceWidth": 1,
                "sourceHeight": 1,
                "targetWidth": 1,
                "targetHeight": 1,
                "borderRule": "invented",
                "inputSeed": False,
                "visiblePixelSHA256": "0" * 64,
            })
            refresh_aggregate(value)
        result = self.evaluate(baseline, candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("locked contract", result.stderr)

    def test_rejects_configuration_changes_after_validating_each_capture(self) -> None:
        baseline, candidate = self.baseline_and_candidate()
        candidate["configuration"]["sampleCountPerCase"] = 14
        for case in candidate["cases"]:
            case["sampleCount"] = 14
            case["cpuMilliseconds"] = case["cpuMilliseconds"][:14]
            case["metalMilliseconds"] = case["metalMilliseconds"][:14]
        refresh_aggregate(candidate)
        result = self.evaluate(baseline, candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid sample count", result.stderr)

    def test_rejects_machine_or_compiler_changes(self) -> None:
        for section, field, replacement in (
            ("environment", "processor", "Different CPU"),
            ("compiler", "swiftVersion", "Different Swift"),
        ):
            with self.subTest(section=section):
                baseline, candidate = self.baseline_and_candidate()
                candidate[section][field] = replacement
                result = self.evaluate(baseline, candidate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{section} differs", result.stderr)

    def test_rejects_non_nominal_or_low_power_captures(self) -> None:
        for field, replacement in (
            ("thermalStateAtEnd", "fair"),
            ("lowPowerModeEnabledAtStart", True),
            ("lowPowerModeEnabledAtStart", 0),
            ("powerSourceAtEnd", "Battery Power"),
        ):
            with self.subTest(field=field):
                baseline, candidate = self.baseline_and_candidate()
                candidate["environment"][field] = replacement
                result = self.evaluate(baseline, candidate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("power envelope is outside", result.stderr)

    def test_rejects_missing_or_nonfinite_raw_samples(self) -> None:
        for replacement in ([], [float("nan")] * 15):
            with self.subTest(replacement=str(replacement[:1])):
                baseline, candidate = self.baseline_and_candidate()
                candidate["cases"][0]["cpuMilliseconds"] = replacement
                result = self.evaluate(baseline, candidate)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(
                    "raw sample count differs" in result.stderr
                    or "invalid positive timing value" in result.stderr
                )

    def test_rejects_forged_case_or_aggregate_metrics(self) -> None:
        for target in ("case", "aggregate"):
            with self.subTest(target=target):
                baseline, candidate = self.baseline_and_candidate()
                if target == "case":
                    candidate["cases"][0]["cpuMedianMilliseconds"] += 1
                else:
                    candidate["aggregate"]["metalP95Milliseconds"] += 1
                result = self.evaluate(baseline, candidate)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("derived timing metric differs", result.stderr)

    def test_rejects_tampered_source_or_binary_identities(self) -> None:
        mutations = (
            lambda value: value["identities"].__setitem__(
                "benchmarkSourceSHA256", sha256_bytes("other harness")
            ),
            lambda value: value["identities"].__setitem__(
                "runnerSourceSHA256", sha256_bytes("other runner")
            ),
            lambda value: value["identities"].__setitem__(
                "engineSourceSHA256", sha256_bytes("other engine aggregate")
            ),
        )
        for mutate in mutations:
            baseline, candidate = self.baseline_and_candidate()
            mutate(candidate)
            result = self.evaluate(baseline, candidate)
            self.assertNotEqual(result.returncode, 0)

    def test_rejects_coherent_forged_candidate_engine_manifest(self) -> None:
        baseline, candidate = self.baseline_and_candidate()
        forged_manifest = "".join(
            f"{path} {sha256_bytes(f'forged:{path}')}\n"
            for path in ENGINE_SOURCE_PATHS
        )
        candidate["identities"]["engineSourceManifest"] = forged_manifest
        candidate["identities"]["engineSourceSHA256"] = hashlib.sha256(
            forged_manifest.encode()
        ).hexdigest()

        result = self.evaluate(baseline, candidate)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "candidate engine source manifest differs from authoritative source",
            result.stderr,
        )

    def test_rejects_equal_baseline_and_candidate_engine_or_executable(self) -> None:
        for field in ("engineSourceSHA256", "executableSHA256"):
            with self.subTest(field=field):
                baseline, candidate = self.baseline_and_candidate()
                if field == "engineSourceSHA256":
                    candidate["identities"]["engineSourceManifest"] = baseline[
                        "identities"
                    ]["engineSourceManifest"]
                candidate["identities"][field] = baseline["identities"][field]
                result = self.evaluate(baseline, candidate)
                self.assertNotEqual(result.returncode, 0)
                if field == "engineSourceSHA256":
                    self.assertIn(
                        "candidate engine source manifest differs from "
                        "authoritative source",
                        result.stderr,
                    )
                else:
                    self.assertIn("identities are equal", result.stderr)

    def test_replays_all_four_checked_in_repeatability_pairs(self) -> None:
        result = subprocess.run(
            [sys.executable, str(REPEATABILITY_VERIFIER)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["pairCount"], 4)
        self.assertTrue(report["allPairsPassed"])


if __name__ == "__main__":
    unittest.main()
