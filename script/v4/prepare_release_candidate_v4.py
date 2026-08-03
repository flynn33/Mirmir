#!/usr/bin/env python3
"""Derive the exact M7 candidate identity from committed release artifacts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import plistlib
import subprocess
import sys
from typing import Any
import zipfile


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
CAPTURE_SPEC = importlib.util.spec_from_file_location(
    "capture_p06_reproduction_v4",
    SCRIPT_DIRECTORY / "capture_p06_reproduction_v4.py",
)
if CAPTURE_SPEC is None or CAPTURE_SPEC.loader is None:
    raise RuntimeError("cannot load the P06 identity implementation")
p06 = importlib.util.module_from_spec(CAPTURE_SPEC)
CAPTURE_SPEC.loader.exec_module(p06)


class CandidateError(ValueError):
    """The supplied files do not describe one committed release candidate."""


def git_output(repository: Path, arguments: list[str], *, binary: bool = False) -> Any:
    process = subprocess.run(
        ["git", *arguments],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise CandidateError(
            f"git {' '.join(arguments)} failed: "
            + process.stderr.decode("utf-8", errors="replace").strip()
        )
    return process.stdout if binary else process.stdout.decode("utf-8").strip()


def committed_file_set(repository: Path, commit: str, relative_root: str) -> list[str]:
    output = git_output(
        repository,
        ["ls-tree", "-r", "--name-only", "-z", commit, "--", relative_root],
        binary=True,
    )
    return sorted(
        value.decode("utf-8") for value in output.split(b"\0") if value
    )


def require_committed_tree(
    repository: Path,
    commit: str,
    local_root: Path,
    repository_relative_root: str,
) -> None:
    local_paths = p06.regular_files(local_root)
    expected = [
        f"{repository_relative_root}/{path.relative_to(local_root).as_posix()}"
        for path in local_paths
    ]
    observed = committed_file_set(repository, commit, repository_relative_root)
    if expected != observed:
        raise CandidateError(
            "committed P06 file set differs from the shipping resource; "
            f"missing={sorted(set(expected) - set(observed))}, "
            f"unexpected={sorted(set(observed) - set(expected))}"
        )
    for local_path, relative_path in zip(local_paths, expected):
        committed = git_output(
            repository,
            ["show", f"{commit}:{relative_path}"],
            binary=True,
        )
        if committed != local_path.read_bytes():
            raise CandidateError(f"shipping P06 differs from candidate commit: {relative_path}")


def require_committed_file(
    repository: Path,
    commit: str,
    local_path: Path,
    repository_relative_path: str,
) -> None:
    committed = git_output(
        repository,
        ["show", f"{commit}:{repository_relative_path}"],
        binary=True,
    )
    if committed != local_path.read_bytes():
        raise CandidateError(
            f"release input differs from candidate commit: {repository_relative_path}"
        )


def application_identity(archive: Path) -> dict[str, str]:
    if not archive.is_file() or archive.is_symlink():
        raise CandidateError("application archive must be a regular, non-symlinked file")
    try:
        with zipfile.ZipFile(archive) as value:
            plist_entries = []
            for entry in value.infolist():
                pure = PurePosixPath(entry.filename)
                if (
                    pure.is_absolute()
                    or any(component in {"", ".", ".."} for component in pure.parts)
                    or "\\" in entry.filename
                ):
                    raise CandidateError(
                        f"application archive contains an unsafe path: {entry.filename}"
                    )
                file_type = (entry.external_attr >> 16) & 0o170000
                if file_type == 0o120000:
                    raise CandidateError(
                        f"application archive contains a symbolic link: {entry.filename}"
                    )
                if len(pure.parts) == 3 and pure.parts[0].endswith(".app") and pure.parts[1:] == (
                    "Contents",
                    "Info.plist",
                ):
                    plist_entries.append(entry)
            if len(plist_entries) != 1:
                raise CandidateError(
                    "application archive must contain exactly one top-level app Info.plist"
                )
            plist = plistlib.loads(value.read(plist_entries[0]))
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise CandidateError(f"cannot inspect application archive: {error}") from error
    if not isinstance(plist, dict):
        raise CandidateError("application Info.plist is not a dictionary")
    keys = {
        "bundleIdentifier": "CFBundleIdentifier",
        "productVersion": "CFBundleShortVersionString",
        "productBuild": "CFBundleVersion",
    }
    result = {"appBundleSHA256": p06.sha256(archive)}
    for output_key, plist_key in keys.items():
        item = plist.get(plist_key)
        if not isinstance(item, str) or not item.strip():
            raise CandidateError(f"application Info.plist omits {plist_key}")
        result[output_key] = item
    return result


def make_candidate(arguments: argparse.Namespace) -> dict[str, Any]:
    repository = arguments.repository.expanduser().resolve(strict=True)
    runtime = arguments.runtime.expanduser().resolve(strict=True)
    release_configuration = arguments.release_configuration.expanduser().resolve(strict=True)
    archive = arguments.application_archive.expanduser().resolve(strict=True)
    commit = git_output(repository, ["rev-parse", f"{arguments.source_commit}^{{commit}}"])
    p06.require_hex(commit, (40,), "source commit")

    runtime_relative = runtime.relative_to(repository).as_posix()
    release_relative = release_configuration.relative_to(repository).as_posix()
    require_committed_tree(repository, commit, runtime, runtime_relative)
    require_committed_file(repository, commit, release_configuration, release_relative)

    manifest_path = runtime / "runtime-manifest.json"
    manifest = p06.load_json(manifest_path)
    if not isinstance(manifest, dict):
        raise CandidateError("P06 runtime manifest is not an object")
    provenance = manifest.get("provenance")
    if not isinstance(provenance, dict):
        raise CandidateError("P06 runtime provenance is missing")
    source_revision = provenance.get("sourceRevision")
    p06.require_hex(source_revision, (40, 64), "runtime source revision")
    semantic_manifest = p06.sha256_bytes(
        p06.MANIFEST_DOMAIN + p06.canonical_bytes(manifest)
    )
    runtime_set = p06.artifact_set_sha(p06.bundle_entries(runtime))
    candidate = {
        "sourceCommit": commit,
        "sourceTreeIdentitySHA256": p06.source_tree_identity(repository, commit),
        "runtimeManifestSHA256": semantic_manifest,
        "runtimeManifestFileSHA256": p06.sha256(manifest_path),
        "runtimeArtifactSetSHA256": runtime_set,
        "runtimeSourceRevision": source_revision,
        "releaseConfigurationSHA256": p06.sha256(release_configuration),
        **application_identity(archive),
    }
    # Reuse the strict parser as a final independent field-shape validation.
    temporary = arguments.output.parent / f".{arguments.output.name}.candidate-check.json"
    if temporary.exists():
        raise CandidateError(f"temporary candidate path already exists: {temporary}")
    try:
        p06.write_json(temporary, candidate)
        return p06.parse_candidate(temporary)
    finally:
        temporary.unlink(missing_ok=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--source-commit", default="HEAD")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--release-configuration", type=Path, required=True)
    parser.add_argument("--application-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    output = arguments.output.expanduser().resolve()
    if output.exists():
        raise CandidateError(f"output already exists: {output}")
    if not output.parent.is_dir():
        raise CandidateError(f"output parent does not exist: {output.parent}")
    candidate = make_candidate(arguments)
    p06.write_json(output, candidate)
    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CandidateError, p06.CaptureError, OSError, ValueError) as error:
        print(f"release candidate preparation failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
