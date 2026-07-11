#!/usr/bin/env python3
"""Build the deterministic artifact manifest for the P05 checkpoint."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


MACHINE = "MacBook Pro Mac16,7; Apple M4 Pro; arm64; macOS 26.5.1 (25F80)"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def producer(relative: Path) -> str:
    top = relative.parts[0]
    if top == "analysis":
        return "P05 independent validation and gate assessment"
    if top == "inputs":
        return "P05 source and lock capture"
    if top in {"tests", "xcode"}:
        return "P05 build and test verification"
    if top == "evidence":
        return "P05 deterministic spatial evidence"
    return "P05 checkpoint assembly"


def command(relative: Path) -> str:
    if any(part.endswith(".xcresult") for part in relative.parts):
        return "xcodebuild retained result bundle"
    top = relative.parts[0]
    if top == "evidence":
        return "deterministic P05 evidence run"
    if top in {"tests", "xcode"}:
        return "checkpoint test or build verification"
    if top == "analysis":
        return "checkpoint validation or assessment"
    if top == "inputs":
        return "checkpoint source or lock capture"
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
                "gate_ids": ["G05"],
                "command": command(relative),
                "machine": MACHINE,
            }
        )

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
