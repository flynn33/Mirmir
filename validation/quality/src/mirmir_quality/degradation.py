"""Deterministic development degradations with explicit serialized parameters."""

from __future__ import annotations

import hashlib
import math
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from .arrays import (
    PlanarFrame,
    bilinear_sample_reflect101,
    frame_sha256,
    resize_bilinear,
    separable_convolve_reflect101,
)


def _decimate_plane(image: np.ndarray, kernel: Sequence[float], factor: int, phase: int) -> np.ndarray:
    if factor <= 0 or phase < 0 or phase >= factor:
        raise ValueError("invalid decimation factor or phase")
    filtered = separable_convolve_reflect101(image, kernel)
    return filtered[phase::factor, phase::factor]


def _rational_resample_plane(
    image: np.ndarray,
    kernel: Sequence[float],
    numerator: int,
    denominator: int,
) -> np.ndarray:
    if numerator <= 0 or denominator <= numerator:
        raise ValueError("rational reduction must satisfy 0 < numerator < denominator")
    source = np.asarray(image, dtype=np.float64)
    scaled_height = source.shape[0] * numerator
    scaled_width = source.shape[1] * numerator
    if scaled_height % denominator != 0 or scaled_width % denominator != 0:
        raise ValueError("source geometry is not exactly divisible by the rational reduction")
    filtered = separable_convolve_reflect101(source, kernel)
    return resize_bilinear(
        filtered,
        (scaled_height // denominator, scaled_width // denominator),
    )


def _reduce_plane(
    image: np.ndarray,
    kernel: Sequence[float],
    profile: Mapping[str, object],
) -> np.ndarray:
    if "output_scale_numerator" in profile or "output_scale_denominator" in profile:
        return _rational_resample_plane(
            image,
            kernel,
            int(profile["output_scale_numerator"]),
            int(profile["output_scale_denominator"]),
        )
    return _decimate_plane(
        image,
        kernel,
        int(profile["decimation_factor"]),
        int(profile["phase"]),
    )


def _quantize_plane(image: np.ndarray, levels: int, *, centered: bool) -> np.ndarray:
    if levels <= 1:
        raise ValueError("quantization levels must exceed one")
    values = np.asarray(image, dtype=np.float64)
    if centered:
        values = values + 0.5
    values = np.rint(np.clip(values, 0.0, 1.0) * (levels - 1)) / (levels - 1)
    return values - 0.5 if centered else values


def _dct_matrix(size: int) -> np.ndarray:
    matrix = np.empty((size, size), dtype=np.float64)
    scale0 = math.sqrt(1.0 / size)
    scale = math.sqrt(2.0 / size)
    for frequency in range(size):
        coefficient = scale0 if frequency == 0 else scale
        for position in range(size):
            matrix[frequency, position] = coefficient * math.cos(
                math.pi * (2 * position + 1) * frequency / (2 * size)
            )
    return matrix


def _block_dct_quantize(image: np.ndarray, block_size: int, step: float) -> np.ndarray:
    if block_size <= 0 or step <= 0.0:
        raise ValueError("DCT block size and quantization step must be positive")
    source = np.asarray(image, dtype=np.float64)
    pad_height = (-source.shape[0]) % block_size
    pad_width = (-source.shape[1]) % block_size
    padded = np.pad(source, ((0, pad_height), (0, pad_width)), mode="reflect")
    output = np.empty_like(padded)
    transform = _dct_matrix(block_size)
    for row in range(0, padded.shape[0], block_size):
        for column in range(0, padded.shape[1], block_size):
            block = padded[row : row + block_size, column : column + block_size]
            coefficients = np.einsum(
                "ux,xy,vy->uv",
                transform,
                block,
                transform,
                optimize=False,
            )
            coefficients = np.rint(coefficients / step) * step
            output[row : row + block_size, column : column + block_size] = np.einsum(
                "ux,uv,vy->xy",
                transform,
                coefficients,
                transform,
                optimize=False,
            )
    return output[: source.shape[0], : source.shape[1]]


def _apply_lowpass(frame: PlanarFrame, profile: Mapping[str, object]) -> PlanarFrame:
    kernel = tuple(float(value) for value in profile["kernel"])
    quantization_levels = int(profile["output_quantization_levels"])
    return PlanarFrame(
        y=_quantize_plane(
            _reduce_plane(frame.y, kernel, profile),
            quantization_levels,
            centered=False,
        ),
        cb=_quantize_plane(
            _reduce_plane(frame.cb, kernel, profile),
            quantization_levels,
            centered=True,
        ),
        cr=_quantize_plane(
            _reduce_plane(frame.cr, kernel, profile),
            quantization_levels,
            centered=True,
        ),
    )


def _apply_codec_proxy(frame: PlanarFrame, profile: Mapping[str, object]) -> PlanarFrame:
    low_resolution = _apply_lowpass(frame, profile)
    block_size = int(profile["block_size"])
    step = float(profile["coefficient_step"])
    levels = int(profile["output_quantization_levels"])
    return PlanarFrame(
        y=_quantize_plane(
            np.clip(_block_dct_quantize(low_resolution.y, block_size, step), 0.0, 1.0),
            levels,
            centered=False,
        ),
        cb=_quantize_plane(
            np.clip(
                _block_dct_quantize(low_resolution.cb + 0.5, block_size, step),
                0.0,
                1.0,
            )
            - 0.5,
            levels,
            centered=True,
        ),
        cr=_quantize_plane(
            np.clip(
                _block_dct_quantize(low_resolution.cr + 0.5, block_size, step),
                0.0,
                1.0,
            )
            - 0.5,
            levels,
            centered=True,
        ),
    )


def apply_degradation(frame: PlanarFrame, profile: Mapping[str, object]) -> PlanarFrame:
    """Apply one serialized spatial development profile."""

    kind = profile.get("kind")
    if kind in {"lowpass_decimate", "camera_blur_decimate"}:
        return _apply_lowpass(frame, profile)
    if kind == "codec_quantized_proxy":
        return _apply_codec_proxy(frame, profile)
    raise ValueError(f"unsupported spatial degradation kind: {kind}")


def _warp_plane(
    image: np.ndarray,
    translation: Tuple[float, float],
    rotation_degrees: float,
) -> np.ndarray:
    height, width = image.shape
    yy, xx = np.indices((height, width), dtype=np.float64)
    center_x = (width - 1) / 2.0
    center_y = (height - 1) / 2.0
    angle = math.radians(rotation_degrees)
    cosine = math.cos(angle)
    sine = math.sin(angle)
    shifted_x = xx - center_x - translation[0]
    shifted_y = yy - center_y - translation[1]
    source_x = cosine * shifted_x + sine * shifted_y + center_x
    source_y = -sine * shifted_x + cosine * shifted_y + center_y
    return bilinear_sample_reflect101(image, source_x, source_y)


def _mask_sha256(mask: np.ndarray) -> str:
    values = np.asarray(mask, dtype=bool)
    digest = hashlib.sha256()
    digest.update(b"MIRMIR-BINARY-MASK-V1\0")
    digest.update(int(values.shape[0]).to_bytes(4, "big"))
    digest.update(int(values.shape[1]).to_bytes(4, "big"))
    digest.update(np.packbits(values, bitorder="big").tobytes())
    return digest.hexdigest()


def _occluder_mask(
    shape: Tuple[int, int],
    specification: Mapping[str, object],
    object_translation: Sequence[float],
) -> np.ndarray:
    rectangle = specification.get("luma_rectangle")
    if not isinstance(rectangle, list) or len(rectangle) != 4:
        raise ValueError("occluder luma_rectangle must contain x, y, width, and height")
    if len(object_translation) != 2:
        raise ValueError("object translation must contain x and y")
    translation_x = float(object_translation[0])
    translation_y = float(object_translation[1])
    if not translation_x.is_integer() or not translation_y.is_integer():
        raise ValueError("occluder translation must use exact integer pixels")
    x = int(rectangle[0]) + int(translation_x)
    y = int(rectangle[1]) + int(translation_y)
    width = int(rectangle[2])
    height = int(rectangle[3])
    if width <= 0 or height <= 0 or x < 0 or y < 0:
        raise ValueError("occluder rectangle is invalid")
    if x + width > shape[1] or y + height > shape[0]:
        raise ValueError("occluder rectangle leaves the luma extent")
    mask = np.zeros(shape, dtype=bool)
    mask[y : y + height, x : x + width] = True
    return mask


def _scaled_mask(mask: np.ndarray, shape: Tuple[int, int]) -> np.ndarray:
    source_height, source_width = mask.shape
    target_height, target_width = shape
    yy, xx = np.nonzero(mask)
    result = np.zeros(shape, dtype=bool)
    if yy.size == 0:
        return result
    x0 = int(np.floor(float(np.min(xx)) * target_width / source_width))
    x1 = int(np.ceil(float(np.max(xx) + 1) * target_width / source_width))
    y0 = int(np.floor(float(np.min(yy)) * target_height / source_height))
    y1 = int(np.ceil(float(np.max(yy) + 1) * target_height / source_height))
    result[y0:y1, x0:x1] = True
    return result


def _apply_occluder(
    frame: PlanarFrame,
    mask: np.ndarray,
    specification: Mapping[str, object],
) -> PlanarFrame:
    values = specification.get("normalized_values")
    if not isinstance(values, dict):
        raise ValueError("occluder normalized_values are absent")
    y = frame.y.copy()
    cb = frame.cb.copy()
    cr = frame.cr.copy()
    y[mask] = float(values["Y"])
    chroma_mask = _scaled_mask(mask, cb.shape)
    cb[chroma_mask] = float(values["Cb"])
    cr[chroma_mask] = float(values["Cr"])
    return PlanarFrame(y=y, cb=cb, cr=cr)


def synthetic_motion_sequence(
    frame: PlanarFrame,
    profile: Mapping[str, object],
    *,
    alternate_scene: Optional[PlanarFrame] = None,
) -> Tuple[List[PlanarFrame], List[Dict[str, object]]]:
    """Create independent scene-cut and moving-occluder stimuli with exact ledgers."""

    if profile.get("kind") != "synthetic_motion":
        raise ValueError("motion sequence requires a synthetic_motion profile")
    transforms = profile.get("transforms")
    if not isinstance(transforms, list) or not transforms:
        raise ValueError("motion profile must contain transforms")
    occluder = profile.get("occluder")
    if not isinstance(occluder, dict):
        raise ValueError("motion profile must contain an occluder specification")
    if alternate_scene is not None and (
        alternate_scene.y.shape != frame.y.shape
        or alternate_scene.cb.shape != frame.cb.shape
        or alternate_scene.cr.shape != frame.cr.shape
    ):
        raise ValueError("alternate scene geometry must match the primary scene")
    sequence = []
    ledger = []
    previous_camera: Optional[Tuple[float, float, float]] = None
    previous_object: Optional[Tuple[float, float]] = None
    previous_mask: Optional[np.ndarray] = None
    for index, transform in enumerate(transforms):
        scene_cut = bool(transform.get("scene_cut", False))
        scene_source = str(transform.get("scene_source", "primary"))
        if scene_source == "primary":
            source_scene = frame
        elif scene_source == "alternate":
            if alternate_scene is None:
                raise ValueError("alternate scene pixels are required for a scene cut")
            source_scene = alternate_scene
        else:
            raise ValueError("unsupported synthetic scene source")
        if scene_cut and scene_source != "alternate":
            raise ValueError("scene-cut frames must originate from the independent alternate scene")

        translation_values = transform["camera_translation"]
        translation = (float(translation_values[0]), float(translation_values[1]))
        rotation = float(transform["camera_rotation_degrees"])
        chroma_translation = (
            translation[0] * source_scene.cb.shape[1] / source_scene.y.shape[1],
            translation[1] * source_scene.cb.shape[0] / source_scene.y.shape[0],
        )
        warped = PlanarFrame(
            y=_warp_plane(source_scene.y, translation, rotation),
            cb=_warp_plane(source_scene.cb, chroma_translation, rotation),
            cr=_warp_plane(source_scene.cr, chroma_translation, rotation),
        )

        object_values = transform.get("object_translation")
        if object_values is None:
            object_translation = None
            mask = np.zeros(frame.y.shape, dtype=bool)
            rendered = warped
        else:
            object_translation = (float(object_values[0]), float(object_values[1]))
            mask = _occluder_mask(frame.y.shape, occluder, object_translation)
            rendered = _apply_occluder(warped, mask, occluder)
        sequence.append(rendered)

        if index == 0 or scene_cut:
            camera_forward = None
            camera_backward = None
            object_forward = None
            occlusion_mask = np.zeros_like(mask)
            reveal_mask = np.zeros_like(mask)
        else:
            assert previous_camera is not None
            camera_forward = [
                translation[0] - previous_camera[0],
                translation[1] - previous_camera[1],
                rotation - previous_camera[2],
            ]
            camera_backward = [-value for value in camera_forward]
            if object_translation is not None and previous_object is not None:
                object_forward = [
                    object_translation[0] - previous_object[0],
                    object_translation[1] - previous_object[1],
                ]
            else:
                object_forward = None
            assert previous_mask is not None
            occlusion_mask = np.logical_and(mask, np.logical_not(previous_mask))
            reveal_mask = np.logical_and(previous_mask, np.logical_not(mask))

        ledger.append(
            {
                "frame_index": index,
                "scene_source": scene_source,
                "scene_source_sha256": frame_sha256(source_scene),
                "scene_cut": scene_cut,
                "camera_transform_absolute": [translation[0], translation[1], rotation],
                "camera_forward_from_previous": camera_forward,
                "camera_backward_to_previous": camera_backward,
                "object_translation_absolute": (
                    None
                    if object_translation is None
                    else [object_translation[0], object_translation[1]]
                ),
                "object_forward_from_previous": object_forward,
                "occluder_mask_sha256": _mask_sha256(mask),
                "occlusion_mask_sha256": _mask_sha256(occlusion_mask),
                "reveal_mask_sha256": _mask_sha256(reveal_mask),
                "occluder_pixel_count_y": int(np.count_nonzero(mask)),
                "newly_occluded_pixel_count_y": int(np.count_nonzero(occlusion_mask)),
                "revealed_pixel_count_y": int(np.count_nonzero(reveal_mask)),
            }
        )
        previous_camera = (translation[0], translation[1], rotation)
        previous_object = object_translation
        previous_mask = mask
    return sequence, ledger
