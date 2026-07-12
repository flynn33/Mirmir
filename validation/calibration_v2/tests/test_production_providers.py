from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import pytest

from validation.calibration_v2.production_evaluator import (
    ProductionEvaluatorError,
    _validate_writer_round_trip,
)
from validation.calibration_v2.production_providers import (
    NativeProductionWriterCapability,
    _normalize_decoded_video_range_nv12,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateContext,
    _planar_to_video_range_nv12,
)


def test_decoded_writer_payload_is_clipped_to_nominal_video_range_with_counts() -> None:
    payload = bytes(
        (
            0,
            15,
            16,
            235,
            236,
            255,
            100,
            200,
            0,
            0,
            255,
            255,
        )
    )
    normalized, evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=4,
        height=2,
    )
    second_normalized, second_evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=4,
        height=2,
    )

    assert normalized == bytes(
        (16, 16, 16, 235, 235, 235, 100, 200, 16, 16, 240, 240)
    )
    assert (second_normalized, second_evidence) == (normalized, evidence)
    assert evidence == {
        "method": "nominal_video_range_clip_v1",
        "nominal_y_code_range": [16, 235],
        "nominal_chroma_code_range": [16, 240],
        "raw_code_ranges": {
            "y": [0, 255],
            "cb": [0, 255],
            "cr": [0, 255],
        },
        "normalized_code_ranges": {
            "y": [16, 235],
            "cb": [16, 240],
            "cr": [16, 240],
        },
        "clipped_sample_counts": {
            "y_below_16": 2,
            "y_above_235": 2,
            "cb_below_16": 1,
            "cb_above_240": 1,
            "cr_below_16": 1,
            "cr_above_240": 1,
        },
        "total_clipped_sample_count": 8,
    }


def test_decoded_writer_payload_preserves_already_legal_bytes() -> None:
    payload = bytes((16, 17, 234, 235, 16, 240))
    normalized, evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=2,
        height=2,
    )

    assert normalized == payload
    assert evidence["total_clipped_sample_count"] == 0


def test_decoded_writer_normalization_preserves_chroma_interleave_positions() -> None:
    payload = bytes((16, 17, 18, 19, 20, 21, 22, 23, 0, 250, 245, 10))
    normalized, evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=4,
        height=2,
    )

    assert normalized[:8] == payload[:8]
    assert normalized[8:][0::2] == bytes((16, 240))
    assert normalized[8:][1::2] == bytes((240, 16))
    assert evidence["clipped_sample_counts"] == {
        "y_below_16": 0,
        "y_above_235": 0,
        "cb_below_16": 1,
        "cb_above_240": 1,
        "cr_below_16": 1,
        "cr_above_240": 1,
    }


@pytest.mark.parametrize(
    ("payload", "width", "height"),
    (
        (bytes(6), 3, 2),
        (bytes(6), 2, 0),
        (bytes(5), 2, 2),
    ),
)
def test_decoded_writer_normalization_rejects_invalid_geometry(
    payload: bytes,
    width: int,
    height: int,
) -> None:
    with pytest.raises(ProductionEvaluatorError):
        _normalize_decoded_video_range_nv12(
            payload,
            width=width,
            height=height,
        )


def test_writer_normalization_evidence_propagates_to_candidate_boundary(
    tmp_path: Path,
) -> None:
    writer = object.__new__(NativeProductionWriterCapability)
    writer._root = tmp_path
    writer._runs = tmp_path / "runs"
    writer._evidence = tmp_path / "evidence"
    writer._runs.mkdir()
    writer._evidence.mkdir()
    writer._settings = {
        "writer_id": "mirmir-product-hevc-avassetwriter-v1",
        "isolation": "one_frame_per_container",
        "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
        "decoded_pixel_normalization": {
            "scope": (
                "reopened isolated production HEVC writer 420v bytes before "
                "PlanarFrame conversion and container-decoded metrics only"
            ),
            "method": "nominal_video_range_clip_v1",
            "nominal_y_code_range": [16, 235],
            "nominal_chroma_code_range": [16, 240],
            "evidence": (
                "bind raw and normalized payload SHA-256 values and sizes, "
                "raw and normalized per-plane code ranges, and exact "
                "six-direction clip counts"
            ),
            "engine_raw_affected": False,
            "uniform_application": (
                "apply identically to every candidate, baseline, fixed "
                "operator, and ablation container-decoded output"
            ),
        },
        "executable_sha256": "1" * 64,
        "product_settings_source_sha256": "2" * 64,
    }
    writer.settings_sha256 = canonical_sha256(writer._settings)
    frame = PlanarFrame(
        y=np.full((2, 2), (100.0 - 16.0) / 219.0),
        cb=np.full((1, 1), (128.0 - 16.0) / 224.0 - 0.5),
        cr=np.full((1, 1), (128.0 - 16.0) / 224.0 - 0.5),
    )
    context = CandidateContext(
        y_shape=(2, 2),
        cb_shape=(1, 1),
        cr_shape=(1, 1),
        target_route="direct-2x",
    )
    input_sha256 = frame_sha256(frame)
    run_key = canonical_sha256(
        {
            "control_key": "focused-control",
            "input_frame_sha256": input_sha256,
            "settings_sha256": writer.settings_sha256,
            "target_route": context.target_route,
            "y_shape": [2, 2],
            "cb_shape": [1, 1],
            "cr_shape": [1, 1],
        }
    )
    paths = writer._paths(run_key)
    paths["decoded_root"].mkdir(parents=True)
    raw_decoded = bytes((16, 100, 235, 236, 128, 128))
    decoded_path = paths["decoded_root"] / "frame-000000.nv12"
    decoded_path.write_bytes(raw_decoded)
    paths["source"].write_bytes(_planar_to_video_range_nv12(frame))
    paths["source_lock"].write_bytes(b"source-lock")
    paths["encoded"].write_bytes(b"encoded")
    report = {
        "artifact_kind": "production_writer_actual_codec",
        "encoder": {
            "product_settings_source": {
                "sha256": writer._settings["product_settings_source_sha256"]
            }
        },
        "encoded": {
            "sha256": hashlib.sha256(b"encoded").hexdigest(),
        },
        "decoder": {
            "frames": [
                {
                    "payload_path": decoded_path.name,
                    "payload_size_bytes": len(raw_decoded),
                    "payload_sha256": hashlib.sha256(raw_decoded).hexdigest(),
                }
            ]
        },
    }
    paths["report"].write_text(
        json.dumps(report, sort_keys=True),
        encoding="utf-8",
    )

    result = writer.round_trip(
        control_key="focused-control",
        frame=frame,
        context=context,
    )
    decoded = _validate_writer_round_trip(
        writer=writer,
        result=result,
        control_key="focused-control",
        raw_frame=frame,
        context=context,
    )
    evidence = writer.reopen_evidence(result.evidence_sha256)

    assert float(np.max(decoded.y)) == 1.0
    assert evidence["raw_decoded_payload_sha256"] == hashlib.sha256(
        raw_decoded
    ).hexdigest()
    assert evidence["raw_decoded_payload_size_bytes"] == len(raw_decoded)
    assert evidence["normalized_decoded_payload_size_bytes"] == len(raw_decoded)
    assert evidence["decoder_legal_range_normalization"][
        "clipped_sample_counts"
    ]["y_above_235"] == 1
    assert evidence["decoder_legal_range_normalization"][
        "raw_code_ranges"
    ]["y"] == [16, 236]
    assert evidence["decoder_legal_range_normalization"][
        "normalized_code_ranges"
    ]["y"] == [16, 235]
    assert evidence["comparison_domain"] == "container_decoded"
    assert evidence["decoded_pixel_normalization"] == writer._settings[
        "decoded_pixel_normalization"
    ]
    assert evidence["decoded_pixel_normalization"]["engine_raw_affected"] is False
    assert result.evidence_sha256 == canonical_sha256(evidence)
