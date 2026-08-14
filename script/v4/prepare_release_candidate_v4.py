#!/usr/bin/env python3
"""Derive the exact M7 candidate identity from committed release artifacts."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from typing import Any


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
CAPTURE_SPEC = importlib.util.spec_from_file_location(
    "capture_p06_reproduction_v4",
    SCRIPT_DIRECTORY / "capture_p06_reproduction_v4.py",
)
if CAPTURE_SPEC is None or CAPTURE_SPEC.loader is None:
    raise RuntimeError("cannot load the P06 identity implementation")
p06 = importlib.util.module_from_spec(CAPTURE_SPEC)
CAPTURE_SPEC.loader.exec_module(p06)

PROVENANCE_SPEC = importlib.util.spec_from_file_location(
    "release_candidate_archive_v4",
    SCRIPT_DIRECTORY / "release_candidate_archive_v4.py",
)
if PROVENANCE_SPEC is None or PROVENANCE_SPEC.loader is None:
    raise RuntimeError("cannot load the release archive provenance implementation")
archive_provenance = importlib.util.module_from_spec(PROVENANCE_SPEC)
sys.modules[PROVENANCE_SPEC.name] = archive_provenance
PROVENANCE_SPEC.loader.exec_module(archive_provenance)


class CandidateError(ValueError):
    """The supplied files do not describe one committed release candidate."""


def candidate_json_bytes(value: Any) -> bytes:
    """Return the existing sorted, indented candidate-record representation."""

    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def make_candidate(
    arguments: argparse.Namespace,
    *,
    source_build_runner: archive_provenance.CleanBuildRunner | None = None,
) -> dict[str, Any]:
    repository = arguments.repository.expanduser()
    runtime = arguments.runtime.expanduser()
    release_configuration = arguments.release_configuration.expanduser()
    archive = arguments.application_archive.expanduser()
    if archive.is_symlink():
        raise CandidateError("application archive cannot be a symbolic link")
    archive = archive.resolve(strict=True)
    context = archive_provenance.release_context(
        repository,
        arguments.source_commit,
        runtime,
        release_configuration,
    )
    repository = Path(context["repositoryAbsolutePath"])
    tools = archive_provenance.tool_descriptors(
        repository,
        context["sourceCommit"],
    )
    application = archive_provenance.inspect_archive(
        archive,
        context,
        tools,
        require_attestation=True,
        verify_source_build=True,
        source_build_runner=source_build_runner,
    )
    candidate = {
        **{
            key: context[key]
            for key in (
                "sourceCommit",
                "sourceTreeIdentitySHA256",
                "runtimeManifestSHA256",
                "runtimeManifestFileSHA256",
                "runtimeArtifactSetSHA256",
                "runtimeSourceRevision",
                "releaseConfigurationSHA256",
            )
        },
        **{
            key: application[key]
            for key in (
                "appBundleSHA256",
                "bundleIdentifier",
                "productVersion",
                "productBuild",
            )
        },
    }
    # Reuse the strict parser through a held anonymous file descriptor. No
    # writable pathname exists for another process to replace or redirect.
    with tempfile.TemporaryFile(prefix="mirmir-v4-candidate-check-") as temporary:
        temporary.write(candidate_json_bytes(candidate))
        temporary.flush()
        temporary.seek(0)
        return p06.parse_candidate(Path(f"/dev/fd/{temporary.fileno()}"))


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
    candidate = make_candidate(arguments)
    output = archive_provenance.write_bytes_no_clobber(
        arguments.output,
        candidate_json_bytes(candidate),
        label="release candidate record",
    )
    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        CandidateError,
        archive_provenance.ArchiveProvenanceError,
        p06.CaptureError,
        OSError,
        ValueError,
    ) as error:
        print(f"release candidate preparation failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
