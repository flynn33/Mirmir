#!/usr/bin/env python3
"""Build the deterministic per-file manifest for this checkpoint."""

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
    if relative.parts[0] == "conformance":
        return ["G03"]
    if relative.parts[0] in {"analysis", "inputs", "runtime"}:
        return ["G01"]
    return ["G01", "G03"]


def producer(relative: Path) -> str:
    if relative.parts[0] == "conformance":
        return "P03 canonical-core conformance"
    if relative.parts[0] in {"analysis", "inputs", "runtime"}:
        return "P01 production telemetry capture"
    if relative.parts[0] == "tests":
        return "P01/P03 build and test verification"
    return "P01/P03 checkpoint assembly"


def command(relative: Path) -> str:
    suffixes = relative.suffixes
    if ".xcresult" in suffixes:
        return "xcodebuild retained result bundle"
    if ".trace" in suffixes:
        return "xctrace retained Logging trace"
    if relative.parts[0] == "conformance":
        return "canonical-core production and independent-oracle verification"
    if relative.parts[0] in {"analysis", "runtime"}:
        return "production telemetry capture or evidence analysis"
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
        artifacts.append(
            {
                "path": relative.as_posix(),
                "sha256": sha256(path),
                "size_bytes": path.stat().st_size,
                "producer": producer(relative),
                "gate_ids": gate_ids(relative),
                "command": command(relative),
                "machine": "MacBook Pro Mac16,7; Apple M4 Pro; arm64; macOS 26.5.1 (25F80)",
            }
        )

    manifest = {
        "schema_version": "1.0.0",
        "created_utc": args.created_utc,
        "project_commit": args.project_commit,
        "working_tree_clean": False,
        "artifacts": artifacts,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(output)
    print(f"artifacts={len(artifacts)} output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
