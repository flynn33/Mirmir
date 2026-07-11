"""Standalone quality-validation primitives for Mirmir."""

from .arrays import PlanarFrame, frame_sha256, normalize_code_plane
from .bootstrap import paired_bootstrap
from .corpus import (
    CorpusValidationError,
    create_corpus_lock,
    seal_corpus_lock,
    validate_corpus_lock,
)
from .degradation import apply_degradation, synthetic_motion_sequence
from .holdout import (
    HashBinding,
    HoldoutAccessError,
    HoldoutAccessGuard,
    initialize_holdout_access_ledger,
)
from .metrics import (
    alias_energy,
    channel_psnr,
    chroma_edge_displacement,
    edge_location_error,
    ms_ssim,
    ms_ssim_detail,
    psnr,
    ringing,
    ssim,
    thin_line_retention,
)

__all__ = [
    "CorpusValidationError",
    "HoldoutAccessError",
    "HoldoutAccessGuard",
    "HashBinding",
    "PlanarFrame",
    "alias_energy",
    "apply_degradation",
    "channel_psnr",
    "chroma_edge_displacement",
    "create_corpus_lock",
    "edge_location_error",
    "frame_sha256",
    "initialize_holdout_access_ledger",
    "ms_ssim",
    "ms_ssim_detail",
    "normalize_code_plane",
    "paired_bootstrap",
    "psnr",
    "ringing",
    "seal_corpus_lock",
    "ssim",
    "synthetic_motion_sequence",
    "thin_line_retention",
    "validate_corpus_lock",
]
