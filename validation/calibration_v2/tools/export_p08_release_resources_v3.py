#!/usr/bin/env python3
"""Replay full six-root authority and recover only an existing V3 exact-six export.

This command cannot execute P06 or publish a second release. It accepts one
already-authoritative V3 release, reopens all six support roots, and publishes
or idempotently verifies only the six Apple product resource files.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.production_release_resources_v3 import (  # noqa: E402
    export_p08_release_resources_v3,
)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Fully replay all six support authorities for one existing P06 V3 "
            "release, then publish or idempotently verify only its exact six "
            "P08 resource files; this command cannot rerun P06 or create a "
            "second release."
        )
    )
    parser.add_argument("--release-root", required=True, type=Path)
    parser.add_argument("--p08-resource-root", required=True, type=Path)
    parser.add_argument("--p08-resource-receipt", required=True, type=Path)
    parser.add_argument("--open-split-support-root", required=True, type=Path)
    parser.add_argument(
        "--calibration-evidence-support-root",
        required=True,
        type=Path,
    )
    parser.add_argument("--native-cache-support-root", required=True, type=Path)
    parser.add_argument(
        "--production-writer-support-root",
        required=True,
        type=Path,
    )
    parser.add_argument(
        "--dispatch-measurement-support-root",
        required=True,
        type=Path,
    )
    parser.add_argument(
        "--calibration-run-support-root",
        required=True,
        type=Path,
    )
    return parser.parse_args()


def main() -> int:
    arguments = _arguments()
    receipt = export_p08_release_resources_v3(
        release_root=arguments.release_root,
        resource_root=arguments.p08_resource_root,
        receipt_path=arguments.p08_resource_receipt,
        support_evidence_roots={
            "open_split": arguments.open_split_support_root,
            "calibration_evidence": (
                arguments.calibration_evidence_support_root
            ),
            "native_cache": arguments.native_cache_support_root,
            "production_writer": arguments.production_writer_support_root,
            "dispatch_measurement": (
                arguments.dispatch_measurement_support_root
            ),
            "calibration_run": arguments.calibration_run_support_root,
        },
    )
    print(
        json.dumps(
            {
                "schema_version": "1.0.0",
                "status": "p08_exact_six_export_reopened",
                "release_root": os.fspath(arguments.release_root.resolve(strict=True)),
                "p08_resource_root": os.fspath(
                    arguments.p08_resource_root.resolve(strict=True)
                ),
                "release_bundle_file_sha256": receipt["release_bundle"][
                    "sha256"
                ],
                "resource_set_sha256": receipt["resource_set_sha256"],
                "holdout_accessed": False,
            },
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
