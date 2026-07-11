"""Analytic and synthetic fixtures with no external media dependency."""

from __future__ import annotations

from typing import Tuple, Union

import numpy as np

from .arrays import PlanarFrame


def step_fixture(size: int, orientation: str, offset: float = 0.0) -> np.ndarray:
    if size < 8:
        raise ValueError("step fixture size must be at least eight")
    yy, xx = np.indices((size, size), dtype=np.float64)
    center = (size - 1) / 2.0 + offset
    if orientation == "vertical":
        signed = xx - center
    elif orientation == "horizontal":
        signed = yy - center
    elif orientation == "diagonal":
        signed = (xx + yy) / np.sqrt(2.0) - center * np.sqrt(2.0)
    else:
        raise ValueError("unsupported step orientation")
    return (signed >= 0.0).astype(np.float64)


def impulse_fixture(size: int = 33) -> Tuple[np.ndarray, np.ndarray]:
    reference = np.zeros((size, size), dtype=np.float64)
    center = size // 2
    reference[center, center] = 1.0
    support = np.zeros_like(reference, dtype=bool)
    support[center, center] = True
    return reference, support


def thin_line_fixture(size: int = 33) -> Tuple[np.ndarray, np.ndarray]:
    reference = np.zeros((size, size), dtype=np.float64)
    support = np.zeros_like(reference, dtype=bool)
    support[:, size // 2] = True
    reference[support] = 1.0
    return reference, support


def synthetic_planar_frame(
    index: int,
    size: Union[int, Tuple[int, int]] = 64,
) -> PlanarFrame:
    height, width = (size, size) if isinstance(size, int) else size
    if min(height, width) < 32 or height % 2 != 0 or width % 2 != 0:
        raise ValueError("synthetic frame dimensions must be even and at least 32")
    yy, xx = np.indices((height, width), dtype=np.float64)
    ramp = xx / (width - 1)
    vertical = (xx >= width / 2 + index).astype(np.float64)
    diagonal = ((xx + yy + index) % 16 < 8).astype(np.float64)
    y = np.clip(0.45 * ramp + 0.35 * vertical + 0.20 * diagonal, 0.0, 1.0)

    chroma_height = height // 2
    chroma_width = width // 2
    cy, cx = np.indices((chroma_height, chroma_width), dtype=np.float64)
    cb = np.where(cx >= chroma_width / 2, 0.30, -0.30)
    cr = 0.25 * np.sin((cx + cy + index) * 2.0 * np.pi / 16.0)
    return PlanarFrame(y=y, cb=cb, cr=cr)
