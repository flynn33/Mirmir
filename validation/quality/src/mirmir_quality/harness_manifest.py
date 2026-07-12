"""Deterministic recursive binding for the quality-harness implementation."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
from typing import Dict, Mapping, Sequence, Tuple

from .json_tools import manifest_sha256, validate_schema


QUALITY_HARNESS_MANIFEST_SCHEMA = (
    Path(__file__).resolve().parents[2]
    / "schemas"
    / "quality-harness-implementation-manifest.schema.json"
)
QUALITY_HARNESS_REQUIRED_IMPLEMENTATION_FILES = (
    "Mirmir.xcodeproj/project.pbxproj",
    "Mirmir/Modules/MediaPipeline/AVFoundationMediaSessionConfiguration.swift",
    "Mirmir/Modules/MediaPipeline/MediaTypes.swift",
    "Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift",
    "Mirmir/Modules/Telemetry/ASHTelemetryModels.swift",
    "Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHAssets.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHAnalysisGridV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHChromaSitingV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHDevelopmentAssetTypes.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTLoaderV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTValidationV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTBinaryFormatV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTBinaryValidationSupportV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerSemanticsV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTLockedConfigurationJSONV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLUTTypesV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedCandidateLUTManifestV1.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedControlResamplerV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedControlRuntimeV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedNonASHOutputCacheV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedLUTManifestRouteV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedOperatorBankV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferencePipelineV2+DispatchProjection.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferencePipelineV2+NonASHCache.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferencePipelineV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferenceTypesV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReleaseLUTManifestV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedRuntimeTypesV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedRuntimeV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedSampleRuntimeV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedVideoMappingV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialDispatchV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialOperatorBankV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialReferencePipelineV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialRuntimeConfigurationV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHStrictJSONV2.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHVideoAnalyzerV2.swift",
    "Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift",
    "Mirmir/Modules/UpscalerEngine/UpscaleStrategy.swift",
    "Mirmir/Resources/ASH/ash-asset-manifest.json",
    "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json",
    "Mirmir/Resources/ASH/operator_bank_v2.seed.json",
    "project.yml",
    "validation/spatial_v2/P05EvidenceMain.swift",
    "validation/spatial_v2/run_p05_evidence.py",
    "validation/spatial_v2/schemas/coordinate-comparison.schema.json",
    "validation/spatial_v2/schemas/cpu-reference-results.schema.json",
    "validation/spatial_v2/schemas/cpu-reference-vectors.schema.json",
    "validation/spatial_v2/schemas/development-mapping.schema.json",
    "validation/spatial_v2/schemas/operator-discrimination.schema.json",
    "validation/spatial_v2/schemas/operator-distinctness.schema.json",
    "validation/spatial_v2/schemas/p05-common.schema.json",
    "validation/spatial_v2/schemas/state-causality-results.schema.json",
    "validation/spatial_v2/schemas/state-fixtures.schema.json",
)
_DISCOVERY_TREES: Sequence[Tuple[str, frozenset[str]]] = (
    ("validation/calibration_v2", frozenset({".json", ".py", ".swift"})),
    ("validation/quality/src/mirmir_quality", frozenset({".py"})),
    ("validation/quality/tools", frozenset({".py", ".swift"})),
    ("validation/quality/schemas", frozenset({".json"})),
    ("validation/quality/reference", frozenset({".json", ".py"})),
)


class QualityHarnessManifestError(ValueError):
    """Raised when the recursive implementation manifest is not exact."""


def _absolute_path(path: Path) -> Path:
    return Path(os.path.abspath(path))


def _require_directory(path: Path, description: str) -> None:
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise QualityHarnessManifestError(f"{description} is absent") from error
    if path.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        raise QualityHarnessManifestError(
            f"{description} is symbolic or not a directory"
        )


def _require_regular_file(path: Path, description: str) -> os.stat_result:
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise QualityHarnessManifestError(f"{description} is absent") from error
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise QualityHarnessManifestError(
            f"{description} is symbolic or not a regular file"
        )
    return metadata


def _relative_path(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError as error:
        raise QualityHarnessManifestError(
            "discovered implementation path escapes the repository root"
        ) from error


def _require_nonsymbolic_parent_directories(path: Path, root: Path) -> None:
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise QualityHarnessManifestError(
            "implementation path escapes the repository root"
        ) from error
    current = root
    _require_directory(current, "repository root")
    for part in relative.parts[:-1]:
        current = current / part
        _require_directory(current, "implementation parent directory")


def _validate_relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise QualityHarnessManifestError(
            f"implementation manifest path is not normalized and relative: {value!r}"
        )
    return path


def _walk_matching_files(
    repository_root: Path,
    relative_directory: str,
    suffixes: frozenset[str],
) -> Tuple[str, ...]:
    directory = repository_root.joinpath(*PurePosixPath(relative_directory).parts)
    _require_nonsymbolic_parent_directories(directory, repository_root)
    _require_directory(directory, f"implementation directory {relative_directory}")
    discovered = []

    def fail_walk(error: OSError) -> None:
        raise QualityHarnessManifestError(
            f"implementation directory {relative_directory} cannot be traversed"
        ) from error

    for current_name, directory_names, file_names in os.walk(
        directory,
        topdown=True,
        onerror=fail_walk,
        followlinks=False,
    ):
        current = Path(current_name)
        _require_nonsymbolic_parent_directories(current, repository_root)
        _require_directory(current, "implementation directory")
        directory_names.sort()
        for directory_name in directory_names:
            child = current / directory_name
            _require_nonsymbolic_parent_directories(child, repository_root)
            _require_directory(child, "implementation subdirectory")
        for file_name in sorted(file_names):
            candidate = current / file_name
            if candidate.suffix not in suffixes:
                continue
            _require_nonsymbolic_parent_directories(candidate, repository_root)
            _require_regular_file(candidate, "implementation source")
            discovered.append(_relative_path(candidate, repository_root))
    return tuple(discovered)


def discover_quality_harness_implementation_paths(
    repository_root: Path,
) -> Tuple[str, ...]:
    """Return the exact sorted implementation file set for a repository root."""

    root = _absolute_path(repository_root)
    _require_directory(root, "repository root")
    discovered = []
    for relative_path in QUALITY_HARNESS_REQUIRED_IMPLEMENTATION_FILES:
        candidate = root.joinpath(*PurePosixPath(relative_path).parts)
        _require_nonsymbolic_parent_directories(candidate, root)
        _require_regular_file(candidate, f"required implementation source {relative_path}")
        discovered.append(relative_path)
    for relative_directory, suffixes in _DISCOVERY_TREES:
        discovered.extend(
            _walk_matching_files(root, relative_directory, suffixes)
        )
    if len(discovered) != len(set(discovered)):
        raise QualityHarnessManifestError(
            "implementation discovery produced duplicate paths"
        )
    return tuple(sorted(discovered))


def _hash_regular_file(path: Path, repository_root: Path) -> Tuple[int, str]:
    _require_nonsymbolic_parent_directories(path, repository_root)
    before = _require_regular_file(path, "implementation source")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise QualityHarnessManifestError(
            "implementation source cannot be opened without following links"
        ) from error
    digest = hashlib.sha256()
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise QualityHarnessManifestError(
                "implementation source changed while it was opened"
            )
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after_read = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    _require_nonsymbolic_parent_directories(path, repository_root)
    after_path = _require_regular_file(path, "implementation source")
    identity_before = (before.st_dev, before.st_ino)
    if (
        (after_read.st_dev, after_read.st_ino) != identity_before
        or (after_path.st_dev, after_path.st_ino) != identity_before
        or after_read.st_size != before.st_size
        or after_path.st_size != before.st_size
        or after_read.st_mtime_ns != before.st_mtime_ns
        or after_path.st_mtime_ns != before.st_mtime_ns
    ):
        raise QualityHarnessManifestError(
            "implementation source changed while it was hashed"
        )
    return before.st_size, digest.hexdigest()


def create_quality_harness_implementation_manifest(
    repository_root: Path,
) -> Dict[str, object]:
    """Build a timestamp-free, canonical manifest from the exact source set."""

    root = _absolute_path(repository_root)
    files = []
    for relative_path in discover_quality_harness_implementation_paths(root):
        parsed = _validate_relative_path(relative_path)
        size_bytes, digest = _hash_regular_file(
            root.joinpath(*parsed.parts),
            root,
        )
        files.append(
            {
                "relative_path": relative_path,
                "size_bytes": size_bytes,
                "sha256": digest,
            }
        )
    manifest: Dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "quality_harness_implementation_manifest",
        "file_count": len(files),
        "files": files,
    }
    manifest["manifest_sha256"] = manifest_sha256(manifest)
    try:
        validate_schema(manifest, QUALITY_HARNESS_MANIFEST_SCHEMA)
    except (OSError, ValueError) as error:
        raise QualityHarnessManifestError(
            "created quality-harness manifest does not satisfy its schema"
        ) from error
    return manifest


def validate_quality_harness_implementation_manifest(
    manifest: Mapping[str, object],
    repository_root: Path,
) -> str:
    """Validate schema, self-hash, exact path set, sizes, and source hashes."""

    candidate = dict(manifest)
    try:
        validate_schema(candidate, QUALITY_HARNESS_MANIFEST_SCHEMA)
    except (OSError, ValueError) as error:
        raise QualityHarnessManifestError(
            "quality-harness implementation manifest schema validation failed"
        ) from error
    declared_hash = candidate["manifest_sha256"]
    actual_hash = manifest_sha256(candidate)
    if declared_hash != actual_hash:
        raise QualityHarnessManifestError(
            "quality-harness implementation manifest self-hash is invalid"
        )

    records = candidate["files"]
    if not isinstance(records, list):
        raise QualityHarnessManifestError(
            "quality-harness implementation files are not a list"
        )
    paths = []
    for record in records:
        if not isinstance(record, dict):
            raise QualityHarnessManifestError(
                "quality-harness implementation record is not an object"
            )
        relative_path = record.get("relative_path")
        if not isinstance(relative_path, str):
            raise QualityHarnessManifestError(
                "quality-harness implementation path is absent"
            )
        _validate_relative_path(relative_path)
        paths.append(relative_path)
    if len(paths) != len(set(paths)):
        raise QualityHarnessManifestError(
            "quality-harness implementation manifest has duplicate paths"
        )
    if paths != sorted(paths):
        raise QualityHarnessManifestError(
            "quality-harness implementation manifest paths are not sorted"
        )
    if candidate["file_count"] != len(records):
        raise QualityHarnessManifestError(
            "quality-harness implementation file count is incorrect"
        )

    root = _absolute_path(repository_root)
    discovered = discover_quality_harness_implementation_paths(root)
    if tuple(paths) != discovered:
        missing = len(set(discovered) - set(paths))
        extra = len(set(paths) - set(discovered))
        raise QualityHarnessManifestError(
            "quality-harness implementation path set is not exact "
            f"(missing={missing}, extra={extra})"
        )

    for record, relative_path in zip(records, paths):
        parsed = _validate_relative_path(relative_path)
        size_bytes, digest = _hash_regular_file(
            root.joinpath(*parsed.parts),
            root,
        )
        if record.get("size_bytes") != size_bytes:
            raise QualityHarnessManifestError(
                f"quality-harness implementation size mismatch: {relative_path}"
            )
        if record.get("sha256") != digest:
            raise QualityHarnessManifestError(
                f"quality-harness implementation hash mismatch: {relative_path}"
            )
    return str(actual_hash)
