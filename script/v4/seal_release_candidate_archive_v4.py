#!/usr/bin/env python3
"""Generate build settings and seal a signed deterministic-v4 app archive."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

import release_candidate_archive_v4 as provenance


def common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--source-commit", default="HEAD")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--release-configuration", type=Path, required=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    settings = commands.add_parser(
        "build-settings",
        help="write the xcconfig overlay that embeds signed provenance claims",
    )
    common(settings)
    settings.add_argument("--output", type=Path, required=True)
    application = commands.add_parser(
        "build-application",
        help=(
            "build an ad-hoc signed candidate from a verified git archive at "
            "the canonical physical compiler root"
        ),
    )
    common(application)
    application.add_argument("--output-application", type=Path, required=True)
    xcarchive = commands.add_parser(
        "build-xcarchive",
        help=(
            "construct an xcarchive from the canonical verified clean-commit "
            "product"
        ),
    )
    common(xcarchive)
    xcarchive.add_argument("--output-xcarchive", type=Path, required=True)
    xcarchive.add_argument(
        "--signing-identity",
        default="-",
        help="codesign identity for the archive app; '-' keeps the replay signature",
    )
    seal = commands.add_parser(
        "seal",
        help="append and verify the canonical final-build attestation",
    )
    common(seal)
    seal.add_argument("--input-archive", type=Path, required=True)
    seal.add_argument(
        "--source-build-receipt",
        type=Path,
        required=True,
        help=(
            "MirmirV4CanonicalBuildReceipt.json from the xcarchive that "
            "produced the notarized candidate"
        ),
    )
    seal.add_argument("--output-archive", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository = arguments.repository.expanduser()
    runtime = arguments.runtime.expanduser()
    release_configuration = arguments.release_configuration.expanduser()
    context = provenance.release_context(
        repository,
        arguments.source_commit,
        runtime,
        release_configuration,
    )
    repository = Path(context["repositoryAbsolutePath"])
    release_configuration = repository.joinpath(
        *Path(context["releaseConfigurationRepositoryRelativePath"]).parts
    )
    tools = provenance.tool_descriptors(repository, context["sourceCommit"])
    if arguments.command == "build-settings":
        output = provenance.write_bytes_no_clobber(
            arguments.output,
            provenance.build_settings_text(
                context,
                release_configuration,
            ).encode("utf-8"),
            label="build-settings output",
        )
        print(output)
        return 0
    if arguments.command == "build-application":
        output = arguments.output_application.expanduser()
        provenance.build_candidate_application(context, output)
        print(output.resolve())
        return 0
    if arguments.command == "build-xcarchive":
        output = arguments.output_xcarchive.expanduser()
        provenance.build_candidate_xcarchive(
            context,
            output,
            signing_identity=arguments.signing_identity,
        )
        print(output.resolve())
        return 0
    if arguments.command == "seal":
        receipt = provenance.load_canonical_json_file(
            arguments.source_build_receipt,
            "source-build receipt",
        )
        provenance.seal_archive(
            arguments.input_archive,
            arguments.output_archive,
            context,
            tools,
            source_build_receipt=receipt,
        )
        print(arguments.output_archive.expanduser().resolve(strict=True))
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, provenance.ArchiveProvenanceError) as error:
        print(f"release candidate archive sealing failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
