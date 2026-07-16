#!/usr/bin/env python3
"""Create a versioned live holdout guard from explicit metadata paths."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.live_holdout_preopen import (  # noqa: E402
    initialize_live_holdout_preopen,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Atomically create a new live access ledger and immutable preopen "
            "receipt. Every metadata path is required; no media root is accepted."
        )
    )
    parser.add_argument("--version-id", required=True)
    parser.add_argument("--created-utc", required=True)
    parser.add_argument("--corpus-manifest-sha256", required=True)
    parser.add_argument("--live-ledger-path", required=True, type=Path)
    parser.add_argument("--live-anchor-path", required=True, type=Path)
    parser.add_argument("--live-preopen-receipt-path", required=True, type=Path)
    parser.add_argument("--repository-sealed-copy-path", required=True, type=Path)
    parser.add_argument("--repository-sealed-copy-sha256", required=True)
    parser.add_argument("--repository-attestation-path", required=True, type=Path)
    parser.add_argument("--repository-attestation-sha256", required=True)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    record = initialize_live_holdout_preopen(
        version_id=arguments.version_id,
        created_utc=arguments.created_utc,
        corpus_manifest_sha256=arguments.corpus_manifest_sha256,
        live_ledger_path=arguments.live_ledger_path,
        live_anchor_path=arguments.live_anchor_path,
        live_preopen_receipt_path=arguments.live_preopen_receipt_path,
        repository_sealed_copy_path=arguments.repository_sealed_copy_path,
        expected_repository_sealed_copy_sha256=(
            arguments.repository_sealed_copy_sha256
        ),
        repository_attestation_path=arguments.repository_attestation_path,
        expected_repository_attestation_sha256=(
            arguments.repository_attestation_sha256
        ),
    )
    print(
        json.dumps(
            record,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
