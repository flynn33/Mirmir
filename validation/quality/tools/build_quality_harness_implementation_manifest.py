#!/usr/bin/env python3
"""Build and validate the recursive quality-harness implementation manifest."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


QUALITY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QUALITY_ROOT / "src"))

from mirmir_quality.harness_manifest import (  # noqa: E402
    create_quality_harness_implementation_manifest,
    validate_quality_harness_implementation_manifest,
)
from mirmir_quality.json_tools import canonical_json_bytes  # noqa: E402


def _write_manifest(path: Path, manifest: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = canonical_json_bytes(manifest) + b"\n"
    with path.open("xb") as stream:
        stream.write(payload)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise FileExistsError(
            "refusing to overwrite a quality-harness implementation manifest"
        )

    manifest = create_quality_harness_implementation_manifest(
        arguments.repository_root
    )
    _write_manifest(arguments.output, manifest)
    validated = validate_quality_harness_implementation_manifest(
        manifest,
        arguments.repository_root,
    )
    print(validated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
