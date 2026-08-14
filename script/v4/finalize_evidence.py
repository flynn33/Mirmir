#!/usr/bin/env python3
"""Seal a generated v4 evidence directory with a recursive hash manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from typing import Any


MANIFEST_NAME = "evidence-manifest.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git(repository: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ["git", *arguments],
        cwd=repository,
        text=True,
        stderr=subprocess.STDOUT,
    ).strip()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository = Path(__file__).resolve().parents[2]
    directory = arguments.directory.expanduser().resolve()
    if not directory.is_dir():
        raise SystemExit(f"Expected an evidence directory: {directory}")
    manifest = directory / MANIFEST_NAME
    if manifest.exists():
        raise SystemExit(f"Refusing to overwrite sealed evidence: {manifest}")

    artifacts: list[dict[str, Any]] = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"Evidence must not contain symlinks: {path}")
        if path.is_file():
            artifacts.append(
                {
                    "path": path.relative_to(directory).as_posix(),
                    "byteCount": path.stat().st_size,
                    "sha256": sha256(path),
                }
            )

    tools = []
    for relative in (
        "script/v4/capture_baseline.py",
        "script/v4/summarize_time_profile.py",
        "script/v4/finalize_evidence.py",
    ):
        path = repository / relative
        tools.append({"path": relative, "sha256": sha256(path)})

    payload = {
        "schemaVersion": "mirmir-v4-evidence-manifest-v1",
        "sourceCommit": git(repository, "rev-parse", "HEAD"),
        "sourceDescribe": git(repository, "describe", "--always", "--dirty", "--broken"),
        "artifactCount": len(artifacts),
        "artifacts": artifacts,
        "tools": tools,
    }
    manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
