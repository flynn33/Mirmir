#!/usr/bin/env python3
"""Identity and evidence checks for the frozen pre-v4 P05 baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
from typing import Any, Iterable


FROZEN_SOURCE_REVISION = "d3a4de55c08391ea8a08c00beb766b5650dc9f58"
SOURCE_MANIFEST_SCHEMA = "mirmir-ash-p05-source-manifest-v1"
BASELINE_IDENTITY_SCHEMA = "mirmir-ash-v4-p05-baseline-identity-v1"
BASELINE_IDENTITY_KEYS = {
    "schemaVersion",
    "implementationVersion",
    "sourceRevision",
    "sourceTreeIdentitySHA256",
    "sourceManifestSHA256",
    "captureSourceSHA256",
    "executableSHA256",
    "captureExecutableSHA256",
}


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact_set_identity(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for path, identity in sorted(entries):
        digest.update(path.encode())
        digest.update(b"\0")
        digest.update(identity.encode())
        digest.update(b"\n")
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_hex(value: Any, length: int, label: str) -> str:
    require(
        isinstance(value, str)
        and len(value) == length
        and all(character in "0123456789abcdef" for character in value),
        f"invalid {label}",
    )
    return value


def git_bytes(repository: Path, *arguments: str, input_bytes: bytes | None = None) -> bytes:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=repository,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise ValueError(
            f"git {' '.join(arguments)} failed: "
            + completed.stderr.decode("utf-8", errors="replace").strip()
        )
    return completed.stdout


def resolve_revision(repository: Path, revision: str) -> str:
    return git_bytes(repository, "rev-parse", "--verify", f"{revision}^{{commit}}").decode().strip()


def source_tree_identity(repository: Path, revision: str) -> str:
    tree = git_bytes(repository, "ls-tree", "-r", "-z", "--full-tree", revision)
    return sha256_bytes(b"mirmir-source-tree-v1\0" + tree)


def tree_rows(repository: Path, revision: str) -> list[tuple[str, str, str, str]]:
    raw = git_bytes(repository, "ls-tree", "-r", "-z", "--full-tree", revision)
    rows: list[tuple[str, str, str, str]] = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        metadata, path_bytes = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode("ascii").split(" ")
        try:
            path = path_bytes.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError("P05 source tree contains a non-UTF-8 path") from error
        require(object_type == "blob", f"unsupported P05 source object: {path}")
        checked_relative(Path("/"), path)
        rows.append((mode, object_type, object_id, path))
    return rows


def checked_relative(root: Path, relative: Any) -> Path:
    require(isinstance(relative, str) and "\\" not in relative, "non-canonical path")
    pure = PurePosixPath(relative)
    require(
        not pure.is_absolute()
        and bool(pure.parts)
        and all(part not in {"", ".", ".."} for part in pure.parts),
        f"path escapes root: {relative}",
    )
    root = root.resolve()
    candidate = root.joinpath(*pure.parts)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise ValueError(f"path escapes root: {relative}") from error
    current = candidate
    while current != root:
        require(not current.is_symlink(), f"path contains a symbolic link: {relative}")
        current = current.parent
    return resolved


def build_source_manifest(repository: Path, revision: str) -> dict[str, Any]:
    repository = repository.resolve()
    commit = resolve_revision(repository, revision)
    require(commit == FROZEN_SOURCE_REVISION, "P05 source revision is not the frozen commit")
    files: list[dict[str, Any]] = []
    for mode, object_type, object_id, path in tree_rows(repository, commit):
        data = git_bytes(repository, "cat-file", "blob", object_id)
        files.append(
            {
                "path": path,
                "gitMode": mode,
                "gitObjectType": object_type,
                "gitObjectID": object_id,
                "byteCount": len(data),
                "sha256": sha256_bytes(data),
            }
        )
    return {
        "schemaVersion": SOURCE_MANIFEST_SCHEMA,
        "sourceRevision": commit,
        "gitTreeObjectID": git_bytes(
            repository, "rev-parse", f"{commit}^{{tree}}"
        ).decode().strip(),
        "sourceTreeIdentitySHA256": source_tree_identity(repository, commit),
        "fileCount": len(files),
        "artifactSetSHA256": artifact_set_identity(
            (item["path"], item["sha256"]) for item in files
        ),
        "files": files,
    }


def validate_source_manifest(
    repository: Path,
    manifest_path: Path,
    archive_root: Path | None = None,
) -> dict[str, Any]:
    repository = repository.resolve()
    manifest_path = manifest_path.resolve()
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get("schemaVersion") == SOURCE_MANIFEST_SCHEMA, "unsupported P05 source manifest")
    revision = require_hex(manifest.get("sourceRevision"), 40, "P05 source revision")
    require(revision == FROZEN_SOURCE_REVISION, "P05 source manifest revision changed")
    expected = build_source_manifest(repository, revision)
    require(manifest == expected, "P05 source manifest differs from the frozen git tree")

    if archive_root is not None:
        archive_root = archive_root.resolve()
        require(archive_root.is_dir(), "P05 archive root is absent")
        expected_paths = {item["path"] for item in manifest["files"]}
        actual_paths: set[str] = set()
        for path in archive_root.rglob("*"):
            require(not path.is_symlink(), f"P05 archive contains a symbolic link: {path}")
            if path.is_file():
                actual_paths.add(path.relative_to(archive_root).as_posix())
        require(actual_paths == expected_paths, "P05 clean archive file set differs from source manifest")
        for item in manifest["files"]:
            path = checked_relative(archive_root, item["path"])
            require(path.is_file(), f"P05 archive file is absent: {item['path']}")
            require(path.stat().st_size == item["byteCount"], f"P05 archive size mismatch: {item['path']}")
            require(sha256(path) == item["sha256"], f"P05 archive hash mismatch: {item['path']}")
        archive_set = artifact_set_identity(
            (item["path"], sha256(checked_relative(archive_root, item["path"])))
            for item in manifest["files"]
        )
        require(archive_set == manifest["artifactSetSHA256"], "P05 archive artifact-set mismatch")
    return manifest


def frozen_identity(contract: dict[str, Any]) -> dict[str, Any]:
    baseline = contract.get("frozenP05Baseline")
    require(isinstance(baseline, dict), "quality contract omits frozen P05 baseline")
    require(set(baseline) == BASELINE_IDENTITY_KEYS | {"sourceManifestPath"}, "frozen P05 contract field set differs")
    identity = {key: baseline[key] for key in BASELINE_IDENTITY_KEYS}
    validate_baseline_identity(identity)
    path = baseline["sourceManifestPath"]
    require(
        path == "script/v4/p05-baseline-source-manifest-v1.json",
        "frozen P05 source-manifest path changed",
    )
    return identity


def validate_baseline_identity(identity: Any) -> dict[str, Any]:
    require(isinstance(identity, dict), "P05 baseline identity is absent")
    require(set(identity) == BASELINE_IDENTITY_KEYS, "P05 baseline identity field set differs")
    require(identity["schemaVersion"] == BASELINE_IDENTITY_SCHEMA, "unsupported P05 baseline identity")
    require(
        identity["implementationVersion"] == "ash-p05-cpu-reference-preview",
        "P05 implementation version changed",
    )
    require(
        require_hex(identity["sourceRevision"], 40, "P05 source revision")
        == FROZEN_SOURCE_REVISION,
        "P05 source revision changed",
    )
    for key in (
        "sourceTreeIdentitySHA256",
        "sourceManifestSHA256",
        "captureSourceSHA256",
        "executableSHA256",
        "captureExecutableSHA256",
    ):
        require_hex(identity[key], 64, f"P05 {key}")
    return identity


def require_observed_identity(contract: dict[str, Any], observed: Any) -> dict[str, Any]:
    expected = frozen_identity(contract)
    actual = validate_baseline_identity(observed)
    require(actual == expected, "P05 baseline identity differs from frozen quality contract")
    return actual


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate-source-manifest")
    generate.add_argument("--repository", type=Path, required=True)
    generate.add_argument("--revision", default=FROZEN_SOURCE_REVISION)
    generate.add_argument("--output", type=Path, required=True)
    verify = subparsers.add_parser("verify-source-manifest")
    verify.add_argument("--repository", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--archive-root", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "generate-source-manifest":
        output = arguments.output.resolve()
        if output.exists():
            raise SystemExit(f"refusing to overwrite P05 source manifest: {output}")
        write_json(
            output,
            build_source_manifest(arguments.repository, arguments.revision),
        )
        print(output)
        return 0
    if arguments.command == "verify-source-manifest":
        validate_source_manifest(
            arguments.repository,
            arguments.manifest,
            arguments.archive_root,
        )
        print(arguments.manifest.resolve())
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"P05 baseline verification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
