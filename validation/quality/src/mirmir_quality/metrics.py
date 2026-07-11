"""Deterministic spatial quality metrics and analytic artifact measures."""

from __future__ import annotations

import math
from typing import Dict, Iterable, Mapping, Optional, Sequence, Tuple

import numpy as np

from .arrays import (
    PlanarFrame,
    bilinear_sample_reflect101,
    downsample2_box_reflect101,
    separable_convolve_reflect101,
)


SSIM_K1 = 0.01
SSIM_K2 = 0.03
SSIM_PEAK = 1.0
MS_SSIM_WEIGHTS = (0.0448, 0.2856, 0.3001, 0.2363, 0.1333)


def _pair(reference: np.ndarray, candidate: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    first = np.asarray(reference, dtype=np.float64)
    second = np.asarray(candidate, dtype=np.float64)
    if first.shape != second.shape or first.ndim != 2 or first.size == 0:
        raise ValueError("metric planes must be nonempty, two-dimensional, and shape matched")
    if not np.all(np.isfinite(first)) or not np.all(np.isfinite(second)):
        raise ValueError("metric planes contain a nonfinite value")
    return first, second


def psnr(reference: np.ndarray, candidate: np.ndarray) -> Dict[str, object]:
    """Return peak-1 PSNR with JSON-safe exact-match representation."""

    first, second = _pair(reference, candidate)
    difference = first - second
    mse = float(np.mean(difference * difference, dtype=np.float64))
    if mse == 0.0:
        return {"mse": 0.0, "value": None, "exact_match": True}
    return {
        "mse": mse,
        "value": 10.0 * math.log10(1.0 / mse),
        "exact_match": False,
    }


def channel_psnr(reference: PlanarFrame, candidate: PlanarFrame) -> Dict[str, Dict[str, object]]:
    return {
        "Y": psnr(reference.y, candidate.y),
        "Cb": psnr(reference.cb, candidate.cb),
        "Cr": psnr(reference.cr, candidate.cr),
    }


def gaussian_kernel(size: int = 11, sigma: float = 1.5) -> np.ndarray:
    if size <= 0 or size % 2 != 1 or sigma <= 0.0:
        raise ValueError("Gaussian size must be positive and odd, and sigma must be positive")
    coordinates = np.arange(size, dtype=np.float64) - size // 2
    kernel = np.exp(-(coordinates * coordinates) / (2.0 * sigma * sigma))
    return kernel / np.sum(kernel)


def _ssim_components(reference: np.ndarray, candidate: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    first, second = _pair(reference, candidate)
    kernel = gaussian_kernel()
    mean_first = separable_convolve_reflect101(first, kernel)
    mean_second = separable_convolve_reflect101(second, kernel)
    mean_first_squared = mean_first * mean_first
    mean_second_squared = mean_second * mean_second
    mean_product = mean_first * mean_second
    variance_first = np.maximum(
        separable_convolve_reflect101(first * first, kernel) - mean_first_squared,
        0.0,
    )
    variance_second = np.maximum(
        separable_convolve_reflect101(second * second, kernel) - mean_second_squared,
        0.0,
    )
    covariance = separable_convolve_reflect101(first * second, kernel) - mean_product
    c1 = (SSIM_K1 * SSIM_PEAK) ** 2
    c2 = (SSIM_K2 * SSIM_PEAK) ** 2
    luminance = (2.0 * mean_product + c1) / (
        mean_first_squared + mean_second_squared + c1
    )
    contrast_structure = (2.0 * covariance + c2) / (
        variance_first + variance_second + c2
    )
    return luminance, contrast_structure


def ssim(reference: np.ndarray, candidate: np.ndarray) -> float:
    """Mean 11x11 Gaussian SSIM using reflect-101 boundaries."""

    luminance, contrast_structure = _ssim_components(reference, candidate)
    return float(np.mean(luminance * contrast_structure, dtype=np.float64))


def ms_ssim_detail(reference: np.ndarray, candidate: np.ndarray) -> Dict[str, object]:
    """Return every five-scale contribution and the combined MS-SSIM value."""

    first, second = _pair(reference, candidate)
    if min(first.shape) < 32:
        raise ValueError("five-scale MS-SSIM requires each dimension to be at least 32")
    contrast_means = []
    ssim_means = []
    for scale_index in range(len(MS_SSIM_WEIGHTS)):
        luminance, contrast_structure = _ssim_components(first, second)
        contrast_means.append(float(np.mean(contrast_structure, dtype=np.float64)))
        ssim_means.append(
            float(np.mean(luminance * contrast_structure, dtype=np.float64))
        )
        if scale_index + 1 < len(MS_SSIM_WEIGHTS):
            first = downsample2_box_reflect101(first)
            second = downsample2_box_reflect101(second)
    value = 1.0
    for component, weight in zip(contrast_means[:-1], MS_SSIM_WEIGHTS[:-1]):
        value *= max(0.0, min(1.0, component)) ** weight
    value *= max(0.0, min(1.0, ssim_means[-1])) ** MS_SSIM_WEIGHTS[-1]
    return {
        "scale_contrast_structure_means": contrast_means,
        "scale_ssim_means": ssim_means,
        "value": float(value),
    }


def ms_ssim(reference: np.ndarray, candidate: np.ndarray) -> float:
    """Five-scale SSIM with locked weights and 2x2 box decimation."""

    return float(ms_ssim_detail(reference, candidate)["value"])


def _crossing(coordinates: np.ndarray, values: np.ndarray, level: float = 0.5) -> float:
    if coordinates.ndim != 1 or values.ndim != 1 or coordinates.size != values.size:
        raise ValueError("crossing coordinates and values must be matching one-dimensional arrays")
    delta = values - level
    exact = np.flatnonzero(delta == 0.0)
    if exact.size:
        return float(coordinates[int(exact[0])])
    for index in range(values.size - 1):
        left = delta[index]
        right = delta[index + 1]
        if left * right < 0.0:
            fraction = -left / (right - left)
            return float(coordinates[index] + fraction * (coordinates[index + 1] - coordinates[index]))
    raise ValueError("profile has no 50-percent crossing")


def profile_along_normal(
    image: np.ndarray,
    *,
    center: Tuple[float, float],
    normal: Tuple[float, float],
    sample_count: int,
) -> Tuple[np.ndarray, np.ndarray]:
    source = np.asarray(image, dtype=np.float64)
    if source.ndim != 2 or sample_count < 2:
        raise ValueError("normal profile requires a two-dimensional image and at least two samples")
    nx, ny = normal
    length = math.hypot(nx, ny)
    if length == 0.0:
        raise ValueError("normal vector must be nonzero")
    nx /= length
    ny /= length
    coordinates = np.arange(sample_count, dtype=np.float64) - (sample_count - 1) / 2.0
    x = center[0] + coordinates * nx
    y = center[1] + coordinates * ny
    return coordinates, bilinear_sample_reflect101(source, x, y)


def edge_location_error(
    reference: np.ndarray,
    candidate: np.ndarray,
    *,
    center: Tuple[float, float],
    normal: Tuple[float, float],
    sample_count: int,
) -> float:
    first, second = _pair(reference, candidate)
    coordinates, reference_profile = profile_along_normal(
        first,
        center=center,
        normal=normal,
        sample_count=sample_count,
    )
    _, candidate_profile = profile_along_normal(
        second,
        center=center,
        normal=normal,
        sample_count=sample_count,
    )
    return abs(_crossing(coordinates, candidate_profile) - _crossing(coordinates, reference_profile))


def ringing(
    reference: np.ndarray,
    candidate: np.ndarray,
    transition_support: np.ndarray,
) -> Dict[str, float]:
    first, second = _pair(reference, candidate)
    support = np.asarray(transition_support, dtype=bool)
    if support.shape != first.shape or np.all(support):
        raise ValueError("transition support must match the image and leave exterior samples")
    amplitude = float(np.max(first) - np.min(first))
    if amplitude <= 0.0:
        raise ValueError("ringing reference must have nonzero amplitude")
    exterior = second[~support]
    overshoot = max(0.0, float(np.max(exterior) - np.max(first))) / amplitude
    undershoot = max(0.0, float(np.min(first) - np.min(exterior))) / amplitude
    return {"overshoot": overshoot, "undershoot": undershoot}


def thin_line_retention(
    reference: np.ndarray,
    candidate: np.ndarray,
    line_support: np.ndarray,
) -> Dict[str, float]:
    first, second = _pair(reference, candidate)
    support = np.asarray(line_support, dtype=bool)
    if support.shape != first.shape or not np.any(support) or np.all(support):
        raise ValueError("line support must identify a proper nonempty subset")
    background = float(np.median(first[~support]))
    reference_contrast = float(np.sum(np.abs(first[support] - background), dtype=np.float64))
    if reference_contrast == 0.0:
        raise ValueError("reference line has zero integrated contrast")
    candidate_contrast = float(np.sum(np.abs(second[support] - background), dtype=np.float64))
    side_lobe = float(np.sum(np.abs(second[~support] - background), dtype=np.float64))
    return {
        "retention_ratio": candidate_contrast / reference_contrast,
        "false_side_lobe_energy": side_lobe / reference_contrast,
    }


def chroma_edge_displacement(
    y_profile: Sequence[float],
    cb_profile: Sequence[float],
    cr_profile: Sequence[float],
    *,
    coordinates: Optional[Sequence[float]] = None,
) -> Dict[str, float]:
    y = np.asarray(y_profile, dtype=np.float64)
    cb = np.asarray(cb_profile, dtype=np.float64)
    cr = np.asarray(cr_profile, dtype=np.float64)
    if y.shape != cb.shape or y.shape != cr.shape or y.ndim != 1:
        raise ValueError("Y, Cb, and Cr profiles must be matching one-dimensional arrays")
    positions = (
        np.arange(y.size, dtype=np.float64)
        if coordinates is None
        else np.asarray(coordinates, dtype=np.float64)
    )
    y_crossing = _crossing(positions, y, level=0.5)
    return {
        "Cb": abs(_crossing(positions, cb, level=0.0) - y_crossing),
        "Cr": abs(_crossing(positions, cr, level=0.0) - y_crossing),
    }


def alias_energy(image: np.ndarray, forbidden_mask: np.ndarray) -> Dict[str, float]:
    source = np.asarray(image, dtype=np.float64)
    mask = np.asarray(forbidden_mask, dtype=bool)
    if source.ndim != 2 or source.shape != mask.shape:
        raise ValueError("alias image and forbidden mask must be matching two-dimensional arrays")
    if not np.any(mask):
        raise ValueError("alias forbidden mask must select at least one spectral bin")
    spectrum = np.fft.fft2(source, norm="ortho")
    power = np.abs(spectrum) ** 2
    total = float(np.sum(power, dtype=np.float64))
    forbidden = float(np.sum(power[mask], dtype=np.float64))
    return {
        "forbidden_energy": forbidden,
        "total_energy": total,
        "ratio": 0.0 if total == 0.0 else forbidden / total,
    }
