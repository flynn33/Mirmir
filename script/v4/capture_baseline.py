#!/usr/bin/env python3
"""Capture the locked Mirmir deterministic-engine quality/time baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
from typing import Any, Iterable

import numpy as np


QUALITY_WEIGHTS = {
    "luma_multiscale_structural_error": 0.35,
    "chroma_multiscale_structural_error": 0.15,
    "perceptual_feature_error": 0.20,
    "temporal_flicker_error": 0.20,
    "edge_ringing_error": 0.10,
}


def run_text(command: list[str], cwd: Path) -> str:
    return subprocess.check_output(
        command,
        cwd=cwd,
        text=True,
        stderr=subprocess.STDOUT,
    ).strip()


def redact_system_profile(raw_json: str) -> str:
    private_key_fragments = ("serial_number", "serial-number", "uuid", "udid")

    def redacted(value: Any) -> Any:
        if isinstance(value, dict):
            return {
                key: redacted(child)
                for key, child in value.items()
                if not any(fragment in key.lower() for fragment in private_key_fragments)
            }
        if isinstance(value, list):
            return [redacted(child) for child in value]
        return value

    return json.dumps(redacted(json.loads(raw_json)), indent=2, sort_keys=True)


def redact_xcodebuild_log(raw_log: str) -> str:
    return re.sub(
        r"(?<=\bid:)[0-9A-Fa-f-]{16,}",
        "<redacted-device-id>",
        raw_log,
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def local_ssim(reference: np.ndarray, observed: np.ndarray) -> float:
    reference = reference.astype(np.float64)
    observed = observed.astype(np.float64)
    window = min(5, reference.shape[0], reference.shape[1])
    if window < 2:
        mse = np.mean((reference - observed) ** 2)
        return float(max(0.0, 1.0 - mse / (255.0**2)))
    windows_reference = np.lib.stride_tricks.sliding_window_view(
        reference, (window, window)
    )
    windows_observed = np.lib.stride_tricks.sliding_window_view(
        observed, (window, window)
    )
    mean_reference = windows_reference.mean(axis=(-2, -1))
    mean_observed = windows_observed.mean(axis=(-2, -1))
    centered_reference = windows_reference - mean_reference[..., None, None]
    centered_observed = windows_observed - mean_observed[..., None, None]
    variance_reference = np.mean(centered_reference**2, axis=(-2, -1))
    variance_observed = np.mean(centered_observed**2, axis=(-2, -1))
    covariance = np.mean(
        centered_reference * centered_observed, axis=(-2, -1)
    )
    c1 = (0.01 * 255.0) ** 2
    c2 = (0.03 * 255.0) ** 2
    numerator = (2.0 * mean_reference * mean_observed + c1) * (
        2.0 * covariance + c2
    )
    denominator = (
        mean_reference**2 + mean_observed**2 + c1
    ) * (variance_reference + variance_observed + c2)
    return float(np.clip(np.mean(numerator / denominator), -1.0, 1.0))


def box_downsample(image: np.ndarray) -> np.ndarray:
    height = image.shape[0] - image.shape[0] % 2
    width = image.shape[1] - image.shape[1] % 2
    cropped = image[:height, :width]
    return cropped.reshape(height // 2, 2, width // 2, 2).mean(axis=(1, 3))


def multiscale_ssim(reference: np.ndarray, observed: np.ndarray) -> float:
    values = [local_ssim(reference, observed)]
    if min(reference.shape) >= 8:
        values.append(local_ssim(box_downsample(reference), box_downsample(observed)))
        return 0.6 * values[0] + 0.4 * values[1]
    return values[0]


def gradient_feature_error(reference: np.ndarray, observed: np.ndarray) -> float:
    ref_x = np.diff(reference.astype(np.float64), axis=1)
    obs_x = np.diff(observed.astype(np.float64), axis=1)
    ref_y = np.diff(reference.astype(np.float64), axis=0)
    obs_y = np.diff(observed.astype(np.float64), axis=0)
    return float(
        0.5 * np.mean(np.abs(ref_x - obs_x)) / 255.0
        + 0.5 * np.mean(np.abs(ref_y - obs_y)) / 255.0
    )


def laplacian(image: np.ndarray) -> np.ndarray:
    padded = np.pad(image.astype(np.float64), 1, mode="edge")
    return (
        -4.0 * padded[1:-1, 1:-1]
        + padded[:-2, 1:-1]
        + padded[2:, 1:-1]
        + padded[1:-1, :-2]
        + padded[1:-1, 2:]
    )


def edge_ringing_error(reference: np.ndarray, observed: np.ndarray) -> float:
    return float(
        np.mean(np.abs(laplacian(reference) - laplacian(observed)))
        / (4.0 * 255.0)
    )


def load_planes(directory: Path, record: dict[str, Any], key: str) -> tuple[np.ndarray, np.ndarray]:
    data = np.fromfile(directory / record[key], dtype=np.uint8)
    luma_count = int(record["targetLumaByteCount"])
    width = int(record["targetWidth"])
    height = int(record["targetHeight"])
    luma = data[:luma_count].reshape(height, width)
    chroma = data[luma_count:].reshape(height // 2, width // 2, 2)
    return luma, chroma


def mean(values: Iterable[float]) -> float:
    materialized = list(values)
    return float(statistics.fmean(materialized)) if materialized else 0.0


def quality_for_backend(
    directory: Path,
    records: list[dict[str, Any]],
    backend_key: str,
) -> dict[str, Any]:
    luma_errors: list[float] = []
    chroma_errors: list[float] = []
    perceptual_errors: list[float] = []
    edge_errors: list[float] = []
    loaded: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]] = {}

    for record in records:
        reference_luma, reference_chroma = load_planes(directory, record, "referenceFile")
        observed_luma, observed_chroma = load_planes(directory, record, backend_key)
        loaded[record["id"]] = (
            reference_luma,
            reference_chroma,
            observed_luma,
            observed_chroma,
        )
        luma_errors.append(1.0 - multiscale_ssim(reference_luma, observed_luma))
        chroma_errors.append(
            mean(
                1.0
                - multiscale_ssim(
                    reference_chroma[:, :, channel],
                    observed_chroma[:, :, channel],
                )
                for channel in range(2)
            )
        )
        perceptual_errors.append(
            gradient_feature_error(reference_luma, observed_luma)
        )
        edge_errors.append(edge_ringing_error(reference_luma, observed_luma))

    temporal_errors: list[float] = []
    groups: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for record in records:
        if record["pattern"].startswith("moving_edge_"):
            groups.setdefault((record["pixelFormat"], record["route"]), []).append(record)
    for group in groups.values():
        group.sort(key=lambda value: value["pattern"])
        for previous, current in zip(group, group[1:]):
            prev_ref, _, prev_obs, _ = loaded[previous["id"]]
            current_ref, _, current_obs, _ = loaded[current["id"]]
            reference_delta = current_ref.astype(np.float64) - prev_ref.astype(np.float64)
            observed_delta = current_obs.astype(np.float64) - prev_obs.astype(np.float64)
            temporal_errors.append(
                float(np.mean(np.abs(reference_delta - observed_delta)) / 255.0)
            )

    components = {
        "luma_multiscale_structural_error": mean(luma_errors),
        "chroma_multiscale_structural_error": mean(chroma_errors),
        "perceptual_feature_error": mean(perceptual_errors),
        "temporal_flicker_error": mean(temporal_errors),
        "edge_ringing_error": mean(edge_errors),
    }
    weighted_error = sum(
        components[name] * weight for name, weight in QUALITY_WEIGHTS.items()
    )
    return {
        "components": components,
        "weightedError": weighted_error,
        "baselineQualityIndex": 100.0,
        "caseCount": len(records),
        "temporalPairCount": len(temporal_errors),
    }


def write_difference_maps(
    directory: Path,
    records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    comparisons = (
        ("cpu-minus-reference", "cpuFile", "referenceFile"),
        ("metal-minus-reference", "metalFile", "referenceFile"),
        ("cpu-minus-metal", "cpuFile", "metalFile"),
    )
    for record in sorted(records, key=lambda value: value["id"]):
        for label, minuend_key, subtrahend_key in comparisons:
            minuend_luma, minuend_chroma = load_planes(
                directory, record, minuend_key
            )
            subtrahend_luma, subtrahend_chroma = load_planes(
                directory, record, subtrahend_key
            )
            difference = np.concatenate(
                (
                    (minuend_luma.astype(np.int16) - subtrahend_luma).ravel(),
                    (minuend_chroma.astype(np.int16) - subtrahend_chroma).ravel(),
                )
            ).astype("<i2", copy=False)
            filename = f"{record['id']}-{label}.s16le"
            difference.tofile(directory / filename)
            entries.append(
                {
                    "caseID": record["id"],
                    "comparison": label,
                    "path": filename,
                    "sampleCount": int(difference.size),
                    "storage": "signed little-endian 16-bit, luma then interleaved CbCr",
                    "minimum": int(difference.min(initial=0)),
                    "maximum": int(difference.max(initial=0)),
                    "nonzeroCount": int(np.count_nonzero(difference)),
                }
            )
    return entries


def percentile(values: list[float], quantile: float) -> float:
    return float(np.percentile(np.asarray(values, dtype=np.float64), quantile))


def summarize_performance(records: list[dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {"cases": []}
    all_cpu: list[float] = []
    all_metal: list[float] = []
    for record in records:
        cpu = [float(value) for value in record["cpuMilliseconds"]]
        metal = [float(value) for value in record["metalMilliseconds"]]
        all_cpu.extend(cpu)
        all_metal.extend(metal)
        result["cases"].append(
            {
                "id": record["id"],
                "cpuMedianMilliseconds": statistics.median(cpu),
                "cpuP95Milliseconds": percentile(cpu, 95),
                "metalMedianMilliseconds": statistics.median(metal),
                "metalP95Milliseconds": percentile(metal, 95),
                "warmupCount": record["warmupCount"],
                "sampleCount": record["sampleCount"],
            }
        )
    result["aggregate"] = {
        "cpuMedianMilliseconds": statistics.median(all_cpu),
        "cpuP95Milliseconds": percentile(all_cpu, 95),
        "metalMedianMilliseconds": statistics.median(all_metal),
        "metalP95Milliseconds": percentile(all_metal, 95),
        "cpuSampleCount": len(all_cpu),
        "metalSampleCount": len(all_metal),
    }
    return result


def signed_delta_summary(values: list[int]) -> dict[str, Any]:
    return {
        "minimumBytes": min(values),
        "medianBytes": statistics.median(values),
        "maximumBytes": max(values),
        "positiveSampleCount": sum(value > 0 for value in values),
        "positiveBytesTotal": sum(max(0, value) for value in values),
    }


def summarize_allocation_pressure(records: list[dict[str, Any]]) -> dict[str, Any]:
    fields = (
        "mallocSizeInUseBytes",
        "mallocSizeAllocatedBytes",
        "residentBytes",
        "physicalFootprintBytes",
    )
    aggregate: dict[str, dict[str, list[int]]] = {
        "cpu": {field: [] for field in fields},
        "metal": {field: [] for field in fields},
    }
    cases: list[dict[str, Any]] = []
    for record in records:
        case: dict[str, Any] = {
            "id": record["id"],
            "memoryBeforeWarmups": record["memoryBeforeWarmups"],
            "memoryAfterSamples": record["memoryAfterSamples"],
        }
        for backend, key in (
            ("cpu", "cpuMemoryDeltas"),
            ("metal", "metalMemoryDeltas"),
        ):
            case[backend] = {}
            for field in fields:
                values = [int(delta[field]) for delta in record[key]]
                aggregate[backend][field].extend(values)
                case[backend][field] = signed_delta_summary(values)
        cases.append(case)
    return {
        "schemaVersion": "mirmir-v4-allocation-profile-v1",
        "measurement": (
            "Per-operation deltas from malloc zone and proc_pid_rusage snapshots; "
            "sampling occurs outside the timed interval."
        ),
        "aggregate": {
            backend: {
                field: signed_delta_summary(values)
                for field, values in by_field.items()
            }
            for backend, by_field in aggregate.items()
        },
        "cases": cases,
    }


def environment_manifest(repository: Path) -> dict[str, Any]:
    commands = {
        "macOS": ["sw_vers"],
        "xcode": ["xcodebuild", "-version"],
        "swift": ["swift", "--version"],
        "hardware": ["system_profiler", "SPHardwareDataType", "-json"],
        "graphics": ["system_profiler", "SPDisplaysDataType", "-json"],
        "power": ["pmset", "-g", "custom"],
        "thermal": ["pmset", "-g", "therm"],
    }
    command_results: dict[str, str] = {}
    for name, command in commands.items():
        try:
            command_results[name] = run_text(command, repository)
            if name in {"hardware", "graphics"}:
                command_results[name] = redact_system_profile(command_results[name])
        except (OSError, subprocess.CalledProcessError) as error:
            command_results[name] = f"unavailable: {error}"
    return {
        "schemaVersion": "mirmir-v4-environment-v1",
        "repository": str(repository),
        "sourceCommit": run_text(["git", "rev-parse", "HEAD"], repository),
        "sourceDescribe": run_text(
            ["git", "describe", "--always", "--dirty", "--broken"], repository
        ),
        "workingTreeStatus": run_text(
            ["git", "status", "--porcelain=v1"], repository
        ).splitlines(),
        "python": sys.version,
        "pythonPlatform": platform.platform(),
        "numpy": np.__version__,
        "commands": command_results,
    }


def artifact_manifest(directory: Path) -> list[dict[str, Any]]:
    artifacts = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name != "capture-manifest.json":
            artifacts.append(
                {
                    "path": path.name,
                    "byteCount": path.stat().st_size,
                    "sha256": sha256(path),
                }
            )
    return artifacts


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, default=Path("/tmp/mirmir-v4-baseline"))
    parser.add_argument("--warmups", type=int, default=5)
    parser.add_argument("--samples", type=int, default=10)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository = Path(__file__).resolve().parents[2]
    output = arguments.output.expanduser().resolve()
    if output.exists():
        raise SystemExit(f"Refusing to overwrite existing output directory: {output}")
    if arguments.warmups < 0 or arguments.samples < 1:
        raise SystemExit("Warmups must be nonnegative and samples must be positive.")
    output.mkdir(parents=True)

    environment = os.environ.copy()
    environment["MIRMIR_V4_BASELINE_DIR"] = str(output)
    environment["MIRMIR_V4_WARMUP_COUNT"] = str(arguments.warmups)
    environment["MIRMIR_V4_SAMPLE_COUNT"] = str(arguments.samples)
    command = [
        "xcodebuild",
        "-project",
        "Mirmir.xcodeproj",
        "-scheme",
        "Mirmir",
        "-configuration",
        "Release",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(arguments.derived_data),
        "test",
        "-only-testing:MirmirTests/DeterministicMetalBackendTests/testCaptureV3BaselineWhenRequested",
        "CODE_SIGNING_ALLOWED=NO",
        "ENABLE_TESTABILITY=YES",
        "ONLY_ACTIVE_ARCH=YES",
        f"MIRMIR_V4_BASELINE_DIR={output}",
        f"MIRMIR_V4_WARMUP_COUNT={arguments.warmups}",
        f"MIRMIR_V4_SAMPLE_COUNT={arguments.samples}",
    ]
    completed = subprocess.run(
        command,
        cwd=repository,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    redacted_build_log = redact_xcodebuild_log(completed.stdout)
    (output / "xcodebuild.log").write_text(redacted_build_log)
    if completed.returncode != 0:
        print(redacted_build_log, file=sys.stderr)
        return completed.returncode

    engine_results_path = output / "engine-results.json"
    if not engine_results_path.is_file():
        raise SystemExit("The baseline test succeeded without producing engine-results.json.")
    engine_results = json.loads(engine_results_path.read_text())
    write_json(
        output / "difference-maps.json",
        {
            "schemaVersion": "mirmir-v4-difference-maps-v1",
            "maps": write_difference_maps(output, engine_results["cases"]),
        },
    )
    quality = {
        "schemaVersion": "mirmir-v4-quality-baseline-v1",
        "weights": QUALITY_WEIGHTS,
        "cpu": quality_for_backend(output, engine_results["cases"], "cpuFile"),
        "metal": quality_for_backend(output, engine_results["cases"], "metalFile"),
    }
    write_json(output / "quality-baseline.json", quality)
    write_json(
        output / "performance-baseline.json",
        {
            "schemaVersion": "mirmir-v4-performance-baseline-v1",
            **summarize_performance(engine_results["performance"]),
        },
    )
    write_json(
        output / "allocation-profile.json",
        summarize_allocation_pressure(engine_results["performance"]),
    )
    write_json(output / "environment.json", environment_manifest(repository))
    write_json(
        output / "capture-manifest.json",
        {
            "schemaVersion": "mirmir-v4-capture-manifest-v1",
            "captureTool": {
                "path": str(Path(__file__).resolve().relative_to(repository)),
                "sha256": sha256(Path(__file__).resolve()),
            },
            "artifacts": artifact_manifest(output),
        },
    )
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
