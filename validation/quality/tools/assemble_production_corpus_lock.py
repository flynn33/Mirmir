#!/usr/bin/env python3
"""Assemble and optionally byte-seal the exact 6/3/3 native-HR corpus lock."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


QUALITY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QUALITY_ROOT / "src"))

from mirmir_quality.corpus import (  # noqa: E402
    QUALITY_CATEGORIES,
    create_corpus_lock,
    seal_corpus_lock,
    validate_corpus_lock,
)
from mirmir_quality.json_tools import read_json, validate_schema  # noqa: E402


def _assets(path: Path) -> list[dict[str, object]]:
    document = read_json(path)
    records = document.get("assets")
    if not isinstance(records, list) or not all(isinstance(item, dict) for item in records):
        raise ValueError(f"asset wrapper is invalid: {path}")
    return records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--development-validation-assets", type=Path, required=True)
    parser.add_argument("--holdout-assets", type=Path, required=True)
    parser.add_argument("--created-utc", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise FileExistsError("refusing to overwrite an existing corpus lock")

    records = _assets(arguments.development_validation_assets) + _assets(
        arguments.holdout_assets
    )
    route_dimensions = {
        "direct-2x": [3840, 2160],
        "direct-3over2": [1920, 1080],
    }
    for record in records:
        routes = record.get("target_routes")
        if not isinstance(routes, list) or len(routes) != 1 or routes[0] not in route_dimensions:
            raise ValueError("each production asset must declare exactly one project route")
        if record.get("presentation_dimensions") != route_dimensions[routes[0]]:
            raise ValueError("production asset dimensions do not match the declared route")
    split_order = {"development": 0, "validation": 1, "holdout": 2}
    records.sort(key=lambda item: (split_order.get(str(item.get("split")), 9), item["asset_id"]))
    manifest = create_corpus_lock(
        corpus_id="mirmir-native-hr-quality-v1",
        corpus_version="1.0.0",
        created_utc=arguments.created_utc,
        category_vocabulary_version="quality-gate-policy-1.1.0",
        split_policy={
            "unit": "source_asset",
            "group_key": "source_family_id",
            "allocation": {
                "development": 0.5,
                "validation": 0.25,
                "holdout": 0.25,
            },
            "algorithm": "predeclared source-family assignment before calibration",
            "seed": None,
            "rounding_rule": "exact twelve-family allocation: 6 development, 3 validation, 3 holdout",
            "expected_family_counts": {
                "development": 6,
                "validation": 3,
                "holdout": 3,
            },
            "minimum_category_counts": {
                category: 4 for category in sorted(QUALITY_CATEGORIES)
            },
            "minimum_category_counts_by_split": {
                split: {category: 1 for category in sorted(QUALITY_CATEGORIES)}
                for split in ("development", "validation", "holdout")
            },
        },
        holdout_policy={
            "state": "sealed",
            "evaluation_opened_utc": None,
            "access_requires_complete_configuration_lock": True,
        },
        assets=records,
    )
    schema_path = QUALITY_ROOT / "schemas" / "corpus-lock.schema.json"
    validate_schema(manifest, schema_path)
    validate_corpus_lock(
        manifest,
        allowed_categories=QUALITY_CATEGORIES,
        require_all_splits=True,
        require_exact_allocation=True,
        require_category_minima=True,
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    digest = seal_corpus_lock(
        manifest,
        arguments.output,
        allowed_categories=QUALITY_CATEGORIES,
        asset_root=arguments.asset_root,
        evidence_root=arguments.evidence_root,
        schema_path=schema_path,
    )
    print(f"corpus_manifest_sha256={manifest['manifest_sha256']}")
    print(f"sealed_file_sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
