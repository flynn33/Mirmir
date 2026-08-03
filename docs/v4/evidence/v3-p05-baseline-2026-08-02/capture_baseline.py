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
import shutil
import statistics
import subprocess
import sys
from typing import Any, Iterable

import numpy as np

import p05_baseline_v4 as p05


QUALITY_WEIGHTS = {
    "luma_multiscale_structural_error": 0.35,
    "chroma_multiscale_structural_error": 0.15,
    "perceptual_feature_error": 0.20,
    "temporal_flicker_error": 0.20,
    "edge_ringing_error": 0.10,
}

FROZEN_SOURCE_REVISION = p05.FROZEN_SOURCE_REVISION


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
    redacted = re.sub(
        r"(?<=\bid:)[0-9A-Fa-f-]{16,}",
        "<redacted-device-id>",
        raw_log,
    )
    return "\n".join(line.rstrip() for line in redacted.splitlines()) + "\n"


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


def summarize_end_to_end(capture: dict[str, Any]) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in capture["runs"]:
        grouped.setdefault(run["backendID"], []).append(run)
    backends: dict[str, Any] = {}
    for backend, runs in sorted(grouped.items()):
        wall = [float(run["wallMilliseconds"]) for run in runs]
        session = [float(run["sessionMilliseconds"]) for run in runs]
        stages: dict[str, dict[str, float]] = {}
        for stage in sorted(runs[0]["stageMilliseconds"]):
            values = [float(run["stageMilliseconds"][stage]) for run in runs]
            stages[stage] = {
                "medianMilliseconds": statistics.median(values),
                "p95Milliseconds": percentile(values, 95),
            }
        backends[backend] = {
            "sampleCount": len(runs),
            "wallMedianMilliseconds": statistics.median(wall),
            "wallP95Milliseconds": percentile(wall, 95),
            "sessionMedianMilliseconds": statistics.median(session),
            "sessionP95Milliseconds": percentile(session, 95),
            "stages": stages,
        }
    return {
        "schemaVersion": "mirmir-v4-end-to-end-summary-v1",
        "inputFile": capture["inputFile"],
        "inputByteCount": capture["inputByteCount"],
        "targetWidth": capture["targetWidth"],
        "targetHeight": capture["targetHeight"],
        "outputCodec": capture["outputCodec"],
        "warmupCount": capture["warmupCount"],
        "sampleCount": capture["sampleCount"],
        "backends": backends,
    }


def environment_manifest(
    archive_root: Path,
    source_tree_identity: str,
    source_manifest_sha256: str,
) -> dict[str, Any]:
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
            command_results[name] = run_text(command, archive_root)
            if name in {"hardware", "graphics"}:
                command_results[name] = redact_system_profile(command_results[name])
        except (OSError, subprocess.CalledProcessError) as error:
            command_results[name] = f"unavailable: {error}"
    return {
        "schemaVersion": "mirmir-v4-environment-v1",
        "repository": "clean-git-archive",
        "sourceCommit": FROZEN_SOURCE_REVISION,
        "sourceDescribe": FROZEN_SOURCE_REVISION[:7],
        "sourceTreeIdentitySHA256": source_tree_identity,
        "sourceManifestSHA256": source_manifest_sha256,
        "workingTreeStatus": [],
        "python": sys.version,
        "pythonPlatform": platform.platform(),
        "numpy": np.__version__,
        "commands": command_results,
    }


def artifact_manifest(directory: Path) -> list[dict[str, Any]]:
    artifacts = []
    for path in sorted(
        directory.rglob("*"), key=lambda item: item.relative_to(directory).as_posix()
    ):
        if path.is_symlink():
            raise SystemExit(f"P05 capture contains a symbolic link: {path}")
        if path.is_file() and path not in {
            directory / "capture-manifest.json",
            directory / "evidence-manifest.json",
        }:
            artifacts.append(
                descriptor(path, directory)
            )
    return artifacts


def descriptor(path: Path, root: Path | None = None) -> dict[str, Any]:
    return {
        "path": (
            path.relative_to(root).as_posix() if root is not None else str(path)
        ),
        "byteCount": path.stat().st_size,
        "sha256": sha256(path),
    }


def artifact_set_identity(artifacts: Iterable[dict[str, Any]]) -> str:
    return p05.artifact_set_identity(
        (artifact["path"], artifact["sha256"]) for artifact in artifacts
    )


def resolved_tool(name: str) -> Path:
    located = shutil.which(name)
    if located is None:
        raise SystemExit(f"Required baseline tool is absent: {name}")
    path = Path(located).resolve()
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Baseline tool is not a regular file: {path}")
    return path


def tool_manifest(
    capture_tool: Path,
    identity_tool: Path,
    source_manifest: Path,
    directory: Path,
) -> dict[str, Any]:
    capture_copy = directory / "capture_baseline.py"
    identity_copy = directory / "p05_baseline_v4.py"
    source_manifest_copy = directory / "p05-baseline-source-manifest-v1.json"
    shutil.copyfile(capture_tool.resolve(), capture_copy)
    shutil.copyfile(identity_tool.resolve(), identity_copy)
    shutil.copyfile(source_manifest.resolve(), source_manifest_copy)
    sealed_tools = {
        "captureTool": capture_copy,
        "identityTool": identity_copy,
        "sourceManifest": source_manifest_copy,
    }
    host_tools = {
        "python": Path(sys.executable).resolve(),
        "numpyModule": Path(np.__file__).resolve(),
        "git": resolved_tool("git"),
        "tar": resolved_tool("tar"),
        "xcodebuild": resolved_tool("xcodebuild"),
    }
    sealed_rows = {
        name: descriptor(path, directory)
        for name, path in sorted(sealed_tools.items())
    }
    host_rows = {
        name: descriptor(path) for name, path in sorted(host_tools.items())
    }
    return {
        "schemaVersion": "mirmir-v4-p05-tool-identities-v1",
        "numpyVersion": np.__version__,
        "sealedTools": sealed_rows,
        "hostTools": host_rows,
        "artifactSetSHA256": p05.artifact_set_identity(
            (f"sealed/{name}", row["sha256"])
            for name, row in sealed_rows.items()
        ),
        "hostToolSetSHA256": p05.artifact_set_identity(
            (f"host/{name}", row["sha256"])
            for name, row in host_rows.items()
        ),
    }


def corpus_manifest(directory: Path, engine_results: dict[str, Any]) -> dict[str, Any]:
    relative_paths = {"end-to-end-input.mov"}
    for record in engine_results["cases"]:
        relative_paths.add(record["sourceFile"])
        relative_paths.add(record["referenceFile"])
    artifacts = [descriptor(directory / relative, directory) for relative in sorted(relative_paths)]
    return {
        "schemaVersion": "mirmir-v4-p05-corpus-manifest-v1",
        "caseCount": len(engine_results["cases"]),
        "artifacts": artifacts,
        "artifactSetSHA256": artifact_set_identity(artifacts),
    }


def build_manifest(
    command: list[str],
    derived_data: Path,
    output: Path,
    source_tree_identity: str,
    source_manifest_sha256: str,
) -> dict[str, Any]:
    products = derived_data / "Build/Products/Release"
    application = products / "Mirmir.app/Contents/MacOS/Mirmir"
    tests = (
        products
        / "Mirmir.app/Contents/PlugIns/MirmirTests.xctest/Contents/MacOS/MirmirTests"
    )
    for label, path in (("application", application), ("tests", tests)):
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f"P05 {label} executable is absent: {path}")
    command_template = [
        argument.replace(str(derived_data), "<DERIVED_DATA>").replace(
            str(output), "<OUTPUT>"
        )
        for argument in command
    ]
    return {
        "schemaVersion": "mirmir-v4-p05-build-identity-v1",
        "configuration": "Release",
        "workingDirectory": "clean-git-archive",
        "sourceRevision": FROZEN_SOURCE_REVISION,
        "sourceTreeIdentitySHA256": source_tree_identity,
        "sourceManifestSHA256": source_manifest_sha256,
        "commandTemplate": command_template,
        "applicationExecutable": descriptor(application, products),
        "captureExecutable": descriptor(tests, products),
    }


def evidence_manifest(directory: Path) -> dict[str, Any]:
    artifacts = []
    for path in sorted(
        directory.rglob("*"), key=lambda item: item.relative_to(directory).as_posix()
    ):
        if path.is_symlink():
            raise SystemExit(f"P05 evidence contains a symbolic link: {path}")
        if path.is_file() and path != directory / "evidence-manifest.json":
            artifacts.append(descriptor(path, directory))
    return {
        "schemaVersion": "mirmir-v4-p05-evidence-manifest-v2",
        "artifactCount": len(artifacts),
        "artifacts": artifacts,
        "artifactSetSHA256": artifact_set_identity(artifacts),
    }


def read_json_object(path: Path, label: str) -> dict[str, Any]:
    value = json.loads(path.read_text())
    p05.require(isinstance(value, dict), f"{label} is not a JSON object")
    return value


def validate_descriptor_row(
    directory: Path,
    row: Any,
    label: str,
) -> Path:
    p05.require(isinstance(row, dict), f"{label} descriptor is absent")
    p05.require(
        set(row) == {"path", "byteCount", "sha256"},
        f"{label} descriptor field set differs",
    )
    path = p05.checked_relative(directory, row["path"])
    p05.require(path.is_file(), f"{label} artifact is absent")
    p05.require(not path.is_symlink(), f"{label} artifact is a symbolic link")
    p05.require(
        row == descriptor(path, directory),
        f"{label} artifact identity differs",
    )
    return path


def validate_external_descriptor(row: Any, label: str) -> None:
    p05.require(isinstance(row, dict), f"{label} descriptor is absent")
    p05.require(
        set(row) == {"path", "byteCount", "sha256"},
        f"{label} descriptor field set differs",
    )
    p05.require(
        isinstance(row["path"], str) and Path(row["path"]).is_absolute(),
        f"{label} path is not absolute",
    )
    p05.require(
        isinstance(row["byteCount"], int) and row["byteCount"] > 0,
        f"{label} byte count is invalid",
    )
    p05.require_hex(row["sha256"], 64, f"{label} SHA-256")


def expected_build_command(
    warmups: int,
    samples: int,
) -> list[str]:
    return [
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
        "<DERIVED_DATA>",
        "-parallel-testing-enabled",
        "NO",
        "test",
        "-only-testing:MirmirTests/DeterministicMetalBackendTests/testCaptureV3BaselineWhenRequested",
        "-only-testing:MirmirTests/VideoProcessingSessionTests/testCaptureV3EndToEndBaselineWhenRequested",
        "CODE_SIGNING_ALLOWED=NO",
        "ENABLE_TESTABILITY=YES",
        "ONLY_ACTIVE_ARCH=YES",
        "MIRMIR_V4_BASELINE_DIR=<OUTPUT>",
        f"MIRMIR_V4_WARMUP_COUNT={warmups}",
        f"MIRMIR_V4_SAMPLE_COUNT={samples}",
    ]


def verify_baseline_evidence(
    directory: Path,
    repository: Path,
) -> dict[str, Any]:
    directory = directory.resolve()
    repository = repository.resolve()
    p05.require(directory.is_dir(), "P05 evidence directory is absent")

    evidence_path = directory / "evidence-manifest.json"
    p05.require(evidence_path.is_file(), "P05 evidence manifest is absent")
    evidence = read_json_object(evidence_path, "P05 evidence manifest")
    p05.require(
        set(evidence)
        == {"schemaVersion", "artifactCount", "artifactSetSHA256", "artifacts"},
        "P05 evidence manifest field set differs",
    )
    p05.require(
        evidence["schemaVersion"] == "mirmir-v4-p05-evidence-manifest-v2",
        "unsupported P05 evidence manifest",
    )
    expected_evidence = evidence_manifest(directory)
    p05.require(evidence == expected_evidence, "P05 evidence seal differs")

    capture_path = directory / "capture-manifest.json"
    capture = read_json_object(capture_path, "P05 capture manifest")
    p05.require(
        set(capture)
        == {
            "schemaVersion",
            "sourceIdentity",
            "buildIdentity",
            "toolIdentity",
            "corpusIdentity",
            "artifactCount",
            "artifactSetSHA256",
            "artifacts",
        },
        "P05 capture manifest field set differs",
    )
    p05.require(
        capture["schemaVersion"] == "mirmir-v4-p05-capture-manifest-v2",
        "unsupported P05 capture manifest",
    )
    artifacts = artifact_manifest(directory)
    p05.require(capture["artifacts"] == artifacts, "P05 capture artifact list differs")
    p05.require(capture["artifactCount"] == len(artifacts), "P05 capture artifact count differs")
    p05.require(
        capture["artifactSetSHA256"] == artifact_set_identity(artifacts),
        "P05 capture artifact-set identity differs",
    )

    source_identity = capture["sourceIdentity"]
    p05.require(
        isinstance(source_identity, dict)
        and set(source_identity)
        == {
            "sourceRevision",
            "gitTreeObjectID",
            "sourceTreeIdentitySHA256",
            "sourceManifestPath",
            "sourceManifestSHA256",
        },
        "P05 capture source identity field set differs",
    )
    p05.require(
        source_identity["sourceManifestPath"] == "source-manifest.json",
        "P05 source-manifest path changed",
    )
    source_manifest_path = directory / "source-manifest.json"
    source_manifest = p05.validate_source_manifest(repository, source_manifest_path)
    p05.require(
        source_identity
        == {
            "sourceRevision": FROZEN_SOURCE_REVISION,
            "gitTreeObjectID": source_manifest["gitTreeObjectID"],
            "sourceTreeIdentitySHA256": source_manifest[
                "sourceTreeIdentitySHA256"
            ],
            "sourceManifestPath": "source-manifest.json",
            "sourceManifestSHA256": sha256(source_manifest_path),
        },
        "P05 capture source identity differs from the frozen tree",
    )

    engine_results = read_json_object(
        directory / "engine-results.json", "P05 engine results"
    )
    end_to_end_results = read_json_object(
        directory / "end-to-end-results.json", "P05 end-to-end results"
    )
    p05.require(
        engine_results.get("schemaVersion") == "mirmir-v4-baseline-v1"
        and engine_results.get("cpuImplementationVersion")
        == "ash-p05-cpu-reference-preview"
        and engine_results.get("metalImplementationVersion")
        == "ash-p05-metal-v3-preview",
        "P05 engine capture identity differs",
    )
    p05.require(
        end_to_end_results.get("schemaVersion")
        == "mirmir-v4-end-to-end-baseline-v1",
        "P05 end-to-end capture identity differs",
    )

    build_binding = capture["buildIdentity"]
    p05.require(
        isinstance(build_binding, dict)
        and set(build_binding)
        == {
            "manifestPath",
            "manifestSHA256",
            "applicationExecutableSHA256",
            "captureExecutableSHA256",
        },
        "P05 build binding field set differs",
    )
    p05.require(
        build_binding["manifestPath"] == "build-identity.json",
        "P05 build-manifest path changed",
    )
    build_path = directory / "build-identity.json"
    build = read_json_object(build_path, "P05 build identity")
    p05.require(
        set(build)
        == {
            "schemaVersion",
            "configuration",
            "workingDirectory",
            "sourceRevision",
            "sourceTreeIdentitySHA256",
            "sourceManifestSHA256",
            "commandTemplate",
            "applicationExecutable",
            "captureExecutable",
        },
        "P05 build identity field set differs",
    )
    p05.require(
        build["schemaVersion"] == "mirmir-v4-p05-build-identity-v1"
        and build["configuration"] == "Release"
        and build["workingDirectory"] == "clean-git-archive",
        "P05 build configuration differs",
    )
    p05.require(
        build["sourceRevision"] == FROZEN_SOURCE_REVISION
        and build["sourceTreeIdentitySHA256"]
        == source_manifest["sourceTreeIdentitySHA256"]
        and build["sourceManifestSHA256"] == sha256(source_manifest_path),
        "P05 build source identity differs",
    )
    warmups = end_to_end_results.get("warmupCount")
    samples = end_to_end_results.get("sampleCount")
    p05.require(
        isinstance(warmups, int)
        and warmups >= 0
        and isinstance(samples, int)
        and samples >= 1,
        "P05 capture sample counts are invalid",
    )
    p05.require(
        build["commandTemplate"] == expected_build_command(warmups, samples),
        "P05 Release build command differs",
    )
    for key, expected_path in (
        ("applicationExecutable", "Mirmir.app/Contents/MacOS/Mirmir"),
        (
            "captureExecutable",
            "Mirmir.app/Contents/PlugIns/MirmirTests.xctest/Contents/MacOS/MirmirTests",
        ),
    ):
        row = build[key]
        p05.require(
            isinstance(row, dict)
            and set(row) == {"path", "byteCount", "sha256"}
            and row["path"] == expected_path
            and isinstance(row["byteCount"], int)
            and row["byteCount"] > 0,
            f"P05 {key} descriptor differs",
        )
        p05.require_hex(row["sha256"], 64, f"P05 {key} SHA-256")
    p05.require(
        build_binding
        == {
            "manifestPath": "build-identity.json",
            "manifestSHA256": sha256(build_path),
            "applicationExecutableSHA256": build["applicationExecutable"]["sha256"],
            "captureExecutableSHA256": build["captureExecutable"]["sha256"],
        },
        "P05 build binding differs",
    )

    tool_binding = capture["toolIdentity"]
    p05.require(
        isinstance(tool_binding, dict)
        and set(tool_binding)
        == {
            "manifestPath",
            "manifestSHA256",
            "artifactSetSHA256",
            "hostToolSetSHA256",
        }
        and tool_binding["manifestPath"] == "tool-identities.json",
        "P05 tool binding field set differs",
    )
    tool_path = directory / "tool-identities.json"
    tools = read_json_object(tool_path, "P05 tool identities")
    p05.require(
        set(tools)
        == {
            "schemaVersion",
            "numpyVersion",
            "sealedTools",
            "hostTools",
            "artifactSetSHA256",
            "hostToolSetSHA256",
        }
        and tools["schemaVersion"] == "mirmir-v4-p05-tool-identities-v1",
        "P05 tool identity schema differs",
    )
    sealed_tools = tools["sealedTools"]
    p05.require(
        isinstance(sealed_tools, dict)
        and set(sealed_tools) == {"captureTool", "identityTool", "sourceManifest"},
        "P05 sealed-tool set differs",
    )
    for name, row in sealed_tools.items():
        validate_descriptor_row(directory, row, f"P05 sealed tool {name}")
    p05.require(
        sealed_tools["captureTool"]["path"] == "capture_baseline.py"
        and sealed_tools["identityTool"]["path"] == "p05_baseline_v4.py"
        and sealed_tools["sourceManifest"]["path"]
        == "p05-baseline-source-manifest-v1.json",
        "P05 sealed-tool paths differ",
    )
    p05.require(
        sealed_tools["sourceManifest"]["sha256"] == sha256(source_manifest_path),
        "P05 sealed source-manifest copy differs",
    )
    expected_tool_set = p05.artifact_set_identity(
        (f"sealed/{name}", row["sha256"])
        for name, row in sealed_tools.items()
    )
    p05.require(
        tools["artifactSetSHA256"] == expected_tool_set,
        "P05 sealed-tool artifact set differs",
    )
    host_tools = tools["hostTools"]
    p05.require(
        isinstance(host_tools, dict)
        and set(host_tools)
        == {"python", "numpyModule", "git", "tar", "xcodebuild"},
        "P05 host-tool set differs",
    )
    for name, row in host_tools.items():
        validate_external_descriptor(row, f"P05 host tool {name}")
    expected_host_set = p05.artifact_set_identity(
        (f"host/{name}", row["sha256"]) for name, row in host_tools.items()
    )
    p05.require(
        tools["hostToolSetSHA256"] == expected_host_set,
        "P05 host-tool artifact set differs",
    )
    p05.require(
        tool_binding
        == {
            "manifestPath": "tool-identities.json",
            "manifestSHA256": sha256(tool_path),
            "artifactSetSHA256": expected_tool_set,
            "hostToolSetSHA256": expected_host_set,
        },
        "P05 tool binding differs",
    )

    corpus_binding = capture["corpusIdentity"]
    p05.require(
        isinstance(corpus_binding, dict)
        and set(corpus_binding)
        == {"manifestPath", "manifestSHA256", "artifactSetSHA256"}
        and corpus_binding["manifestPath"] == "corpus-manifest.json",
        "P05 corpus binding field set differs",
    )
    corpus_path = directory / "corpus-manifest.json"
    corpus = read_json_object(corpus_path, "P05 corpus manifest")
    p05.require(
        set(corpus)
        == {"schemaVersion", "caseCount", "artifacts", "artifactSetSHA256"}
        and corpus["schemaVersion"] == "mirmir-v4-p05-corpus-manifest-v1",
        "P05 corpus schema differs",
    )
    expected_corpus_paths = {"end-to-end-input.mov"}
    for record in engine_results["cases"]:
        expected_corpus_paths.add(record["sourceFile"])
        expected_corpus_paths.add(record["referenceFile"])
    rows = corpus["artifacts"]
    p05.require(isinstance(rows, list), "P05 corpus artifact list is absent")
    actual_corpus_paths: set[str] = set()
    for index, row in enumerate(rows):
        validate_descriptor_row(directory, row, f"P05 corpus artifact {index}")
        p05.require(row["path"] not in actual_corpus_paths, "duplicate P05 corpus path")
        actual_corpus_paths.add(row["path"])
    p05.require(
        actual_corpus_paths == expected_corpus_paths,
        "P05 corpus file set differs",
    )
    p05.require(
        corpus["caseCount"] == len(engine_results["cases"])
        and corpus["artifactSetSHA256"] == artifact_set_identity(rows),
        "P05 corpus identity differs",
    )
    p05.require(
        corpus_binding
        == {
            "manifestPath": "corpus-manifest.json",
            "manifestSHA256": sha256(corpus_path),
            "artifactSetSHA256": corpus["artifactSetSHA256"],
        },
        "P05 corpus binding differs",
    )

    environment = read_json_object(directory / "environment.json", "P05 environment")
    p05.require(
        environment.get("repository") == "clean-git-archive"
        and environment.get("sourceCommit") == FROZEN_SOURCE_REVISION
        and environment.get("sourceTreeIdentitySHA256")
        == source_manifest["sourceTreeIdentitySHA256"]
        and environment.get("sourceManifestSHA256") == sha256(source_manifest_path)
        and environment.get("workingTreeStatus") == [],
        "P05 environment does not describe the frozen clean archive",
    )
    return capture


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def extract_clean_archive(repository: Path, archive_root: Path) -> None:
    archive_root.mkdir(parents=True, exist_ok=False)
    git_tool = resolved_tool("git")
    tar_tool = resolved_tool("tar")
    archive = subprocess.run(
        [str(git_tool), "archive", "--format=tar", FROZEN_SOURCE_REVISION],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if archive.returncode != 0:
        raise SystemExit(
            "Unable to export the frozen P05 source: "
            + archive.stderr.decode("utf-8", errors="replace").strip()
        )
    extracted = subprocess.run(
        [str(tar_tool), "-xf", "-", "-C", str(archive_root)],
        input=archive.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if extracted.returncode != 0:
        raise SystemExit(
            "Unable to extract the frozen P05 source: "
            + extracted.stderr.decode("utf-8", errors="replace").strip()
        )


def require_disjoint_work_paths(
    output: Path,
    derived_data: Path,
    archive_root: Path,
) -> None:
    paths = {"output": output, "derived data": derived_data, "archive": archive_root}
    for left_label, left in paths.items():
        for right_label, right in paths.items():
            if left_label >= right_label:
                continue
            if left == right or left in right.parents or right in left.parents:
                raise SystemExit(
                    f"P05 {left_label} and {right_label} paths must be disjoint"
                )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-existing", type=Path)
    parser.add_argument("--derived-data", type=Path, default=Path("/tmp/mirmir-v4-baseline"))
    parser.add_argument("--warmups", type=int, default=5)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--keep-work", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository = (
        arguments.repository.expanduser().resolve()
        if arguments.repository is not None
        else Path(__file__).resolve().parents[2]
    )
    if not (repository / ".git").exists():
        raise SystemExit(f"P05 source repository is absent: {repository}")
    if arguments.verify_existing is not None:
        if arguments.output is not None:
            raise SystemExit("Choose either --verify-existing or --output")
        verify_baseline_evidence(arguments.verify_existing, repository)
        print(arguments.verify_existing.expanduser().resolve())
        return 0
    if arguments.output is None:
        raise SystemExit("--output is required when capturing P05 evidence")
    capture_tool = Path(__file__).resolve()
    identity_tool = capture_tool.with_name("p05_baseline_v4.py")
    source_manifest_input = capture_tool.with_name(
        "p05-baseline-source-manifest-v1.json"
    )
    output = arguments.output.expanduser().resolve()
    derived_data = arguments.derived_data.expanduser().resolve()
    archive_root = derived_data.with_name(
        f"{derived_data.name}-p05-clean-source-{FROZEN_SOURCE_REVISION[:12]}"
    )
    require_disjoint_work_paths(output, derived_data, archive_root)
    if output.exists():
        raise SystemExit(f"Refusing to overwrite existing output directory: {output}")
    if derived_data.exists():
        raise SystemExit(f"Refusing to overwrite existing derived data: {derived_data}")
    if archive_root.exists():
        raise SystemExit(f"Refusing to overwrite existing P05 archive: {archive_root}")
    for required in (identity_tool, source_manifest_input):
        if not required.is_file() or required.is_symlink():
            raise SystemExit(f"Required P05 identity input is absent: {required}")
    if arguments.warmups < 0 or arguments.samples < 1:
        raise SystemExit("Warmups must be nonnegative and samples must be positive.")
    output.mkdir(parents=True, exist_ok=False)
    derived_data.parent.mkdir(parents=True, exist_ok=True)

    try:
        extract_clean_archive(repository, archive_root)
        source_manifest = p05.validate_source_manifest(
            repository,
            source_manifest_input,
            archive_root,
        )
        source_manifest_output = output / "source-manifest.json"
        shutil.copyfile(source_manifest_input, source_manifest_output)
        source_manifest_sha256 = sha256(source_manifest_output)
        if source_manifest_sha256 != sha256(source_manifest_input):
            raise SystemExit("Copied P05 source manifest identity changed")

        tools = tool_manifest(
            capture_tool,
            identity_tool,
            source_manifest_output,
            output,
        )
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
            str(derived_data),
            "-parallel-testing-enabled",
            "NO",
            "test",
            "-only-testing:MirmirTests/DeterministicMetalBackendTests/testCaptureV3BaselineWhenRequested",
            "-only-testing:MirmirTests/VideoProcessingSessionTests/testCaptureV3EndToEndBaselineWhenRequested",
            "CODE_SIGNING_ALLOWED=NO",
            "ENABLE_TESTABILITY=YES",
            "ONLY_ACTIVE_ARCH=YES",
            f"MIRMIR_V4_BASELINE_DIR={output}",
            f"MIRMIR_V4_WARMUP_COUNT={arguments.warmups}",
            f"MIRMIR_V4_SAMPLE_COUNT={arguments.samples}",
        ]
        completed = subprocess.run(
            command,
            cwd=archive_root,
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
            raise SystemExit(
                "The baseline test succeeded without producing engine-results.json."
            )
        end_to_end_results_path = output / "end-to-end-results.json"
        if not end_to_end_results_path.is_file():
            raise SystemExit(
                "The baseline test succeeded without producing end-to-end-results.json."
            )
        engine_results = json.loads(engine_results_path.read_text())
        end_to_end_results = json.loads(end_to_end_results_path.read_text())
        if engine_results.get("schemaVersion") != "mirmir-v4-baseline-v1":
            raise SystemExit("Frozen P05 engine capture schema changed")
        if (
            engine_results.get("cpuImplementationVersion")
            != "ash-p05-cpu-reference-preview"
            or engine_results.get("metalImplementationVersion")
            != "ash-p05-metal-v3-preview"
        ):
            raise SystemExit("Frozen P05 engine implementation identity changed")
        if (
            end_to_end_results.get("schemaVersion")
            != "mirmir-v4-end-to-end-baseline-v1"
        ):
            raise SystemExit("Frozen P05 end-to-end capture schema changed")

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
        write_json(
            output / "end-to-end-baseline.json",
            summarize_end_to_end(end_to_end_results),
        )
        write_json(
            output / "environment.json",
            environment_manifest(
                archive_root,
                source_manifest["sourceTreeIdentitySHA256"],
                source_manifest_sha256,
            ),
        )
        corpus = corpus_manifest(output, engine_results)
        write_json(output / "corpus-manifest.json", corpus)
        build = build_manifest(
            command,
            derived_data,
            output,
            source_manifest["sourceTreeIdentitySHA256"],
            source_manifest_sha256,
        )
        write_json(output / "build-identity.json", build)
        write_json(output / "tool-identities.json", tools)

        artifacts = artifact_manifest(output)
        capture = {
            "schemaVersion": "mirmir-v4-p05-capture-manifest-v2",
            "sourceIdentity": {
                "sourceRevision": FROZEN_SOURCE_REVISION,
                "gitTreeObjectID": source_manifest["gitTreeObjectID"],
                "sourceTreeIdentitySHA256": source_manifest[
                    "sourceTreeIdentitySHA256"
                ],
                "sourceManifestPath": "source-manifest.json",
                "sourceManifestSHA256": source_manifest_sha256,
            },
            "buildIdentity": {
                "manifestPath": "build-identity.json",
                "manifestSHA256": sha256(output / "build-identity.json"),
                "applicationExecutableSHA256": build["applicationExecutable"][
                    "sha256"
                ],
                "captureExecutableSHA256": build["captureExecutable"]["sha256"],
            },
            "toolIdentity": {
                "manifestPath": "tool-identities.json",
                "manifestSHA256": sha256(output / "tool-identities.json"),
                "artifactSetSHA256": tools["artifactSetSHA256"],
                "hostToolSetSHA256": tools["hostToolSetSHA256"],
            },
            "corpusIdentity": {
                "manifestPath": "corpus-manifest.json",
                "manifestSHA256": sha256(output / "corpus-manifest.json"),
                "artifactSetSHA256": corpus["artifactSetSHA256"],
            },
            "artifactCount": len(artifacts),
            "artifactSetSHA256": artifact_set_identity(artifacts),
            "artifacts": artifacts,
        }
        write_json(output / "capture-manifest.json", capture)
        write_json(output / "evidence-manifest.json", evidence_manifest(output))
        verify_baseline_evidence(output, repository)
        print(output)
        if arguments.keep_work:
            print(f"clean archive: {archive_root}")
            print(f"derived data: {derived_data}")
        return 0
    finally:
        if not arguments.keep_work:
            if archive_root.exists():
                shutil.rmtree(archive_root)
            if derived_data.exists():
                shutil.rmtree(derived_data)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"P05 baseline verification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
