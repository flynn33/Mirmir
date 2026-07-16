"""Production-locked development dry run with sealed-holdout isolation."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import secrets
import stat
from typing import Callable, Dict, List, Mapping, Optional, Sequence, Set, Tuple

import numpy as np

from .arrays import PlanarFrame, frame_sha256, resize_bilinear
from .bootstrap import paired_bootstrap
from .common_writer import (
    CommonWriterInputFrame,
    CommonWriterResult,
    PRODUCT_MEDIA_TYPES_PATH,
    RationalTime,
    compile_common_writer,
    compile_production_writer,
    run_common_writer,
    run_isolated_production_writer_cases,
)
from .conformance import run_metric_conformance
from .corpus import (
    QUALITY_CATEGORIES,
    sha256_file,
    validate_corpus_bindings_for_splits,
    validate_corpus_lock,
)
from .degradation import apply_degradation, synthetic_motion_sequence
from .fixtures import synthetic_planar_frame
from .json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
    read_json,
    validate_schema,
    write_json,
)
from .metrics import channel_psnr, ms_ssim, ssim
from .samples import load_development_samples


class ProductionDryRunInterrupted(RuntimeError):
    """A failed attempt whose partial evidence was preserved."""

    def __init__(self, message: str, failure_path: Path) -> None:
        super().__init__(message)
        self.failure_path = failure_path


ENGINE_RAW_PIXEL_REPRESENTATION = "bt709-video-range-420v-8bit-nv12-v1"


@dataclass(frozen=True)
class CandidateContext:
    """Non-pixel output geometry and route metadata exposed to candidates."""

    y_shape: Tuple[int, int]
    cb_shape: Tuple[int, int]
    cr_shape: Tuple[int, int]
    target_route: str

    def __post_init__(self) -> None:
        if (
            len(self.y_shape) != 2
            or min(self.y_shape) <= 0
            or self.y_shape[0] % 2
            or self.y_shape[1] % 2
            or self.cb_shape != (self.y_shape[0] // 2, self.y_shape[1] // 2)
            or self.cr_shape != self.cb_shape
            or self.target_route not in {"direct-2x", "direct-3over2"}
        ):
            raise ValueError("candidate context has invalid route or 4:2:0 geometry")


CandidateCallable = Callable[[PlanarFrame, CandidateContext], PlanarFrame]


@dataclass(frozen=True)
class CandidateAdapter:
    """A hash-identified candidate callable accepted by the unchanged harness."""

    candidate_id: str
    configuration: Mapping[str, object]
    configuration_sha256: str
    callable: CandidateCallable

    def __post_init__(self) -> None:
        if not self.candidate_id:
            raise ValueError("candidate ID must be nonempty")
        self.validate_configuration()
        if not callable(self.callable):
            raise ValueError("candidate adapter callable is not callable")

    def validate_configuration(self) -> None:
        if self.configuration_sha256 != canonical_sha256(self.configuration):
            raise ValueError("candidate configuration SHA-256 mismatch")

    def reconstruct(
        self,
        low_resolution: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        self.validate_configuration()
        candidate = self.callable(low_resolution, context)
        self.validate_configuration()
        _validate_candidate_frame(candidate, context)
        return candidate


def _nearest(image: np.ndarray, output_shape: Tuple[int, int]) -> np.ndarray:
    output_height, output_width = output_shape
    source_height, source_width = image.shape
    y = np.minimum(
        (np.arange(output_height, dtype=np.int64) * source_height) // output_height,
        source_height - 1,
    )
    x = np.minimum(
        (np.arange(output_width, dtype=np.int64) * source_width) // output_width,
        source_width - 1,
    )
    return image[y[:, None], x[None, :]]


def _reconstruct(
    low_resolution: PlanarFrame,
    target: PlanarFrame,
    *,
    bilinear: bool,
) -> PlanarFrame:
    resize = resize_bilinear if bilinear else _nearest
    return PlanarFrame(
        y=resize(low_resolution.y, target.y.shape),
        cb=resize(low_resolution.cb, target.cb.shape),
        cr=resize(low_resolution.cr, target.cr.shape),
    )


def _bilinear_candidate(
    low_resolution: PlanarFrame,
    context: CandidateContext,
) -> PlanarFrame:
    return PlanarFrame(
        y=np.clip(
            resize_bilinear(low_resolution.y, context.y_shape),
            0.0,
            1.0,
        ),
        cb=np.clip(
            resize_bilinear(low_resolution.cb, context.cb_shape),
            -0.5,
            0.5,
        ),
        cr=np.clip(
            resize_bilinear(low_resolution.cr, context.cr_shape),
            -0.5,
            0.5,
        ),
    )


def default_candidate_adapter() -> CandidateAdapter:
    configuration = {
        "algorithm": "deterministic-half-pixel-bilinear",
        "implementation": "mirmir_quality.arrays.resize_bilinear",
        "output_range_clamp": {"Y": [0.0, 1.0], "Cb_Cr": [-0.5, 0.5]},
        "version": "1.0.0",
    }
    return CandidateAdapter(
        candidate_id="bilinear-development-control-v1",
        configuration=configuration,
        configuration_sha256=canonical_sha256(configuration),
        callable=_bilinear_candidate,
    )


def _validate_frame_geometry(
    frame: object,
    context: CandidateContext,
) -> None:
    if not isinstance(frame, PlanarFrame):
        raise ValueError("frame must be a PlanarFrame")
    expected_shapes = (context.y_shape, context.cb_shape, context.cr_shape)
    observed_shapes = (frame.y.shape, frame.cb.shape, frame.cr.shape)
    if observed_shapes != expected_shapes:
        raise ValueError("candidate adapter returned the wrong output geometry")
    if not all(
        np.all(np.isfinite(plane))
        for plane in (frame.y, frame.cb, frame.cr)
    ):
        raise ValueError("candidate adapter returned nonfinite values")


def _validate_candidate_frame(
    candidate: object,
    context: CandidateContext,
) -> None:
    _validate_frame_geometry(candidate, context)
    assert isinstance(candidate, PlanarFrame)
    if (
        np.any(candidate.y < 0.0)
        or np.any(candidate.y > 1.0)
        or np.any(candidate.cb < -0.5)
        or np.any(candidate.cb > 0.5)
        or np.any(candidate.cr < -0.5)
        or np.any(candidate.cr > 0.5)
    ):
        raise ValueError("candidate adapter returned values outside normalized ranges")


def _isolated_candidate_input(frame: PlanarFrame) -> PlanarFrame:
    planes = []
    for source in (frame.y, frame.cb, frame.cr):
        isolated = np.array(source, dtype=np.float64, copy=True, order="C")
        isolated.setflags(write=False)
        planes.append(isolated)
    return PlanarFrame(y=planes[0], cb=planes[1], cr=planes[2])


def _planar_to_video_range_nv12(frame: PlanarFrame) -> bytes:
    height, width = frame.y.shape
    if (
        height <= 0
        or width <= 0
        or height % 2
        or width % 2
        or frame.cb.shape != (height // 2, width // 2)
        or frame.cr.shape != frame.cb.shape
    ):
        raise ValueError("PlanarFrame does not have even 4:2:0 geometry")
    y_codes = np.clip(
        np.rint(frame.y * 219.0 + 16.0),
        0.0,
        255.0,
    ).astype(np.uint8)
    cb_codes = np.clip(
        np.rint((frame.cb + 0.5) * 224.0 + 16.0),
        0.0,
        255.0,
    ).astype(np.uint8)
    cr_codes = np.clip(
        np.rint((frame.cr + 0.5) * 224.0 + 16.0),
        0.0,
        255.0,
    ).astype(np.uint8)
    cbcr = np.empty((height // 2, width), dtype=np.uint8)
    cbcr[:, 0::2] = cb_codes
    cbcr[:, 1::2] = cr_codes
    return y_codes.tobytes(order="C") + cbcr.tobytes(order="C")


def _video_range_nv12_to_planar(
    payload: bytes,
    *,
    width: int,
    height: int,
) -> PlanarFrame:
    if width <= 0 or height <= 0 or width % 2 or height % 2:
        raise ValueError("decoded NV12 geometry must be positive and even")
    expected_size = width * height * 3 // 2
    if len(payload) != expected_size:
        raise ValueError("decoded active-row NV12 byte count disagrees with geometry")
    y_size = width * height
    y_codes = np.frombuffer(payload[:y_size], dtype=np.uint8).reshape(height, width)
    cbcr_codes = np.frombuffer(payload[y_size:], dtype=np.uint8).reshape(
        height // 2,
        width,
    )
    return PlanarFrame(
        y=(y_codes.astype(np.float64) - 16.0) / 219.0,
        cb=(cbcr_codes[:, 0::2].astype(np.float64) - 16.0) / 224.0 - 0.5,
        cr=(cbcr_codes[:, 1::2].astype(np.float64) - 16.0) / 224.0 - 0.5,
    )


def _round_trip_locked_bt709_video_range_nv12(
    frame: PlanarFrame,
) -> Tuple[bytes, PlanarFrame]:
    """Expose the exact 8-bit 420v values visible at the production boundary."""

    height, width = frame.y.shape
    payload = _planar_to_video_range_nv12(frame)
    return payload, _video_range_nv12_to_planar(
        payload,
        width=width,
        height=height,
    )


def _file_binding(path: Path) -> Dict[str, object]:
    return {
        "sha256": sha256_file(path),
        "size_bytes": path.stat().st_size,
    }


def _development_sample_fingerprints(
    samples: Sequence[Tuple[Mapping[str, object], PlanarFrame]],
) -> List[Tuple[str, str]]:
    return [
        (canonical_sha256(asset), frame_sha256(frame))
        for asset, frame in samples
    ]


def _validate_run_id(run_id: object) -> str:
    if (
        not isinstance(run_id, str)
        or not run_id
        or run_id in {".", ".."}
        or Path(run_id).is_absolute()
        or Path(run_id).name != run_id
        or "/" in run_id
        or "\\" in run_id
        or "\x00" in run_id
    ):
        raise ValueError("run ID must be one safe filename component")
    return run_id


def _profile_conformance(
    degradation_policy: Mapping[str, object],
) -> Dict[str, object]:
    cases: List[Dict[str, object]] = []
    profiles = degradation_policy.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        raise ValueError("degradation policy lacks profiles")
    for profile in profiles:
        if not isinstance(profile, dict):
            raise ValueError("degradation profile is not an object")
        if profile.get("kind") == "synthetic_motion":
            primary = synthetic_planar_frame(1)
            alternate = synthetic_planar_frame(2)
            first, _ = synthetic_motion_sequence(
                primary,
                profile,
                alternate_scene=alternate,
            )
            second, _ = synthetic_motion_sequence(
                primary,
                profile,
                alternate_scene=alternate,
            )
            first_hashes = [frame_sha256(frame) for frame in first]
            second_hashes = [frame_sha256(frame) for frame in second]
            expected = profile.get("expected_sequence_sha256")
            passed = first_hashes == second_hashes == expected
            cases.append(
                {
                    "profile_id": profile["id"],
                    "expected": expected,
                    "actual": first_hashes,
                    "repeat_actual": second_hashes,
                    "pass": passed,
                }
            )
            continue

        size = (
            (192, 324)
            if profile.get("target_route") == "direct-3over2"
            else (64, 64)
        )
        fixture = synthetic_planar_frame(0, size=size)
        first_hash = frame_sha256(apply_degradation(fixture, profile))
        second_hash = frame_sha256(apply_degradation(fixture, profile))
        expected_hash = profile.get("expected_output_sha256")
        cases.append(
            {
                "profile_id": profile["id"],
                "expected": expected_hash,
                "actual": first_hash,
                "repeat_actual": second_hash,
                "pass": first_hash == second_hash == expected_hash,
            }
        )
    return {
        "schema_version": "1.0.0",
        "degradation_policy_sha256": degradation_policy["policy_sha256"],
        "cases": cases,
        "status": "pass" if all(case["pass"] for case in cases) else "fail",
    }


def _plane_signatures(route: Mapping[str, object]) -> List[List[object]]:
    runs = route.get("runs")
    if not isinstance(runs, list):
        raise ValueError("actual-codec decoder route lacks runs")
    signatures = []
    for run in runs:
        if not isinstance(run, dict) or not isinstance(run.get("frames"), list):
            raise ValueError("actual-codec decoder run lacks frames")
        signatures.append(
            [frame.get("active_row_sha256") for frame in run["frames"]]
        )
    return signatures


def _verify_decoder_timing(
    routes: List[Mapping[str, object]],
    source_lock: Mapping[str, object],
) -> None:
    source_frames = source_lock.get("frames")
    if not isinstance(source_frames, list):
        raise ValueError("actual-codec source lock lacks frame timing")
    for route in routes:
        runs = route.get("runs")
        if not isinstance(runs, list):
            raise ValueError("actual-codec decoder route lacks runs")
        for run_index, run in enumerate(runs):
            if not isinstance(run, dict) or run.get("run_index") != run_index:
                raise ValueError("actual-codec decoder run index mismatch")
            frames = run.get("frames")
            if not isinstance(frames, list) or len(frames) != len(source_frames):
                raise ValueError("actual-codec decoder frame count mismatch")
            for frame_index, (frame, source) in enumerate(zip(frames, source_frames)):
                if not isinstance(frame, dict) or not isinstance(source, dict):
                    raise ValueError("actual-codec frame timing record is invalid")
                expected_presentation = source.get("presentation_time")
                expected_duration = source.get("duration")
                observed_presentation = frame.get("presentation_time")
                observed_duration = frame.get("duration")
                if (
                    frame.get("index") != frame_index
                    or not isinstance(expected_presentation, dict)
                    or not isinstance(expected_duration, dict)
                    or not isinstance(observed_presentation, dict)
                    or not isinstance(observed_duration, dict)
                    or observed_presentation.get("value")
                    != expected_presentation.get("value")
                    or observed_presentation.get("timescale")
                    != expected_presentation.get("timescale")
                    or observed_duration.get("value") != expected_duration.get("value")
                    or observed_duration.get("timescale")
                    != expected_duration.get("timescale")
                ):
                    raise ValueError("actual-codec decoded index or timing mismatch")


def _verify_source_payload(
    payload: bytes,
    source_lock: Mapping[str, object],
) -> None:
    layout = source_lock.get("pixel_layout")
    frames = source_lock.get("frames")
    if not isinstance(layout, dict) or not isinstance(frames, list):
        raise ValueError("actual-codec source lock lacks frame geometry")
    width = int(layout["width"])
    height = int(layout["height"])
    frame_size = width * height * 3 // 2
    if len(payload) != frame_size * len(frames):
        raise ValueError("actual-codec source payload geometry mismatch")
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict) or int(frame.get("index", -1)) != index:
            raise ValueError("actual-codec source frame ordering mismatch")
        frame_payload = payload[index * frame_size : (index + 1) * frame_size]
        if hashlib.sha256(frame_payload).hexdigest() != frame["frame_nv12_sha256"]:
            raise ValueError("actual-codec source frame SHA-256 mismatch")
        luma_size = width * height
        luma = frame_payload[:luma_size]
        chroma = frame_payload[luma_size:]
        active_hashes = {
            "Y": hashlib.sha256(luma).hexdigest(),
            "Cb": hashlib.sha256(chroma[0::2]).hexdigest(),
            "Cr": hashlib.sha256(chroma[1::2]).hexdigest(),
        }
        if active_hashes != frame.get("active_row_sha256"):
            raise ValueError("actual-codec source active-plane SHA-256 mismatch")


def _verify_actual_codec(
    quality_root: Path,
    schemas: Path,
    degradation_policy: Mapping[str, object],
) -> Tuple[Mapping[str, object], Mapping[str, object], Dict[str, object]]:
    locked_fixture = degradation_policy.get("actual_codec_fixture")
    if degradation_policy.get("actual_codec_fixture_required_for_gate") is not True:
        raise ValueError("actual-codec fixture is not required by the degradation lock")
    if not isinstance(locked_fixture, dict):
        raise ValueError("degradation lock lacks actual-codec fixture binding")

    fixture_path = quality_root / str(locked_fixture["fixture_path"])
    evidence_path = quality_root / str(locked_fixture["evidence_path"])
    if not fixture_path.is_file() or not evidence_path.is_file():
        raise ValueError("actual-codec fixture or evidence is absent")
    fixture_binding = _file_binding(fixture_path)
    evidence_binding = _file_binding(evidence_path)
    if fixture_binding["sha256"] != locked_fixture.get("fixture_sha256"):
        raise ValueError("actual-codec fixture SHA-256 does not match the degradation lock")
    if evidence_binding["sha256"] != locked_fixture.get("evidence_sha256"):
        raise ValueError("actual-codec evidence SHA-256 does not match the degradation lock")

    report = read_json(evidence_path)
    validate_schema(report, schemas / "actual-codec-fixture.schema.json")
    report_fixture = report.get("fixture")
    report_source = report.get("source")
    report_integration = report.get("integration")
    if not isinstance(report_fixture, dict) or not isinstance(report_source, dict):
        raise ValueError("actual-codec report lacks source or fixture binding")
    if not isinstance(report_integration, dict) or not isinstance(
        report_integration.get("degradation_lock_profile"),
        dict,
    ):
        raise ValueError("actual-codec report lacks degradation-lock integration")
    integration_profile = report_integration["degradation_lock_profile"]
    if (
        report.get("fixture_id") != locked_fixture.get("id")
        or report_fixture.get("sha256") != fixture_binding["sha256"]
        or report_fixture.get("size_bytes") != fixture_binding["size_bytes"]
        or report_source.get("degradation_profile_id")
        != locked_fixture.get("source_profile_id")
        or report_source.get("degradation_policy_sha256")
        != degradation_policy.get("preintegration_policy_sha256")
    ):
        raise ValueError("actual-codec report disagrees with the degradation lock")
    for field in ("id", "kind", "version", "source_profile_id", "fixture_sha256"):
        if integration_profile.get(field) != locked_fixture.get(field):
            raise ValueError("actual-codec integration profile disagrees with the lock")
    if (
        integration_profile.get("deterministic_decoded_pixels_on_recorded_environment")
        is not True
        or locked_fixture.get("deterministic_decoded_pixels_on_recorded_environment")
        is not True
    ):
        raise ValueError("actual-codec decoded-pixel determinism is not locked")

    source_root = evidence_path.parent
    source_lock_path = source_root / str(report_source["source_lock_path"])
    source_path = source_root / str(report_source["payload_path"])
    if not source_lock_path.is_file() or not source_path.is_file():
        raise ValueError("actual-codec source payload or lock is absent")
    source_lock_binding = _file_binding(source_lock_path)
    source_binding = _file_binding(source_path)
    if source_lock_binding["sha256"] != report_source.get("source_lock_sha256"):
        raise ValueError("actual-codec source-lock SHA-256 mismatch")
    if (
        source_binding["sha256"] != report_source.get("payload_sha256")
        or source_binding["size_bytes"] != report_source.get("payload_size_bytes")
    ):
        raise ValueError("actual-codec source payload binding mismatch")
    source_lock = read_json(source_lock_path)
    validate_schema(source_lock, schemas / "actual-codec-source.schema.json")
    if (
        source_lock.get("payload_sha256") != source_binding["sha256"]
        or source_lock.get("payload_size_bytes") != source_binding["size_bytes"]
        or source_lock.get("fixture_id") != report.get("fixture_id")
        or source_lock.get("source", {}).get("degradation_profile_id")
        != report_source.get("degradation_profile_id")
        or source_lock.get("source", {}).get("degradation_policy_sha256")
        != report_source.get("degradation_policy_sha256")
    ):
        raise ValueError("actual-codec source lock disagrees with source bytes")
    _verify_source_payload(source_path.read_bytes(), source_lock)

    verification = report.get("verification")
    required_flags = {
        "attachments_recorded",
        "cross_route_pixel_identical",
        "dimensions_preserved",
        "exact_timing_preserved",
        "pixel_format_preserved",
        "product_reader_runs_pixel_identical",
        "row_padding_excluded",
        "software_runs_pixel_identical",
    }
    if not isinstance(verification, dict) or any(
        verification.get(field) is not True for field in required_flags
    ):
        raise ValueError("actual-codec verification flags are incomplete")
    routes = report.get("decoder_routes")
    if not isinstance(routes, list) or len(routes) != 2:
        raise ValueError("actual-codec report must contain both decoder routes")
    _verify_decoder_timing(routes, source_lock)
    signatures = [_plane_signatures(route) for route in routes]
    if any(len(route_runs) != 3 for route_runs in signatures):
        raise ValueError("actual-codec report must contain three runs per route")
    if any(
        any(run != route_runs[0] for run in route_runs)
        for route_runs in signatures
    ):
        raise ValueError("actual-codec decoder repeats are not pixel identical")
    if signatures[0][0] != signatures[1][0]:
        raise ValueError("actual-codec decoder routes are not pixel identical")
    if any(len(run) != int(report_fixture["frame_count"]) for run in signatures[0]):
        raise ValueError("actual-codec decoded frame count mismatch")

    binding = {
        "fixture": fixture_binding,
        "evidence": evidence_binding,
        "source_lock": source_lock_binding,
        "source_payload": source_binding,
        "decoded_plane_signatures": signatures[0][0],
    }
    return report, source_lock, binding


def _case_result(
    asset: Mapping[str, object],
    target: PlanarFrame,
    profile: Mapping[str, object],
    low_resolution: PlanarFrame,
    candidate_adapter: CandidateAdapter,
) -> Tuple[Dict[str, object], PlanarFrame]:
    case_id = f"{asset['source_asset_id']}::{profile['id']}"
    input_nv12, low_resolution = _round_trip_locked_bt709_video_range_nv12(
        low_resolution
    )
    input_sha256 = hashlib.sha256(input_nv12).hexdigest()
    nearest_float = _reconstruct(low_resolution, target, bilinear=False)
    candidate_context = CandidateContext(
        y_shape=target.y.shape,
        cb_shape=target.cb.shape,
        cr_shape=target.cr.shape,
        target_route=str(profile["target_route"]),
    )
    candidate_float = candidate_adapter.reconstruct(
        _isolated_candidate_input(low_resolution),
        candidate_context,
    )
    if hashlib.sha256(
        _planar_to_video_range_nv12(low_resolution)
    ).hexdigest() != input_sha256:
        raise ValueError("candidate execution mutated the harness LR input")
    candidate_nv12, candidate = _round_trip_locked_bt709_video_range_nv12(
        candidate_float
    )
    nearest_nv12, nearest = _round_trip_locked_bt709_video_range_nv12(
        nearest_float
    )
    result = {
        "case_id": case_id,
        "source_asset_id": asset["source_asset_id"],
        "categories": asset["categories"],
        "target_route": profile["target_route"],
        "degradation_profile": profile["id"],
        "candidate_id": candidate_adapter.candidate_id,
        "candidate_configuration_sha256": (
            candidate_adapter.configuration_sha256
        ),
        "baseline_id": "nearest-neighbor-v1",
        "pixel_representation": ENGINE_RAW_PIXEL_REPRESENTATION,
        "target_sha256": frame_sha256(target),
        "input_sha256": input_sha256,
        "candidate_sha256": hashlib.sha256(candidate_nv12).hexdigest(),
        "nearest_baseline_sha256": hashlib.sha256(nearest_nv12).hexdigest(),
        "metrics": {
            "candidate": {
                "channel_psnr": channel_psnr(target, candidate),
                "Y_SSIM": ssim(target.y, candidate.y),
                "Y_MS_SSIM": ms_ssim(target.y, candidate.y),
            },
            "nearest_baseline": {
                "channel_psnr": channel_psnr(target, nearest),
                "Y_SSIM": ssim(target.y, nearest.y),
                "Y_MS_SSIM": ms_ssim(target.y, nearest.y),
            },
        },
        "interpretation": "dry-run control measurement; no algorithm-quality claim",
        "status": "pass",
    }
    return result, candidate


def _container_result(
    engine_result: Mapping[str, object],
    target: PlanarFrame,
    raw_candidate: PlanarFrame,
    decoded_candidate_nv12: bytes,
) -> Dict[str, object]:
    height, width = target.y.shape
    raw_candidate_nv12, raw_candidate = (
        _round_trip_locked_bt709_video_range_nv12(raw_candidate)
    )
    preencode_sha256 = hashlib.sha256(raw_candidate_nv12).hexdigest()
    if preencode_sha256 != engine_result.get("candidate_sha256"):
        raise ValueError("container preencode pixels do not match engine_raw pixels")
    decoded_candidate = _video_range_nv12_to_planar(
        decoded_candidate_nv12,
        width=width,
        height=height,
    )
    _validate_frame_geometry(
        decoded_candidate,
        CandidateContext(
            y_shape=target.y.shape,
            cb_shape=target.cb.shape,
            cr_shape=target.cr.shape,
            target_route=str(engine_result["target_route"]),
        ),
    )
    return {
        "case_id": engine_result["case_id"],
        "source_asset_id": engine_result["source_asset_id"],
        "categories": engine_result["categories"],
        "target_route": engine_result["target_route"],
        "degradation_profile": engine_result["degradation_profile"],
        "candidate_id": engine_result["candidate_id"],
        "candidate_configuration_sha256": engine_result[
            "candidate_configuration_sha256"
        ],
        "pixel_representation": ENGINE_RAW_PIXEL_REPRESENTATION,
        "target_sha256": frame_sha256(target),
        "preencode_candidate_sha256": preencode_sha256,
        "decoded_candidate_sha256": hashlib.sha256(
            decoded_candidate_nv12
        ).hexdigest(),
        "preencode_matches_engine_raw": True,
        "metrics": {
            "candidate": {
                "channel_psnr": channel_psnr(target, decoded_candidate),
                "Y_SSIM": ssim(target.y, decoded_candidate.y),
                "Y_MS_SSIM": ms_ssim(target.y, decoded_candidate.y),
            }
        },
        "interpretation": (
            "postencode dry-run control measurement; no algorithm-quality claim"
        ),
        "status": "pass",
    }


def _common_writer_profiles(
    degradation_policy: Mapping[str, object],
) -> Dict[str, Mapping[str, object]]:
    profiles = degradation_policy.get("common_writer_profiles")
    if not isinstance(profiles, list) or len(profiles) != 2:
        raise ValueError("degradation lock must contain exactly two common-writer profiles")
    spatial_by_id = {
        str(profile["id"]): profile
        for profile in degradation_policy["profiles"]
        if isinstance(profile, dict)
    }
    expected_sources = {
        "direct-2x": "hq-binomial7-decimate-2x-v1",
        "direct-3over2": "hq-binomial7-resample-2over3-v1",
    }
    by_route: Dict[str, Mapping[str, object]] = {}
    for profile in profiles:
        if not isinstance(profile, dict):
            raise ValueError("common-writer profile is not an object")
        route = str(profile.get("target_route", ""))
        source_profile_id = str(profile.get("source_profile_id", ""))
        source = spatial_by_id.get(source_profile_id)
        if (
            route not in expected_sources
            or route in by_route
            or profile.get("kind") != "actual_codec"
            or profile.get("writer_id")
            != "apple-h264-software-common-writer-v1"
            or source_profile_id != expected_sources[route]
            or not isinstance(source, dict)
            or source.get("kind") != "lowpass_decimate"
            or source.get("target_route") != route
        ):
            raise ValueError("common-writer profile does not bind its route's locked HQ source")
        by_route[route] = profile
    if set(by_route) != set(expected_sources):
        raise ValueError("common-writer profiles do not cover both production routes")
    return by_route


def _safe_relative_path(path: Path, root: Path) -> str:
    resolved_root = root.resolve()
    resolved_path = path.resolve()
    try:
        relative = resolved_path.relative_to(resolved_root)
    except ValueError as error:
        raise ValueError("artifact path escapes the run directory") from error
    if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
        raise ValueError("artifact path is not a safe relative path")
    return relative.as_posix()


def _bound_artifact_file(root: Path, relative_path: object, *, label: str) -> Path:
    if not isinstance(relative_path, str):
        raise ValueError(f"{label} path is absent")
    relative = Path(relative_path)
    if (
        relative.is_absolute()
        or not relative.parts
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise ValueError(f"{label} path is unsafe")
    cursor = root.resolve(strict=True)
    for part in relative.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError(f"{label} path traverses a symbolic link")
    try:
        resolved = cursor.resolve(strict=True)
        resolved.relative_to(root.resolve(strict=True))
    except (FileNotFoundError, ValueError) as error:
        raise ValueError(f"{label} path is absent or escapes the run") from error
    if not resolved.is_file():
        raise ValueError(f"{label} path is not a regular file")
    return resolved


def _replace_with_new_immutable_inode(path: Path, payload: bytes) -> None:
    previous = None
    if path.exists():
        previous = os.stat(path, follow_symlinks=False)
        if path.is_symlink() or not stat.S_ISREG(previous.st_mode):
            raise ValueError("artifact replacement target is not a regular file")
    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.{secrets.token_hex(16)}.detached"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o400)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("artifact replacement write made no progress")
            offset += written
        os.fchmod(descriptor, 0o400)
        os.fsync(descriptor)
        detached = os.fstat(descriptor)
        os.replace(temporary, path)
        os.chflags(
            path,
            detached.st_flags | stat.UF_IMMUTABLE,
            follow_symlinks=False,
        )
        published = os.stat(path, follow_symlinks=False)
        if (
            (published.st_dev, published.st_ino)
            != (detached.st_dev, detached.st_ino)
            or previous is not None
            and (published.st_dev, published.st_ino)
            == (previous.st_dev, previous.st_ino)
            or published.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
            or not published.st_flags & stat.UF_IMMUTABLE
        ):
            raise ValueError("artifact replacement did not publish a detached immutable inode")
    finally:
        os.close(descriptor)
        temporary.unlink(missing_ok=True)
    rebound = path.read_bytes()
    if rebound != payload:
        raise ValueError("detached artifact bytes differ from the captured payload")


def _detach_and_freeze_artifact_files(root: Path) -> None:
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("artifact tree contains a symbolic link")
        if path.is_file():
            before = os.stat(path, follow_symlinks=False)
            payload = path.read_bytes()
            after = os.stat(path, follow_symlinks=False)
            if (
                (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
                or before.st_size != after.st_size
                or before.st_mtime_ns != after.st_mtime_ns
                or len(payload) != before.st_size
            ):
                raise ValueError("artifact changed while its final bytes were captured")
            _replace_with_new_immutable_inode(path, payload)


def _make_artifact_directories_read_only(root: Path) -> None:
    paths = sorted(root.rglob("*"))
    if any(path.is_symlink() for path in paths):
        raise ValueError("artifact tree contains a symbolic link")
    directories = [path for path in paths if path.is_dir()]
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        directory.chmod(0o555)
    root.chmod(0o555)


def _seal_published_directories(root: Path) -> None:
    directories = [root, *(path for path in root.rglob("*") if path.is_dir())]
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        flags = os.stat(directory, follow_symlinks=False).st_flags
        os.chflags(
            directory,
            flags | stat.UF_IMMUTABLE,
            follow_symlinks=False,
        )


def _thaw_artifact_tree(root: Path) -> None:
    if not root.exists() or root.is_symlink():
        return
    directories = [root, *(path for path in root.rglob("*") if path.is_dir())]
    for directory in sorted(directories, key=lambda item: len(item.parts)):
        flags = os.stat(directory, follow_symlinks=False).st_flags
        if flags & stat.UF_IMMUTABLE:
            os.chflags(
                directory,
                flags & ~stat.UF_IMMUTABLE,
                follow_symlinks=False,
            )
        directory.chmod(0o755)
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        flags = os.stat(path, follow_symlinks=False).st_flags
        if flags & stat.UF_IMMUTABLE:
            os.chflags(path, flags & ~stat.UF_IMMUTABLE, follow_symlinks=False)


def _reopen_writer_result(
    root: Path,
    record: Mapping[str, object],
    *,
    schemas: Path,
) -> Tuple[CommonWriterResult, Mapping[str, object]]:
    bound_paths: Dict[str, Path] = {}
    for field in ("report", "source_payload", "source_lock", "encoded"):
        binding = record.get(field)
        if not isinstance(binding, dict):
            raise ValueError(f"writer run lacks {field} binding")
        path = _bound_artifact_file(
            root,
            binding.get("path"),
            label=f"writer {field}",
        )
        if _file_binding(path) != {
            "sha256": binding.get("sha256"),
            "size_bytes": binding.get("size_bytes"),
        }:
            raise ValueError(f"writer {field} binding changed")
        bound_paths[field] = path

    source_lock = read_json(bound_paths["source_lock"])
    validate_schema(source_lock, schemas / "common-writer-source.schema.json")
    source_payload = bound_paths["source_payload"].read_bytes()
    if (
        len(source_payload) != source_lock.get("payload_size_bytes")
        or hashlib.sha256(source_payload).hexdigest()
        != source_lock.get("payload_sha256")
    ):
        raise ValueError("writer source bytes differ from the source lock")
    _verify_source_payload(source_payload, source_lock)

    report = read_json(bound_paths["report"])
    report_schema = (
        "production-writer.schema.json"
        if record.get("writer_id") == "mirmir-product-hevc-avassetwriter-v1"
        else "common-writer.schema.json"
    )
    validate_schema(report, schemas / report_schema)
    source = report.get("source")
    encoded = report.get("encoded")
    decoder = report.get("decoder")
    if (
        not isinstance(source, dict)
        or source.get("payload_sha256") != hashlib.sha256(source_payload).hexdigest()
        or source.get("source_lock_sha256")
        != sha256_file(bound_paths["source_lock"])
        or not isinstance(encoded, dict)
        or encoded.get("sha256") != sha256_file(bound_paths["encoded"])
        or not isinstance(decoder, dict)
        or not isinstance(decoder.get("frames"), list)
    ):
        raise ValueError("writer report bytes are not cross-bound")

    report_name = bound_paths["report"].name
    suffix = "-report.json"
    if not report_name.endswith(suffix):
        raise ValueError("writer report filename does not identify its decoded directory")
    output_name = report_name[: -len(suffix)]
    decoded_directory = bound_paths["report"].parent / f"{output_name}-decoded"
    decoded_frames = []
    for index, frame in enumerate(decoder["frames"]):
        if not isinstance(frame, dict):
            raise ValueError("writer decoded frame record is invalid")
        try:
            decoded_relative = decoded_directory.relative_to(
                root.resolve(strict=True)
            ).joinpath(
                str(frame.get("payload_path", ""))
            )
        except ValueError as error:
            raise ValueError("writer decoded directory escapes the run") from error
        decoded_path = _bound_artifact_file(
            root,
            decoded_relative.as_posix(),
            label=f"writer decoded frame {index}",
        )
        payload = decoded_path.read_bytes()
        if (
            len(payload) != frame.get("payload_size_bytes")
            or hashlib.sha256(payload).hexdigest() != frame.get("payload_sha256")
        ):
            raise ValueError("writer decoded payload binding changed")
        decoded_frames.append(payload)
    return (
        CommonWriterResult(
            report=report,
            decoded_frames=tuple(decoded_frames),
            source_path=bound_paths["source_payload"],
            source_lock_path=bound_paths["source_lock"],
            encoded_path=bound_paths["encoded"],
            report_path=bound_paths["report"],
            decoded_directory=decoded_directory,
        ),
        source_lock,
    )


def _verify_common_writer_result(
    result: CommonWriterResult,
    *,
    expected_case_ids: Sequence[str],
    width: int,
    height: int,
    writer_id: str,
    run_root: Path,
    purpose: str,
    profile_id: Optional[str],
    target_route: Optional[str],
    source_profile_id: Optional[str],
) -> Dict[str, object]:
    report = result.report
    if read_json(result.report_path) != report:
        raise ValueError("common-writer report file changed after verification")
    if writer_id != "apple-h264-software-common-writer-v1":
        raise ValueError("common-writer policy ID is not the sealed Apple H.264 writer")
    expected_settings = {
        "framework": "VideoToolbox",
        "session_type": "VTCompressionSession",
        "encoder_id": "com.apple.videotoolbox.videoencoder.h264",
        "encoder_name": "Apple H.264 (SW)",
        "hardware_accelerated": False,
        "real_time": False,
        "allow_frame_reordering": False,
        "allow_temporal_compression": False,
        "max_key_frame_interval": 1,
        "all_frames_sync": True,
        "profile_level": "H264_Baseline_3_0",
        "average_bit_rate": 250000,
        "data_rate_limit_bytes": 31250,
        "data_rate_limit_seconds": 1,
        "expected_frame_rate": 30,
        "pixel_format": "420v",
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location": "Left",
    }
    encoder = report.get("encoder")
    source = report.get("source")
    encoded = report.get("encoded")
    decoder = report.get("decoder")
    if (
        report.get("artifact_kind") != "common_writer_actual_codec"
        or not isinstance(encoder, dict)
        or any(encoder.get(key) != value for key, value in expected_settings.items())
        or not isinstance(source, dict)
        or not isinstance(encoded, dict)
        or not isinstance(decoder, dict)
    ):
        raise ValueError("common-writer report does not prove the sealed encoder settings")
    source_frames = source.get("frames")
    decoded_frames = decoder.get("frames")
    expected_source_layout = {
        "pixel_format": "420v",
        "range": "video",
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location_top_field": "Left",
        "chroma_location_bottom_field": "Left",
        "width": width,
        "height": height,
    }
    expected_attachments = {
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location_top_field": "Left",
        "chroma_location_bottom_field": "Left",
        "range": "video",
    }
    expected_ids = list(expected_case_ids)
    if (
        source.get("pixel_layout") != expected_source_layout
        or encoded.get("width") != width
        or encoded.get("height") != height
        or not isinstance(source_frames, list)
        or not isinstance(decoded_frames, list)
        or len(result.decoded_frames) != len(expected_ids)
        or [frame.get("case_id") for frame in source_frames] != expected_ids
        or [frame.get("case_id") for frame in decoded_frames] != expected_ids
    ):
        raise ValueError("common-writer geometry, count, or exact case order mismatch")
    if encoded.get("format_attachments") != expected_attachments or any(
        not isinstance(frame, dict)
        or frame.get("attachments") != expected_attachments
        for frame in decoded_frames
    ):
        raise ValueError("common-writer report does not prove Left-sited metadata")
    for index, (source_frame, decoded_frame) in enumerate(
        zip(source_frames, decoded_frames)
    ):
        expected_time = {"value": index * 20, "timescale": 600}
        expected_duration = {"value": 20, "timescale": 600}
        if (
            source_frame.get("index") != index
            or source_frame.get("presentation_time") != expected_time
            or source_frame.get("duration") != expected_duration
            or decoded_frame.get("index") != index
            or decoded_frame.get("presentation_time", {}).get("value") != index * 20
            or decoded_frame.get("presentation_time", {}).get("timescale") != 600
            or decoded_frame.get("duration", {}).get("value") != 20
            or decoded_frame.get("duration", {}).get("timescale") != 600
        ):
            raise ValueError("common-writer exact index or timing mismatch")
    verification = report.get("verification")
    if not isinstance(verification, dict) or not all(verification.values()):
        raise ValueError("common-writer verification flags are incomplete")
    if report.get("limitations", {}).get("mp4_byte_identity_across_runs_claimed") is not False:
        raise ValueError("common-writer report makes an unsupported MP4 byte-repeat claim")
    return {
        "purpose": purpose,
        "writer_id": writer_id,
        "profile_id": profile_id,
        "target_route": target_route,
        "source_profile_id": source_profile_id,
        "frame_count": len(expected_ids),
        "dimensions": {"width": width, "height": height},
        "report": {
            "path": _safe_relative_path(result.report_path, run_root),
            **_file_binding(result.report_path),
        },
        "source_payload": {
            "path": _safe_relative_path(result.source_path, run_root),
            **_file_binding(result.source_path),
        },
        "source_lock": {
            "path": _safe_relative_path(result.source_lock_path, run_root),
            **_file_binding(result.source_lock_path),
        },
        "encoded": {
            "path": _safe_relative_path(result.encoded_path, run_root),
            **_file_binding(result.encoded_path),
        },
        "encoder_settings_sha256": canonical_sha256(encoder),
        "mp4_byte_identity_across_runs_claimed": False,
    }


def _expected_product_attachments(
    sample_lock: Mapping[str, object],
) -> Dict[str, str]:
    samples = sample_lock.get("samples")
    if not isinstance(samples, list) or len(samples) != 6:
        raise ValueError("development sample metadata does not cover six sources")
    expected_source = {
        "range": "video",
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location": "left",
    }
    for sample in samples:
        if not isinstance(sample, dict) or any(
            sample.get(field) != value for field, value in expected_source.items()
        ):
            raise ValueError(
                "production container metrics require explicit BT.709 "
                "video-range left-sited samples"
            )
    return {
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location_top_field": "Left",
        "range": "video",
    }


def _verify_production_writer_result(
    result: CommonWriterResult,
    *,
    expected_case_ids: Sequence[str],
    expected_attachments: Mapping[str, str],
    expected_settings_binding: Mapping[str, object],
    run_root: Path,
    metric_eligible: bool,
) -> Dict[str, object]:
    report = result.report
    if read_json(result.report_path) != report:
        raise ValueError("production-writer report file changed after verification")
    encoder = report.get("encoder")
    source = report.get("source")
    encoded = report.get("encoded")
    decoder = report.get("decoder")
    if (
        report.get("artifact_kind") != "production_writer_actual_codec"
        or not isinstance(encoder, dict)
        or encoder.get("framework") != "AVFoundation"
        or encoder.get("session_type") != "AVAssetWriterInput"
        or encoder.get("requested_codec") != "hevc"
        or encoder.get("requested_average_bit_rate") != 2_000_000
        or encoder.get("expected_frame_rate") != 30
        or encoder.get("expects_media_data_in_real_time") is not False
        or encoder.get("reopened_codec") not in {"hvc1", "hev1"}
        or not isinstance(source, dict)
        or not isinstance(encoded, dict)
        or not isinstance(decoder, dict)
    ):
        raise ValueError("production-writer report does not prove product HEVC settings")
    settings_source = encoder.get("product_settings_source")
    settings_binding = dict(expected_settings_binding)
    if settings_binding != {
        "path": "Mirmir/Modules/MediaPipeline/MediaTypes.swift",
        **_file_binding(PRODUCT_MEDIA_TYPES_PATH),
    }:
        raise ValueError("shared product settings changed during the dry run")
    if (
        not isinstance(settings_source, dict)
        or settings_source.get("path") != PRODUCT_MEDIA_TYPES_PATH.name
        or settings_source.get("sha256") != settings_binding["sha256"]
        or settings_source.get("size_bytes") != settings_binding["size_bytes"]
    ):
        raise ValueError("production-writer report is not bound to shared product settings")
    expected_ids = list(expected_case_ids)
    expected_count = len(expected_ids)
    if expected_count < 1:
        raise ValueError("production-writer verification requires at least one case")
    source_frames = source.get("frames")
    decoded_frames = decoder.get("frames")
    if (
        source.get("pixel_layout")
        != {
            "pixel_format": "420v",
            "range": "video",
            "color_primaries": "ITU_R_709_2",
            "transfer_function": "ITU_R_709_2",
            "ycbcr_matrix": "ITU_R_709_2",
            "chroma_location_top_field": "Left",
            "chroma_location_bottom_field": "Left",
            "width": 324,
            "height": 192,
        }
        or encoded.get("codec") not in {"hvc1", "hev1"}
        or encoded.get("width") != 324
        or encoded.get("height") != 192
        or not isinstance(source_frames, list)
        or not isinstance(decoded_frames, list)
        or source.get("frame_count") != expected_count
        or encoded.get("frame_count") != expected_count
        or decoder.get("frame_count") != expected_count
        or len(result.decoded_frames) != expected_count
        or [frame.get("case_id") for frame in source_frames] != expected_ids
        or [frame.get("case_id") for frame in decoded_frames] != expected_ids
    ):
        raise ValueError("production-writer geometry, count, codec, or case order mismatch")
    expected_scope = {
        "frame_count": expected_count,
        "single_frame_container": expected_count == 1,
        "neighbor_frames_present": expected_count > 1,
        "metric_role": (
            "isolated_metric_case" if expected_count == 1 else "non_metric_smoke_only"
        ),
    }
    if report.get("container_scope") != expected_scope:
        raise ValueError("production-writer container scope evidence is inconsistent")
    if metric_eligible and expected_count != 1:
        raise ValueError("metric production-writer evidence must isolate exactly one case")
    if not metric_eligible and expected_count == 1:
        raise ValueError("isolated production-writer evidence must be metric eligible")
    encoded_attachments = encoded.get("format_attachments")
    if not isinstance(encoded_attachments, dict) or any(
        encoded_attachments.get(field) != value
        for field, value in expected_attachments.items()
    ) or encoded_attachments.get("chroma_location_bottom_field") not in {
        None,
        "Left",
    }:
        raise ValueError("reopened production container metadata differs from source targets")
    for index, (source_frame, decoded_frame) in enumerate(
        zip(source_frames, decoded_frames)
    ):
        expected_time = {"value": index * 20, "timescale": 600}
        expected_duration = {"value": 20, "timescale": 600}
        attachments = decoded_frame.get("attachments")
        if (
            source_frame.get("index") != index
            or source_frame.get("presentation_time") != expected_time
            or source_frame.get("duration") != expected_duration
            or decoded_frame.get("index") != index
            or decoded_frame.get("presentation_time", {}).get("value") != index * 20
            or decoded_frame.get("presentation_time", {}).get("timescale") != 600
            or decoded_frame.get("duration", {}).get("value") != 20
            or decoded_frame.get("duration", {}).get("timescale") != 600
            or not isinstance(attachments, dict)
            or any(
                attachments.get(field) != value
                for field, value in expected_attachments.items()
            )
            or attachments.get("chroma_location_bottom_field")
            not in {None, "Left"}
        ):
            raise ValueError(
                "production-writer timing, order, or decoded metadata mismatch"
            )
    verification = report.get("verification")
    if not isinstance(verification, dict) or not all(verification.values()):
        raise ValueError("production-writer verification flags are incomplete")
    if (
        report.get("limitations", {}).get("mp4_byte_identity_across_runs_claimed")
        is not False
    ):
        raise ValueError("production-writer report makes an unsupported MP4 repeat claim")
    observed_rate = encoder.get("observed_estimated_data_rate")
    if (
        not isinstance(observed_rate, (int, float))
        or not np.isfinite(observed_rate)
        or observed_rate <= 0
    ):
        raise ValueError("production-writer observed data rate is invalid")
    record = {
        "purpose": (
            "candidate_postencode_isolated"
            if metric_eligible
            else "candidate_postencode_smoke"
        ),
        "writer_id": "mirmir-product-hevc-avassetwriter-v1",
        "profile_id": (
            "candidate-postencode-isolated"
            if metric_eligible
            else "candidate-postencode-smoke"
        ),
        "target_route": None,
        "source_profile_id": None,
        "frame_count": expected_count,
        "dimensions": {"width": 324, "height": 192},
        "report": {
            "path": _safe_relative_path(result.report_path, run_root),
            **_file_binding(result.report_path),
        },
        "source_payload": {
            "path": _safe_relative_path(result.source_path, run_root),
            **_file_binding(result.source_path),
        },
        "source_lock": {
            "path": _safe_relative_path(result.source_lock_path, run_root),
            **_file_binding(result.source_lock_path),
        },
        "encoded": {
            "path": _safe_relative_path(result.encoded_path, run_root),
            **_file_binding(result.encoded_path),
        },
        "encoder_settings_sha256": canonical_sha256(encoder),
        "requested_codec": "hevc",
        "reopened_codec": str(encoder["reopened_codec"]),
        "requested_average_bit_rate": 2_000_000,
        "observed_estimated_data_rate": float(observed_rate),
        "product_settings_source": settings_binding,
        "validated_attachments": dict(expected_attachments),
        "metric_eligible": metric_eligible,
        "container_scope": expected_scope,
        "mp4_byte_identity_across_runs_claimed": False,
    }
    if metric_eligible:
        decoded_path = result.decoded_directory / str(
            decoded_frames[0]["payload_path"]
        )
        record["case_id"] = expected_ids[0]
        record["decoded_payload"] = {
            "path": _safe_relative_path(decoded_path, run_root),
            **_file_binding(decoded_path),
        }
    return record


class ProductionDevelopmentDryRun:
    """Execute the locked development corpus while leaving holdout media sealed."""

    def __init__(
        self,
        *,
        output_root: Path,
        run_id: str,
        quality_root: Path,
        corpus_lock_path: Path,
        asset_root: Path,
        evidence_root: Path,
        development_sample_lock_path: Path,
        sample_root: Path,
        candidate_adapter: Optional[CandidateAdapter] = None,
        common_writer_executable: Optional[Path] = None,
        production_writer_executable: Optional[Path] = None,
    ) -> None:
        self.output_root = output_root
        self.run_id = _validate_run_id(run_id)
        self.quality_root = quality_root
        self.corpus_lock_path = corpus_lock_path
        self.asset_root = asset_root
        self.evidence_root = evidence_root
        self.development_sample_lock_path = development_sample_lock_path
        self.sample_root = sample_root
        self.candidate_adapter = candidate_adapter or default_candidate_adapter()
        self.common_writer_executable = common_writer_executable
        self.production_writer_executable = production_writer_executable
        self.schemas = quality_root / "schemas"

    def _failure_destination(self) -> Path:
        attempt = 1
        while True:
            destination = self.output_root / f"{self.run_id}.failed-{attempt}"
            if not destination.exists():
                return destination
            attempt += 1

    def _preserve_failure(self, partial: Path, error: BaseException) -> Path:
        write_json(
            partial / "failure.json",
            {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "failure_type": type(error).__name__,
                "message": str(error),
                "partial_preserved": True,
                "holdout_accessed": False,
            },
        )
        destination = self._failure_destination()
        os.replace(partial, destination)
        return destination

    def _read_and_validate_inputs(
        self,
    ) -> Tuple[
        Mapping[str, object],
        Mapping[str, object],
        Mapping[str, object],
        Mapping[str, object],
        List[Tuple[Mapping[str, object], PlanarFrame]],
        Mapping[str, object],
        Mapping[str, object],
        Mapping[str, object],
    ]:
        corpus = read_json(self.corpus_lock_path)
        sealed_corpus_bytes = canonical_json_bytes(corpus) + b"\n"
        if self.corpus_lock_path.read_bytes() != sealed_corpus_bytes:
            raise ValueError("production corpus lock is not the canonical sealed byte artifact")
        validate_schema(corpus, self.schemas / "corpus-lock.schema.json")
        validate_corpus_lock(
            corpus,
            allowed_categories=QUALITY_CATEGORIES,
            require_all_splits=True,
            require_exact_allocation=True,
            require_category_minima=True,
        )
        split_policy = corpus["split_policy"]
        exact_overall_minima = {category: 4 for category in QUALITY_CATEGORIES}
        exact_split_minima = {
            split: {category: 1 for category in QUALITY_CATEGORIES}
            for split in ("development", "validation", "holdout")
        }
        if split_policy.get("minimum_category_counts") != exact_overall_minima:
            raise ValueError(
                "production corpus requires an exact overall minimum of four per category"
            )
        if split_policy.get("minimum_category_counts_by_split") != exact_split_minima:
            raise ValueError(
                "production corpus requires an exact per-split minimum of one per category"
            )
        source_counts = {
            split: len(
                {
                    str(asset["source_asset_id"])
                    for asset in corpus["assets"]
                    if asset["split"] == split
                }
            )
            for split in ("development", "validation", "holdout")
        }
        if source_counts != {"development": 6, "validation": 3, "holdout": 3}:
            raise ValueError("production corpus must contain exactly 6/3/3 source assets")
        if len(corpus["assets"]) != 12:
            raise ValueError("production corpus must contain one asset per source asset")
        route_by_dimensions = {
            (3840, 2160): "direct-2x",
            (1920, 1080): "direct-3over2",
        }
        for asset in corpus["assets"]:
            dimensions = tuple(int(value) for value in asset["presentation_dimensions"])
            expected_route = route_by_dimensions.get(dimensions)
            if expected_route is None or asset.get("target_routes") != [expected_route]:
                raise ValueError(
                    "production assets require exactly one route matching 3840x2160 or 1920x1080"
                )
        validate_corpus_bindings_for_splits(
            corpus,
            asset_root=self.asset_root,
            evidence_root=self.evidence_root,
            asset_splits={"development", "validation"},
            evidence_splits={"development", "validation", "holdout"},
        )

        sample_lock = read_json(self.development_sample_lock_path)
        validate_schema(
            sample_lock,
            self.schemas / "development-sample-lock.schema.json",
        )
        samples = load_development_samples(
            sample_lock,
            corpus,
            sample_root=self.sample_root,
            asset_root=self.asset_root,
        )

        metric_policy_path = self.quality_root / "policies" / "metric-policy.json"
        degradation_policy_path = (
            self.quality_root / "policies" / "degradation-policy.json"
        )
        metric_policy = read_json(metric_policy_path)
        degradation_policy = read_json(degradation_policy_path)
        if metric_policy.get("policy_sha256") != manifest_sha256(
            metric_policy,
            "policy_sha256",
        ):
            raise ValueError("metric policy hash mismatch")
        if degradation_policy.get("policy_sha256") != manifest_sha256(
            degradation_policy,
            "policy_sha256",
        ):
            raise ValueError("degradation policy hash mismatch")
        if degradation_policy.get("status") != "locked":
            raise ValueError("production degradation policy status must be locked")
        preintegration_policy = dict(degradation_policy)
        expected_preintegration_sha256 = preintegration_policy.pop(
            "preintegration_policy_sha256",
            None,
        )
        preintegration_policy.pop("actual_codec_fixture", None)
        preintegration_policy.pop("common_writer_profiles", None)
        preintegration_policy["status"] = "development_seed"
        if (
            not isinstance(expected_preintegration_sha256, str)
            or manifest_sha256(preintegration_policy, "policy_sha256")
            != expected_preintegration_sha256
        ):
            raise ValueError("degradation pre-integration policy lineage hash mismatch")
        validate_schema(metric_policy, self.schemas / "metric-policy.schema.json")
        validate_schema(
            degradation_policy,
            self.schemas / "degradation-lock.schema.json",
        )
        vector_path = self.quality_root / "reference" / "metric-vectors-v1.json"
        if sha256_file(vector_path) != metric_policy["independent_oracle"]["vector_sha256"]:
            raise ValueError("independent metric-vector file hash mismatch")
        metric_conformance = run_metric_conformance(metric_policy["policy_sha256"])
        validate_schema(
            metric_conformance,
            self.schemas / "metric-conformance.schema.json",
        )
        if metric_conformance["status"] != "pass":
            raise ValueError("metric conformance failed")
        degradation_conformance = _profile_conformance(degradation_policy)
        if degradation_conformance["status"] != "pass":
            raise ValueError("degradation conformance failed")
        codec_report, codec_source_lock, codec_binding = _verify_actual_codec(
            self.quality_root,
            self.schemas,
            degradation_policy,
        )
        return (
            corpus,
            sample_lock,
            metric_policy,
            degradation_policy,
            samples,
            metric_conformance,
            degradation_conformance,
            {
                "report": codec_report,
                "source_lock": codec_source_lock,
                "binding": codec_binding,
            },
        )

    def _revalidate_inputs_before_publish(
        self,
        expected: Tuple[object, ...],
    ) -> None:
        observed = self._read_and_validate_inputs()
        named_indices = (
            ("corpus lock", 0),
            ("development sample lock", 1),
            ("metric policy", 2),
            ("degradation policy", 3),
            ("metric conformance", 5),
            ("degradation conformance", 6),
            ("actual-codec fixture", 7),
        )
        for label, index in named_indices:
            if observed[index] != expected[index]:
                raise ValueError(f"{label} changed before finalization")
        expected_samples = expected[4]
        observed_samples = observed[4]
        if not isinstance(expected_samples, list) or not isinstance(
            observed_samples,
            list,
        ):
            raise ValueError("development sample snapshot has an invalid type")
        if _development_sample_fingerprints(
            observed_samples
        ) != _development_sample_fingerprints(expected_samples):
            raise ValueError("development sample bytes changed before finalization")

    def _verify_artifact_semantics(
        self,
        partial: Path,
        *,
        expected: Mapping[str, object],
    ) -> None:
        document_paths = {
            "benchmark": "benchmark-dry-run.json",
            "engine_quality": "quality-result-engine-raw.json",
            "container_quality": "quality-result-container-decoded.json",
            "bootstrap": "paired-bootstrap-engine-raw.json",
            "checkpoint": "checkpoint.json",
            "configuration_inputs": "configuration-inputs.json",
            "input_bindings": "input-bindings.json",
        }
        documents = {
            name: read_json(_bound_artifact_file(partial, relative, label=name))
            for name, relative in document_paths.items()
        }
        validate_schema(
            documents["benchmark"],
            self.schemas / "benchmark-dry-run.schema.json",
        )
        validate_schema(
            documents["engine_quality"],
            self.schemas / "quality-result.schema.json",
        )
        validate_schema(
            documents["container_quality"],
            self.schemas / "quality-result.schema.json",
        )
        for name in (
            "benchmark",
            "engine_quality",
            "container_quality",
            "bootstrap",
            "configuration_inputs",
            "input_bindings",
        ):
            if documents[name] != expected.get(name):
                raise ValueError(f"artifact semantic snapshot differs for {name}")

        checkpoint = documents["checkpoint"]
        if (
            checkpoint.get("checkpoint_sha256")
            != manifest_sha256(checkpoint, "checkpoint_sha256")
            or checkpoint.get("run_id") != self.run_id
            or checkpoint.get("configuration_sha256")
            != documents["benchmark"].get("configuration_sha256")
            or checkpoint.get("completed") != expected.get("completed")
        ):
            raise ValueError("final checkpoint does not reproduce the completed cases")

        engine_results = documents["engine_quality"].get("asset_results")
        container_results = documents["container_quality"].get("asset_results")
        if not isinstance(engine_results, list) or not isinstance(container_results, list):
            raise ValueError("quality artifacts lack result rows")
        expected_order = expected.get("expected_order")
        engine_order = [row.get("case_id") for row in engine_results if isinstance(row, dict)]
        container_order = [
            row.get("case_id") for row in container_results if isinstance(row, dict)
        ]
        if (
            engine_order != expected_order
            or container_order != expected_order
            or canonical_sha256(engine_order)
            != documents["benchmark"].get("comparison_case_order_sha256")
        ):
            raise ValueError("quality artifact case order is not the locked order")

        bootstrap_records = []
        for result in engine_results:
            if not isinstance(result, dict):
                raise ValueError("engine quality row is not an object")
            bootstrap_records.append(
                {
                    "source_asset_id": result["source_asset_id"],
                    "candidate": result["metrics"]["candidate"]["channel_psnr"]["Y"][
                        "value"
                    ],
                    "baseline": result["metrics"]["nearest_baseline"][
                        "channel_psnr"
                    ]["Y"]["value"],
                    "categories": result["categories"],
                }
            )
        if paired_bootstrap(bootstrap_records) != documents["bootstrap"]:
            raise ValueError("bootstrap artifact does not recompute from engine rows")

        benchmark = documents["benchmark"]
        for field, quality_name in (
            ("engine_raw_result", "engine_quality"),
            ("container_decoded_result", "container_quality"),
        ):
            binding = benchmark.get(field)
            if not isinstance(binding, dict):
                raise ValueError(f"benchmark lacks {field}")
            bound_path = _bound_artifact_file(
                partial,
                binding.get("path"),
                label=field,
            )
            if _file_binding(bound_path) != {
                "sha256": binding.get("sha256"),
                "size_bytes": binding.get("size_bytes"),
            } or read_json(bound_path) != documents[quality_name]:
                raise ValueError(f"benchmark {field} binding is inconsistent")

        writer_runs = benchmark.get("common_writer_runs")
        input_bindings = documents["input_bindings"]
        if (
            not isinstance(writer_runs, list)
            or len(writer_runs) != 26
            or input_bindings.get("common_writer_runs") != writer_runs
        ):
            raise ValueError("writer runs are not exactly cross-bound")
        sample_lock = expected.get("sample_lock")
        if not isinstance(sample_lock, dict):
            raise ValueError("semantic snapshot lacks the development sample lock")
        product_attachments = _expected_product_attachments(sample_lock)
        product_settings = benchmark.get("product_settings_source")
        if not isinstance(product_settings, dict):
            raise ValueError("benchmark lacks product settings binding")
        product_count = 0
        for record in writer_runs:
            if not isinstance(record, dict):
                raise ValueError("writer run is not an object")
            reopened, source_lock = _reopen_writer_result(
                partial,
                record,
                schemas=self.schemas,
            )
            frames = source_lock.get("frames")
            if not isinstance(frames, list):
                raise ValueError("writer source lock lacks frames")
            case_ids = [frame.get("case_id") for frame in frames if isinstance(frame, dict)]
            dimensions = record.get("dimensions")
            if not isinstance(dimensions, dict):
                raise ValueError("writer run lacks dimensions")
            if record.get("writer_id") == "apple-h264-software-common-writer-v1":
                reproduced = _verify_common_writer_result(
                    reopened,
                    expected_case_ids=case_ids,
                    width=int(dimensions["width"]),
                    height=int(dimensions["height"]),
                    writer_id=str(record["writer_id"]),
                    run_root=partial,
                    purpose=str(record["purpose"]),
                    profile_id=record.get("profile_id"),
                    target_route=record.get("target_route"),
                    source_profile_id=record.get("source_profile_id"),
                )
            elif record.get("writer_id") == "mirmir-product-hevc-avassetwriter-v1":
                product_count += 1
                reproduced = _verify_production_writer_result(
                    reopened,
                    expected_case_ids=case_ids,
                    expected_attachments=product_attachments,
                    expected_settings_binding=product_settings,
                    run_root=partial,
                    metric_eligible=record.get("metric_eligible") is True,
                )
            else:
                raise ValueError("writer run uses an unknown implementation")
            if reproduced != record:
                raise ValueError("writer run does not reproduce from its artifacts")
        if product_count != 24:
            raise ValueError("semantic verification did not find 24 isolated HEVC runs")

        preserved_documents = expected.get("preserved_documents")
        if not isinstance(preserved_documents, dict):
            raise ValueError("semantic snapshot lacks preserved input documents")
        for relative_path, expected_document in preserved_documents.items():
            path = _bound_artifact_file(
                partial,
                relative_path,
                label=f"preserved document {relative_path}",
            )
            if read_json(path) != expected_document:
                raise ValueError(f"preserved document {relative_path} changed")

    def _verify_artifacts_before_publish(
        self,
        partial: Path,
        *,
        require_directory_immutable: bool = False,
    ) -> None:
        manifest_path = partial / "artifact-manifest.json"
        manifest = read_json(manifest_path)
        validate_schema(
            manifest,
            self.schemas / "artifact-manifest.schema.json",
        )
        if manifest.get("run_id") != self.run_id:
            raise ValueError("artifact manifest run ID mismatch")
        if manifest.get("manifest_sha256") != manifest_sha256(manifest):
            raise ValueError("artifact manifest self-hash mismatch")
        records = manifest.get("artifacts")
        if not isinstance(records, list):
            raise ValueError("artifact manifest lacks artifact records")
        recorded_paths = [
            str(record.get("path", ""))
            for record in records
            if isinstance(record, dict)
        ]
        if len(recorded_paths) != len(records) or len(recorded_paths) != len(
            set(recorded_paths)
        ):
            raise ValueError("artifact manifest paths are absent or duplicated")

        actual_paths = []
        for path in sorted(partial.rglob("*")):
            if path.is_symlink():
                raise ValueError("artifact tree contains a symbolic link")
            if path.is_file() and path != manifest_path:
                actual_paths.append(_safe_relative_path(path, partial))
        if set(recorded_paths) != set(actual_paths):
            raise ValueError("artifact manifest does not match the exact artifact path set")

        for record in records:
            if not isinstance(record, dict):
                raise ValueError("artifact manifest record is not an object")
            relative = Path(str(record["path"]))
            cursor = partial
            for component in relative.parts:
                cursor = cursor / component
                if cursor.is_symlink():
                    raise ValueError("artifact path traverses a symbolic link")
            if not cursor.is_file():
                raise ValueError("artifact manifest references a non-file")
            payload = cursor.read_bytes()
            if (
                len(payload) != record.get("size_bytes")
                or hashlib.sha256(payload).hexdigest() != record.get("sha256")
            ):
                raise ValueError("artifact bytes changed before publish")
            metadata = os.stat(cursor, follow_symlinks=False)
            if metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
                raise ValueError("artifact file is writable during finalization")
            if not metadata.st_flags & stat.UF_IMMUTABLE:
                raise ValueError("artifact file is not immutable during finalization")

        manifest_metadata = os.stat(manifest_path, follow_symlinks=False)
        if manifest_metadata.st_mode & (
            stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
        ):
            raise ValueError("artifact manifest is writable during finalization")
        if not manifest_metadata.st_flags & stat.UF_IMMUTABLE:
            raise ValueError("artifact manifest is not immutable during finalization")
        directories = [partial, *(path for path in partial.rglob("*") if path.is_dir())]
        for directory in directories:
            mode = os.stat(directory, follow_symlinks=False).st_mode
            if mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
                raise ValueError("artifact directory is writable during finalization")
            flags = os.stat(directory, follow_symlinks=False).st_flags
            if require_directory_immutable and not flags & stat.UF_IMMUTABLE:
                raise ValueError("published artifact directory is not immutable")

    def _load_checkpoint(
        self,
        resume_from: Path,
        configuration_sha256: str,
        expected_case_ids: Set[str],
    ) -> Dict[str, Dict[str, object]]:
        checkpoint = read_json(resume_from / "checkpoint.json")
        if checkpoint.get("checkpoint_sha256") != manifest_sha256(
            checkpoint,
            "checkpoint_sha256",
        ):
            raise ValueError("resume checkpoint hash mismatch")
        if checkpoint.get("run_id") != self.run_id:
            raise ValueError("resume checkpoint run ID mismatch")
        if checkpoint.get("configuration_sha256") != configuration_sha256:
            raise ValueError("resume checkpoint configuration mismatch")
        completed = checkpoint.get("completed")
        if not isinstance(completed, dict) or not set(completed).issubset(expected_case_ids):
            raise ValueError("resume checkpoint contains an invalid case set")
        for case_id, result in completed.items():
            if not isinstance(result, dict) or result.get("status") != "pass":
                raise ValueError(f"resume checkpoint case {case_id} is invalid")
        return dict(completed)

    def _write_checkpoint(
        self,
        partial: Path,
        configuration_sha256: str,
        completed: Mapping[str, object],
    ) -> None:
        checkpoint = {
            "schema_version": "1.0.0",
            "run_id": self.run_id,
            "configuration_sha256": configuration_sha256,
            "completed": completed,
        }
        checkpoint["checkpoint_sha256"] = manifest_sha256(
            checkpoint,
            "checkpoint_sha256",
        )
        write_json(partial / "checkpoint.json", checkpoint)

    def run(
        self,
        *,
        resume_from: Optional[Path] = None,
        fail_after_cases: Optional[int] = None,
    ) -> Path:
        if fail_after_cases is not None and fail_after_cases <= 0:
            raise ValueError("fail_after_cases must be positive")
        self.candidate_adapter.validate_configuration()
        self.output_root.mkdir(parents=True, exist_ok=True)
        partial = self.output_root / f".{self.run_id}.partial"
        final = self.output_root / self.run_id
        if final.exists():
            raise FileExistsError("run ID already has a final directory")
        if partial.exists():
            failure_path = self._preserve_failure(
                partial,
                RuntimeError("recovered an interrupted process from its partial directory"),
            )
            raise ProductionDryRunInterrupted(
                "recovered an interrupted process from its partial directory",
                failure_path,
            )
        partial.mkdir()

        try:
            validated_inputs = self._read_and_validate_inputs()
            (
                corpus,
                sample_lock,
                metric_policy,
                degradation_policy,
                samples,
                metric_conformance,
                degradation_conformance,
                codec,
            ) = validated_inputs
            codec_report = codec["report"]
            codec_binding = codec["binding"]

            spatial_profiles = [
                profile
                for profile in degradation_policy["profiles"]
                if profile["kind"] != "synthetic_motion"
            ]
            profiles_by_route = {
                route: [
                    profile
                    for profile in spatial_profiles
                    if profile.get("target_route") == route
                ]
                for route in ("direct-2x", "direct-3over2")
            }
            if any(len(profiles) != 3 for profiles in profiles_by_route.values()):
                raise ValueError("each production route must have exactly three profiles")
            writer_profiles_by_route = _common_writer_profiles(degradation_policy)
            sample_routes = {
                sample["source_asset_id"]: sample["target_route"]
                for sample in sample_lock["samples"]
            }
            if set(sample_routes.values()) != {"direct-2x", "direct-3over2"}:
                raise ValueError("production development samples must execute both routes")
            all_profiles_by_route = {
                route: profiles_by_route[route] + [writer_profiles_by_route[route]]
                for route in ("direct-2x", "direct-3over2")
            }
            observed_profile_ids = sorted(
                {
                    str(profile["id"])
                    for profiles in all_profiles_by_route.values()
                    for profile in profiles
                }
            )
            if len(observed_profile_ids) != 8:
                raise ValueError("production dry run requires exactly eight degradation profiles")

            writer_id = "apple-h264-software-common-writer-v1"
            production_writer_id = "mirmir-product-hevc-avassetwriter-v1"
            product_settings_binding = {
                "path": "Mirmir/Modules/MediaPipeline/MediaTypes.swift",
                **_file_binding(PRODUCT_MEDIA_TYPES_PATH),
            }
            metric_policy_path = self.quality_root / "policies" / "metric-policy.json"
            metric_vectors_path = (
                self.quality_root / "reference" / "metric-vectors-v1.json"
            )
            metric_policy_source = {
                "path": "policies/metric-policy.json",
                **_file_binding(metric_policy_path),
            }
            metric_vectors_source = {
                "path": "reference/metric-vectors-v1.json",
                **_file_binding(metric_vectors_path),
            }
            validated_corpus_bytes = canonical_json_bytes(corpus) + b"\n"
            corpus_lock_source = {
                "sha256": hashlib.sha256(validated_corpus_bytes).hexdigest(),
                "size_bytes": len(validated_corpus_bytes),
            }
            configuration = {
                "candidate_id": self.candidate_adapter.candidate_id,
                "candidate_configuration_sha256": (
                    self.candidate_adapter.configuration_sha256
                ),
                "candidate_input_pixel_representation": (
                    ENGINE_RAW_PIXEL_REPRESENTATION
                ),
                "baseline": "nearest-neighbor-v1",
                "common_writer_id": writer_id,
                "production_output_writer_id": production_writer_id,
                "product_settings_source": product_settings_binding,
                "common_writer_profiles": [
                    writer_profiles_by_route[route]
                    for route in ("direct-2x", "direct-3over2")
                ],
                "corpus_manifest_sha256": corpus["manifest_sha256"],
                "corpus_lock_source": corpus_lock_source,
                "sample_manifest_sha256": sample_lock["manifest_sha256"],
                "metric_policy_sha256": metric_policy["policy_sha256"],
                "metric_policy_source": metric_policy_source,
                "metric_vectors_source": metric_vectors_source,
                "degradation_policy_sha256": degradation_policy["policy_sha256"],
                "actual_codec_fixture_evidence_sha256": codec_binding["evidence"][
                    "sha256"
                ],
            }
            configuration_sha256 = canonical_sha256(configuration)

            configuration_inputs_path = partial / "configuration-inputs.json"
            configuration_inputs = {
                "schema_version": "1.0.0",
                "configuration_sha256": configuration_sha256,
                "configuration": configuration,
            }
            write_json(configuration_inputs_path, configuration_inputs)
            configuration_inputs_binding = {
                "path": _safe_relative_path(configuration_inputs_path, partial),
                **_file_binding(configuration_inputs_path),
            }
            corpus_lock_evidence_path = partial / "corpus-lock.json"
            corpus_lock_evidence_path.write_bytes(validated_corpus_bytes)
            corpus_lock_evidence = {
                "path": _safe_relative_path(corpus_lock_evidence_path, partial),
                **_file_binding(corpus_lock_evidence_path),
            }
            if (
                corpus_lock_evidence["sha256"] != corpus_lock_source["sha256"]
                or corpus_lock_evidence["size_bytes"]
                != corpus_lock_source["size_bytes"]
            ):
                raise ValueError("preserved corpus lock binding mismatch")
            write_json(partial / "development-sample-lock.json", sample_lock)
            write_json(partial / "degradation-lock.json", degradation_policy)
            metric_inputs = partial / "metric-inputs"
            metric_inputs.mkdir()
            metric_policy_evidence_path = metric_inputs / "metric-policy.json"
            metric_vectors_evidence_path = metric_inputs / "metric-vectors-v1.json"
            metric_policy_evidence_path.write_bytes(metric_policy_path.read_bytes())
            metric_vectors_evidence_path.write_bytes(metric_vectors_path.read_bytes())
            metric_policy_evidence = {
                "path": _safe_relative_path(metric_policy_evidence_path, partial),
                **_file_binding(metric_policy_evidence_path),
            }
            metric_vectors_evidence = {
                "path": _safe_relative_path(metric_vectors_evidence_path, partial),
                **_file_binding(metric_vectors_evidence_path),
            }
            if (
                metric_policy_evidence["sha256"] != metric_policy_source["sha256"]
                or metric_policy_evidence["size_bytes"]
                != metric_policy_source["size_bytes"]
                or metric_vectors_evidence["sha256"]
                != metric_vectors_source["sha256"]
                or metric_vectors_evidence["size_bytes"]
                != metric_vectors_source["size_bytes"]
            ):
                raise ValueError("preserved metric input binding mismatch")
            write_json(partial / "metric-conformance.json", metric_conformance)
            write_json(
                partial / "degradation-conformance.json",
                degradation_conformance,
            )
            write_json(partial / "actual-codec-evidence.json", codec_report)
            write_json(partial / "actual-codec-source-lock.json", codec["source_lock"])
            settings_evidence_path = (
                partial / "product-settings-source" / "MediaTypes.swift"
            )
            settings_evidence_path.parent.mkdir(parents=True)
            settings_evidence_path.write_bytes(PRODUCT_MEDIA_TYPES_PATH.read_bytes())
            product_settings_evidence = {
                "path": _safe_relative_path(settings_evidence_path, partial),
                **_file_binding(settings_evidence_path),
            }
            if (
                product_settings_evidence["sha256"]
                != product_settings_binding["sha256"]
                or product_settings_evidence["size_bytes"]
                != product_settings_binding["size_bytes"]
            ):
                raise ValueError("preserved product settings source binding mismatch")
            write_json(
                partial / "scope.json",
                {
                    "schema_version": "1.0.0",
                    "purpose": "production-locked development harness dry run",
                    "candidate_id": self.candidate_adapter.candidate_id,
                    "candidate_configuration": self.candidate_adapter.configuration,
                    "candidate_configuration_sha256": (
                        self.candidate_adapter.configuration_sha256
                    ),
                    "candidate_input_pixel_representation": (
                        ENGINE_RAW_PIXEL_REPRESENTATION
                    ),
                    "baseline_id": "nearest-neighbor-v1",
                    "common_writer_id": writer_id,
                    "production_output_writer_id": production_writer_id,
                    "product_settings_source": product_settings_binding,
                    "product_settings_evidence": product_settings_evidence,
                    "actual_codec_fixture_role": "codec conformance only",
                    "postencode_metric_container_scope": (
                        "one case per product-settings HEVC container"
                    ),
                    "postencode_smoke_batch_executed": False,
                    "algorithm_quality_claimed": False,
                    "mp4_byte_identity_across_runs_claimed": False,
                    "holdout_accessed": False,
                },
            )

            executable = self.common_writer_executable
            if executable is None:
                executable = compile_common_writer(
                    partial / "common-writer-build" / "common-writer"
                )
            elif not executable.is_file() or not os.access(executable, os.X_OK):
                raise ValueError("injected common-writer executable is absent or not executable")
            production_executable = self.production_writer_executable
            if production_executable is None:
                production_executable = compile_production_writer(
                    partial / "production-writer-build" / "production-writer"
                )
            elif not production_executable.is_file() or not os.access(
                production_executable,
                os.X_OK,
            ):
                raise ValueError(
                    "injected production-writer executable is absent or not executable"
                )

            source_profile_by_id = {
                str(profile["id"]): profile for profile in spatial_profiles
            }
            low_resolution_by_case: Dict[str, PlanarFrame] = {}
            target_by_case: Dict[str, PlanarFrame] = {}
            asset_by_case: Dict[str, Mapping[str, object]] = {}
            profile_by_case: Dict[str, Mapping[str, object]] = {}
            writer_runs: List[Dict[str, object]] = []

            for asset, target in samples:
                route = sample_routes[asset["source_asset_id"]]
                for profile in profiles_by_route[route]:
                    case_id = f"{asset['source_asset_id']}::{profile['id']}"
                    low_resolution_by_case[case_id] = apply_degradation(target, profile)
                    target_by_case[case_id] = target
                    asset_by_case[case_id] = asset
                    profile_by_case[case_id] = profile

            for route in ("direct-2x", "direct-3over2"):
                writer_profile = writer_profiles_by_route[route]
                source_profile_id = str(writer_profile["source_profile_id"])
                source_profile = source_profile_by_id[source_profile_id]
                route_inputs = sorted(
                    (
                        f"{asset['source_asset_id']}::{writer_profile['id']}",
                        asset,
                        target,
                    )
                    for asset, target in samples
                    if sample_routes[asset["source_asset_id"]] == route
                )
                if not route_inputs:
                    raise ValueError("common-writer route has no development sources")
                source_frames = [
                    apply_degradation(target, source_profile)
                    for _, _, target in route_inputs
                ]
                geometry = {frame.y.shape for frame in source_frames}
                if len(geometry) != 1:
                    raise ValueError("common-writer LR batch contains mixed geometry")
                lr_height, lr_width = next(iter(geometry))
                common_frames = tuple(
                    CommonWriterInputFrame(
                        case_id=case_id,
                        nv12=_planar_to_video_range_nv12(frame),
                        presentation_time=RationalTime(index * 20, 600),
                        duration=RationalTime(20, 600),
                    )
                    for index, ((case_id, _, _), frame) in enumerate(
                        zip(route_inputs, source_frames)
                    )
                )
                writer_result = run_common_writer(
                    frames=common_frames,
                    width=lr_width,
                    height=lr_height,
                    output_directory=partial / "common-writer" / f"lr-{route}",
                    source_id=f"{self.run_id}-lr-{route}",
                    output_name=f"lr-{route}",
                    executable=executable,
                )
                ordered_ids = [case_id for case_id, _, _ in route_inputs]
                writer_runs.append(
                    _verify_common_writer_result(
                        writer_result,
                        expected_case_ids=ordered_ids,
                        width=lr_width,
                        height=lr_height,
                        writer_id=writer_id,
                        run_root=partial,
                        purpose="low_resolution_degradation",
                        profile_id=str(writer_profile["id"]),
                        target_route=route,
                        source_profile_id=source_profile_id,
                    )
                )
                for (case_id, asset, target), payload in zip(
                    route_inputs,
                    writer_result.decoded_frames,
                ):
                    low_resolution_by_case[case_id] = _video_range_nv12_to_planar(
                        payload,
                        width=lr_width,
                        height=lr_height,
                    )
                    target_by_case[case_id] = target
                    asset_by_case[case_id] = asset
                    profile_by_case[case_id] = writer_profile

            expected_order = sorted(low_resolution_by_case)
            expected_case_ids = set(expected_order)
            if (
                len(expected_order) != 24
                or len(target_by_case) != 24
                or len(asset_by_case) != 24
                or len(profile_by_case) != 24
            ):
                raise ValueError("production development case coverage is not exactly 24")

            recomputed_results: Dict[str, Dict[str, object]] = {}
            candidate_frames: Dict[str, PlanarFrame] = {}
            for case_id in expected_order:
                result, candidate_frame = _case_result(
                    asset_by_case[case_id],
                    target_by_case[case_id],
                    profile_by_case[case_id],
                    low_resolution_by_case[case_id],
                    self.candidate_adapter,
                )
                if result["case_id"] != case_id:
                    raise ValueError("candidate result case ID mismatch")
                recomputed_results[case_id] = result
                candidate_frames[case_id] = candidate_frame

            target_geometries = {frame.y.shape for frame in candidate_frames.values()}
            if target_geometries != {(192, 324)}:
                raise ValueError("candidate postencode cases must be exactly 324x192")
            candidate_writer_frames = tuple(
                CommonWriterInputFrame(
                    case_id=case_id,
                    nv12=_planar_to_video_range_nv12(candidate_frames[case_id]),
                    presentation_time=RationalTime(index * 20, 600),
                    duration=RationalTime(20, 600),
                )
                for index, case_id in enumerate(expected_order)
            )
            isolated_writer_results = run_isolated_production_writer_cases(
                frames=candidate_writer_frames,
                width=324,
                height=192,
                output_directory=(
                    partial / "production-writer" / "candidate-postencode-isolated"
                ),
                source_id=f"{self.run_id}-candidate-postencode-isolated",
                executable=production_executable,
            )
            if [item.case_id for item in isolated_writer_results] != expected_order:
                raise ValueError("isolated production-writer case order mismatch")
            expected_product_attachments = _expected_product_attachments(sample_lock)
            isolated_decoded_by_case: Dict[str, bytes] = {}
            for isolated in isolated_writer_results:
                result = isolated.result
                if isolated.case_id in isolated_decoded_by_case:
                    raise ValueError("isolated production-writer case ID is duplicated")
                writer_runs.append(
                    _verify_production_writer_result(
                        result,
                        expected_case_ids=[isolated.case_id],
                        expected_attachments=expected_product_attachments,
                        expected_settings_binding=product_settings_binding,
                        run_root=partial,
                        metric_eligible=True,
                    )
                )
                if len(result.decoded_frames) != 1:
                    raise ValueError(
                        "isolated production-writer result does not contain one frame"
                    )
                isolated_decoded_by_case[isolated.case_id] = result.decoded_frames[0]
            if set(isolated_decoded_by_case) != expected_case_ids:
                raise ValueError("isolated production-writer case coverage is incomplete")
            if len(writer_runs) != 26:
                raise ValueError("writer evidence does not contain 24 isolated containers")
            container_results = [
                _container_result(
                    recomputed_results[case_id],
                    target_by_case[case_id],
                    candidate_frames[case_id],
                    isolated_decoded_by_case[case_id],
                )
                for case_id in expected_order
            ]
            if (
                [result["case_id"] for result in container_results] != expected_order
                or [result["source_asset_id"] for result in container_results]
                != [recomputed_results[case_id]["source_asset_id"] for case_id in expected_order]
                or [result["degradation_profile"] for result in container_results]
                != [
                    recomputed_results[case_id]["degradation_profile"]
                    for case_id in expected_order
                ]
            ):
                raise ValueError("engine and container quality rows are not one-to-one ordered")

            input_bindings = {
                "schema_version": "1.0.0",
                "configuration_inputs": configuration_inputs_binding,
                "corpus_lock": corpus_lock_source,
                "corpus_lock_evidence": corpus_lock_evidence,
                "development_sample_lock": _file_binding(
                    self.development_sample_lock_path
                ),
                "development_and_validation_media_rehashed": True,
                "all_split_evidence_rehashed": True,
                "holdout_media_rehashed": False,
                "holdout_accessed": False,
                "actual_codec_fixture_conformance": codec_binding,
                "common_writer_id": writer_id,
                "production_output_writer_id": production_writer_id,
                "product_settings_source": product_settings_binding,
                "product_settings_evidence": product_settings_evidence,
                "metric_policy_source": metric_policy_source,
                "metric_policy_evidence": metric_policy_evidence,
                "metric_vectors_source": metric_vectors_source,
                "metric_vectors_evidence": metric_vectors_evidence,
                "common_writer_runs": writer_runs,
            }
            write_json(partial / "input-bindings.json", input_bindings)

            completed: Dict[str, Dict[str, object]] = {}
            resumed = resume_from is not None
            if resume_from is not None:
                completed = self._load_checkpoint(
                    resume_from,
                    configuration_sha256,
                    expected_case_ids,
                )
                for case_id, result in completed.items():
                    if result != recomputed_results[case_id]:
                        raise ValueError("resume checkpoint result does not reproduce")

            for case_id in expected_order:
                if case_id in completed:
                    continue
                completed[case_id] = recomputed_results[case_id]
                self._write_checkpoint(
                    partial,
                    configuration_sha256,
                    completed,
                )
                if (
                    fail_after_cases is not None
                    and len(completed) >= fail_after_cases
                ):
                    raise RuntimeError(
                        "injected production development dry-run interruption"
                    )

            if set(completed) != expected_case_ids:
                raise ValueError("production development case coverage is incomplete")
            engine_results = [completed[key] for key in expected_order]
            bootstrap_records = []
            for result in engine_results:
                candidate_psnr = result["metrics"]["candidate"]["channel_psnr"][
                    "Y"
                ]["value"]
                nearest_psnr = result["metrics"]["nearest_baseline"][
                    "channel_psnr"
                ]["Y"]["value"]
                if candidate_psnr is None or nearest_psnr is None:
                    raise ValueError("source-asset bootstrap requires finite Y PSNR")
                bootstrap_records.append(
                    {
                        "source_asset_id": result["source_asset_id"],
                        "candidate": candidate_psnr,
                        "baseline": nearest_psnr,
                        "categories": result["categories"],
                    }
                )
            bootstrap = paired_bootstrap(bootstrap_records)
            if bootstrap["asset_count"] != 6:
                raise ValueError("source-asset bootstrap does not cover six sources")
            write_json(partial / "paired-bootstrap-engine-raw.json", bootstrap)

            engine_quality = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "configuration_sha256": configuration_sha256,
                "corpus_manifest_sha256": corpus["manifest_sha256"],
                "split": "development",
                "comparison_domain": "engine_raw",
                "asset_results": engine_results,
                "status": "pass",
                "holdout_opened_utc": None,
                "configuration_files_modified_after_holdout": False,
            }
            container_quality = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "configuration_sha256": configuration_sha256,
                "corpus_manifest_sha256": corpus["manifest_sha256"],
                "split": "development",
                "comparison_domain": "container_decoded",
                "asset_results": container_results,
                "status": "pass",
                "holdout_opened_utc": None,
                "configuration_files_modified_after_holdout": False,
            }
            validate_schema(
                engine_quality,
                self.schemas / "quality-result.schema.json",
            )
            validate_schema(
                container_quality,
                self.schemas / "quality-result.schema.json",
            )
            write_json(
                partial / "quality-result-engine-raw.json",
                engine_quality,
            )
            write_json(
                partial / "quality-result-container-decoded.json",
                container_quality,
            )

            engine_order = [result["case_id"] for result in engine_results]
            container_order = [result["case_id"] for result in container_results]
            if engine_order != expected_order or container_order != expected_order:
                raise ValueError("final comparison-domain case order mismatch")
            self.candidate_adapter.validate_configuration()
            if product_settings_binding != {
                "path": "Mirmir/Modules/MediaPipeline/MediaTypes.swift",
                **_file_binding(PRODUCT_MEDIA_TYPES_PATH),
            }:
                raise ValueError("shared product settings changed before finalization")
            benchmark = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "split": "development",
                "corpus_mode": "production_locked",
                "configuration_sha256": configuration_sha256,
                "corpus_manifest_sha256": corpus["manifest_sha256"],
                "sample_manifest_sha256": sample_lock["manifest_sha256"],
                "development_source_asset_count": 6,
                "candidate_id": self.candidate_adapter.candidate_id,
                "candidate_configuration_sha256": (
                    self.candidate_adapter.configuration_sha256
                ),
                "candidate_input_pixel_representation": (
                    ENGINE_RAW_PIXEL_REPRESENTATION
                ),
                "baseline_id": "nearest-neighbor-v1",
                "degradation_policy_sha256": degradation_policy["policy_sha256"],
                "degradation_profile_ids": observed_profile_ids,
                "metric_policy_sha256": metric_policy["policy_sha256"],
                "case_count": 24,
                "completed_case_count": len(engine_results),
                "resumed_from_failure": resumed,
                "resume_checkpoint_semantics": (
                    "recomputed" if resumed else "not_applicable"
                ),
                "actual_codec_fixture_reverified": True,
                "postencode_results_recomputed": True,
                "postencode_isolation_mode": (
                    "one-case-per-product-hevc-container"
                ),
                "postencode_isolated_container_count": 24,
                "postencode_metric_rows_from_isolated_containers": True,
                "postencode_smoke_batch_executed": False,
                "stale_partial_preservation_enabled": True,
                "artifact_semantic_reverification": True,
                "artifact_publish_freeze": (
                    "detached owner-read-only immutable inodes before hashing and "
                    "atomic rename"
                ),
                "published_directory_immutable": True,
                "fixture_dimensions": {"width": 324, "height": 192},
                "routes_executed": ["direct-2x", "direct-3over2"],
                "comparison_domains_executed": [
                    "engine_raw",
                    "container_decoded",
                ],
                "actual_codec_fixture_used": True,
                "actual_codec_fixture_conformance_only": True,
                "actual_codec_fixture_id": codec_report["fixture_id"],
                "actual_codec_fixture_evidence_sha256": codec_binding["evidence"][
                    "sha256"
                ],
                "common_writer_id": writer_id,
                "production_output_writer_id": production_writer_id,
                "product_settings_source": product_settings_binding,
                "product_settings_evidence": product_settings_evidence,
                "common_writer_runs": writer_runs,
                "low_resolution_actual_codec_frame_count": sum(
                    int(run["frame_count"])
                    for run in writer_runs
                    if run["purpose"] == "low_resolution_degradation"
                ),
                "engine_raw_frame_count": 24,
                "container_decoded_frame_count": 24,
                "engine_raw_result": {
                    "path": "quality-result-engine-raw.json",
                    **_file_binding(partial / "quality-result-engine-raw.json"),
                },
                "container_decoded_result": {
                    "path": "quality-result-container-decoded.json",
                    **_file_binding(
                        partial / "quality-result-container-decoded.json"
                    ),
                },
                "comparison_case_order_sha256": canonical_sha256(expected_order),
                "mp4_byte_identity_across_runs_claimed": False,
                "holdout_accessed": False,
                "gate_interpretation": (
                    "harness integrity pass; no algorithm-quality claim"
                ),
                "gate_status": "pass",
                "status": "pass",
            }
            validate_schema(
                benchmark,
                self.schemas / "benchmark-dry-run.schema.json",
            )
            write_json(partial / "benchmark-dry-run.json", benchmark)

            self._revalidate_inputs_before_publish(validated_inputs)
            self.candidate_adapter.validate_configuration()
            if read_json(configuration_inputs_path) != configuration_inputs or (
                configuration_inputs_binding
                != {
                "path": _safe_relative_path(configuration_inputs_path, partial),
                **_file_binding(configuration_inputs_path),
                }
            ):
                raise ValueError("preserved configuration inputs changed before publish")
            if (
                corpus_lock_evidence_path.read_bytes() != validated_corpus_bytes
                or corpus_lock_evidence != {
                    "path": _safe_relative_path(corpus_lock_evidence_path, partial),
                    **_file_binding(corpus_lock_evidence_path),
                }
            ):
                raise ValueError("preserved corpus lock changed before publish")
            if product_settings_binding != {
                "path": "Mirmir/Modules/MediaPipeline/MediaTypes.swift",
                **_file_binding(PRODUCT_MEDIA_TYPES_PATH),
            } or product_settings_evidence != {
                "path": _safe_relative_path(settings_evidence_path, partial),
                **_file_binding(settings_evidence_path),
            }:
                raise ValueError("product settings changed before publish")
            if metric_policy_source != {
                "path": "policies/metric-policy.json",
                **_file_binding(metric_policy_path),
            } or metric_policy_evidence != {
                "path": _safe_relative_path(metric_policy_evidence_path, partial),
                **_file_binding(metric_policy_evidence_path),
            }:
                raise ValueError("metric policy changed before publish")
            if metric_vectors_source != {
                "path": "reference/metric-vectors-v1.json",
                **_file_binding(metric_vectors_path),
            } or metric_vectors_evidence != {
                "path": _safe_relative_path(metric_vectors_evidence_path, partial),
                **_file_binding(metric_vectors_evidence_path),
            }:
                raise ValueError("metric vectors changed before publish")

            semantic_snapshot = {
                "benchmark": benchmark,
                "engine_quality": engine_quality,
                "container_quality": container_quality,
                "bootstrap": bootstrap,
                "configuration_inputs": configuration_inputs,
                "input_bindings": input_bindings,
                "completed": completed,
                "expected_order": expected_order,
                "sample_lock": sample_lock,
                "preserved_documents": {
                    "corpus-lock.json": corpus,
                    "development-sample-lock.json": sample_lock,
                    "degradation-lock.json": degradation_policy,
                    "metric-inputs/metric-policy.json": metric_policy,
                    "metric-inputs/metric-vectors-v1.json": read_json(
                        metric_vectors_path
                    ),
                    "metric-conformance.json": metric_conformance,
                    "degradation-conformance.json": degradation_conformance,
                    "actual-codec-evidence.json": codec_report,
                    "actual-codec-source-lock.json": codec["source_lock"],
                },
            }

            manifest_path = partial / "artifact-manifest.json"
            if manifest_path.exists():
                raise FileExistsError("artifact manifest path already exists")
            _detach_and_freeze_artifact_files(partial)
            artifacts = []
            for path in sorted(partial.rglob("*")):
                if path.is_symlink():
                    raise ValueError("artifact tree contains a symbolic link")
                if path.is_file() and path != manifest_path:
                    content = path.read_bytes()
                    artifacts.append(
                        {
                            "path": _safe_relative_path(path, partial),
                            "sha256": hashlib.sha256(content).hexdigest(),
                            "size_bytes": len(content),
                        }
                    )
            artifact_manifest = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "artifacts": artifacts,
            }
            artifact_manifest["manifest_sha256"] = manifest_sha256(
                artifact_manifest
            )
            validate_schema(
                artifact_manifest,
                self.schemas / "artifact-manifest.schema.json",
            )
            _replace_with_new_immutable_inode(
                manifest_path,
                canonical_json_bytes(artifact_manifest) + b"\n",
            )
            _make_artifact_directories_read_only(partial)
            self._verify_artifact_semantics(
                partial,
                expected=semantic_snapshot,
            )
            self._verify_artifacts_before_publish(partial)
            os.replace(partial, final)
            _seal_published_directories(final)
            self._verify_artifacts_before_publish(
                final,
                require_directory_immutable=True,
            )
            self._verify_artifact_semantics(
                final,
                expected=semantic_snapshot,
            )
            return final
        except BaseException as error:
            if partial.exists():
                _thaw_artifact_tree(partial)
                failure_path = self._preserve_failure(partial, error)
                raise ProductionDryRunInterrupted(str(error), failure_path) from error
            if final.exists():
                _thaw_artifact_tree(final)
                failure_path = self._preserve_failure(final, error)
                raise ProductionDryRunInterrupted(str(error), failure_path) from error
            raise
