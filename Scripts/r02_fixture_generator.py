#!/usr/bin/env python3
"""Pure deterministic byte generators frozen for R02 contract fixtures."""

from __future__ import annotations

import hashlib


GENERATOR_CONTRACT = "r02-deterministic-contract-fixtures-v1"
NV12_GENERATOR_ID = "r02-deterministic-nv12-v1"
PCM_GENERATOR_ID = "r02-deterministic-pcm-s16le-v1"


def nv12_frame_bytes(
    *, width: int, height: int, seed: int, sequence_number: int
) -> bytes:
    """Return one video-range-shaped NV12 payload without framework padding."""
    if width < 2 or height < 2 or width % 2 or height % 2:
        raise ValueError("NV12 fixture dimensions must be positive and even")
    if seed < 1 or sequence_number < 0:
        raise ValueError("NV12 fixture seed/sequence is outside the closed domain")
    luma_count = width * height
    chroma_count = luma_count // 2
    luma = bytes(
        16 + ((seed + sequence_number * 17 + index * 13) % 220)
        for index in range(luma_count)
    )
    chroma = bytes(
        16 + ((seed * 3 + sequence_number * 19 + index * 7) % 225)
        for index in range(chroma_count)
    )
    return luma + chroma


def pcm_s16le_bytes(
    *, sample_frames: int, channel_count: int, seed: int
) -> bytes:
    """Return interleaved signed-16 little-endian PCM source semantics."""
    if sample_frames < 1 or channel_count < 1 or seed < 1:
        raise ValueError("PCM fixture parameters are outside the closed domain")
    payload = bytearray()
    for sample_index in range(sample_frames):
        for channel_index in range(channel_count):
            unsigned = (seed + sample_index * 97 + channel_index * 31) % 65536
            signed = unsigned - 32768
            payload.extend(signed.to_bytes(2, byteorder="little", signed=True))
    return bytes(payload)


def sha256_hex(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()
