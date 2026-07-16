#!/usr/bin/env python3
"""Build the deterministic artifact manifest for the P02 checkpoint."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gate_ids(relative: Path) -> list[str]:
    if relative.as_posix() == "analysis/g01-reassessment.json":
        return ["G01"]
    if relative.name == "GATE_REPORT.md":
        return ["G01", "G02"]
    return ["G02"]


def producer(relative: Path) -> str:
    if relative.parts[0] == "raw":
        return "P02 retained build, test, route, or development-failure evidence"
    if relative.parts[0] == "analysis":
        return "P02 independent validation and gate assessment"
    if relative.parts[0] == "inputs":
        return "P02 byte-bound route fixture"
    return "P02 checkpoint assembly"


def command(relative: Path) -> str:
    if ".xcresult" in relative.suffixes:
        return "xcodebuild retained result bundle"
    if relative.name == "avmediainfo.txt":
        return "avmediainfo output inspection"
    if relative.name == "telemetry.json":
        return "production route telemetry capture"
    if relative.parts[0] == "analysis":
        return "checkpoint validation or assessment"
    return "checkpoint verification or assembly"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--created-utc", required=True)
    parser.add_argument("--project-commit", required=True)
    args = parser.parse_args()

    root = args.root.resolve()
    output = args.output.resolve()
    files = sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and path.resolve() != output
    )
    artifacts = []
    for path in files:
        relative = path.relative_to(root)
        artifacts.append({
            "path": relative.as_posix(),
            "sha256": sha256(path),
            "size_bytes": path.stat().st_size,
            "producer": producer(relative),
            "gate_ids": gate_ids(relative),
            "command": command(relative),
            "machine": "MacBook Pro Mac16,7; Apple M4 Pro; arm64; macOS 26.5.1 (25F80)",
        })

    manifest = {
        "schema_version": "1.0.0",
        "created_utc": args.created_utc,
        "project_commit": args.project_commit,
        "working_tree_clean": False,
        "artifacts": artifacts,
    }
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)
    print(f"artifacts={len(artifacts)} output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
