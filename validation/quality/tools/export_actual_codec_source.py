#!/usr/bin/env python3
"""Export the locked degradation output as active-row video-range NV12 bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Dict, List, Tuple

import numpy as np


QUALITY_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = QUALITY_ROOT / "src"
if str(SOURCE_ROOT) not in sys.path:
    sys.path.insert(0, str(SOURCE_ROOT))

from mirmir_quality.degradation import apply_degradation  # noqa: E402
from mirmir_quality.fixtures import synthetic_planar_frame  # noqa: E402
from mirmir_quality.json_tools import manifest_sha256, read_json, write_json  # noqa: E402


FIXTURE_ID = "actual-h264-software-nv12-v1"
PROFILE_ID = "hq-binomial7-decimate-2x-v1"
SOURCE_DIMENSIONS = (180, 320)
FRAME_COUNT = 3
TIMESCALE = 600
FRAME_DURATION = 20


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _video_range_codes(frame) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    y = np.rint(np.clip(frame.y, 0.0, 1.0) * 219.0 + 16.0).astype(np.uint8)
    cb = np.rint((np.clip(frame.cb, -0.5, 0.5) + 0.5) * 224.0 + 16.0).astype(np.uint8)
    cr = np.rint((np.clip(frame.cr, -0.5, 0.5) + 0.5) * 224.0 + 16.0).astype(np.uint8)
    uv = np.empty((cb.shape[0], cb.shape[1] * 2), dtype=np.uint8)
    uv[:, 0::2] = cb
    uv[:, 1::2] = cr
    return y, cb, cr, uv


def build_fixture() -> Tuple[bytes, Dict[str, object]]:
    policy_path = QUALITY_ROOT / "policies" / "degradation-policy.json"
    policy = read_json(policy_path)
    if policy["policy_sha256"] != manifest_sha256(policy, "policy_sha256"):
        raise ValueError("degradation policy hash mismatch")
    source_policy_sha256 = policy.get(
        "preintegration_policy_sha256",
        policy["policy_sha256"],
    )
    if "preintegration_policy_sha256" in policy:
        precursor = dict(policy)
        precursor.pop("preintegration_policy_sha256")
        precursor.pop("actual_codec_fixture")
        precursor.pop("common_writer_profiles")
        precursor["status"] = "development_seed"
        if manifest_sha256(precursor, "policy_sha256") != source_policy_sha256:
            raise ValueError("actual-codec precursor policy hash mismatch")
    profile = next(item for item in policy["profiles"] if item["id"] == PROFILE_ID)

    payload = bytearray()
    frame_records: List[Dict[str, object]] = []
    for index in range(FRAME_COUNT):
        native = synthetic_planar_frame(index, size=SOURCE_DIMENSIONS)
        low_resolution = apply_degradation(native, profile)
        y, cb, cr, uv = _video_range_codes(low_resolution)
        frame_payload = y.tobytes(order="C") + uv.tobytes(order="C")
        payload.extend(frame_payload)
        frame_records.append(
            {
                "index": index,
                "presentation_time": {
                    "value": index * FRAME_DURATION,
                    "timescale": TIMESCALE,
                },
                "duration": {"value": FRAME_DURATION, "timescale": TIMESCALE},
                "active_row_sha256": {
                    "Y": _sha256(y.tobytes(order="C")),
                    "Cb": _sha256(cb.tobytes(order="C")),
                    "Cr": _sha256(cr.tobytes(order="C")),
                },
                "frame_nv12_sha256": _sha256(frame_payload),
            }
        )

    encoded_width = int(frame_records and y.shape[1])
    encoded_height = int(frame_records and y.shape[0])
    metadata: Dict[str, object] = {
        "schema_version": "1.0.0",
        "fixture_id": FIXTURE_ID,
        "source": {
            "generator": "synthetic_planar_frame",
            "frame_indices": list(range(FRAME_COUNT)),
            "native_dimensions": {
                "width": SOURCE_DIMENSIONS[1],
                "height": SOURCE_DIMENSIONS[0],
            },
            "degradation_profile_id": PROFILE_ID,
            "degradation_policy_sha256": source_policy_sha256,
        },
        "pixel_layout": {
            "pixel_format": "420v",
            "range": "video",
            "color_primaries": "ITU_R_709_2",
            "transfer_function": "ITU_R_709_2",
            "ycbcr_matrix": "ITU_R_709_2",
            "chroma_location_top_field": "Left",
            "chroma_location_bottom_field": "Left",
            "width": encoded_width,
            "height": encoded_height,
            "plane_order": ["Y", "interleaved_CbCr"],
            "row_padding": "absent",
            "active_row_hash_contract": "SHA-256 over raster-order active bytes with no row padding",
            "luma_code_range": [16, 235],
            "chroma_code_range": [16, 240],
            "rounding": "binary64 multiply/add then round to nearest, ties to even",
        },
        "timing": {
            "frame_rate_numerator": 30,
            "frame_rate_denominator": 1,
            "timescale": TIMESCALE,
            "frame_duration_value": FRAME_DURATION,
        },
        "frame_count": FRAME_COUNT,
        "frames": frame_records,
        "payload_size_bytes": len(payload),
        "payload_sha256": _sha256(bytes(payload)),
    }
    return bytes(payload), metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    if not args.replace and (args.output.exists() or args.metadata.exists()):
        raise FileExistsError("refusing to overwrite an existing fixture; pass --replace explicitly")

    payload, metadata = build_fixture()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.metadata.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    write_json(args.metadata, metadata)
    print(json.dumps({"payload_sha256": metadata["payload_sha256"], "status": "pass"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
