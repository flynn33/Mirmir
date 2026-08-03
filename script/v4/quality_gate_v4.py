#!/usr/bin/env python3
"""Generate and evaluate the preregistered deterministic-engine v4 quality gate.

The checked-in generator is deliberately synthetic and therefore diagnostic,
not release-qualifying.  The evaluator is also usable with a locked natural
corpus that follows the same manifest schema; it never promotes the synthetic
fixtures to release evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys
from typing import Any, Iterable

import numpy as np

import p05_baseline_v4 as p05


SCHEMA_CORPUS = "mirmir-ash-v4-quality-corpus-v1"
SCHEMA_CAPTURE = "mirmir-ash-v4-quality-capture-v1"
SCHEMA_REPORT = "mirmir-ash-v4-quality-report-v1"
VARIANTS = (
    "baseline_p05",
    "candidate_v4",
    "uniform_priors",
    "randomized_state_message",
    "temporal_hysteresis_off",
    "motion_history_off",
)
CANDIDATE_VARIANTS = VARIANTS[1:]


def require_frozen_p05_identity(
    contract: dict[str, Any], observed: Any
) -> dict[str, Any]:
    try:
        return p05.require_observed_identity(contract, observed)
    except ValueError as error:
        raise SystemExit(f"frozen P05 identity failure: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_relative(root: Path, relative: str) -> Path:
    root = root.resolve()
    if not isinstance(relative, str) or "\\" in relative:
        raise ValueError(f"artifact path is not canonical: {relative}")
    pure = Path(relative)
    if (
        pure.is_absolute()
        or pure.as_posix() != relative
        or any(part in {"", ".", ".."} for part in pure.parts)
    ):
        raise ValueError(f"artifact escapes root: {relative}")
    candidate = root / pure
    path = candidate.resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise ValueError(f"artifact escapes root: {relative}") from error
    current = candidate
    while current != root:
        if current.is_symlink():
            raise ValueError(f"artifact path contains a symbolic link: {relative}")
        current = current.parent
    return path


def artifact_set_sha(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for path, identity in sorted(entries):
        digest.update(path.encode())
        digest.update(b"\0")
        digest.update(identity.encode())
        digest.update(b"\n")
    return digest.hexdigest()


def round_ties_even(numerator: int, denominator: int) -> int:
    if numerator < 0 or denominator <= 0:
        raise ValueError("round_ties_even accepts a nonnegative fraction")
    quotient, remainder = divmod(numerator, denominator)
    complement = denominator - remainder
    if remainder > complement or (remainder == complement and quotient & 1):
        quotient += 1
    return quotient


def mix32(value: int) -> int:
    value &= 0xFFFFFFFF
    value ^= value >> 16
    value = (value * 0x7FEB352D) & 0xFFFFFFFF
    value ^= value >> 15
    value = (value * 0x846CA68B) & 0xFFFFFFFF
    value ^= value >> 16
    return value


def code_from_unit(value: int, denominator: int, low: int, high: int) -> int:
    value = min(denominator, max(0, value))
    return low + round_ties_even(value * (high - low), denominator)


def synthetic_luma(
    cohort: str,
    clip: int,
    frame: int,
    x: int,
    y: int,
    width: int,
    height: int,
    low: int,
    high: int,
) -> int:
    seed = mix32((clip + 1) * 0x9E3779B1 ^ (frame + 3) * 0x85EBCA77)
    if cohort == "natural_detail":
        broad = (x * 271 + y * 193 + ((x * y + clip * 31) % 257) * 97) % 4096
        vein = 4095 if ((x + 2 * y + clip * 7) % (11 + clip)) < 2 else 0
        grain = mix32(seed ^ (x * 0x1F123BB5) ^ (y * 0x5F356495)) & 1023
        unit = (3 * broad + vein + grain + frame * 53) // 5
        return code_from_unit(unit, 4095, low, high)
    if cohort == "text_graphics":
        background = 420 + clip * 110
        vertical = ((x - 5 - clip * 2) % 13) in (0, 1, 2)
        horizontal = ((y - 7 - frame) % 11) in (0, 1)
        diagonal = abs((x + frame * 2) - (2 * y + clip * 5)) <= 1
        box = width // 3 < x < 2 * width // 3 and height // 3 < y < 2 * height // 3
        unit = 3650 if vertical or horizontal or diagonal else background
        if box and not (vertical or horizontal):
            unit = 2500 + ((x + y) & 1) * 420
        return code_from_unit(unit, 4095, low, high)
    if cohort == "animation":
        cx = 12 + clip * 9 + frame * (clip + 1)
        cy = 12 + clip * 4 + (frame % 3) * 3
        dx, dy = x - (cx % width), y - (cy % height)
        circle = dx * dx + dy * dy <= (7 + clip) ** 2
        stripe = ((x + frame * 3) // 8 + y // 8) % 3
        unit = 3300 if circle else (520 + stripe * 760)
        return code_from_unit(unit, 4095, low, high)
    if cohort == "faces":
        cx = width // 2 + clip - 2 + (frame % 3) - 1
        cy = height // 2
        dx, dy = x - cx, y - cy
        face = dx * dx * 9 + dy * dy * 16 <= 17 * 17 * 9
        left_eye = (x - (cx - 6)) ** 2 + (y - (cy - 5)) ** 2 <= 4
        right_eye = (x - (cx + 6)) ** 2 + (y - (cy - 5)) ** 2 <= 4
        mouth = abs(y - (cy + 7) - ((x - cx) * (x - cx) // 30)) <= 1 and abs(dx) < 9
        hair = face and y < cy - 10 + ((x + clip) % 3)
        unit = 2450 if face else 680 + ((x + y) % 5) * 35
        if left_eye or right_eye or mouth:
            unit = 260
        if hair:
            unit = 520
        return code_from_unit(unit, 4095, low, high)
    if cohort == "low_light_noise":
        noise = mix32(seed ^ x * 0x27D4EB2D ^ y * 0x165667B1) & 511
        hot = 1800 if (mix32(seed + x * 257 + y * 911) & 127) == 0 else 0
        unit = 180 + noise + hot + (x * 3 + y * 5 + clip * 41) % 260
        return code_from_unit(unit, 4095, low, high)
    if cohort == "high_motion":
        shift = frame * (7 + clip)
        moving_bar = ((x - shift) % width) < 8 + clip
        checker = (((x + shift) // 5) + ((y + frame * 3) // 5)) & 1
        unit = 3750 if moving_bar else (550 if checker == 0 else 2850)
        return code_from_unit(unit, 4095, low, high)
    if cohort == "scene_cuts":
        if frame < 3:
            unit = (x * 53 + y * 31 + clip * 317 + frame * 71) % 2400 + 400
            if (x - 10 - frame * 2) ** 2 + (y - 14) ** 2 < 55:
                unit = 3700
        else:
            unit = 3450 - ((x * 19 + y * 67 + clip * 211) % 2550)
            if ((x // (4 + clip)) + y // 6 + frame) & 1:
                unit = 300
        return code_from_unit(unit, 4095, low, high)
    raise ValueError(f"unknown cohort: {cohort}")


def synthetic_chroma(
    cohort: str,
    clip: int,
    frame: int,
    x: int,
    y: int,
    channel: int,
    low: int,
    high: int,
) -> int:
    cohort_index = (
        "natural_detail",
        "text_graphics",
        "animation",
        "faces",
        "low_light_noise",
        "high_motion",
        "scene_cuts",
    ).index(cohort)
    base = 2048 + (cohort_index - 3) * (190 if channel == 0 else -170)
    motion = (frame * (71 + clip * 13) + x * 43 + y * 29) % 901 - 450
    if cohort == "scene_cuts" and frame >= 3:
        base = 4095 - base
    if cohort == "low_light_noise":
        motion = (mix32(x * 1237 ^ y * 3571 ^ frame * 101 ^ clip) & 511) - 255
    unit = base + (motion if channel == 0 else -motion)
    return code_from_unit(unit, 4095, low, high)


def box_downsample_ties_even(plane: np.ndarray) -> np.ndarray:
    if plane.shape[0] % 2 or plane.shape[1] % 2:
        raise ValueError("2x2 downsampling requires even dimensions")
    total = (
        plane[0::2, 0::2].astype(np.uint16)
        + plane[0::2, 1::2].astype(np.uint16)
        + plane[1::2, 0::2].astype(np.uint16)
        + plane[1::2, 1::2].astype(np.uint16)
    )
    quotient = total // 4
    remainder = total % 4
    rounded = quotient + ((remainder > 2) | ((remainder == 2) & (quotient & 1))).astype(np.uint16)
    return rounded.astype(np.uint8)


def make_reference(
    cohort: str,
    clip: int,
    frame: int,
    pixel_format: str,
    width: int,
    height: int,
) -> tuple[np.ndarray, np.ndarray]:
    if pixel_format == "420v":
        y_bounds, c_bounds = (16, 235), (16, 240)
    elif pixel_format == "420f":
        y_bounds = c_bounds = (0, 255)
    else:
        raise ValueError(pixel_format)
    luma = np.empty((height, width), dtype=np.uint8)
    chroma = np.empty((height // 2, width // 2, 2), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            luma[y, x] = synthetic_luma(
                cohort, clip, frame, x, y, width, height, *y_bounds
            )
    for y in range(height // 2):
        for x in range(width // 2):
            for channel in range(2):
                chroma[y, x, channel] = synthetic_chroma(
                    cohort, clip, frame, x, y, channel, *c_bounds
                )
    return luma, chroma


def generate_corpus(contract_path: Path, output: Path) -> int:
    contract_path = contract_path.resolve()
    contract = json.loads(contract_path.read_text())
    if contract.get("schemaVersion") != "mirmir-ash-v4-quality-gate-contract-v1":
        raise SystemExit("unsupported quality contract")
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f"refusing to overwrite nonempty corpus directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    construction = contract["corpusConstruction"]
    cohorts = contract["cohortConstraints"]["contentCohorts"]
    width = int(construction["referenceWidth"])
    height = int(construction["referenceHeight"])
    source_width = int(construction["sourceWidth"])
    source_height = int(construction["sourceHeight"])
    if width != source_width * 2 or height != source_height * 2:
        raise SystemExit("synthetic generator implements only the declared exact 2x route")

    cases: list[dict[str, Any]] = []
    artifacts: list[dict[str, Any]] = []
    for cohort_index, cohort in enumerate(cohorts):
        for clip in range(int(construction["syntheticDiagnosticClipCountPerCohort"])):
            pixel_format = "420v" if (cohort_index + clip) % 2 == 0 else "420f"
            clip_id = f"{cohort}-c{clip:02d}-{pixel_format}"
            for frame in range(int(construction["syntheticDiagnosticFramesPerClip"])):
                luma, chroma = make_reference(
                    cohort, clip, frame, pixel_format, width, height
                )
                source_luma = box_downsample_ties_even(luma)
                source_chroma = np.stack(
                    [box_downsample_ties_even(chroma[:, :, channel]) for channel in range(2)],
                    axis=2,
                )
                case_id = f"{clip_id}-f{frame:02d}"
                source_relative = f"artifacts/{case_id}-source.nv12"
                reference_relative = f"artifacts/{case_id}-reference.nv12"
                source_bytes = source_luma.tobytes() + source_chroma.tobytes()
                reference_bytes = luma.tobytes() + chroma.tobytes()
                source_path = output / source_relative
                reference_path = output / reference_relative
                source_path.parent.mkdir(parents=True, exist_ok=True)
                source_path.write_bytes(source_bytes)
                reference_path.write_bytes(reference_bytes)
                source_hash = sha256_bytes(source_bytes)
                reference_hash = sha256_bytes(reference_bytes)
                artifacts.extend(
                    [
                        {"path": source_relative, "byteCount": len(source_bytes), "sha256": source_hash},
                        {"path": reference_relative, "byteCount": len(reference_bytes), "sha256": reference_hash},
                    ]
                )
                cases.append(
                    {
                        "id": case_id,
                        "clipID": clip_id,
                        "cohort": cohort,
                        "frameIndex": frame,
                        "pixelFormat": pixel_format,
                        "sourceWidth": source_width,
                        "sourceHeight": source_height,
                        "targetWidth": width,
                        "targetHeight": height,
                        "sourceFile": source_relative,
                        "sourceByteCount": len(source_bytes),
                        "sourceSHA256": source_hash,
                        "referenceFile": reference_relative,
                        "referenceByteCount": len(reference_bytes),
                        "referenceSHA256": reference_hash,
                    }
                )
    artifact_identity = artifact_set_sha((a["path"], a["sha256"]) for a in artifacts)
    manifest = {
        "schemaVersion": SCHEMA_CORPUS,
        "contractSHA256": sha256(contract_path),
        "corpusID": "ash-v4-seven-cohort-synthetic-diagnostic-v1",
        "corpusKind": "synthetic_diagnostic",
        "releaseEligible": False,
        "limitations": [
            "Every source is deterministic procedural imagery; the natural-detail and faces cohorts are synthetic approximations, not camera-native natural media.",
            "The 64x48 raster is suitable for deterministic regression and calibration diagnostics, not final perceptual release qualification.",
            "The corpus contains progressive 8-bit SDR only, matching the baseline comparison population but not newly supported formats."
        ],
        "construction": construction,
        "cohorts": cohorts,
        "caseCount": len(cases),
        "clipCount": len(cohorts) * int(construction["syntheticDiagnosticClipCountPerCohort"]),
        "artifactSetSHA256": artifact_identity,
        "artifacts": sorted(artifacts, key=lambda item: item["path"]),
        "cases": sorted(cases, key=lambda item: item["id"]),
    }
    write_json(output / "corpus-manifest.json", manifest)
    print(output / "corpus-manifest.json")
    return 0


def load_plane_pair(root: Path, record: dict[str, Any], key: str) -> tuple[np.ndarray, np.ndarray]:
    path = checked_relative(root, record[key])
    data = np.fromfile(path, dtype=np.uint8)
    width = int(record["targetWidth"])
    height = int(record["targetHeight"])
    luma_count = width * height
    chroma_count = width * height // 2
    if data.size != luma_count + chroma_count:
        raise ValueError(f"unexpected visible byte count for {record['id']} {key}")
    return (
        data[:luma_count].reshape(height, width),
        data[luma_count:].reshape(height // 2, width // 2, 2),
    )


def normalized(plane: np.ndarray, low: int, high: int) -> np.ndarray:
    values = plane.astype(np.float64)
    if np.any(values < low) or np.any(values > high):
        raise ValueError("signal code is outside the declared range")
    return (values - low) / float(high - low)


def crop(plane: np.ndarray, count: int) -> np.ndarray:
    if count < 0 or min(plane.shape[:2]) <= 2 * count:
        raise ValueError("invalid crop")
    return plane[count:-count, count:-count] if count else plane


def local_ssim(reference: np.ndarray, observed: np.ndarray, window: int) -> float:
    window = min(window, reference.shape[0], reference.shape[1])
    if window < 2:
        raise ValueError("SSIM image is too small")
    ref_windows = np.lib.stride_tricks.sliding_window_view(reference, (window, window))
    obs_windows = np.lib.stride_tricks.sliding_window_view(observed, (window, window))
    mean_ref = ref_windows.mean(axis=(-2, -1))
    mean_obs = obs_windows.mean(axis=(-2, -1))
    centered_ref = ref_windows - mean_ref[..., None, None]
    centered_obs = obs_windows - mean_obs[..., None, None]
    variance_ref = np.mean(centered_ref * centered_ref, axis=(-2, -1))
    variance_obs = np.mean(centered_obs * centered_obs, axis=(-2, -1))
    covariance = np.mean(centered_ref * centered_obs, axis=(-2, -1))
    c1, c2 = 0.01**2, 0.03**2
    numerator = (2 * mean_ref * mean_obs + c1) * (2 * covariance + c2)
    denominator = (mean_ref * mean_ref + mean_obs * mean_obs + c1) * (
        variance_ref + variance_obs + c2
    )
    return float(np.mean(numerator / denominator))


def float_box_downsample(plane: np.ndarray) -> np.ndarray:
    height = plane.shape[0] - plane.shape[0] % 2
    width = plane.shape[1] - plane.shape[1] % 2
    source = plane[:height, :width]
    return source.reshape(height // 2, 2, width // 2, 2).mean(axis=(1, 3))


def multiscale_structural_error(
    reference: np.ndarray, observed: np.ndarray, crop_count: int, window: int
) -> float:
    ref = crop(reference, crop_count)
    obs = crop(observed, crop_count)
    first = 1.0 - local_ssim(ref, obs, window)
    second = 1.0 - local_ssim(
        float_box_downsample(ref), float_box_downsample(obs), max(2, window // 2)
    )
    return float(max(0.0, 0.6 * first + 0.4 * second))


def feature_distance(reference: np.ndarray, observed: np.ndarray) -> float:
    ref = crop(reference, 4)
    obs = crop(observed, 4)
    ref_x = np.diff(ref, axis=1)
    obs_x = np.diff(obs, axis=1)
    ref_y = np.diff(ref, axis=0)
    obs_y = np.diff(obs, axis=0)
    ref_pad = np.pad(ref, 1, mode="edge")
    obs_pad = np.pad(obs, 1, mode="edge")
    ref_lap = (
        -4 * ref_pad[1:-1, 1:-1]
        + ref_pad[:-2, 1:-1]
        + ref_pad[2:, 1:-1]
        + ref_pad[1:-1, :-2]
        + ref_pad[1:-1, 2:]
    )
    obs_lap = (
        -4 * obs_pad[1:-1, 1:-1]
        + obs_pad[:-2, 1:-1]
        + obs_pad[2:, 1:-1]
        + obs_pad[1:-1, :-2]
        + obs_pad[1:-1, 2:]
    )
    return float(
        0.375 * np.mean(np.abs(ref_x - obs_x))
        + 0.375 * np.mean(np.abs(ref_y - obs_y))
        + 0.25 * np.mean(np.abs(ref_lap - obs_lap)) / 4.0
    )


def laplacian(plane: np.ndarray) -> np.ndarray:
    padded = np.pad(plane, 1, mode="edge")
    return (
        -4 * padded[1:-1, 1:-1]
        + padded[:-2, 1:-1]
        + padded[2:, 1:-1]
        + padded[1:-1, :-2]
        + padded[1:-1, 2:]
    )


def local_envelope(plane: np.ndarray, radius: int = 2) -> tuple[np.ndarray, np.ndarray]:
    padded = np.pad(plane, radius, mode="edge")
    windows = np.lib.stride_tricks.sliding_window_view(
        padded, (radius * 2 + 1, radius * 2 + 1)
    )
    return windows.min(axis=(-2, -1)), windows.max(axis=(-2, -1))


def edge_error(reference: np.ndarray, observed: np.ndarray) -> float:
    ref = crop(reference, 4)
    obs = crop(observed, 4)
    ref_y, ref_x = np.gradient(ref)
    obs_y, obs_x = np.gradient(obs)
    ref_magnitude = np.hypot(ref_x, ref_y)
    obs_magnitude = np.hypot(obs_x, obs_y)
    positive = ref_magnitude[ref_magnitude > 1e-12]
    if positive.size:
        threshold = float(np.percentile(positive, 75))
        locations = np.argwhere(ref_magnitude >= threshold)
        displacements: list[float] = []
        for y, x in locations:
            candidates: list[tuple[float, int, int, int]] = []
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < obs.shape[0] and 0 <= xx < obs.shape[1]:
                        candidates.append(
                            (-float(obs_magnitude[yy, xx]), abs(dx) + abs(dy), dy, dx)
                        )
            best = min(candidates)
            displacements.append(math.hypot(best[3], best[2]) / math.sqrt(8.0))
        displacement = float(statistics.fmean(displacements))
    else:
        displacement = 0.0
    ringing = float(np.mean(np.abs(laplacian(ref) - laplacian(obs))) / 4.0)
    local_min, local_max = local_envelope(ref)
    overshoot = np.maximum(0.0, obs - local_max) + np.maximum(0.0, local_min - obs)
    return float(0.40 * displacement + 0.35 * ringing + 0.25 * np.mean(overshoot))


def histogram_scene_cut(previous: np.ndarray, current: np.ndarray) -> bool:
    prev_hist, _ = np.histogram(previous, bins=16, range=(0.0, 1.0))
    curr_hist, _ = np.histogram(current, bins=16, range=(0.0, 1.0))
    difference = np.abs(prev_hist - curr_hist).sum() / (2.0 * previous.size)
    return bool(difference >= 0.375)


def temporal_pair_error(
    previous_reference: np.ndarray,
    current_reference: np.ndarray,
    previous_observed: np.ndarray,
    current_observed: np.ndarray,
) -> float:
    if histogram_scene_cut(previous_reference, current_reference):
        reference_delta = current_reference - previous_reference
        observed_delta = current_observed - previous_observed
        return float(np.mean(np.abs(reference_delta - observed_delta)))
    height, width = current_reference.shape
    errors: list[float] = []
    for origin_y in range(4, height - 4, 8):
        for origin_x in range(4, width - 4, 8):
            block_height = min(8, height - 4 - origin_y)
            block_width = min(8, width - 4 - origin_x)
            if block_height <= 0 or block_width <= 0:
                continue
            current_block = current_reference[
                origin_y : origin_y + block_height,
                origin_x : origin_x + block_width,
            ]
            choices: list[tuple[float, int, int, int]] = []
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    y0, x0 = origin_y + dy, origin_x + dx
                    if y0 < 0 or x0 < 0 or y0 + block_height > height or x0 + block_width > width:
                        continue
                    previous_block = previous_reference[
                        y0 : y0 + block_height, x0 : x0 + block_width
                    ]
                    choices.append(
                        (
                            float(np.sum(np.abs(current_block - previous_block))),
                            abs(dx) + abs(dy),
                            dy,
                            dx,
                        )
                    )
            _, _, dy, dx = min(choices)
            previous_ref = previous_reference[
                origin_y + dy : origin_y + dy + block_height,
                origin_x + dx : origin_x + dx + block_width,
            ]
            previous_obs = previous_observed[
                origin_y + dy : origin_y + dy + block_height,
                origin_x + dx : origin_x + dx + block_width,
            ]
            current_obs = current_observed[
                origin_y : origin_y + block_height,
                origin_x : origin_x + block_width,
            ]
            errors.append(
                float(np.mean(np.abs((current_block - previous_ref) - (current_obs - previous_obs))))
            )
    if not errors:
        raise ValueError("no admitted temporal blocks")
    return float(statistics.fmean(errors))


def component_errors(
    reference_frames: list[tuple[np.ndarray, np.ndarray]],
    observed_frames: list[tuple[np.ndarray, np.ndarray]],
    pixel_format: str,
) -> dict[str, float]:
    if len(reference_frames) != len(observed_frames) or len(reference_frames) < 2:
        raise ValueError("clip frame count mismatch")
    y_bounds = (16, 235) if pixel_format == "420v" else (0, 255)
    c_bounds = (16, 240) if pixel_format == "420v" else (0, 255)
    ref_y = [normalized(frame[0], *y_bounds) for frame in reference_frames]
    obs_y = [normalized(frame[0], *y_bounds) for frame in observed_frames]
    ref_c = [normalized(frame[1], *c_bounds) for frame in reference_frames]
    obs_c = [normalized(frame[1], *c_bounds) for frame in observed_frames]
    luma = [multiscale_structural_error(r, o, 4, 7) for r, o in zip(ref_y, obs_y)]
    chroma = [
        statistics.fmean(
            multiscale_structural_error(r[:, :, channel], o[:, :, channel], 2, 5)
            for channel in range(2)
        )
        for r, o in zip(ref_c, obs_c)
    ]
    perceptual = [feature_distance(r, o) for r, o in zip(ref_y, obs_y)]
    edge = [edge_error(r, o) for r, o in zip(ref_y, obs_y)]
    temporal = [
        temporal_pair_error(ref_y[index - 1], ref_y[index], obs_y[index - 1], obs_y[index])
        for index in range(1, len(ref_y))
    ]
    return {
        "luma_multiscale_structural_error": float(statistics.fmean(luma)),
        "chroma_multiscale_structural_error": float(statistics.fmean(chroma)),
        "perceptual_feature_distance": float(statistics.fmean(perceptual)),
        "motion_compensated_temporal_flicker_error": float(statistics.fmean(temporal)),
        "edge_displacement_ringing_overshoot_error": float(statistics.fmean(edge)),
    }


class SplitMix64:
    def __init__(self, seed: int):
        self.state = seed & 0xFFFFFFFFFFFFFFFF

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        return (value ^ (value >> 31)) & 0xFFFFFFFFFFFFFFFF

    def index(self, upper_bound: int) -> int:
        if upper_bound <= 0:
            raise ValueError("empty bootstrap stratum")
        limit = (1 << 64) - ((1 << 64) % upper_bound)
        while True:
            value = self.next()
            if value < limit:
                return value % upper_bound


def aggregate_ratios(
    metrics: dict[str, dict[str, dict[str, float]]],
    clips_by_cohort: dict[str, list[str]],
    variant: str,
    weights: dict[str, float],
    sampled: dict[str, list[str]] | None = None,
) -> tuple[dict[str, float], dict[str, dict[str, float]], float, float]:
    by_cohort: dict[str, dict[str, float]] = {}
    for cohort, clips in clips_by_cohort.items():
        selected = sampled[cohort] if sampled is not None else clips
        component_ratios: dict[str, float] = {}
        for component in weights:
            baseline = statistics.fmean(metrics[clip]["baseline_p05"][component] for clip in selected)
            candidate = statistics.fmean(metrics[clip][variant][component] for clip in selected)
            if not math.isfinite(baseline) or baseline <= 0:
                raise ValueError(f"nonpositive baseline normalizer: {cohort} {component}")
            ratio = candidate / baseline
            if not math.isfinite(ratio):
                raise ValueError(f"nonfinite normalized metric: {cohort} {component}")
            component_ratios[component] = ratio
        by_cohort[cohort] = component_ratios
    aggregate = {
        component: float(statistics.fmean(by_cohort[c][component] for c in sorted(by_cohort)))
        for component in weights
    }
    error = float(sum(weights[c] * aggregate[c] for c in weights))
    quality = 100.0 * (2.0 - error)
    return aggregate, by_cohort, error, quality


def percentile(values: list[float], quantile: float) -> float:
    return float(np.percentile(np.asarray(values, dtype=np.float64), quantile))


def output_set_identity(capture_root: Path, capture: dict[str, Any], variant: str) -> str:
    entries = []
    for record in capture["cases"]:
        relative = record["outputs"][variant]
        entries.append((relative, sha256(checked_relative(capture_root, relative))))
    return artifact_set_sha(entries)


def validate_artifacts(root: Path, artifacts: list[dict[str, Any]]) -> None:
    declared = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {
            "path",
            "byteCount",
            "sha256",
        }:
            raise ValueError("artifact descriptor field set differs")
        path = checked_relative(root, artifact["path"])
        if artifact["path"] in declared:
            raise ValueError(f"duplicate artifact: {artifact['path']}")
        declared.add(artifact["path"])
        if not path.is_file():
            raise ValueError(f"missing artifact: {artifact['path']}")
        if path.stat().st_size != int(artifact["byteCount"]):
            raise ValueError(f"artifact size mismatch: {artifact['path']}")
        if sha256(path) != artifact["sha256"]:
            raise ValueError(f"artifact hash mismatch: {artifact['path']}")


def merge_captures(
    contract_path: Path,
    corpus_path: Path,
    p05_capture_path: Path,
    candidate_capture_path: Path,
    output: Path,
) -> int:
    """Join independently built P05 and candidate lanes without executing P05.

    The frozen identity is checked before any case or artifact data is read, so
    a candidate-tree P05 capture cannot be relabeled and merged.
    """

    contract_path = contract_path.resolve()
    corpus_path = corpus_path.resolve()
    p05_capture_path = p05_capture_path.resolve()
    candidate_capture_path = candidate_capture_path.resolve()
    contract = json.loads(contract_path.read_text())
    p05_capture = json.loads(p05_capture_path.read_text())
    candidate = json.loads(candidate_capture_path.read_text())
    baseline_identity = require_frozen_p05_identity(
        contract, p05_capture.get("baselineIdentity")
    )
    if p05_capture.get("schemaVersion") != "mirmir-ash-v4-quality-p05-capture-v1":
        raise SystemExit("unsupported frozen P05 capture manifest")
    if candidate.get("schemaVersion") != "mirmir-ash-v4-quality-candidate-capture-v1":
        raise SystemExit("unsupported candidate quality capture manifest")
    contract_hash = sha256(contract_path)
    corpus_hash = sha256(corpus_path)
    for label, capture in (("P05", p05_capture), ("candidate", candidate)):
        if capture.get("contractSHA256") != contract_hash:
            raise SystemExit(f"{label} capture contract identity mismatch")
        if capture.get("corpusManifestSHA256") != corpus_hash:
            raise SystemExit(f"{label} capture corpus identity mismatch")

    baseline_cases = p05_capture.get("cases")
    candidate_cases = candidate.get("cases")
    if not isinstance(baseline_cases, list) or not isinstance(candidate_cases, list):
        raise SystemExit("quality capture case arrays are absent")
    baseline_by_id = {
        item.get("id"): item for item in baseline_cases if isinstance(item, dict)
    }
    candidate_by_id = {
        item.get("id"): item for item in candidate_cases if isinstance(item, dict)
    }
    if (
        len(baseline_by_id) != len(baseline_cases)
        or len(candidate_by_id) != len(candidate_cases)
        or set(baseline_by_id) != set(candidate_by_id)
        or any(not isinstance(case_id, str) for case_id in baseline_by_id)
    ):
        raise SystemExit("P05 and candidate capture case sets differ")

    merged_cases: list[dict[str, Any]] = []
    for case_id in sorted(baseline_by_id):
        baseline = baseline_by_id[case_id]
        observed = candidate_by_id[case_id]
        if set(baseline) != {"id", "output", "milliseconds"}:
            raise SystemExit(f"P05 capture case field set differs: {case_id}")
        if set(observed) != {"id", "outputs", "milliseconds"}:
            raise SystemExit(f"candidate capture case field set differs: {case_id}")
        outputs = observed["outputs"]
        milliseconds = observed["milliseconds"]
        if not isinstance(outputs, dict) or set(outputs) != set(CANDIDATE_VARIANTS):
            raise SystemExit(f"candidate capture variant set differs: {case_id}")
        if not isinstance(milliseconds, dict) or set(milliseconds) != set(CANDIDATE_VARIANTS):
            raise SystemExit(f"candidate timing variant set differs: {case_id}")
        merged_cases.append(
            {
                "id": case_id,
                "outputs": {"baseline_p05": baseline["output"], **outputs},
                "milliseconds": {
                    "baseline_p05": baseline["milliseconds"],
                    **milliseconds,
                },
            }
        )

    candidate_fields = {
        "contractSHA256",
        "corpusManifestSHA256",
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "candidateBackendID",
        "candidateImplementationVersion",
        "runtimeManifestSHA256",
        "runtimeSourceRevision",
        "productionRuntimeLocked",
        "fullMirrorIdentityPass",
        "warmupCount",
    }
    if set(candidate) != candidate_fields | {"schemaVersion", "cases"}:
        raise SystemExit("candidate capture manifest field set differs")
    merged = {
        "schemaVersion": SCHEMA_CAPTURE,
        **{key: candidate[key] for key in sorted(candidate_fields)},
        "baselineIdentity": baseline_identity,
        "baselineImplementationVersion": baseline_identity[
            "implementationVersion"
        ],
        "baselineWarmupCount": p05_capture.get("warmupCount"),
        "cases": merged_cases,
    }
    write_json(output.resolve(), merged)
    print(output.resolve())
    return 0


def replay_raw_components(
    contract: dict[str, Any],
    corpus: dict[str, Any],
    corpus_root: Path,
    capture: dict[str, Any],
    capture_root: Path,
) -> tuple[
    list[dict[str, Any]],
    dict[str, dict[str, dict[str, float]]],
    dict[str, list[str]],
]:
    """Recompute every per-clip component from reference and output planes."""

    corpus_cases = corpus.get("cases")
    capture_cases = capture.get("cases")
    if not isinstance(corpus_cases, list) or not isinstance(capture_cases, list):
        raise SystemExit("quality raw case arrays are absent")
    expected_ids = [case.get("id") for case in corpus_cases if isinstance(case, dict)]
    captured_ids = [case.get("id") for case in capture_cases if isinstance(case, dict)]
    if (
        len(expected_ids) != len(corpus_cases)
        or len(captured_ids) != len(capture_cases)
        or any(not isinstance(case_id, str) for case_id in expected_ids + captured_ids)
        or len(expected_ids) != len(set(expected_ids))
        or len(captured_ids) != len(set(captured_ids))
        or set(expected_ids) != set(captured_ids)
    ):
        raise SystemExit("capture case set differs from corpus case set")
    capture_by_id = {case["id"]: case for case in capture_cases}
    for case in corpus_cases:
        record = capture_by_id[case["id"]]
        if set(record) != {"id", "outputs", "milliseconds"}:
            raise SystemExit(f"capture case field set differs: {case['id']}")
        if set(record.get("outputs", {})) != set(VARIANTS):
            raise SystemExit(f"variant set mismatch for {case['id']}")
        if set(record.get("milliseconds", {})) != set(VARIANTS):
            raise SystemExit(f"timing variant set mismatch for {case['id']}")
        for variant, relative in record["outputs"].items():
            path = checked_relative(capture_root, relative)
            expected_bytes = int(case["targetWidth"]) * int(case["targetHeight"]) * 3 // 2
            if path.is_symlink() or not path.is_file() or path.stat().st_size != expected_bytes:
                raise SystemExit(f"output artifact mismatch: {relative}")
            milliseconds = record["milliseconds"][variant]
            if (
                not isinstance(milliseconds, (int, float))
                or not math.isfinite(float(milliseconds))
                or milliseconds < 0
            ):
                raise SystemExit(f"invalid capture timing: {case['id']} {variant}")

    cohorts_required = contract["cohortConstraints"]["contentCohorts"]
    cases_by_clip: dict[str, list[dict[str, Any]]] = {}
    clips_by_cohort: dict[str, list[str]] = {
        cohort: [] for cohort in cohorts_required
    }
    for case in corpus_cases:
        cases_by_clip.setdefault(case["clipID"], []).append(case)
    for clip_id, cases in cases_by_clip.items():
        cohorts = {case["cohort"] for case in cases}
        formats = {case["pixelFormat"] for case in cases}
        frame_indices = sorted(int(case["frameIndex"]) for case in cases)
        if (
            len(cohorts) != 1
            or len(formats) != 1
            or frame_indices != list(range(len(cases)))
        ):
            raise SystemExit(f"invalid clip manifest: {clip_id}")
        cohort = next(iter(cohorts))
        if cohort not in clips_by_cohort:
            raise SystemExit(f"unexpected cohort: {cohort}")
        clips_by_cohort[cohort].append(clip_id)
    minimum_clips = int(contract["cohortConstraints"]["minimumClipsPerCohort"])
    minimum_frames = int(contract["cohortConstraints"]["minimumFramesPerClip"])
    for cohort, clips in clips_by_cohort.items():
        clips.sort()
        if len(clips) < minimum_clips:
            raise SystemExit(f"cohort has too few clips: {cohort}")
        if any(len(cases_by_clip[clip]) < minimum_frames for clip in clips):
            raise SystemExit(f"cohort has a short clip: {cohort}")

    metrics: dict[str, dict[str, dict[str, float]]] = {}
    per_clip: list[dict[str, Any]] = []
    for clip_id in sorted(cases_by_clip):
        cases = sorted(
            cases_by_clip[clip_id], key=lambda item: int(item["frameIndex"])
        )
        reference_frames = [
            load_plane_pair(corpus_root, case, "referenceFile") for case in cases
        ]
        variant_frames = {
            variant: [
                load_plane_pair(
                    capture_root,
                    {
                        **case,
                        "output": capture_by_id[case["id"]]["outputs"][variant],
                    },
                    "output",
                )
                for case in cases
            ]
            for variant in VARIANTS
        }
        metrics[clip_id] = {
            variant: component_errors(
                reference_frames, frames, cases[0]["pixelFormat"]
            )
            for variant, frames in variant_frames.items()
        }
        per_clip.append(
            {
                "clipID": clip_id,
                "cohort": cases[0]["cohort"],
                "pixelFormat": cases[0]["pixelFormat"],
                "frameCount": len(cases),
                "components": metrics[clip_id],
            }
        )
    return per_clip, metrics, clips_by_cohort


def evaluate(contract_path: Path, corpus_path: Path, capture_path: Path, output: Path) -> int:
    contract_path = contract_path.resolve()
    corpus_path = corpus_path.resolve()
    capture_path = capture_path.resolve()
    contract = json.loads(contract_path.read_text())
    corpus = json.loads(corpus_path.read_text())
    capture_data = json.loads(capture_path.read_text())
    if corpus.get("schemaVersion") != SCHEMA_CORPUS:
        raise SystemExit("unsupported corpus manifest")
    if capture_data.get("schemaVersion") != SCHEMA_CAPTURE:
        raise SystemExit("unsupported capture manifest")
    # This must precede all artifact reads and metric evaluation. A P05 lane
    # built from, or relabeled by, the candidate tree is not scoreable.
    baseline_identity = require_frozen_p05_identity(
        contract, capture_data.get("baselineIdentity")
    )
    if (
        capture_data.get("baselineImplementationVersion")
        != baseline_identity["implementationVersion"]
    ):
        raise SystemExit("capture P05 implementation identity mismatch")
    contract_hash = sha256(contract_path)
    corpus_hash = sha256(corpus_path)
    if corpus.get("contractSHA256") != contract_hash:
        raise SystemExit("corpus contract identity mismatch")
    if capture_data.get("contractSHA256") != contract_hash:
        raise SystemExit("capture contract identity mismatch")
    if capture_data.get("corpusManifestSHA256") != corpus_hash:
        raise SystemExit("capture corpus identity mismatch")
    corpus_root = corpus_path.parent
    capture_root = capture_path.parent
    validate_artifacts(corpus_root, corpus["artifacts"])
    computed_corpus_set = artifact_set_sha((a["path"], a["sha256"]) for a in corpus["artifacts"])
    if computed_corpus_set != corpus.get("artifactSetSHA256"):
        raise SystemExit("corpus artifact-set identity mismatch")

    per_clip_report, metrics, clips_by_cohort = replay_raw_components(
        contract, corpus, corpus_root, capture_data, capture_root
    )
    cohorts_required = contract["cohortConstraints"]["contentCohorts"]

    weights = {item["id"]: float(item["weight"]) for item in contract["components"]}
    if not math.isclose(sum(weights.values()), 1.0, rel_tol=0, abs_tol=1e-15):
        raise SystemExit("quality weights do not sum exactly to one")
    summaries: dict[str, Any] = {}
    for variant in VARIANTS:
        aggregate, by_cohort, error, quality = aggregate_ratios(
            metrics, clips_by_cohort, variant, weights
        )
        summaries[variant] = {
            "normalizedComponents": aggregate,
            "normalizedComponentsByCohort": by_cohort,
            "weightedError": error,
            "qualityIndex": quality,
        }

    bootstrap = contract["bootstrap"]
    rng = SplitMix64(int(bootstrap["seedUnsignedDecimal"]))
    replicates: list[float] = []
    for _ in range(int(bootstrap["replicateCount"])):
        sampled = {
            cohort: [clips[rng.index(len(clips))] for _ in clips]
            for cohort, clips in sorted(clips_by_cohort.items())
        }
        _, _, _, quality = aggregate_ratios(
            metrics, clips_by_cohort, "candidate_v4", weights, sampled
        )
        replicates.append(quality)
    ordered = sorted(replicates)
    lower_index = math.floor(0.025 * len(ordered))
    lower_bound = ordered[lower_index]
    upper_bound = ordered[len(ordered) - 1 - lower_index]
    candidate_summary = summaries["candidate_v4"]
    candidate_summary["pairedBootstrap95PercentCI"] = {
        "lower": lower_bound,
        "upper": upper_bound,
        "replicateCount": len(ordered),
        "lowerOrderStatisticIndex": lower_index,
    }

    luma_id = "luma_multiscale_structural_error"
    temporal_id = "motion_compensated_temporal_flicker_error"
    luma_limit = float(
        contract["cohortConstraints"]["lumaStructuralMaximumCandidateToBaselineRatio"]
    )
    temporal_limit = float(
        contract["cohortConstraints"]["temporalStructuralMaximumCandidateToBaselineRatio"]
    )
    per_cohort_luma = {
        cohort: candidate_summary["normalizedComponentsByCohort"][cohort][luma_id]
        for cohort in cohorts_required
    }
    temporal_cohorts = contract["cohortConstraints"]["temporalNonRegressionCohorts"]
    per_cohort_temporal = {
        cohort: candidate_summary["normalizedComponentsByCohort"][cohort][temporal_id]
        for cohort in temporal_cohorts
    }
    release_threshold = float(contract["aggregate"]["releaseThreshold"])
    gates = {
        "identityPass": True,
        "naturalCorpusEligibilityPass": bool(corpus.get("releaseEligible"))
            and corpus.get("corpusKind") == "locked_natural",
        "productionRuntimeLockPass": bool(capture_data.get("productionRuntimeLocked", False)),
        "requiredAblationsPresentPass": all(
            name in VARIANTS for name in contract["ablationRequirements"]
        ),
        "qualityPointEstimatePass": candidate_summary["qualityIndex"] >= release_threshold,
        "qualityLowerConfidenceBoundPass": lower_bound >= release_threshold,
        "allCohortLumaNonRegressionPass": all(value <= luma_limit for value in per_cohort_luma.values()),
        "temporalCohortNonRegressionPass": all(value <= temporal_limit for value in per_cohort_temporal.values()),
        "candidateBackendIdentityPass": capture_data.get("candidateBackendID")
            == contract["comparisonPopulation"]["candidateBackend"],
        "fullMirrorIdentityPass": bool(capture_data.get("fullMirrorIdentityPass", False)),
    }
    gates["releaseQualityGatePass"] = all(gates.values())

    timing_by_variant: dict[str, dict[str, float | int]] = {}
    for variant in VARIANTS:
        samples = [float(record["milliseconds"][variant]) for record in capture_data["cases"]]
        timing_by_variant[variant] = {
            "sampleCount": len(samples),
            "medianMilliseconds": statistics.median(samples),
            "p95Milliseconds": percentile(samples, 95),
            "totalMilliseconds": sum(samples),
        }
    timing_by_variant["candidate_v4"]["medianRatioVersusP05"] = (
        timing_by_variant["candidate_v4"]["medianMilliseconds"]
        / timing_by_variant["baseline_p05"]["medianMilliseconds"]
    )
    timing_by_variant["candidate_v4"]["p95RatioVersusP05"] = (
        timing_by_variant["candidate_v4"]["p95Milliseconds"]
        / timing_by_variant["baseline_p05"]["p95Milliseconds"]
    )

    tool_path = Path(__file__).resolve()
    capture_source = tool_path.with_name("QualityGateCaptureTests.swift")
    crop_identity = sha256_bytes(
        canonical_bytes([{item["id"]: item["crop"]} for item in contract["components"]])
    )
    metric_model_identity = sha256_bytes(
        b"mirmir-analytic-quality-model-v1\0"
        + canonical_bytes(contract["components"])
        + bytes.fromhex(sha256(tool_path))
    )
    output_identities = {
        variant: output_set_identity(capture_root, capture_data, variant)
        for variant in VARIANTS
    }
    report = {
        "schemaVersion": SCHEMA_REPORT,
        "contract": contract,
        "identities": {
            "contractSHA256": contract_hash,
            "metricToolSHA256": sha256(tool_path),
            "captureTestSourceSHA256": sha256(capture_source),
            "corpusManifestSHA256": corpus_hash,
            "corpusArtifactSetSHA256": computed_corpus_set,
            "runtimeManifestSHA256": capture_data["runtimeManifestSHA256"],
            "runtimeSourceRevision": capture_data["runtimeSourceRevision"],
            "sourceCommit": capture_data["sourceCommit"],
            "sourceTreeIdentitySHA256": capture_data["sourceTreeIdentitySHA256"],
            "cropRuleSHA256": crop_identity,
            "metricModelSHA256": metric_model_identity,
            "outputSetSHA256": output_identities,
        },
        "corpus": {
            "corpusID": corpus["corpusID"],
            "corpusKind": corpus["corpusKind"],
            "releaseEligible": corpus["releaseEligible"],
            "limitations": corpus["limitations"],
            "clipCount": corpus["clipCount"],
            "caseCount": corpus["caseCount"],
            "cohorts": corpus["cohorts"],
        },
        "runtime": {
            "candidateBackendID": capture_data["candidateBackendID"],
            "candidateImplementationVersion": capture_data["candidateImplementationVersion"],
            "baselineImplementationVersion": capture_data["baselineImplementationVersion"],
            "baselineIdentity": baseline_identity,
            "productionRuntimeLocked": capture_data["productionRuntimeLocked"],
            "fullMirrorIdentityPass": capture_data["fullMirrorIdentityPass"],
        },
        "quality": {
            "summaries": summaries,
            "perCohortLumaCandidateToBaselineRatio": per_cohort_luma,
            "temporalCandidateToBaselineRatio": per_cohort_temporal,
            "gates": gates,
        },
        "timingDiagnostic": {
            "scope": "engine calls on the declared quality corpus; no decode, encode, or end-to-end wall measurement",
            "warmupCount": int(capture_data.get("warmupCount", 0)),
            "variants": timing_by_variant,
            "releasePerformanceGateEligible": False,
        },
        "perClip": per_clip_report,
    }
    write_json(output.resolve(), report)
    print(output.resolve())
    return 0


def replay_sealed_evidence(
    report_path: Path,
    contract_path: Path,
    contract: dict[str, Any],
    identities: dict[str, Any],
) -> list[dict[str, Any]]:
    """Validate the recursive seal, then replay metrics from every raw plane."""

    evidence_root = report_path.parent.resolve()
    evidence_manifest = evidence_root / "artifact-manifest.json"
    if not evidence_manifest.is_file() or evidence_manifest.is_symlink():
        raise SystemExit("quality evidence seal is absent")
    evidence_document = json.loads(evidence_manifest.read_text())
    if evidence_document.get("schemaVersion") != "mirmir-ash-v4-quality-evidence-manifest-v1":
        raise SystemExit("unsupported evidence manifest")
    artifacts = evidence_document.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise SystemExit("quality evidence seal is empty")
    paths = [item.get("path") if isinstance(item, dict) else None for item in artifacts]
    if any(not isinstance(path, str) for path in paths) or paths != sorted(paths):
        raise SystemExit("quality evidence seal paths are invalid or unsorted")
    if len(paths) != len(set(paths)) or "artifact-manifest.json" in paths:
        raise SystemExit("quality evidence seal repeats or self-seals an artifact")
    validate_artifacts(evidence_root, artifacts)
    # M7 wraps this self-contained quality evidence directory in its own
    # release-suite seal.  The inner quality seal cannot include that outer
    # manifest without creating a hash cycle, so admit only this exact
    # integration envelope while continuing to reject every other unsealed
    # file (including similarly named files in subdirectories).
    release_envelope = evidence_root / "sealed-manifest.json"
    actual_files: set[str] = set()
    for path in evidence_root.rglob("*"):
        if path.is_symlink():
            raise SystemExit(f"quality evidence contains a symbolic link: {path}")
        if path.is_file() and path not in {evidence_manifest, release_envelope}:
            actual_files.add(path.relative_to(evidence_root).as_posix())
    if actual_files != set(paths):
        missing = sorted(set(paths) - actual_files)
        unsealed = sorted(actual_files - set(paths))
        raise SystemExit(
            f"quality evidence sealed file set mismatch; missing={missing}, unsealed={unsealed}"
        )

    corpus_manifest = evidence_root / "corpus-manifest.json"
    capture_manifest = evidence_root / "capture-manifest.json"
    required_sealed = {
        report_path.resolve(),
        corpus_manifest.resolve(),
        capture_manifest.resolve(),
        contract_path.resolve(),
    }
    sealed_paths = {
        checked_relative(evidence_root, relative).resolve() for relative in paths
    }
    if not required_sealed.issubset(sealed_paths):
        raise SystemExit("quality evidence seal omits a required identity artifact")

    if not corpus_manifest.is_file() or corpus_manifest.is_symlink():
        raise SystemExit("corpus manifest is absent from quality evidence")
    corpus = json.loads(corpus_manifest.read_text())
    if corpus.get("schemaVersion") != SCHEMA_CORPUS:
        raise SystemExit("unsupported sealed corpus manifest")
    if sha256(corpus_manifest) != identities["corpusManifestSHA256"]:
        raise SystemExit("corpus manifest identity mismatch")
    corpus_artifacts = corpus.get("artifacts")
    if not isinstance(corpus_artifacts, list) or not corpus_artifacts:
        raise SystemExit("corpus artifacts are absent")
    validate_artifacts(evidence_root, corpus_artifacts)
    computed_corpus_set = artifact_set_sha(
        (artifact["path"], artifact["sha256"]) for artifact in corpus_artifacts
    )
    if corpus.get("artifactSetSHA256") != computed_corpus_set:
        raise SystemExit("corpus artifact-set identity mismatch")
    if identities["corpusArtifactSetSHA256"] != computed_corpus_set:
        raise SystemExit("report corpus artifact-set identity mismatch")
    if corpus.get("contractSHA256") != identities["contractSHA256"]:
        raise SystemExit("corpus contract identity mismatch")

    if not capture_manifest.is_file() or capture_manifest.is_symlink():
        raise SystemExit("capture manifest is absent from quality evidence")
    capture = json.loads(capture_manifest.read_text())
    if capture.get("schemaVersion") != SCHEMA_CAPTURE:
        raise SystemExit("unsupported sealed capture manifest")
    expected_capture_identities = {
        "contractSHA256": identities["contractSHA256"],
        "corpusManifestSHA256": identities["corpusManifestSHA256"],
        "runtimeManifestSHA256": identities["runtimeManifestSHA256"],
        "runtimeSourceRevision": identities["runtimeSourceRevision"],
        "sourceCommit": identities["sourceCommit"],
        "sourceTreeIdentitySHA256": identities["sourceTreeIdentitySHA256"],
    }
    for key, value in expected_capture_identities.items():
        if capture.get(key) != value:
            raise SystemExit(f"capture manifest identity mismatch: {key}")
    baseline_identity = require_frozen_p05_identity(
        contract, capture.get("baselineIdentity")
    )
    if capture.get("baselineImplementationVersion") != baseline_identity[
        "implementationVersion"
    ]:
        raise SystemExit("sealed capture P05 implementation identity mismatch")

    capture_cases = capture.get("cases")
    if not isinstance(capture_cases, list) or not capture_cases:
        raise SystemExit("capture cases are absent")
    output_entries: dict[str, list[tuple[str, str]]] = {
        variant: [] for variant in VARIANTS
    }
    for case_index, case in enumerate(capture_cases):
        if not isinstance(case, dict):
            raise SystemExit(f"invalid capture case: {case_index}")
        outputs = case.get("outputs")
        if not isinstance(outputs, dict) or set(outputs) != set(VARIANTS):
            raise SystemExit(f"capture output variants differ: {case_index}")
        for variant, relative in outputs.items():
            output_path = checked_relative(evidence_root, relative)
            if not output_path.is_file() or output_path.is_symlink():
                raise SystemExit(f"missing capture output artifact: {relative}")
            output_entries[variant].append((relative, sha256(output_path)))
    computed_output_sets = {
        variant: artifact_set_sha(entries)
        for variant, entries in output_entries.items()
    }
    if identities["outputSetSHA256"] != computed_output_sets:
        raise SystemExit("capture output artifact-set identity mismatch")

    return replay_raw_components(
        contract, corpus, evidence_root, capture, evidence_root
    )[0]


def verify_report(report_path: Path, contract_path: Path | None = None) -> int:
    report = json.loads(report_path.read_text())
    if report.get("schemaVersion") != SCHEMA_REPORT:
        raise SystemExit("unsupported report")
    identities = report.get("identities", {})
    required = {
        "contractSHA256",
        "metricToolSHA256",
        "captureTestSourceSHA256",
        "corpusManifestSHA256",
        "corpusArtifactSetSHA256",
        "runtimeManifestSHA256",
        "runtimeSourceRevision",
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "cropRuleSHA256",
        "metricModelSHA256",
        "outputSetSHA256",
    }
    if set(identities) != required:
        raise SystemExit("report identity set is incomplete or unexpected")

    # Reject an eligibility promotion before any deeper validation so this
    # invariant remains independently testable with a minimal report fixture.
    quality = report["quality"]
    if quality["gates"]["releaseQualityGatePass"]:
        if not report["corpus"]["releaseEligible"] or not report["runtime"]["productionRuntimeLocked"]:
            raise SystemExit("ineligible evidence was promoted to a release pass")

    def require_hex(value: Any, lengths: int | tuple[int, ...], label: str) -> None:
        admitted_lengths = (lengths,) if isinstance(lengths, int) else lengths
        if (
            not isinstance(value, str)
            or len(value) not in admitted_lengths
            or any(character not in "0123456789abcdef" for character in value)
        ):
            raise SystemExit(f"invalid identity: {label}")

    for key, value in identities.items():
        if key == "outputSetSHA256":
            if not isinstance(value, dict) or set(value) != set(VARIANTS):
                raise SystemExit("invalid output-set identities")
            for variant, identity in value.items():
                require_hex(identity, 64, f"outputSetSHA256.{variant}")
        elif key == "runtimeSourceRevision":
            require_hex(value, (40, 64), key)
        elif key == "sourceCommit":
            require_hex(value, 40, key)
        else:
            require_hex(value, 64, key)

    tool_path = Path(__file__).resolve()
    contract_path = (
        contract_path.resolve()
        if contract_path is not None
        else report_path.parent.resolve() / "quality-gate-contract-v1.json"
    )
    capture_source = tool_path.with_name("QualityGateCaptureTests.swift")
    p05_capture_source = tool_path.with_name("P05QualityBaselineCaptureTests.swift")
    p05_source_manifest = tool_path.with_name("p05-baseline-source-manifest-v1.json")
    p05_identity_tool = tool_path.with_name("p05_baseline_v4.py")
    if not all(
        path.is_file() and not path.is_symlink()
        for path in (
            contract_path,
            capture_source,
            p05_capture_source,
            p05_source_manifest,
            p05_identity_tool,
        )
    ):
        raise SystemExit("quality verifier sources are incomplete")
    contract = json.loads(contract_path.read_text())
    if report.get("contract") != contract or identities["contractSHA256"] != sha256(contract_path):
        raise SystemExit("contract identity mismatch")
    if identities["metricToolSHA256"] != sha256(tool_path):
        raise SystemExit("metric tool identity mismatch")
    if identities["captureTestSourceSHA256"] != sha256(capture_source):
        raise SystemExit("capture source identity mismatch")
    crop_identity = sha256_bytes(
        canonical_bytes([{item["id"]: item["crop"]} for item in contract["components"]])
    )
    metric_model_identity = sha256_bytes(
        b"mirmir-analytic-quality-model-v1\0"
        + canonical_bytes(contract["components"])
        + bytes.fromhex(identities["metricToolSHA256"])
    )
    if identities["cropRuleSHA256"] != crop_identity:
        raise SystemExit("crop-rule identity mismatch")
    if identities["metricModelSHA256"] != metric_model_identity:
        raise SystemExit("metric-model identity mismatch")

    expected_p05 = p05.frozen_identity(contract)
    if sha256(p05_capture_source) != expected_p05["captureSourceSHA256"]:
        raise SystemExit("frozen P05 capture-source identity mismatch")
    if sha256(p05_source_manifest) != expected_p05["sourceManifestSHA256"]:
        raise SystemExit("frozen P05 source-manifest identity mismatch")
    runtime = report.get("runtime")
    if not isinstance(runtime, dict):
        raise SystemExit("quality runtime identity is absent")
    observed_p05 = require_frozen_p05_identity(
        contract, runtime.get("baselineIdentity")
    )
    if runtime.get("baselineImplementationVersion") != observed_p05[
        "implementationVersion"
    ]:
        raise SystemExit("report P05 implementation identity mismatch")

    # Replay every component from the recursively sealed reference, P05,
    # candidate, and ablation planes before trusting perClip or aggregates.
    replayed_per_clip = replay_sealed_evidence(
        report_path.resolve(), contract_path, contract, identities
    )
    if report.get("perClip") != replayed_per_clip:
        raise SystemExit("perClip metrics differ from sealed raw-plane replay")

    def require_equal(actual: Any, expected: Any, label: str) -> None:
        if isinstance(expected, dict):
            if not isinstance(actual, dict) or set(actual) != set(expected):
                raise SystemExit(f"report structure mismatch: {label}")
            for key in expected:
                require_equal(actual[key], expected[key], f"{label}.{key}")
        elif isinstance(expected, list):
            if not isinstance(actual, list) or len(actual) != len(expected):
                raise SystemExit(f"report structure mismatch: {label}")
            for index, item in enumerate(expected):
                require_equal(actual[index], item, f"{label}[{index}]")
        elif isinstance(expected, bool):
            if actual is not expected:
                raise SystemExit(f"report value mismatch: {label}")
        elif isinstance(expected, (int, float)):
            try:
                number = float(actual)
            except (TypeError, ValueError) as error:
                raise SystemExit(f"non-numeric report value: {label}") from error
            if not math.isfinite(number) or not math.isclose(
                number, float(expected), rel_tol=1e-13, abs_tol=1e-13
            ):
                raise SystemExit(f"report value mismatch: {label}")
        elif actual != expected:
            raise SystemExit(f"report value mismatch: {label}")

    cohorts = contract["cohortConstraints"]["contentCohorts"]
    weights = {item["id"]: float(item["weight"]) for item in contract["components"]}
    if not math.isclose(sum(weights.values()), 1.0, rel_tol=0, abs_tol=1e-15):
        raise SystemExit("quality weights do not sum exactly to one")
    per_clip = report.get("perClip")
    if not isinstance(per_clip, list):
        raise SystemExit("per-clip evidence is absent")
    metrics: dict[str, dict[str, dict[str, float]]] = {}
    clips_by_cohort: dict[str, list[str]] = {cohort: [] for cohort in cohorts}
    minimum_frames = int(contract["cohortConstraints"]["minimumFramesPerClip"])
    admitted_formats = {"420v", "420f"}
    for item in per_clip:
        clip_id = item.get("clipID")
        cohort = item.get("cohort")
        if not isinstance(clip_id, str) or clip_id in metrics:
            raise SystemExit("duplicate or invalid clip identity")
        if cohort not in clips_by_cohort:
            raise SystemExit(f"unexpected report cohort: {cohort}")
        if item.get("pixelFormat") not in admitted_formats:
            raise SystemExit(f"unexpected report pixel format: {clip_id}")
        if int(item.get("frameCount", 0)) < minimum_frames:
            raise SystemExit(f"short report clip: {clip_id}")
        components = item.get("components")
        if not isinstance(components, dict) or set(components) != set(VARIANTS):
            raise SystemExit(f"variant set mismatch: {clip_id}")
        for variant, values in components.items():
            if not isinstance(values, dict) or set(values) != set(weights):
                raise SystemExit(f"component set mismatch: {clip_id} {variant}")
            for component, value in values.items():
                if not isinstance(value, (int, float)) or not math.isfinite(float(value)) or value < 0:
                    raise SystemExit(f"invalid component metric: {clip_id} {variant} {component}")
        metrics[clip_id] = components
        clips_by_cohort[cohort].append(clip_id)
    minimum_clips = int(contract["cohortConstraints"]["minimumClipsPerCohort"])
    for cohort, clips in clips_by_cohort.items():
        clips.sort()
        if len(clips) < minimum_clips:
            raise SystemExit(f"report cohort has too few clips: {cohort}")
    if report["corpus"].get("clipCount") != len(per_clip):
        raise SystemExit("report clip count mismatch")
    if report["corpus"].get("caseCount") != sum(int(item["frameCount"]) for item in per_clip):
        raise SystemExit("report case count mismatch")
    if set(report["corpus"].get("cohorts", [])) != set(cohorts):
        raise SystemExit("report cohort set mismatch")

    summaries = quality.get("summaries")
    if not isinstance(summaries, dict) or set(summaries) != set(VARIANTS):
        raise SystemExit("quality summary variant set mismatch")
    recomputed_summaries: dict[str, dict[str, Any]] = {}
    for variant in VARIANTS:
        aggregate, by_cohort, error, quality_index = aggregate_ratios(
            metrics, clips_by_cohort, variant, weights
        )
        recomputed = {
            "normalizedComponents": aggregate,
            "normalizedComponentsByCohort": by_cohort,
            "weightedError": error,
            "qualityIndex": quality_index,
        }
        recomputed_summaries[variant] = recomputed
        for key, value in recomputed.items():
            require_equal(summaries[variant].get(key), value, f"summaries.{variant}.{key}")

    bootstrap = contract["bootstrap"]
    rng = SplitMix64(int(bootstrap["seedUnsignedDecimal"]))
    replicates: list[float] = []
    for _ in range(int(bootstrap["replicateCount"])):
        sampled = {
            cohort: [clips[rng.index(len(clips))] for _ in clips]
            for cohort, clips in sorted(clips_by_cohort.items())
        }
        _, _, _, quality_index = aggregate_ratios(
            metrics, clips_by_cohort, "candidate_v4", weights, sampled
        )
        replicates.append(quality_index)
    ordered = sorted(replicates)
    lower_index = math.floor(0.025 * len(ordered))
    expected_interval = {
        "lower": ordered[lower_index],
        "upper": ordered[len(ordered) - 1 - lower_index],
        "replicateCount": len(ordered),
        "lowerOrderStatisticIndex": lower_index,
    }
    require_equal(
        summaries["candidate_v4"].get("pairedBootstrap95PercentCI"),
        expected_interval,
        "summaries.candidate_v4.pairedBootstrap95PercentCI",
    )

    candidate = recomputed_summaries["candidate_v4"]
    luma_id = "luma_multiscale_structural_error"
    temporal_id = "motion_compensated_temporal_flicker_error"
    per_cohort_luma = {
        cohort: candidate["normalizedComponentsByCohort"][cohort][luma_id]
        for cohort in cohorts
    }
    temporal_cohorts = contract["cohortConstraints"]["temporalNonRegressionCohorts"]
    per_cohort_temporal = {
        cohort: candidate["normalizedComponentsByCohort"][cohort][temporal_id]
        for cohort in temporal_cohorts
    }
    require_equal(
        quality.get("perCohortLumaCandidateToBaselineRatio"),
        per_cohort_luma,
        "perCohortLumaCandidateToBaselineRatio",
    )
    require_equal(
        quality.get("temporalCandidateToBaselineRatio"),
        per_cohort_temporal,
        "temporalCandidateToBaselineRatio",
    )
    release_threshold = float(contract["aggregate"]["releaseThreshold"])
    expected_gates = {
        "identityPass": True,
        "naturalCorpusEligibilityPass": bool(report["corpus"].get("releaseEligible"))
            and report["corpus"].get("corpusKind") == "locked_natural",
        "productionRuntimeLockPass": bool(report["runtime"].get("productionRuntimeLocked")),
        "requiredAblationsPresentPass": all(
            name in VARIANTS for name in contract["ablationRequirements"]
        ),
        "qualityPointEstimatePass": candidate["qualityIndex"] >= release_threshold,
        "qualityLowerConfidenceBoundPass": expected_interval["lower"] >= release_threshold,
        "allCohortLumaNonRegressionPass": all(
            value
            <= float(contract["cohortConstraints"]["lumaStructuralMaximumCandidateToBaselineRatio"])
            for value in per_cohort_luma.values()
        ),
        "temporalCohortNonRegressionPass": all(
            value
            <= float(contract["cohortConstraints"]["temporalStructuralMaximumCandidateToBaselineRatio"])
            for value in per_cohort_temporal.values()
        ),
        "candidateBackendIdentityPass": report["runtime"].get("candidateBackendID")
            == contract["comparisonPopulation"]["candidateBackend"],
        "fullMirrorIdentityPass": bool(report["runtime"].get("fullMirrorIdentityPass")),
    }
    expected_gates["releaseQualityGatePass"] = all(expected_gates.values())
    require_equal(quality.get("gates"), expected_gates, "quality.gates")

    if report.get("timingDiagnostic", {}).get("releasePerformanceGateEligible") is not False:
        raise SystemExit("diagnostic timing was promoted to release evidence")

    print(report_path.resolve())
    return 0


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate")
    generate.add_argument("--contract", required=True, type=Path)
    generate.add_argument("--output", required=True, type=Path)
    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument("--contract", required=True, type=Path)
    evaluate_parser.add_argument("--corpus", required=True, type=Path)
    evaluate_parser.add_argument("--capture", required=True, type=Path)
    evaluate_parser.add_argument("--output", required=True, type=Path)
    merge = subparsers.add_parser("merge")
    merge.add_argument("--contract", required=True, type=Path)
    merge.add_argument("--corpus", required=True, type=Path)
    merge.add_argument("--p05-capture", required=True, type=Path)
    merge.add_argument("--candidate-capture", required=True, type=Path)
    merge.add_argument("--output", required=True, type=Path)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--report", required=True, type=Path)
    verify.add_argument("--contract", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "generate":
        return generate_corpus(arguments.contract, arguments.output)
    if arguments.command == "evaluate":
        return evaluate(
            arguments.contract, arguments.corpus, arguments.capture, arguments.output
        )
    if arguments.command == "merge":
        return merge_captures(
            arguments.contract,
            arguments.corpus,
            arguments.p05_capture,
            arguments.candidate_capture,
            arguments.output,
        )
    if arguments.command == "verify":
        return verify_report(arguments.report, arguments.contract)
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"quality gate failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
