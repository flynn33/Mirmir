#!/usr/bin/env python3
"""Create the three-source validation sample lock from frozen decode manifests."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


QUALITY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QUALITY_ROOT / "src"))

from mirmir_quality.json_tools import read_json, validate_schema, write_json  # noqa: E402
from mirmir_quality.samples import (  # noqa: E402
    build_sample_record,
    create_validation_sample_lock,
    load_validation_samples,
)


def _mapping(value: str) -> tuple[str, str]:
    asset_id, separator, relative_path = value.partition("=")
    if not separator or not asset_id or not relative_path:
        raise argparse.ArgumentTypeError("decode manifest must use ASSET_ID=RELATIVE_PATH")
    return asset_id, relative_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus-lock", type=Path, required=True)
    parser.add_argument("--sample-root", type=Path, required=True)
    parser.add_argument("--asset-root", type=Path)
    parser.add_argument("--decode-manifest", action="append", type=_mapping, required=True)
    parser.add_argument("--evidence-manifest", action="append", type=_mapping, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise FileExistsError("refusing to overwrite an existing validation sample lock")
    mappings = dict(arguments.decode_manifest)
    evidence_mappings = dict(arguments.evidence_manifest)
    if len(mappings) != len(arguments.decode_manifest):
        raise ValueError("decode manifest asset IDs must be unique")
    if len(evidence_mappings) != len(arguments.evidence_manifest):
        raise ValueError("evidence manifest asset IDs must be unique")

    corpus = read_json(arguments.corpus_lock)
    validation_assets = [
        asset for asset in corpus["assets"] if asset.get("split") == "validation"
    ]
    if len(validation_assets) != 3:
        raise ValueError("corpus validation split must contain exactly three assets")
    if set(mappings) != {asset["asset_id"] for asset in validation_assets}:
        raise ValueError("decode manifest mappings must exactly cover validation asset IDs")
    if set(evidence_mappings) != {asset["asset_id"] for asset in validation_assets}:
        raise ValueError("evidence manifest mappings must exactly cover validation asset IDs")

    records = []
    for asset in sorted(validation_assets, key=lambda item: item["asset_id"]):
        routes = asset["target_routes"]
        if len(routes) != 1 or routes[0] not in {"direct-2x", "direct-3over2"}:
            raise ValueError("each validation asset must declare exactly one supported route")
        records.append(
            build_sample_record(
                asset=asset,
                target_route=routes[0],
                sample_root=arguments.sample_root,
                asset_root=arguments.asset_root or arguments.sample_root,
                decode_manifest_path=mappings[asset["asset_id"]],
                source_evidence_manifest_path=evidence_mappings[asset["asset_id"]],
                split="validation",
            )
        )
    lock = create_validation_sample_lock(
        corpus_manifest_sha256=corpus["manifest_sha256"],
        samples=records,
    )
    validate_schema(
        lock,
        QUALITY_ROOT / "schemas" / "validation-sample-lock.schema.json",
    )
    load_validation_samples(
        lock,
        corpus,
        sample_root=arguments.sample_root,
        asset_root=arguments.asset_root or arguments.sample_root,
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    write_json(arguments.output, lock)
    print(f"sample_manifest_sha256={lock['manifest_sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
