#!/usr/bin/env python3
"""Compile the P05 Swift reference and emit schema-validated synthetic evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

import jsonschema
from referencing import Registry, Resource


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parents[1]

PRODUCTION_SOURCES = (
    "Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift",
    "Mirmir/Modules/Telemetry/ASHTelemetryModels.swift",
    "Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialOperatorBankV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHChromaSitingV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHVideoAnalyzerV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCodePlaneNormalizerV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialDispatchV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialRuntimeConfigurationV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialReferencePipelineV2.swift",
)

CONFIGURATION_FILES = (
    "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json",
    "Mirmir/Resources/ASH/operator_bank_v2.seed.json",
)

EXPECTED_OUTPUTS = (
    "development-mapping.json",
    "state-fixtures.json",
    "operator-discrimination.json",
    "operator-distinctness.json",
    "coordinate-comparison.json",
    "state-causality-results.json",
    "cpu-reference-results.json",
    "cpu-reference-vectors.json",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def digest_records(relative_paths: tuple[str, ...]) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for relative_path in relative_paths:
        path = PROJECT_ROOT / relative_path
        if not path.is_file():
            raise FileNotFoundError(path)
        records.append(
            {
                "path": relative_path,
                "sha256": sha256(path),
                "byte_count": path.stat().st_size,
            }
        )
    return records


def composite_sha256(records: list[dict[str, object]]) -> str:
    material = "".join(
        f"{record['path']}\0{record['sha256']}\0{record['byte_count']}\n"
        for record in records
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def require_unchanged(
    label: str,
    relative_paths: tuple[str, ...],
    expected: list[dict[str, object]],
) -> None:
    observed = digest_records(relative_paths)
    if observed != expected:
        raise RuntimeError(f"{label} changed during evidence execution")


def swift_literal(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def write_digest_source(
    path: Path,
    source_records: list[dict[str, object]],
    configuration_records: list[dict[str, object]],
    harness_records: list[dict[str, object]],
) -> None:
    def rows(records: list[dict[str, object]]) -> str:
        return ",\n".join(
            "        P05EvidenceFileDigest("
            f"path: {swift_literal(str(record['path']))}, "
            f"sha256: {swift_literal(str(record['sha256']))}, "
            f"byteCount: {int(record['byte_count'])})"
            for record in records
        )

    text = f"""import Foundation

enum P05EvidenceInputDigests {{
    static let productionSources = [
{rows(source_records)}
    ]
    static let configurationFiles = [
{rows(configuration_records)}
    ]
    static let harnessFiles = [
{rows(harness_records)}
    ]
    static let productionSourceManifestSHA256 = {swift_literal(composite_sha256(source_records))}
    static let configurationManifestSHA256 = {swift_literal(composite_sha256(configuration_records))}
    static let harnessManifestSHA256 = {swift_literal(composite_sha256(harness_records))}
}}
"""
    path.write_text(text, encoding="utf-8")


def validate_outputs(directory: Path) -> None:
    schema_directory = SCRIPT_DIR / "schemas"
    common = json.loads((schema_directory / "p05-common.schema.json").read_text(encoding="utf-8"))
    registry = Registry().with_resource(common["$id"], Resource.from_contents(common))
    observed = sorted(path.name for path in directory.glob("*.json"))
    if observed != sorted(EXPECTED_OUTPUTS):
        raise RuntimeError(f"unexpected evidence set: {observed}")

    for filename in EXPECTED_OUTPUTS:
        schema_path = schema_directory / filename.replace(".json", ".schema.json")
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        instance = json.loads((directory / filename).read_text(encoding="utf-8"))
        validator = jsonschema.Draft202012Validator(schema, registry=registry)
        errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
        if errors:
            details = "\n".join(
                f"{filename}:{'/'.join(map(str, error.path))}: {error.message}"
                for error in errors
            )
            raise RuntimeError(details)


def ensure_synthetic_output_path(path: Path) -> None:
    if any("holdout" in part.lower() for part in path.parts):
        raise ValueError("P05 evidence output may not target a holdout path")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    output = arguments.output.expanduser().resolve()
    ensure_synthetic_output_path(output)
    if output.exists():
        raise FileExistsError(f"refusing to overwrite existing evidence: {output}")

    source_records = digest_records(PRODUCTION_SOURCES)
    configuration_records = digest_records(CONFIGURATION_FILES)
    harness_paths = (
        str((SCRIPT_DIR / "P05EvidenceMain.swift").relative_to(PROJECT_ROOT)),
        str((SCRIPT_DIR / "run_p05_evidence.py").relative_to(PROJECT_ROOT)),
    ) + tuple(
        str(path.relative_to(PROJECT_ROOT))
        for path in sorted((SCRIPT_DIR / "schemas").glob("*.json"))
    )
    harness_records = digest_records(harness_paths)

    build_directory = SCRIPT_DIR / ".build"
    build_directory.mkdir(parents=True, exist_ok=True)
    digest_source = build_directory / "P05InputDigests.swift"
    executable = build_directory / "p05-evidence"
    write_digest_source(digest_source, source_records, configuration_records, harness_records)

    swiftc = subprocess.run(
        ["xcrun", "--find", "swiftc"],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    compile_command = [
        swiftc,
        "-O",
        "-warnings-as-errors",
        *[str(PROJECT_ROOT / path) for path in PRODUCTION_SOURCES],
        str(digest_source),
        str(SCRIPT_DIR / "P05EvidenceMain.swift"),
        "-o",
        str(executable),
    ]
    subprocess.run(compile_command, cwd=PROJECT_ROOT, check=True)

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.parent / f".{output.name}.tmp-{uuid.uuid4()}"
    staging.mkdir()
    try:
        subprocess.run([str(executable), str(staging)], cwd=PROJECT_ROOT, check=True)
        require_unchanged("production source", PRODUCTION_SOURCES, source_records)
        require_unchanged("configuration", CONFIGURATION_FILES, configuration_records)
        require_unchanged("evidence harness", harness_paths, harness_records)
        validate_outputs(staging)
        os.replace(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    for filename in EXPECTED_OUTPUTS:
        path = output / filename
        print(f"{sha256(path)}  {filename}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"P05 evidence failed: {error}", file=sys.stderr)
        raise SystemExit(1)
