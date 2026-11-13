#!/usr/bin/env python3
"""Build the locked native-source quality corpus for deterministic engine v4.

The source selection is separately versioned and hash-bound.  This tool never
labels generated imagery as natural media: every reference frame is decoded
from a verified, redistributable source asset, converted to BT.709 NV12 by the
integer procedure below, and downsampled exactly once to form the P05/v4 input.
"""

from __future__ import annotations

import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from typing import Any, Iterable

import numpy as np
import chroma_geometry_v4 as chroma_geometry


SCHEMA_CONTRACT = "mirmir-ash-v4-quality-gate-contract-v1"
SCHEMA_SELECTION = "mirmir-ash-v4-natural-source-selection-v1"
SCHEMA_CORPUS = "mirmir-ash-v4-quality-corpus-v1"
ALLOWED_LICENSES = {"public-domain", "CC-BY-3.0"}


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_set_sha(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for path, identity in sorted(entries):
        digest.update(path.encode())
        digest.update(b"\0")
        digest.update(identity.encode())
        digest.update(b"\n")
    return digest.hexdigest()


def require_safe_filename(value: str) -> str:
    if not value or Path(value).name != value or value in {".", ".."}:
        raise ValueError(f"unsafe source filename: {value!r}")
    return value


def validate_source(path: Path, record: dict[str, Any]) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"source is absent or not a regular file: {record['id']}")
    if path.stat().st_size != int(record["byteCount"]):
        raise ValueError(f"source byte count mismatch: {record['id']}")
    if sha256(path) != record["sha256"]:
        raise ValueError(f"source SHA-256 mismatch: {record['id']}")


def download_source(cache: Path, record: dict[str, Any]) -> Path:
    filename = require_safe_filename(record["file"])
    destination = cache / filename
    if destination.exists():
        validate_source(destination, record)
        return destination
    parsed = urllib.parse.urlparse(record["sourceURL"])
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"source URL is not HTTPS: {record['id']}")
    temporary = cache / f".{filename}.download"
    if temporary.exists():
        raise ValueError(f"stale source download exists: {temporary}")
    request = urllib.request.Request(
        record["sourceURL"],
        headers={"User-Agent": "Mirmir-P06-corpus-builder/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("xb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        validate_source(temporary, record)
        os.replace(temporary, destination)
    except BaseException:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        raise
    return destination


def ffmpeg_identity(executable: str) -> dict[str, str]:
    located = shutil.which(executable)
    if located is None:
        raise ValueError(f"ffmpeg executable not found: {executable}")
    resolved = Path(located).resolve()
    result = subprocess.run(
        [str(resolved), "-version"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    first_line = result.stdout.splitlines()[0]
    return {
        "executable": resolved.name,
        "version": first_line,
        "executableSHA256": sha256(resolved),
        "decodeProcedureID": "ffmpeg-accurate-input-seek-rgb24-center-crop-lanczos-v1",
    }


def decode_segment(
    executable: str,
    source: Path,
    source_rate: Fraction,
    start_frame: int,
    step: int,
    count: int,
    width: int,
    height: int,
) -> list[np.ndarray]:
    if start_frame < 0 or step < 1 or count < 1:
        raise ValueError("invalid segment frame selection")
    start = Fraction(start_frame, 1) / source_rate
    timestamp = f"{float(start):.9f}"
    select = f"select=not(mod(n\\,{step}))"
    filters = (
        f"{select},"
        f"scale={width}:{height}:force_original_aspect_ratio=increase:flags=lanczos,"
        f"crop={width}:{height},setsar=1"
    )
    command = [
        executable,
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        timestamp,
        "-i",
        str(source),
        "-map",
        "0:v:0",
        "-vf",
        filters,
        "-frames:v",
        str(count),
        "-pix_fmt",
        "rgb24",
        "-f",
        "rawvideo",
        "pipe:1",
    ]
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE)
    frame_size = width * height * 3
    if len(result.stdout) != frame_size * count:
        raise ValueError(
            f"decoder returned {len(result.stdout)} bytes, expected {frame_size * count}"
        )
    values = np.frombuffer(result.stdout, dtype=np.uint8)
    return [
        values[index * frame_size : (index + 1) * frame_size]
        .reshape(height, width, 3)
        .copy()
        for index in range(count)
    ]


def rounded_divide_signed(numerator: np.ndarray, denominator: int) -> np.ndarray:
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    values = numerator.astype(np.int64, copy=False)
    negative = values < 0
    magnitude = np.abs(values)
    quotient = magnitude // denominator
    remainder = magnitude % denominator
    complement = denominator - remainder
    quotient += ((remainder > complement) | ((remainder == complement) & (quotient & 1))).astype(
        np.int64
    )
    return np.where(negative, -quotient, quotient)


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
    quotient += ((remainder > 2) | ((remainder == 2) & (quotient & 1))).astype(np.uint16)
    return quotient.astype(np.uint8)


def rgb_to_nv12(rgb: np.ndarray, pixel_format: str) -> tuple[np.ndarray, np.ndarray]:
    values = rgb.astype(np.int64)
    red, green, blue = values[:, :, 0], values[:, :, 1], values[:, :, 2]
    luma_numerator = 2126 * red + 7152 * green + 722 * blue
    cb_numerator = -1146 * red - 3854 * green + 5000 * blue
    cr_numerator = 5000 * red - 4542 * green - 458 * blue
    if pixel_format == "420f":
        luma = rounded_divide_signed(luma_numerator, 10_000)
        cb = 128 + rounded_divide_signed(cb_numerator, 10_000)
        cr = 128 + rounded_divide_signed(cr_numerator, 10_000)
        luma_bounds, chroma_bounds = (0, 255), (0, 255)
    elif pixel_format == "420v":
        luma = 16 + rounded_divide_signed(luma_numerator * 219, 10_000 * 255)
        cb = 128 + rounded_divide_signed(cb_numerator * 224, 10_000 * 255)
        cr = 128 + rounded_divide_signed(cr_numerator * 224, 10_000 * 255)
        luma_bounds, chroma_bounds = (16, 235), (16, 240)
    else:
        raise ValueError(f"unsupported pixel format: {pixel_format}")
    luma = np.clip(luma, *luma_bounds).astype(np.uint8)
    cb = box_downsample_ties_even(np.clip(cb, *chroma_bounds).astype(np.uint8))
    cr = box_downsample_ties_even(np.clip(cr, *chroma_bounds).astype(np.uint8))
    chroma = np.stack([cb, cr], axis=2)
    return luma, chroma


def nv12_bytes(luma: np.ndarray, chroma: np.ndarray) -> bytes:
    return luma.tobytes(order="C") + chroma.tobytes(order="C")


def source_asset_set_sha(assets: list[dict[str, Any]]) -> str:
    return artifact_set_sha((asset["id"], asset["sha256"]) for asset in assets)


def source_license_set_sha(assets: list[dict[str, Any]]) -> str:
    licenses = [
        {
            "id": asset["id"],
            "creator": asset["creator"],
            "licenseID": asset["licenseID"],
            "licenseURL": asset["licenseURL"],
            "sourceURL": asset["sourceURL"],
        }
        for asset in sorted(assets, key=lambda item: item["id"])
    ]
    return sha256_bytes(canonical_bytes(licenses))


def build_corpus(
    contract_path: Path,
    selection_path: Path,
    source_cache: Path,
    output: Path,
    ffmpeg: str,
    download: bool,
) -> Path:
    contract_path = contract_path.resolve()
    selection_path = selection_path.resolve()
    source_cache = source_cache.resolve()
    output = output.resolve()
    contract = json.loads(contract_path.read_text())
    selection = json.loads(selection_path.read_text())
    chroma_geometry.quality_contract_phase2(contract)
    if selection.get("schemaVersion") != SCHEMA_SELECTION:
        raise ValueError("unsupported natural source selection")
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"refusing to overwrite nonempty corpus directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    source_cache.mkdir(parents=True, exist_ok=True)

    construction = contract["corpusConstruction"]
    width = int(construction["referenceWidth"])
    height = int(construction["referenceHeight"])
    source_width = int(construction["sourceWidth"])
    source_height = int(construction["sourceHeight"])
    if width != source_width * 2 or height != source_height * 2:
        raise ValueError("release corpus requires the declared exact 2x route")
    assets = selection["assets"]
    if len({asset["id"] for asset in assets}) != len(assets):
        raise ValueError("duplicate source asset identity")
    asset_by_id = {asset["id"]: asset for asset in assets}
    paths: dict[str, Path] = {}
    for asset in assets:
        if asset["licenseID"] not in ALLOWED_LICENSES:
            raise ValueError(f"unapproved source license: {asset['id']}")
        if int(asset["width"]) < int(construction["minimumDecodedSourceWidth"]):
            raise ValueError(f"source width below contract: {asset['id']}")
        if int(asset["height"]) < int(construction["minimumDecodedSourceHeight"]):
            raise ValueError(f"source height below contract: {asset['id']}")
        path = source_cache / require_safe_filename(asset["file"])
        if download:
            path = download_source(source_cache, asset)
        validate_source(path, asset)
        paths[asset["id"]] = path

    required_cohorts = contract["cohortConstraints"]["contentCohorts"]
    clips = selection["clips"]
    clips_by_cohort = {cohort: [] for cohort in required_cohorts}
    if len({clip["id"] for clip in clips}) != len(clips):
        raise ValueError("duplicate clip identity")
    for clip in clips:
        if clip["cohort"] not in clips_by_cohort:
            raise ValueError(f"unexpected cohort: {clip['cohort']}")
        clips_by_cohort[clip["cohort"]].append(clip)
    required_clip_count = int(contract["cohortConstraints"]["minimumClipsPerCohort"])
    if any(len(value) != required_clip_count for value in clips_by_cohort.values()):
        raise ValueError("source selection must contain exactly four clips per cohort")

    located_ffmpeg = shutil.which(ffmpeg)
    if located_ffmpeg is None:
        raise ValueError(f"ffmpeg executable not found: {ffmpeg}")
    resolved_ffmpeg = str(Path(located_ffmpeg).resolve())
    decoder = ffmpeg_identity(resolved_ffmpeg)
    if decoder != selection.get("decoder"):
        raise ValueError("decoder toolchain identity mismatch")
    cases: list[dict[str, Any]] = []
    artifacts: list[dict[str, Any]] = []
    decoded_source_ids_by_cohort: dict[str, set[str]] = {
        cohort: set() for cohort in required_cohorts
    }
    artifacts_root = output / "artifacts"
    artifacts_root.mkdir()
    required_frames = int(contract["cohortConstraints"]["minimumFramesPerClip"])
    for clip in sorted(clips, key=lambda item: item["id"]):
        frames: list[tuple[str, int, np.ndarray]] = []
        for segment in clip["segments"]:
            asset_id = segment["assetID"]
            asset = asset_by_id.get(asset_id)
            if asset is None:
                raise ValueError(f"unknown source asset: {asset_id}")
            count = int(segment["count"])
            start = int(segment["startFrame"])
            step = int(segment["step"])
            rate = Fraction(
                int(asset["frameRateNumerator"]),
                int(asset["frameRateDenominator"]),
            )
            decoded = decode_segment(
                resolved_ffmpeg,
                paths[asset_id],
                rate,
                start,
                step,
                count,
                width,
                height,
            )
            frames.extend(
                (asset_id, start + index * step, frame)
                for index, frame in enumerate(decoded)
            )
            decoded_source_ids_by_cohort[clip["cohort"]].add(asset_id)
        if len(frames) != required_frames:
            raise ValueError(f"clip does not contain exactly six frames: {clip['id']}")
        for frame_index, (asset_id, source_frame_index, rgb) in enumerate(frames):
            luma, chroma = rgb_to_nv12(rgb, clip["pixelFormat"])
            source_luma = box_downsample_ties_even(luma)
            source_chroma = np.stack(
                [box_downsample_ties_even(chroma[:, :, channel]) for channel in range(2)],
                axis=2,
            )
            case_id = f"{clip['id']}-f{frame_index:02d}"
            source_relative = f"artifacts/{case_id}-source.nv12"
            reference_relative = f"artifacts/{case_id}-reference.nv12"
            source_data = nv12_bytes(source_luma, source_chroma)
            reference_data = nv12_bytes(luma, chroma)
            source_path = output / source_relative
            reference_path = output / reference_relative
            source_path.write_bytes(source_data)
            reference_path.write_bytes(reference_data)
            source_hash = sha256_bytes(source_data)
            reference_hash = sha256_bytes(reference_data)
            artifacts.extend(
                [
                    {"path": source_relative, "byteCount": len(source_data), "sha256": source_hash},
                    {
                        "path": reference_relative,
                        "byteCount": len(reference_data),
                        "sha256": reference_hash,
                    },
                ]
            )
            cases.append(
                {
                    "id": case_id,
                    "clipID": clip["id"],
                    "cohort": clip["cohort"],
                    "frameIndex": frame_index,
                    "pixelFormat": clip["pixelFormat"],
                    "sourceWidth": source_width,
                    "sourceHeight": source_height,
                    "targetWidth": width,
                    "targetHeight": height,
                    "sourceFile": source_relative,
                    "sourceByteCount": len(source_data),
                    "sourceSHA256": source_hash,
                    "referenceFile": reference_relative,
                    "referenceByteCount": len(reference_data),
                    "referenceSHA256": reference_hash,
                    "nativeAssetID": asset_id,
                    "nativeAssetFrameIndex": source_frame_index,
                }
            )

    # Camera-native cohorts must each contain four independent source assets.
    for cohort in ("natural_detail", "faces"):
        if len(decoded_source_ids_by_cohort[cohort]) < 4:
            raise ValueError(f"cohort lacks four independent native sources: {cohort}")
    artifact_identity = artifact_set_sha((item["path"], item["sha256"]) for item in artifacts)
    manifest = {
        "schemaVersion": SCHEMA_CORPUS,
        "contractSHA256": sha256(contract_path),
        "corpusID": "ash-v4-seven-cohort-locked-natural-v1",
        "corpusKind": "locked_natural",
        "releaseEligible": True,
        "limitations": [
            "The comparative gate is progressive 8-bit SDR by design; newly supported HDR, alpha, and interlaced formats have separate exact conformance gates.",
            "Animation and low-light cohorts include CC-BY Sintel material; camera-native natural-detail and face cohorts use four independent public-domain source assets each."
        ],
        "construction": construction,
        "decoder": decoder,
        "sourceSelectionSHA256": sha256(selection_path),
        "sourceAssetSetSHA256": source_asset_set_sha(assets),
        "sourceLicenseSetSHA256": source_license_set_sha(assets),
        "sources": sorted(assets, key=lambda item: item["id"]),
        "cohorts": required_cohorts,
        "sourceAssetIDsByCohort": {
            cohort: sorted(ids) for cohort, ids in decoded_source_ids_by_cohort.items()
        },
        "caseCount": len(cases),
        "clipCount": len(clips),
        "artifactSetSHA256": artifact_identity,
        "artifacts": sorted(artifacts, key=lambda item: item["path"]),
        "cases": sorted(cases, key=lambda item: item["id"]),
    }
    manifest_path = output / "corpus-manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--selection", required=True, type=Path)
    parser.add_argument("--source-cache", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--download", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    manifest = build_corpus(
        arguments.contract,
        arguments.selection,
        arguments.source_cache,
        arguments.output,
        arguments.ffmpeg,
        arguments.download,
    )
    print(manifest)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"natural corpus build failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
