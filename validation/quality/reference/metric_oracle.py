#!/usr/bin/env python3
"""Independent direct-convolution oracle for locked non-identical metric vectors."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Dict, Tuple

import numpy as np


WEIGHTS = (0.0448, 0.2856, 0.3001, 0.2363, 0.1333)


def fixture() -> Tuple[np.ndarray, np.ndarray]:
    height = 96
    width = 96
    yy, xx = np.indices((height, width), dtype=np.float64)
    x = xx / (width - 1)
    y = yy / (height - 1)
    checker = ((xx // 4 + yy // 6) % 2).astype(np.float64)
    reference = np.clip(0.50 * x + 0.25 * y + 0.25 * checker, 0.0, 1.0)
    candidate = np.roll(reference, shift=(1, -1), axis=(0, 1))
    candidate = np.clip(
        0.965 * candidate
        + 0.0175
        + 0.0125 * np.sin((3.0 * xx + 5.0 * yy) * 2.0 * np.pi / 37.0),
        0.0,
        1.0,
    )
    return reference, candidate


def gaussian_kernel() -> np.ndarray:
    coordinates = np.arange(-5, 6, dtype=np.float64)
    kernel = np.exp(-(coordinates * coordinates) / (2.0 * 1.5 * 1.5))
    return kernel / np.sum(kernel, dtype=np.float64)


def direct_gaussian(image: np.ndarray) -> np.ndarray:
    kernel = gaussian_kernel()
    padded = np.pad(np.asarray(image, dtype=np.float64), ((5, 5), (5, 5)), mode="reflect")
    output = np.zeros_like(image, dtype=np.float64)
    for row in range(11):
        for column in range(11):
            output += (
                kernel[row]
                * kernel[column]
                * padded[row : row + image.shape[0], column : column + image.shape[1]]
            )
    return output


def components(reference: np.ndarray, candidate: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    mean_reference = direct_gaussian(reference)
    mean_candidate = direct_gaussian(candidate)
    reference_squared = mean_reference * mean_reference
    candidate_squared = mean_candidate * mean_candidate
    product = mean_reference * mean_candidate
    variance_reference = np.maximum(direct_gaussian(reference * reference) - reference_squared, 0.0)
    variance_candidate = np.maximum(direct_gaussian(candidate * candidate) - candidate_squared, 0.0)
    covariance = direct_gaussian(reference * candidate) - product
    luminance = (2.0 * product + 0.01**2) / (reference_squared + candidate_squared + 0.01**2)
    contrast_structure = (2.0 * covariance + 0.03**2) / (
        variance_reference + variance_candidate + 0.03**2
    )
    return luminance, contrast_structure


def downsample(image: np.ndarray) -> np.ndarray:
    source = np.asarray(image, dtype=np.float64)
    if source.shape[0] % 2 or source.shape[1] % 2:
        source = np.pad(source, ((0, source.shape[0] % 2), (0, source.shape[1] % 2)), mode="reflect")
    return (
        source[0::2, 0::2]
        + source[1::2, 0::2]
        + source[0::2, 1::2]
        + source[1::2, 1::2]
    ) / 4.0


def array_sha256(value: np.ndarray) -> str:
    return hashlib.sha256(np.asarray(value, dtype="<f8").tobytes(order="C")).hexdigest()


def generate() -> Dict[str, object]:
    reference, candidate = fixture()
    luminance, contrast = components(reference, candidate)
    ssim_value = float(np.mean(luminance * contrast, dtype=np.float64))
    first = reference
    second = candidate
    contrast_means = []
    ssim_means = []
    for scale in range(5):
        luminance, contrast = components(first, second)
        contrast_means.append(float(np.mean(contrast, dtype=np.float64)))
        ssim_means.append(float(np.mean(luminance * contrast, dtype=np.float64)))
        if scale < 4:
            first = downsample(first)
            second = downsample(second)
    combined = 1.0
    for value, weight in zip(contrast_means[:-1], WEIGHTS[:-1]):
        combined *= max(0.0, min(1.0, value)) ** weight
    combined *= max(0.0, min(1.0, ssim_means[-1])) ** WEIGHTS[-1]
    return {
        "schema_version": "1.0.0",
        "oracle": "independent direct two-dimensional Gaussian convolution",
        "fixture": {
            "id": "nonidentical-multiscale-pattern-v1",
            "dimensions": [96, 96],
            "reference_f64le_sha256": array_sha256(reference),
            "candidate_f64le_sha256": array_sha256(candidate),
        },
        "expected": {
            "ssim": ssim_value,
            "scale_contrast_structure_means": contrast_means,
            "scale_ssim_means": ssim_means,
            "ms_ssim": float(combined),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=Path)
    arguments = parser.parse_args()
    generated = generate()
    if arguments.check is None:
        print(json.dumps(generated, sort_keys=True, indent=2))
        return 0
    locked = json.loads(arguments.check.read_text(encoding="utf-8"))
    if locked != generated:
        print("locked metric vectors do not match the independent oracle")
        return 1
    print("locked metric vectors match the independent oracle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
