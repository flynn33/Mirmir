"""Planar numeric storage and deterministic array operations."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import struct
from typing import Iterable, Tuple

import numpy as np


def _as_plane(value: np.ndarray, name: str) -> np.ndarray:
    plane = np.asarray(value, dtype=np.float64)
    if plane.ndim != 2 or plane.size == 0:
        raise ValueError(f"{name} must be a nonempty two-dimensional plane")
    if not np.all(np.isfinite(plane)):
        raise ValueError(f"{name} contains a nonfinite value")
    return plane


@dataclass(frozen=True)
class PlanarFrame:
    """Normalized luma and centered chroma planes."""

    y: np.ndarray
    cb: np.ndarray
    cr: np.ndarray

    def __post_init__(self) -> None:
        y = _as_plane(self.y, "Y")
        cb = _as_plane(self.cb, "Cb")
        cr = _as_plane(self.cr, "Cr")
        if cb.shape != cr.shape:
            raise ValueError("Cb and Cr shapes must match")
        object.__setattr__(self, "y", y)
        object.__setattr__(self, "cb", cb)
        object.__setattr__(self, "cr", cr)


def normalize_code_plane(
    codes: np.ndarray,
    legal_minimum: float,
    legal_maximum: float,
    *,
    centered: bool = False,
) -> np.ndarray:
    """Map legal code values to [0, 1] or centered [-0.5, 0.5]."""

    if not legal_maximum > legal_minimum:
        raise ValueError("legal maximum must be greater than legal minimum")
    normalized = (np.asarray(codes, dtype=np.float64) - legal_minimum) / (
        legal_maximum - legal_minimum
    )
    if centered:
        normalized = normalized - 0.5
    return normalized


def separable_convolve_reflect101(image: np.ndarray, kernel: Iterable[float]) -> np.ndarray:
    """Apply a normalized separable correlation with reflect-101 boundaries."""

    source = _as_plane(image, "image")
    coefficients = np.asarray(tuple(kernel), dtype=np.float64)
    if coefficients.ndim != 1 or coefficients.size % 2 != 1:
        raise ValueError("kernel must contain an odd number of coefficients")
    if not np.all(np.isfinite(coefficients)):
        raise ValueError("kernel contains a nonfinite value")
    coefficient_sum = float(np.sum(coefficients))
    if coefficient_sum == 0.0:
        raise ValueError("kernel sum must be nonzero")
    coefficients = coefficients / coefficient_sum
    radius = coefficients.size // 2

    def correlate_rows(values: np.ndarray) -> np.ndarray:
        padded = np.pad(values, ((0, 0), (radius, radius)), mode="reflect")
        return np.apply_along_axis(
            lambda row: np.correlate(row, coefficients, mode="valid"),
            1,
            padded,
        )

    horizontal = correlate_rows(source)
    return correlate_rows(horizontal.T).T


def downsample2_box_reflect101(image: np.ndarray) -> np.ndarray:
    """Apply a normalized 2x2 box and decimate by two."""

    source = _as_plane(image, "image")
    pad_height = source.shape[0] % 2
    pad_width = source.shape[1] % 2
    if pad_height or pad_width:
        source = np.pad(source, ((0, pad_height), (0, pad_width)), mode="reflect")
    return (
        source[0::2, 0::2]
        + source[1::2, 0::2]
        + source[0::2, 1::2]
        + source[1::2, 1::2]
    ) / 4.0


def resize_bilinear(image: np.ndarray, output_shape: Tuple[int, int]) -> np.ndarray:
    """Resize with deterministic half-pixel-center bilinear sampling and edge clamp."""

    source = _as_plane(image, "image")
    output_height, output_width = output_shape
    if output_height <= 0 or output_width <= 0:
        raise ValueError("output dimensions must be positive")
    source_height, source_width = source.shape
    y_coordinates = (
        (np.arange(output_height, dtype=np.float64) + 0.5)
        * source_height
        / output_height
        - 0.5
    )
    x_coordinates = (
        (np.arange(output_width, dtype=np.float64) + 0.5)
        * source_width
        / output_width
        - 0.5
    )
    y_coordinates = np.clip(y_coordinates, 0.0, source_height - 1.0)
    x_coordinates = np.clip(x_coordinates, 0.0, source_width - 1.0)
    y0 = np.floor(y_coordinates).astype(np.int64)
    x0 = np.floor(x_coordinates).astype(np.int64)
    y1 = np.minimum(y0 + 1, source_height - 1)
    x1 = np.minimum(x0 + 1, source_width - 1)
    wy = y_coordinates - y0
    wx = x_coordinates - x0

    top = source[y0[:, None], x0[None, :]] * (1.0 - wx)[None, :]
    top += source[y0[:, None], x1[None, :]] * wx[None, :]
    bottom = source[y1[:, None], x0[None, :]] * (1.0 - wx)[None, :]
    bottom += source[y1[:, None], x1[None, :]] * wx[None, :]
    return top * (1.0 - wy)[:, None] + bottom * wy[:, None]


def _reflect101_indices(indices: np.ndarray, extent: int) -> np.ndarray:
    if extent <= 0:
        raise ValueError("extent must be positive")
    if extent == 1:
        return np.zeros_like(indices, dtype=np.int64)
    period = 2 * extent - 2
    folded = np.mod(indices, period)
    return np.where(folded < extent, folded, period - folded).astype(np.int64)


def bilinear_sample_reflect101(image: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Sample a plane at floating coordinates using reflect-101 boundaries."""

    source = _as_plane(image, "image")
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    x1 = x0 + 1
    y1 = y0 + 1
    wx = x - x0
    wy = y - y0
    x0r = _reflect101_indices(x0, source.shape[1])
    x1r = _reflect101_indices(x1, source.shape[1])
    y0r = _reflect101_indices(y0, source.shape[0])
    y1r = _reflect101_indices(y1, source.shape[0])
    top = source[y0r, x0r] * (1.0 - wx) + source[y0r, x1r] * wx
    bottom = source[y1r, x0r] * (1.0 - wx) + source[y1r, x1r] * wx
    return top * (1.0 - wy) + bottom * wy


def _plane_hash_bytes(plane: np.ndarray, *, centered: bool) -> bytes:
    values = np.asarray(plane, dtype=np.float64)
    if centered:
        values = values + 0.5
    quantized = np.rint(np.clip(values, 0.0, 1.0) * 65535.0).astype(">u2")
    return struct.pack(">II", values.shape[0], values.shape[1]) + quantized.tobytes(order="C")


def frame_sha256(frame: PlanarFrame) -> str:
    """Hash normalized planes after canonical unsigned-16 quantization."""

    digest = hashlib.sha256()
    digest.update(b"MIRMIR-PLANAR-Q16-V1\0")
    digest.update(b"Y\0")
    digest.update(_plane_hash_bytes(frame.y, centered=False))
    digest.update(b"CB\0")
    digest.update(_plane_hash_bytes(frame.cb, centered=True))
    digest.update(b"CR\0")
    digest.update(_plane_hash_bytes(frame.cr, centered=True))
    return digest.hexdigest()
