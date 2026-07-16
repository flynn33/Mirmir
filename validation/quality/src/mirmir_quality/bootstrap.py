"""Deterministic paired bootstrap with source assets as the resampling unit."""

from __future__ import annotations

import hashlib
import struct
from typing import Dict, Iterable, List, Mapping, MutableMapping, Sequence

import numpy as np


MASK64 = (1 << 64) - 1


class SplitMix64:
    """Small versioned generator with fully specified unsigned-64 arithmetic."""

    def __init__(self, seed: int) -> None:
        self.state = seed & MASK64

    def next_u64(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK64
        return (value ^ (value >> 31)) & MASK64

    def index(self, extent: int) -> int:
        if extent <= 0:
            raise ValueError("index extent must be positive")
        limit = (1 << 64) - ((1 << 64) % extent)
        while True:
            value = self.next_u64()
            if value < limit:
                return value % extent


def _linear_quantile(sorted_values: np.ndarray, probability: float) -> float:
    if sorted_values.ndim != 1 or sorted_values.size == 0:
        raise ValueError("quantile input must be a nonempty vector")
    if not 0.0 <= probability <= 1.0:
        raise ValueError("quantile probability must be within [0, 1]")
    position = (sorted_values.size - 1) * probability
    lower = int(np.floor(position))
    upper = int(np.ceil(position))
    if lower == upper:
        return float(sorted_values[lower])
    weight = position - lower
    return float(sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight)


def paired_bootstrap(
    records: Sequence[Mapping[str, object]],
    *,
    replicates: int = 10_000,
    seed: int = 20_260_710,
) -> Dict[str, object]:
    """Aggregate rows per source asset, then resample asset deltas with replacement."""

    if replicates <= 0:
        raise ValueError("bootstrap replicate count must be positive")
    grouped: MutableMapping[str, List[float]] = {}
    categories: MutableMapping[str, set] = {}
    for record in records:
        asset_id = str(record["source_asset_id"])
        candidate = float(record["candidate"])
        baseline = float(record["baseline"])
        if not np.isfinite(candidate) or not np.isfinite(baseline):
            raise ValueError("bootstrap inputs must be finite")
        grouped.setdefault(asset_id, []).append(candidate - baseline)
        category_values = record.get("categories", [])
        categories.setdefault(asset_id, set()).update(str(value) for value in category_values)
    if not grouped:
        raise ValueError("bootstrap requires at least one source asset")

    asset_ids = sorted(grouped)
    asset_deltas = np.asarray(
        [float(np.mean(grouped[asset_id], dtype=np.float64)) for asset_id in asset_ids],
        dtype=np.float64,
    )
    generator = SplitMix64(seed)
    replicate_values = np.empty(replicates, dtype=np.float64)
    index_digest = hashlib.sha256()
    for replicate in range(replicates):
        total = 0.0
        for _ in asset_ids:
            index = generator.index(len(asset_ids))
            index_digest.update(struct.pack(">I", index))
            total += float(asset_deltas[index])
        replicate_values[replicate] = total / len(asset_ids)
    replicate_values.sort()

    category_estimates = {}
    all_categories = sorted(set().union(*categories.values()))
    for category in all_categories:
        members = [
            asset_deltas[index]
            for index, asset_id in enumerate(asset_ids)
            if category in categories[asset_id]
        ]
        if members:
            category_estimates[category] = float(np.mean(members, dtype=np.float64))

    return {
        "method": "paired_source_asset_mean_splitmix64_v1",
        "replicates": replicates,
        "seed": seed,
        "asset_count": len(asset_ids),
        "asset_ids": asset_ids,
        "asset_deltas": [float(value) for value in asset_deltas],
        "point_delta": float(np.mean(asset_deltas, dtype=np.float64)),
        "ci_low": _linear_quantile(replicate_values, 0.025),
        "ci_high": _linear_quantile(replicate_values, 0.975),
        "category_estimates": category_estimates,
        "resample_index_sha256": index_digest.hexdigest(),
    }
