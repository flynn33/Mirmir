#!/usr/bin/env python3
"""Build and verify fail-closed M7 media-preservation evidence.

The Swift capture records AVFoundation observations and media bytes.  This
evaluator never trusts its pass flags: it validates every artifact identity,
recomputes each fixture policy, writes nested side manifests and a semantic
verifier, and seals the complete lane.  The M7 release evaluator performs the
same comparisons again from the sealed artifacts.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from fractions import Fraction
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
from typing import Any, Iterable, Mapping
import zipfile


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIRECTORY / "media-preservation-contract-v1.json"
DEFAULT_RELEASE_CONTRACT = SCRIPT_DIRECTORY / "release-qualification-contract-v1.json"
CONTRACT_SCHEMA = "mirmir-ash-v4-media-preservation-contract-v1"
CAPTURE_SCHEMA = "mirmir-ash-v4-media-preservation-capture-v2"
REPORT_SCHEMA = "mirmir-ash-v4-media-preservation-report-v2"
SIDE_MANIFEST_SCHEMA = "mirmir-ash-v4-media-side-manifest-v1"
VERIFIER_SCHEMA = "mirmir-ash-v4-media-semantic-verifier-v1"
SEALED_MANIFEST_SCHEMA = "mirmir-ash-v4-media-preservation-sealed-manifest-v2"
TRACK_SCHEMA = "mirmir-ash-v4-track-observation-v2"
TIMING_SCHEMA = "mirmir-ash-v4-timing-observation-v1"
PIXEL_SCHEMA = "mirmir-ash-v4-pixel-observation-v2"
ATTACHMENT_SCHEMA = "mirmir-ash-v4-attachment-observation-v1"
ROUTE_SCHEMA = "mirmir-ash-v4-media-production-route-receipt-v2"
EXECUTION_RECEIPT_SCHEMA = "ash.deterministic-media-execution-receipt.v4.1"
PREFLIGHT_SCHEMA = "mirmir-ash-v4-media-independent-preflight-v2"
EXPECTED_PREPARED_BACKEND_TYPE_BY_FIXTURE = {
    "combined-p010-hdr-interlaced": "Mirmir.PreparedDeterministicV4Upscaler",
    "combined-alpha-geometry-straight":
        "Mirmir.PreparedDeterministicAlphaPlanningBackendV4",
    "combined-alpha-geometry-premultiplied":
        "Mirmir.PreparedDeterministicAlphaPlanningBackendV4",
    "rich-track-graph": "Mirmir.PreparedDeterministicV4Upscaler",
    "legible-track-graph": "Mirmir.PreparedDeterministicV4Upscaler",
    "auxiliary-picture-track": "Mirmir.PreparedDeterministicV4Upscaler",
}
PACKAGE_SCHEMA = "mirmir-v4-packaged-candidate-identity-v1"
ATTESTATION_SCHEMA = "mirmir-v4-release-build-attestation-v1"
ATTESTATION_PATH = "MirmirV4BuildAttestation.json"
HEX = frozenset("0123456789abcdef")
PACKAGED_EVIDENCE_TOOL = SCRIPT_DIRECTORY / "packaged_candidate_evidence_v4.py"
RELEASE_ARCHIVE_TOOL = SCRIPT_DIRECTORY / "release_candidate_archive_v4.py"


class EvidenceError(ValueError):
    """Evidence is stale, malformed, incomplete, or semantically incorrect."""


@contextmanager
def snapshot_application_archive(path: Path) -> Iterable[Path]:
    """Hold one no-follow descriptor and inspect/copy only its byte snapshot."""

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor_number = -1
    try:
        descriptor_number = os.open(path, flags)
        before = os.fstat(descriptor_number)
        require(
            stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
            "application archive is not a single-link regular file",
        )
        with tempfile.TemporaryDirectory(
            prefix="mirmir-media-archive-snapshot-"
        ) as temporary:
            snapshot = Path(temporary) / "application-archive.zip"
            byte_count = 0
            with os.fdopen(os.dup(descriptor_number), "rb") as source, snapshot.open("xb") as target:
                while True:
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    target.write(block)
                    byte_count += len(block)
            after = os.fstat(descriptor_number)
            try:
                lexical_after = os.stat(path, follow_symlinks=False)
            except OSError as error:
                raise EvidenceError(
                    f"application archive path changed during snapshot: {error}"
                ) from error
            require(
                (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                and (before.st_dev, before.st_ino)
                == (lexical_after.st_dev, lexical_after.st_ino)
                and byte_count == before.st_size,
                "application archive changed during snapshot",
            )
            yield snapshot
    except OSError as error:
        raise EvidenceError(f"cannot snapshot application archive: {error}") from error
    finally:
        if descriptor_number >= 0:
            os.close(descriptor_number)


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value: str) -> None:
    raise EvidenceError(f"non-finite JSON number is forbidden: {value}")


def load_json_bytes(raw: bytes, label: str) -> Any:
    try:
        return json.loads(
            raw,
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot read canonical JSON {label}: {error}") from error


def load_json(path: Path) -> Any:
    try:
        return load_json_bytes(path.read_bytes(), str(path))
    except OSError as error:
        raise EvidenceError(f"cannot read canonical JSON {path}: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)
        + "\n",
        encoding="utf-8",
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise EvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be text")
    return value


def require_bool(value: Any, label: str, expected: bool | None = None) -> bool:
    require(type(value) is bool, f"{label} must be Boolean")
    if expected is not None:
        require(value is expected, f"{label} must be {str(expected).lower()}")
    return value


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    require(type(value) is int and value >= minimum, f"{label} must be an integer >= {minimum}")
    return value


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, unexpected={sorted(actual-expected_set)}",
    )


def require_sha256(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(len(text) == 64 and set(text) <= HEX, f"{label} must be lowercase SHA-256")
    return text


def require_revision(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(len(text) == 40 and set(text) <= HEX, f"{label} must be a full lowercase Git revision")
    return text


def require_safe_relative(value: Any, label: str) -> str:
    text = require_string(value, label)
    path = PurePosixPath(text)
    require(not path.is_absolute() and ".." not in path.parts and text == path.as_posix(), f"{label} is unsafe")
    return text


def require_fraction(value: Any, label: str) -> Fraction:
    text = require_string(value, label)
    try:
        result = Fraction(text)
    except (ValueError, ZeroDivisionError) as error:
        raise EvidenceError(f"{label} is not an exact rational") from error
    require(str(result) == text or (result.denominator == 1 and text == f"{result.numerator}/1"), f"{label} is not reduced")
    return result


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    relative = resolved.relative_to(root.resolve(strict=True)).as_posix()
    return {
        "path": relative,
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def checked_file(root: Path, relative: Any, label: str) -> Path:
    text = require_safe_relative(relative, label)
    path = (root / text).resolve(strict=True)
    require(path.is_file() and root.resolve(strict=True) in path.parents, f"{label} is not a regular file")
    require(not path.is_symlink(), f"{label} may not be a symbolic link")
    return path


def candidate_identity(value: Any) -> dict[str, Any]:
    candidate = require_mapping(value, "candidate")
    fields = {
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "runtimeSourceRevision",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
        "bundleIdentifier",
        "productVersion",
        "productBuild",
    }
    require_exact_keys(candidate, fields, "candidate")
    require_revision(candidate["sourceCommit"], "candidate.sourceCommit")
    for key in (
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
    ):
        require_sha256(candidate[key], f"candidate.{key}")
    runtime_revision = require_string(candidate["runtimeSourceRevision"], "candidate.runtimeSourceRevision")
    require(len(runtime_revision) in (40, 64) and set(runtime_revision) <= HEX, "candidate runtime revision is invalid")
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"candidate.{key}")
    return candidate


def validate_packaged_candidate_identity(
    value: Any,
    candidate: Mapping[str, Any],
) -> dict[str, Any]:
    package = require_mapping(value, "packaged candidate identity")
    fields = {
        "schemaVersion", "buildConfiguration", "applicationArchiveSHA256",
        "applicationPayloadIdentitySHA256", "applicationInfoPlistSHA256",
        "applicationExecutableSHA256", "codeDirectories",
        "codeDirectorySetSHA256", "designatedRequirementSHA256",
        "releaseConfigurationSHA256", "attestationSHA256", "sourceCommit",
        "sourceTreeIdentitySHA256", "runtimeManifestSHA256",
        "runtimeManifestFileSHA256", "runtimeArtifactSetSHA256",
        "runtimeSourceRevision", "bundleIdentifier", "productVersion",
        "productBuild",
    }
    require_exact_keys(package, fields, "packaged candidate identity")
    require(package["schemaVersion"] == PACKAGE_SCHEMA, "package schema differs")
    require(package["buildConfiguration"] == "Release", "package is not Release")
    require_revision(package["sourceCommit"], "package.sourceCommit")
    runtime_revision = require_string(
        package["runtimeSourceRevision"], "package.runtimeSourceRevision"
    )
    require(
        len(runtime_revision) in (40, 64) and set(runtime_revision) <= HEX,
        "package runtime source revision is invalid",
    )
    scalar_hashes = fields - {
        "schemaVersion", "buildConfiguration", "sourceCommit",
        "runtimeSourceRevision", "bundleIdentifier", "productVersion",
        "productBuild", "codeDirectories",
    }
    for key in scalar_hashes:
        require_sha256(package[key], f"package.{key}")
    architectures: list[str] = []
    for index, raw in enumerate(require_list(
        package["codeDirectories"], "package.codeDirectories"
    )):
        row = require_mapping(raw, f"package.codeDirectories[{index}]")
        require_exact_keys(row, ("architecture", "sha256"), f"package.codeDirectories[{index}]")
        architecture = require_string(
            row["architecture"], f"package.codeDirectories[{index}].architecture"
        )
        require(
            all(character.isalnum() or character == "_" for character in architecture),
            "package CodeDirectory architecture is invalid",
        )
        require_sha256(row["sha256"], f"package.codeDirectories[{index}].sha256")
        architectures.append(architecture)
    require(
        architectures == ["arm64", "x86_64"],
        "package CodeDirectories must be exactly arm64 and x86_64",
    )
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(package[key], f"package.{key}")
    projection = {
        "sourceCommit": package["sourceCommit"],
        "sourceTreeIdentitySHA256": package["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": package["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": package["runtimeManifestFileSHA256"],
        "runtimeArtifactSetSHA256": package["runtimeArtifactSetSHA256"],
        "runtimeSourceRevision": package["runtimeSourceRevision"],
        "releaseConfigurationSHA256": package["releaseConfigurationSHA256"],
        "appBundleSHA256": package["applicationArchiveSHA256"],
        "bundleIdentifier": package["bundleIdentifier"],
        "productVersion": package["productVersion"],
        "productBuild": package["productBuild"],
    }
    require(projection == candidate, "package differs from candidate identity")
    return dict(package)


def inspect_packaged_candidate(
    archive_path: Path,
    candidate: Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], bytes]:
    """Parse/rehash a stable archive snapshot; clean-build replay is separate."""
    require(
        archive_path.is_file() and not archive_path.is_symlink(),
        "application archive is missing, symbolic, or non-regular",
    )
    archive_sha = sha256_file(archive_path)
    require(
        archive_sha == candidate["appBundleSHA256"],
        "application archive differs from candidate identity",
    )
    try:
        with zipfile.ZipFile(archive_path) as archive:
            matches = [
                item for item in archive.infolist()
                if item.filename == ATTESTATION_PATH
            ]
            require(
                len(matches) == 1 and not matches[0].is_dir(),
                "application archive attestation is missing or repeated",
            )
            require(
                matches[0].file_size <= 16 * 1024 * 1024,
                "application archive attestation is oversized",
            )
            attestation_bytes = archive.read(matches[0])
    except (OSError, RuntimeError, zipfile.BadZipFile, KeyError) as error:
        raise EvidenceError(f"cannot inspect application archive: {error}") from error
    attestation = require_mapping(
        load_json_bytes(attestation_bytes, "application archive attestation"),
        "application archive attestation",
    )
    require(
        canonical_bytes(attestation) == attestation_bytes,
        "application archive attestation is not canonical JSON",
    )
    require(
        attestation.get("schemaVersion") == ATTESTATION_SCHEMA
        and attestation.get("buildConfiguration") == "Release"
        and attestation.get("hashAlgorithm") == "sha256",
        "application archive attestation header differs",
    )
    application = require_mapping(attestation.get("application"), "attested application")
    payload = require_mapping(attestation.get("archivePayload"), "attested archive payload")
    source = require_mapping(attestation.get("source"), "attested source")
    runtime = require_mapping(attestation.get("runtime"), "attested runtime")
    release = require_mapping(
        attestation.get("releaseConfiguration"), "attested release configuration"
    )
    package = {
        "schemaVersion": PACKAGE_SCHEMA,
        "buildConfiguration": attestation["buildConfiguration"],
        "applicationArchiveSHA256": archive_sha,
        "applicationPayloadIdentitySHA256": payload.get("identitySHA256"),
        "applicationInfoPlistSHA256": application.get("infoPlistSHA256"),
        "applicationExecutableSHA256": application.get("executableSHA256"),
        "codeDirectories": application.get("codeDirectories"),
        "codeDirectorySetSHA256": application.get("codeDirectorySetSHA256"),
        "designatedRequirementSHA256": application.get("designatedRequirementSHA256"),
        "releaseConfigurationSHA256": release.get("sha256"),
        "attestationSHA256": sha256_bytes(attestation_bytes),
        "sourceCommit": source.get("commit"),
        "sourceTreeIdentitySHA256": source.get("treeIdentitySHA256"),
        "runtimeManifestSHA256": runtime.get("manifestSHA256"),
        "runtimeManifestFileSHA256": runtime.get("manifestFileSHA256"),
        "runtimeArtifactSetSHA256": runtime.get("artifactSetSHA256"),
        "runtimeSourceRevision": runtime.get("sourceRevision"),
        "bundleIdentifier": application.get("bundleIdentifier"),
        "productVersion": application.get("productVersion"),
        "productBuild": application.get("productBuild"),
    }
    return (
        validate_packaged_candidate_identity(package, candidate),
        attestation,
        attestation_bytes,
    )


def load_contract(path: Path) -> tuple[dict[str, Any], str]:
    contract = require_mapping(load_json(path), "media-preservation contract")
    require(contract.get("schemaVersion") == CONTRACT_SCHEMA, "unsupported media-preservation contract")
    fixtures = require_list(contract.get("fixtures"), "contract.fixtures")
    require(len(fixtures) == 6, "media-preservation contract must lock six fixtures")
    seen: set[str] = set()
    covered: set[str] = set()
    for index, raw in enumerate(fixtures):
        fixture = require_mapping(raw, f"contract fixture {index}")
        require_exact_keys(fixture, ("id", "coverage", "policy"), f"contract fixture {index}")
        identifier = require_string(fixture["id"], f"contract fixture {index}.id")
        require(identifier not in seen, f"contract repeats fixture {identifier}")
        seen.add(identifier)
        coverage = require_list(fixture["coverage"], f"contract fixture {identifier}.coverage")
        require(coverage and len(coverage) == len(set(coverage)), f"contract fixture {identifier} coverage is empty/repeated")
        covered.update(coverage)
        require(
            fixture["policy"] in {
                "p010_field_normalization",
                "alpha_geometry",
                "process_primary_preserve_auxiliary",
            },
            f"contract fixture {identifier} policy is invalid",
        )
    require("combined_p010_hdr_interlaced" in covered and "combined_alpha_geometry" in covered, "mandatory combined fixtures are absent")
    capture = require_mapping(contract.get("capture"), "contract.capture")
    require_exact_keys(
        capture,
        {
            "buildConfiguration", "captureSourceSHA256",
            "evaluatorSHA256", "fixtureSourceSHA256", "runnerSHA256",
            "packagedEvidenceToolSHA256",
            "releaseCandidateArchiveToolSHA256", "observerSourceSHA256",
        },
        "contract.capture",
    )
    require(capture.get("buildConfiguration") == "Release", "capture must be Release")
    for key in (
        "captureSourceSHA256", "evaluatorSHA256", "fixtureSourceSHA256",
        "runnerSHA256", "packagedEvidenceToolSHA256",
        "releaseCandidateArchiveToolSHA256", "observerSourceSHA256",
    ):
        require_sha256(capture.get(key), f"contract.capture.{key}")
    return contract, sha256_file(path)


def validate_raw_descriptor(capture_root: Path, value: Any, label: str) -> Path:
    item = require_mapping(value, label)
    require_exact_keys(item, ("path", "byteCount", "sha256"), label)
    path = checked_file(capture_root, item["path"], f"{label}.path")
    require_integer(item["byteCount"], f"{label}.byteCount")
    require_sha256(item["sha256"], f"{label}.sha256")
    require(path.stat().st_size == item["byteCount"], f"{label} byte count mismatch")
    require(sha256_file(path) == item["sha256"], f"{label} SHA-256 mismatch")
    return path


def load_observation(path: Path, schema: str, fixture_id: str, side: str, label: str) -> dict[str, Any]:
    value = require_mapping(load_json(path), label)
    require(value.get("schemaVersion") == schema, f"{label} schema mismatch")
    require(value.get("fixtureID") == fixture_id, f"{label} fixture identity mismatch")
    require(value.get("side") == side, f"{label} side mismatch")
    return value


def index_tracks(observation: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    tracks = require_list(observation.get("tracks"), f"{label}.tracks")
    result: dict[int, dict[str, Any]] = {}
    for index, raw in enumerate(tracks):
        track = require_mapping(raw, f"{label}.tracks[{index}]")
        ordinal = require_integer(track.get("ordinal"), f"{label}.tracks[{index}].ordinal")
        require(ordinal not in result, f"{label} repeats track ordinal {ordinal}")
        result[ordinal] = track
    require(list(result) == sorted(result), f"{label} track order is not canonical")
    return result


def validate_track_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(
        value,
        (
            "schemaVersion", "fixtureID", "side", "enabledTrackCount", "tracks",
            "groups", "associations", "assetMetadataSHA256", "chapterMetadataSHA256",
        ),
        label,
    )
    require_sha256(value["assetMetadataSHA256"], f"{label}.assetMetadataSHA256")
    require_sha256(value["chapterMetadataSHA256"], f"{label}.chapterMetadataSHA256")
    tracks = index_tracks(value, label)
    enabled = 0
    for ordinal, track in tracks.items():
        require_exact_keys(
            track,
            (
                "ordinal", "stableID", "kind", "enabled", "mediaTypeID", "codecID", "languageCode",
                "extendedLanguageTag", "roleIDs", "timebase", "timeRangeSHA256", "editsSHA256",
                "formatSHA256", "metadataSHA256",
            ),
            f"{label}.track[{ordinal}]",
        )
        require_string(track["stableID"], f"{label}.track[{ordinal}].stableID")
        require_string(track["kind"], f"{label}.track[{ordinal}].kind")
        require_bool(track["enabled"], f"{label}.track[{ordinal}].enabled")
        enabled += int(track["enabled"])
        for key in ("mediaTypeID", "codecID", "timebase"):
            require_string(track[key], f"{label}.track[{ordinal}].{key}")
        for key in ("timeRangeSHA256", "editsSHA256", "formatSHA256", "metadataSHA256"):
            require_sha256(track[key], f"{label}.track[{ordinal}].{key}")
        require(isinstance(track["languageCode"], (str, type(None))), f"{label}.track[{ordinal}].languageCode is invalid")
        require(isinstance(track["extendedLanguageTag"], (str, type(None))), f"{label}.track[{ordinal}].extendedLanguageTag is invalid")
        roles = require_list(track["roleIDs"], f"{label}.track[{ordinal}].roleIDs")
        require(roles == sorted(set(roles)) and all(isinstance(item, str) and item for item in roles), f"{label}.track[{ordinal}] roles are noncanonical")
    require(require_integer(value["enabledTrackCount"], f"{label}.enabledTrackCount") == enabled, f"{label} enabled-track count mismatch")
    for key in ("groups", "associations"):
        require_list(value[key], f"{label}.{key}")
    return tracks


def validate_timing_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(value, ("schemaVersion", "fixtureID", "side", "tracks"), label)
    tracks = index_tracks(value, label)
    for ordinal, track in tracks.items():
        require_exact_keys(track, ("ordinal", "sampleCount", "timingSHA256", "encodedPayloadSHA256", "samples"), f"{label}.track[{ordinal}]")
        samples = require_list(track["samples"], f"{label}.track[{ordinal}].samples")
        require(require_integer(track["sampleCount"], f"{label}.track[{ordinal}].sampleCount") == len(samples), f"{label}.track[{ordinal}] sample count mismatch")
        require_sha256(track["timingSHA256"], f"{label}.track[{ordinal}].timingSHA256")
        require_sha256(track["encodedPayloadSHA256"], f"{label}.track[{ordinal}].encodedPayloadSHA256")
        require(track["timingSHA256"] == sha256_bytes(canonical_bytes([{key: sample[key] for key in ("pts", "dts", "duration")} for sample in samples])), f"{label}.track[{ordinal}] timing identity mismatch")
        require(track["encodedPayloadSHA256"] == sha256_bytes(canonical_bytes([sample["payloadSHA256"] for sample in samples])), f"{label}.track[{ordinal}] payload-set identity mismatch")
        for sample_index, raw_sample in enumerate(samples):
            sample = require_mapping(raw_sample, f"{label}.track[{ordinal}].sample[{sample_index}]")
            require_exact_keys(sample, ("pts", "dts", "duration", "byteCount", "payloadSHA256"), f"{label}.track[{ordinal}].sample[{sample_index}]")
            require_fraction(sample["pts"], f"{label}.track[{ordinal}].sample[{sample_index}].pts")
            if sample["dts"] != "invalid":
                require_fraction(sample["dts"], f"{label}.track[{ordinal}].sample[{sample_index}].dts")
            require_fraction(sample["duration"], f"{label}.track[{ordinal}].sample[{sample_index}].duration")
            require_integer(sample["byteCount"], f"{label}.track[{ordinal}].sample[{sample_index}].byteCount")
            require_sha256(sample["payloadSHA256"], f"{label}.track[{ordinal}].sample[{sample_index}].payloadSHA256")
    return tracks


def validate_pixel_observation(value: Mapping[str, Any], pixel_path: Path, label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(value, ("schemaVersion", "fixtureID", "side", "pixelArtifactSHA256", "pixelArtifactByteCount", "tracks"), label)
    require(sha256_file(pixel_path) == require_sha256(value["pixelArtifactSHA256"], f"{label}.pixelArtifactSHA256"), f"{label} pixel artifact SHA mismatch")
    require(pixel_path.stat().st_size == require_integer(value["pixelArtifactByteCount"], f"{label}.pixelArtifactByteCount"), f"{label} pixel artifact byte count mismatch")
    tracks = index_tracks(value, label)
    for ordinal, track in tracks.items():
        require_exact_keys(
            track,
            (
                "ordinal", "kind", "pixelFormat", "bitDepth", "width", "height", "frameCount",
                "visibleSHA256", "repeatVisibleSHA256", "alphaSHA256",
                "alphaFrameSHA256", "preEncodeAlphaFrameSHA256",
                "repeatPreEncodeAlphaFrameSHA256", "decodedAlphaSHA256",
                "uniqueSignalCodeCount", "lowPaddingBitViolationCount",
            ),
            f"{label}.track[{ordinal}]",
        )
        for key in ("kind", "pixelFormat"):
            require_string(track[key], f"{label}.track[{ordinal}].{key}")
        for key in ("bitDepth", "width", "height", "frameCount", "uniqueSignalCodeCount", "lowPaddingBitViolationCount"):
            require_integer(track[key], f"{label}.track[{ordinal}].{key}")
        require_sha256(track["visibleSHA256"], f"{label}.track[{ordinal}].visibleSHA256")
        require_sha256(track["repeatVisibleSHA256"], f"{label}.track[{ordinal}].repeatVisibleSHA256")
        for key in ("alphaSHA256", "decodedAlphaSHA256"):
            if track[key] is not None:
                require_sha256(track[key], f"{label}.track[{ordinal}].{key}")
        for key in (
            "alphaFrameSHA256", "preEncodeAlphaFrameSHA256",
            "repeatPreEncodeAlphaFrameSHA256",
        ):
            frames = require_list(track[key], f"{label}.track[{ordinal}].{key}")
            require(
                len(frames) in {0, track["frameCount"]},
                f"{label}.track[{ordinal}].{key} frame count differs",
            )
            for index, identity in enumerate(frames):
                require_sha256(
                    identity, f"{label}.track[{ordinal}].{key}[{index}]"
                )
    return tracks


def validate_attachment_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(value, ("schemaVersion", "fixtureID", "side", "tracks"), label)
    tracks = index_tracks(value, label)
    required = (
        "ordinal", "kind", "fieldCount", "fieldDetail", "cadence", "pixelAspectRatio",
        "cleanAperture", "preferredTransform", "colorPrimaries", "transferFunction",
        "yCbCrMatrix", "masteringDisplaySHA256", "contentLightSHA256",
        "ambientViewingEnvironmentSHA256", "dynamicHDRSamples", "alphaAssociation",
    )
    for ordinal, track in tracks.items():
        require_exact_keys(track, required, f"{label}.track[{ordinal}]")
        require_integer(track["fieldCount"], f"{label}.track[{ordinal}].fieldCount", 1)
        for key in ("kind", "fieldDetail", "cadence"):
            require_string(track[key], f"{label}.track[{ordinal}].{key}")
        sar = require_mapping(track["pixelAspectRatio"], f"{label}.track[{ordinal}].pixelAspectRatio")
        require_exact_keys(sar, ("horizontal", "vertical"), f"{label}.track[{ordinal}].pixelAspectRatio")
        require_integer(sar["horizontal"], f"{label}.track[{ordinal}].sar.horizontal", 1)
        require_integer(sar["vertical"], f"{label}.track[{ordinal}].sar.vertical", 1)
        clean = require_mapping(track["cleanAperture"], f"{label}.track[{ordinal}].cleanAperture")
        require_exact_keys(clean, ("width", "height", "horizontalOffset", "verticalOffset"), f"{label}.track[{ordinal}].cleanAperture")
        for key in clean:
            require_fraction(clean[key], f"{label}.track[{ordinal}].cleanAperture.{key}")
        transform = require_list(track["preferredTransform"], f"{label}.track[{ordinal}].preferredTransform")
        require(len(transform) == 6, f"{label}.track[{ordinal}] transform must have six values")
        for index, item in enumerate(transform):
            require_fraction(item, f"{label}.track[{ordinal}].preferredTransform[{index}]")
        for key in ("colorPrimaries", "transferFunction", "yCbCrMatrix", "masteringDisplaySHA256", "contentLightSHA256", "ambientViewingEnvironmentSHA256", "alphaAssociation"):
            if track[key] is not None:
                require_string(track[key], f"{label}.track[{ordinal}].{key}")
        for key in ("masteringDisplaySHA256", "contentLightSHA256", "ambientViewingEnvironmentSHA256"):
            if track[key] is not None:
                require_sha256(track[key], f"{label}.track[{ordinal}].{key}")
        dynamic = require_list(track["dynamicHDRSamples"], f"{label}.track[{ordinal}].dynamicHDRSamples")
        for sample_index, raw_sample in enumerate(dynamic):
            sample = require_mapping(raw_sample, f"{label}.track[{ordinal}].dynamic[{sample_index}]")
            require_exact_keys(sample, ("sampleOrdinal", "pts", "hdr10PlusSHA256", "postDecodeSHA256"), f"{label}.track[{ordinal}].dynamic[{sample_index}]")
            require_integer(sample["sampleOrdinal"], f"{label}.track[{ordinal}].dynamic[{sample_index}].ordinal")
            require_fraction(sample["pts"], f"{label}.track[{ordinal}].dynamic[{sample_index}].pts")
            for key in ("hdr10PlusSHA256", "postDecodeSHA256"):
                if sample[key] is not None:
                    require_sha256(sample[key], f"{label}.track[{ordinal}].dynamic[{sample_index}].{key}")
    return tracks


def first_video(tracks: Mapping[int, Mapping[str, Any]], label: str) -> tuple[int, Mapping[str, Any]]:
    videos = [(ordinal, track) for ordinal, track in tracks.items() if track.get("kind") == "video"]
    require(videos, f"{label} has no video observation")
    return videos[0]


def scale_geometry(input_track: Mapping[str, Any], output_track: Mapping[str, Any], input_pixel: Mapping[str, Any], output_pixel: Mapping[str, Any], label: str) -> None:
    width_scale = Fraction(output_pixel["width"], input_pixel["width"])
    height_scale = Fraction(output_pixel["height"], input_pixel["height"])
    require(width_scale > 0 and height_scale > 0, f"{label} has invalid scale")
    require(input_track["pixelAspectRatio"] == output_track["pixelAspectRatio"], f"{label} changed pixel aspect ratio")
    input_clean = input_track["cleanAperture"]
    output_clean = output_track["cleanAperture"]
    for key, scale in (("width", width_scale), ("height", height_scale), ("horizontalOffset", width_scale), ("verticalOffset", height_scale)):
        require(require_fraction(output_clean[key], f"{label}.output.clean.{key}") == require_fraction(input_clean[key], f"{label}.input.clean.{key}") * scale, f"{label} clean aperture {key} was not scaled exactly")
    source_transform = [require_fraction(value, f"{label}.input.transform") for value in input_track["preferredTransform"]]
    target_transform = [require_fraction(value, f"{label}.output.transform") for value in output_track["preferredTransform"]]
    require(target_transform[:4] == source_transform[:4], f"{label} changed transform rotation/shear")
    require(target_transform[4] == source_transform[4] * width_scale, f"{label} transform x translation was not scaled")
    require(target_transform[5] == source_transform[5] * height_scale, f"{label} transform y translation was not scaled")


def compare_processed_primary_preservation(
    fixture_id: str,
    input_track: Mapping[str, Any],
    output_track: Mapping[str, Any],
    input_timing: Mapping[int, Mapping[str, Any]],
    output_timing: Mapping[int, Mapping[str, Any]],
    input_pixels: Mapping[int, Mapping[str, Any]],
    output_pixels: Mapping[int, Mapping[str, Any]],
    input_attachments: Mapping[int, Mapping[str, Any]],
    output_attachments: Mapping[int, Mapping[str, Any]],
) -> None:
    input_tracks = index_tracks(input_track, f"{fixture_id}.input.track")
    output_tracks = index_tracks(output_track, f"{fixture_id}.output.track")
    input_primary, _ = first_video(input_tracks, f"{fixture_id} input")
    output_primary, _ = first_video(output_tracks, f"{fixture_id} output")
    require(input_primary == output_primary, f"{fixture_id} primary video ordinal differs")
    require(set(input_tracks) == set(output_tracks), f"{fixture_id} track inventory differs")
    for key in (
        "groups", "associations", "assetMetadataSHA256",
        "chapterMetadataSHA256",
    ):
        require(
            canonical_bytes(input_track[key]) == canonical_bytes(output_track[key]),
            f"{fixture_id} protected asset semantics differ: {key}",
        )
    protected_primary_keys = {
        "ordinal", "kind", "enabled", "mediaTypeID", "languageCode",
        "extendedLanguageTag", "roleIDs", "timebase", "timeRangeSHA256",
        "editsSHA256", "metadataSHA256",
    }
    require(
        {key: input_tracks[input_primary][key] for key in protected_primary_keys}
        == {key: output_tracks[output_primary][key] for key in protected_primary_keys},
        f"{fixture_id} processed primary changed protected track semantics",
    )
    for ordinal in input_tracks:
        if ordinal != input_primary:
            require(
                canonical_bytes({
                    key: value
                    for key, value in input_tracks[ordinal].items()
                    if key != "stableID"
                }) == canonical_bytes({
                    key: value
                    for key, value in output_tracks[ordinal].items()
                    if key != "stableID"
                }),
                f"{fixture_id} auxiliary track {ordinal} semantics differ",
            )
    require(set(input_timing) == set(output_timing), f"{fixture_id} timing track inventory differs")
    for ordinal in input_timing:
        if ordinal == input_primary:
            source_samples = input_timing[ordinal]["samples"]
            target_samples = output_timing[ordinal]["samples"]
            require(
                [
                    (sample["pts"], sample["duration"])
                    for sample in source_samples
                ]
                == [
                    (sample["pts"], sample["duration"])
                    for sample in target_samples
                ],
                f"{fixture_id} processed primary presentation timing differs",
            )
        else:
            require(
                input_timing[ordinal]["timingSHA256"]
                == output_timing[ordinal]["timingSHA256"],
                f"{fixture_id} auxiliary track {ordinal} timing differs",
            )
            require(
                input_timing[ordinal]["encodedPayloadSHA256"]
                == output_timing[ordinal]["encodedPayloadSHA256"],
                f"{fixture_id} auxiliary track {ordinal} encoded samples differ",
            )
    require(set(input_attachments) == set(output_attachments), f"{fixture_id} attachment inventory differs")
    for ordinal in input_attachments:
        if ordinal != input_primary:
            require(canonical_bytes(input_attachments[ordinal]) == canonical_bytes(output_attachments[ordinal]), f"{fixture_id} auxiliary track {ordinal} attachments differ")
    require(set(input_pixels) == set(output_pixels), f"{fixture_id} decoded-pixel inventory differs")
    for ordinal in input_pixels:
        if ordinal != input_primary:
            require(input_pixels[ordinal]["visibleSHA256"] == output_pixels[ordinal]["visibleSHA256"], f"{fixture_id} auxiliary track {ordinal} decoded pixels differ")


def validate_production_route(
    fixture_id: str,
    production_value: Any,
    candidate: Mapping[str, Any],
    capture_binding: Mapping[str, Any],
    observations: Mapping[str, Mapping[str, Any]],
    runtime_provenance_sha256: str,
) -> str:
    production = require_mapping(production_value, f"{fixture_id}.production")
    require_exact_keys(
        production,
        ("runtimeManifestSHA256", "routeReceipt"),
        f"{fixture_id}.production",
    )
    require(
        production["runtimeManifestSHA256"] == candidate["runtimeManifestSHA256"],
        f"{fixture_id} used another runtime",
    )
    route = require_mapping(
        production["routeReceipt"], f"{fixture_id}.production.routeReceipt"
    )
    route_keys = {
        "schemaVersion", "entryPoint", "executionProducer",
        "dispatchRequirement", "planEvidenceBoundary",
        "evidenceRequestSHA256", "evidenceNonceSHA256",
        "applicationArchiveSHA256", "applicationExecutableSHA256",
        "sourceTreeIdentitySHA256", "independentPreflight",
        "repeatIndependentPreflight", "executionReceipt",
        "repeatExecutionReceipt", "independentPreflightSHA256",
        "repeatIndependentPreflightSHA256", "executionReceiptSHA256",
        "repeatExecutionReceiptSHA256", "inputEnabledTrackCount",
        "outputEnabledTrackCount", "routeProofSHA256",
    }
    require_exact_keys(route, route_keys, f"{fixture_id}.production.routeReceipt")
    require(
        route["schemaVersion"] == ROUTE_SCHEMA
        and route["entryPoint"]
        == "VideoProcessingSession.processWithDeterministicV4ExecutionReceipt"
        and route["executionProducer"] == "exact_archived_mirmir_executable"
        and route["dispatchRequirement"]
        == "PreparedDeterministicV4RuntimePlanningBackend"
        and route["planEvidenceBoundary"]
        == "actual_session_receipt_matched_independent_preflight",
        f"{fixture_id} did not identify the exact shipping receipt boundary",
    )
    for key, expected in (
        ("evidenceRequestSHA256", capture_binding["evidenceRequestSHA256"]),
        ("evidenceNonceSHA256", capture_binding["evidenceNonceSHA256"]),
        (
            "applicationArchiveSHA256",
            capture_binding["packagedCandidateIdentity"][
                "applicationArchiveSHA256"
            ],
        ),
        (
            "applicationExecutableSHA256",
            capture_binding["packagedCandidateIdentity"][
                "applicationExecutableSHA256"
            ],
        ),
        ("sourceTreeIdentitySHA256", candidate["sourceTreeIdentitySHA256"]),
    ):
        require_sha256(route[key], f"{fixture_id}.{key}")
        require(route[key] == expected, f"{fixture_id} route binding differs: {key}")

    preflight_keys = {
        "schemaVersion", "preparedBackendType", "executor",
        "requestedBackendID", "ashPlanSHA256", "runtimeManifestSHA256",
        "runtimeProvenanceSHA256", "trackPlanSHA256",
        "sourceGraphSHA256", "migrationBlueprintSHA256",
        "primaryTrackOrdinal", "plannedTracks", "targetWidth",
        "targetHeight", "sourceVideoTrackCount", "sourceAudioTrackCount",
        "plannedEnabledTrackCount",
    }
    receipt_keys = {
        "schemaID", "preparedBackendType", "executor", "requestedBackendID",
        "actualBackendID", "ashPlanSHA256", "runtimeManifestSHA256",
        "runtimeProvenanceSHA256", "trackPlanSHA256",
        "sourceGraphSHA256", "migrationSourceGraphSHA256",
        "migrationPlanSHA256", "migrationBlueprintSHA256",
        "sourceAssetMetadataSHA256", "outputAssetMetadataSHA256",
        "sourceChapterMetadataSHA256", "outputChapterMetadataSHA256",
        "outputGraphSHA256", "semanticVerificationSHA256",
        "primaryTrackOrdinal", "plannedTracks", "migratedTracks",
        "targetWidth", "targetHeight", "encodedWidth", "encodedHeight",
        "processedFrameCount", "sourceVideoTrackCount",
        "sourceAudioTrackCount", "plannedEnabledTrackCount",
        "alphaVerification",
    }
    first_preflight = require_mapping(
        route["independentPreflight"], f"{fixture_id}.independentPreflight"
    )
    repeat_preflight = require_mapping(
        route["repeatIndependentPreflight"],
        f"{fixture_id}.repeatIndependentPreflight",
    )
    for label, preflight in (
        ("independentPreflight", first_preflight),
        ("repeatIndependentPreflight", repeat_preflight),
    ):
        require_exact_keys(preflight, preflight_keys, f"{fixture_id}.{label}")
        require(
            preflight["schemaVersion"] == PREFLIGHT_SCHEMA,
            f"{fixture_id} {label} schema differs",
        )
    require(
        first_preflight == repeat_preflight,
        f"{fixture_id} independent preflight is not repeatable",
    )
    expected_backend = EXPECTED_PREPARED_BACKEND_TYPE_BY_FIXTURE[fixture_id]
    require(
        first_preflight["preparedBackendType"] == expected_backend,
        f"{fixture_id} prepared backend does not match the locked fixture route",
    )
    require(
        require_sha256(
            first_preflight["runtimeManifestSHA256"],
            f"{fixture_id}.runtimeManifestSHA256",
        ) == candidate["runtimeManifestSHA256"]
        and require_sha256(
            first_preflight["runtimeProvenanceSHA256"],
            f"{fixture_id}.runtimeProvenanceSHA256",
        ) == runtime_provenance_sha256,
        f"{fixture_id} independent preflight runtime binding differs",
    )

    input_tracks = observations["inputTracks"]
    output_tracks = observations["outputTracks"]
    input_primary, _ = first_video(input_tracks, f"{fixture_id} input")
    output_primary, _ = first_video(output_tracks, f"{fixture_id} output")
    require(input_primary == output_primary, f"{fixture_id} primary ordinal differs")
    expected_planned: list[dict[str, Any]] = []
    for ordinal in sorted(input_tracks):
        track = input_tracks[ordinal]
        expected_planned.append({
            "ordinal": ordinal,
            "stableID": track["stableID"],
            "kind": track["kind"],
            "action": "process" if ordinal == input_primary else "pass_through",
        })
    planned_rows = require_list(
        first_preflight["plannedTracks"], f"{fixture_id}.plannedTracks"
    )
    projected: list[dict[str, Any]] = []
    for index, raw in enumerate(planned_rows):
        row = require_mapping(raw, f"{fixture_id}.plannedTracks[{index}]")
        require_exact_keys(
            row, ("ordinal", "stableID", "kind", "action"),
            f"{fixture_id}.plannedTracks[{index}]",
        )
        require_string(row["stableID"], f"{fixture_id}.plannedTracks[{index}].stableID")
        projected.append({
            key: row[key]
            for key in ("ordinal", "stableID", "kind", "action")
        })
    require(projected == expected_planned, f"{fixture_id} planned actions differ")

    input_track_observation = observations["inputTrackObservation"]
    output_track_observation = observations["outputTrackObservation"]
    output_pixels = observations["outputPixels"]
    output_timing = observations["outputTiming"]
    output_attachments = observations["outputAttachments"]
    output_pixel = output_pixels[output_primary]
    input_enabled = input_track_observation["enabledTrackCount"]
    output_enabled = output_track_observation["enabledTrackCount"]

    def validate_receipt(
        value: Any, label: str, expected_alpha_frames: list[str]
    ) -> Mapping[str, Any]:
        receipt = require_mapping(value, f"{fixture_id}.{label}")
        require_exact_keys(receipt, receipt_keys, f"{fixture_id}.{label}")
        require(
            receipt["schemaID"] == EXECUTION_RECEIPT_SCHEMA
            and receipt["preparedBackendType"] == expected_backend
            and receipt["executor"] == "cpu_fixed_point"
            and receipt["requestedBackendID"] == "mirmirDeterministicCPU"
            and receipt["actualBackendID"] == "mirmirDeterministicCPU",
            f"{fixture_id} {label} backend route differs",
        )
        for receipt_key, preflight_key in (
            ("preparedBackendType", "preparedBackendType"),
            ("executor", "executor"),
            ("requestedBackendID", "requestedBackendID"),
            ("ashPlanSHA256", "ashPlanSHA256"),
            ("runtimeManifestSHA256", "runtimeManifestSHA256"),
            ("runtimeProvenanceSHA256", "runtimeProvenanceSHA256"),
            ("trackPlanSHA256", "trackPlanSHA256"),
            ("sourceGraphSHA256", "sourceGraphSHA256"),
            ("migrationBlueprintSHA256", "migrationBlueprintSHA256"),
            ("primaryTrackOrdinal", "primaryTrackOrdinal"),
            ("plannedTracks", "plannedTracks"),
            ("targetWidth", "targetWidth"),
            ("targetHeight", "targetHeight"),
            ("sourceVideoTrackCount", "sourceVideoTrackCount"),
            ("sourceAudioTrackCount", "sourceAudioTrackCount"),
            ("plannedEnabledTrackCount", "plannedEnabledTrackCount"),
        ):
            require(
                receipt[receipt_key] == first_preflight[preflight_key],
                f"{fixture_id} {label} differs from independent preflight: {receipt_key}",
            )
        require(
            receipt["migrationSourceGraphSHA256"] == receipt["sourceGraphSHA256"]
            and receipt["migrationPlanSHA256"] == receipt["trackPlanSHA256"],
            f"{fixture_id} {label} internal plan receipt differs",
        )
        for key in (
            "ashPlanSHA256", "runtimeManifestSHA256",
            "runtimeProvenanceSHA256", "trackPlanSHA256",
            "sourceGraphSHA256",
            "migrationSourceGraphSHA256", "migrationPlanSHA256",
            "migrationBlueprintSHA256", "sourceAssetMetadataSHA256",
            "outputAssetMetadataSHA256", "sourceChapterMetadataSHA256",
            "outputChapterMetadataSHA256", "outputGraphSHA256",
            "semanticVerificationSHA256",
        ):
            require_sha256(receipt[key], f"{fixture_id}.{label}.{key}")
        require(
            receipt["sourceAssetMetadataSHA256"]
            == input_track_observation["assetMetadataSHA256"]
            and receipt["outputAssetMetadataSHA256"]
            == output_track_observation["assetMetadataSHA256"]
            and receipt["sourceChapterMetadataSHA256"]
            == input_track_observation["chapterMetadataSHA256"]
            and receipt["outputChapterMetadataSHA256"]
            == output_track_observation["chapterMetadataSHA256"],
            f"{fixture_id} {label} actual metadata receipt differs",
        )
        require(
            require_integer(receipt["primaryTrackOrdinal"], f"{fixture_id}.{label}.primary")
            == input_primary
            and require_integer(receipt["targetWidth"], f"{fixture_id}.{label}.width", 1)
            == require_integer(receipt["encodedWidth"], f"{fixture_id}.{label}.encodedWidth", 1)
            == output_pixel["width"]
            and require_integer(receipt["targetHeight"], f"{fixture_id}.{label}.height", 1)
            == require_integer(receipt["encodedHeight"], f"{fixture_id}.{label}.encodedHeight", 1)
            == output_pixel["height"]
            and require_integer(receipt["processedFrameCount"], f"{fixture_id}.{label}.frames", 1)
            == output_timing[output_primary]["sampleCount"]
            and require_integer(receipt["plannedEnabledTrackCount"], f"{fixture_id}.{label}.enabled", 1)
            == input_enabled,
            f"{fixture_id} {label} output/count receipt differs",
        )
        migrated_rows = require_list(
            receipt["migratedTracks"], f"{fixture_id}.{label}.migratedTracks"
        )
        expected_migrated = [
            row for row in planned_rows if row["action"] != "drop_with_consent"
        ]
        require(
            len(migrated_rows) == len(expected_migrated),
            f"{fixture_id} {label} migrated inventory count differs",
        )
        for index, (raw_migrated, planned) in enumerate(
            zip(migrated_rows, expected_migrated)
        ):
            migrated = require_mapping(
                raw_migrated, f"{fixture_id}.{label}.migratedTracks[{index}]"
            )
            require_exact_keys(
                migrated,
                {
                    "stableID", "action", "migratedSampleCount",
                    "sourceSampleStreamSHA256", "outputSampleStreamSHA256",
                },
                f"{fixture_id}.{label}.migratedTracks[{index}]",
            )
            require(
                migrated["stableID"] == planned["stableID"]
                and migrated["action"] == planned["action"],
                f"{fixture_id} {label} migrated stable-ID/action order differs",
            )
            ordinal = require_integer(
                planned["ordinal"], f"{fixture_id}.{label}.plannedOrdinal"
            )
            require(
                require_integer(
                    migrated["migratedSampleCount"],
                    f"{fixture_id}.{label}.migratedTracks[{index}].sampleCount",
                ) == output_timing[ordinal]["sampleCount"],
                f"{fixture_id} {label} migrated sample count differs",
            )
            source_stream = migrated["sourceSampleStreamSHA256"]
            output_stream = migrated["outputSampleStreamSHA256"]
            if planned["action"] == "pass_through":
                require(
                    require_sha256(
                        source_stream,
                        f"{fixture_id}.{label}.migratedTracks[{index}].sourceStream",
                    ) == require_sha256(
                        output_stream,
                        f"{fixture_id}.{label}.migratedTracks[{index}].outputStream",
                    ),
                    f"{fixture_id} {label} pass-through stream identity differs",
                )
            else:
                require(
                    source_stream is None and output_stream is None,
                    f"{fixture_id} {label} non-pass-through stream hashes are invalid",
                )
        alpha = receipt["alphaVerification"]
        if expected_alpha_frames:
            alpha = require_mapping(alpha, f"{fixture_id}.{label}.alphaVerification")
            require_exact_keys(
                alpha,
                {
                    "schemaID", "codec", "association", "inputLayout",
                    "width", "height", "encodedFormat", "frames",
                },
                f"{fixture_id}.{label}.alphaVerification",
            )
            require(
                alpha["schemaID"] == "ash.alpha-video-writer-verification.v4.1"
                and alpha["codec"] == "proRes4444"
                and alpha["association"]
                == output_attachments[output_primary]["alphaAssociation"]
                and alpha["inputLayout"] == "bgra8"
                and alpha["width"] == output_pixel["width"]
                and alpha["height"] == output_pixel["height"],
                f"{fixture_id} {label} alpha verification header differs",
            )
            frames = require_list(alpha["frames"], f"{fixture_id}.{label}.alpha.frames")
            expected_samples = output_timing[output_primary]["samples"]
            require(
                len(frames) == len(expected_alpha_frames) == len(expected_samples),
                f"{fixture_id} {label} alpha frame inventory differs",
            )
            source_frames: list[str] = []
            for index, raw in enumerate(frames):
                frame = require_mapping(raw, f"{fixture_id}.{label}.alpha.frames[{index}]")
                require_exact_keys(
                    frame,
                    {
                        "ordinal", "presentationTime", "alphaByteCount",
                        "sourceAlphaSHA256", "decodedAlphaSHA256",
                    },
                    f"{fixture_id}.{label}.alpha.frames[{index}]",
                )
                require(
                    require_integer(
                        frame["ordinal"],
                        f"{fixture_id}.{label}.alpha.frames[{index}].ordinal",
                    ) == index,
                    f"{fixture_id} {label} alpha frame ordinal differs",
                )
                require(
                    require_integer(
                        frame["alphaByteCount"],
                        f"{fixture_id}.{label}.alpha.frames[{index}].byteCount",
                        1,
                    ) == output_pixel["width"] * output_pixel["height"],
                    f"{fixture_id} {label} alpha byte count differs",
                )
                presentation = require_mapping(
                    frame["presentationTime"],
                    f"{fixture_id}.{label}.alpha.frames[{index}].presentationTime",
                )
                require_exact_keys(
                    presentation,
                    ("numerator", "denominator"),
                    f"{fixture_id}.{label}.alpha.frames[{index}].presentationTime",
                )
                numerator = presentation["numerator"]
                denominator = presentation["denominator"]
                require(
                    type(numerator) is int
                    and type(denominator) is int
                    and denominator > 0,
                    f"{fixture_id} {label} alpha presentation rational is invalid",
                )
                presentation_value = Fraction(numerator, denominator)
                require(
                    presentation_value.numerator == numerator
                    and presentation_value.denominator == denominator
                    and presentation_value == require_fraction(
                        expected_samples[index]["pts"],
                        f"{fixture_id}.{label}.alpha.expectedPTS[{index}]",
                    ),
                    f"{fixture_id} {label} alpha presentation time differs",
                )
                source_sha = require_sha256(
                    frame["sourceAlphaSHA256"],
                    f"{fixture_id}.{label}.alpha.frames[{index}].source",
                )
                decoded_sha = require_sha256(
                    frame["decodedAlphaSHA256"],
                    f"{fixture_id}.{label}.alpha.frames[{index}].decoded",
                )
                require(source_sha == decoded_sha, f"{fixture_id} {label} alpha frame differs")
                source_frames.append(source_sha)
            require(
                source_frames == expected_alpha_frames,
                f"{fixture_id} {label} pre-encode alpha evidence differs",
            )
        else:
            require(alpha is None, f"{fixture_id} {label} has unexpected alpha receipt")
        return receipt

    first_output_alpha = output_pixel["preEncodeAlphaFrameSHA256"]
    repeat_output_alpha = output_pixel["repeatPreEncodeAlphaFrameSHA256"]
    first_receipt = validate_receipt(
        route["executionReceipt"], "executionReceipt", first_output_alpha
    )
    repeat_receipt = validate_receipt(
        route["repeatExecutionReceipt"],
        "repeatExecutionReceipt",
        repeat_output_alpha,
    )
    require(
        first_output_alpha == repeat_output_alpha,
        f"{fixture_id} pre-encode alpha repeat differs",
    )
    require(
        first_receipt == repeat_receipt,
        f"{fixture_id} actual execution receipt is not repeatable",
    )
    for key, value in (
        ("independentPreflightSHA256", first_preflight),
        ("repeatIndependentPreflightSHA256", repeat_preflight),
        ("executionReceiptSHA256", first_receipt),
        ("repeatExecutionReceiptSHA256", repeat_receipt),
    ):
        require(
            require_sha256(route[key], f"{fixture_id}.{key}")
            == sha256_bytes(canonical_bytes(value)),
            f"{fixture_id} rehashed receipt identity differs: {key}",
        )
    require(
        route["independentPreflightSHA256"]
        == route["repeatIndependentPreflightSHA256"]
        and route["executionReceiptSHA256"]
        == route["repeatExecutionReceiptSHA256"],
        f"{fixture_id} preflight/execution receipt identities differ",
    )
    require(
        require_integer(route["inputEnabledTrackCount"], f"{fixture_id}.inputEnabled", 1)
        == input_enabled
        and require_integer(route["outputEnabledTrackCount"], f"{fixture_id}.outputEnabled", 1)
        == output_enabled,
        f"{fixture_id} route track accounting differs",
    )
    claimed_proof = require_sha256(
        route["routeProofSHA256"], f"{fixture_id}.routeProofSHA256"
    )
    proof_payload = dict(route)
    del proof_payload["routeProofSHA256"]
    require(
        claimed_proof == sha256_bytes(canonical_bytes(proof_payload)),
        f"{fixture_id} production route proof identity differs",
    )
    return claimed_proof

def alpha_axis_samples(source: int, target: int) -> list[tuple[list[int], list[int]]]:
    require(source > 0 and target >= source, "alpha oracle geometry is invalid")
    result: list[tuple[list[int], list[int]]] = []
    for destination in range(target):
        numerator = (2 * destination + 1) * source - target
        denominator = 2 * target
        base, remainder = divmod(numerator, denominator)
        phase = Fraction(remainder, denominator)
        n, d = phase.numerator, phase.denominator
        d2, d3 = d * d, d * d * d
        n2, n3 = n * n, n * n * n
        weight_numerators = [
            -n * d2 + 2 * n2 * d - n3,
            2 * d3 - 5 * n2 * d + 3 * n3,
            n * d2 + 4 * n2 * d - 3 * n3,
            -n2 * d + n3,
        ]
        common = 2 * d3
        require(sum(weight_numerators) == common, "alpha oracle cubic sum differs")
        floors: list[int] = []
        fractions: list[int] = []
        for weight in weight_numerators:
            quotient, fractional = divmod(weight * (1 << 14), common)
            floors.append(quotient)
            fractions.append(fractional)
        residual = (1 << 14) - sum(floors)
        require(0 <= residual <= 3, "alpha oracle coefficient residual differs")
        preferred = [1, 2, 0, 3] if phase <= Fraction(1, 2) else [2, 1, 3, 0]
        rank = {tap: index for index, tap in enumerate(preferred)}
        order = sorted(range(4), key=lambda tap: (-fractions[tap], rank[tap]))
        for tap in order[:residual]:
            floors[tap] += 1

        def reflect101(index: int) -> int:
            if source == 1:
                return 0
            period = 2 * (source - 1)
            reflected = index % period
            return reflected if reflected < source else period - reflected

        indices = [reflect101(base + offset) for offset in (-1, 0, 1, 2)]
        result.append((indices, floors))
    return result


def round_ties_to_even(value: int, fractional_bits: int) -> int:
    denominator = 1 << fractional_bits
    quotient, remainder = divmod(value, denominator)
    doubled = remainder * 2
    if doubled < denominator:
        return quotient
    if doubled > denominator:
        return quotient + 1
    return quotient if quotient % 2 == 0 else quotient + 1


def independent_alpha_oracle(
    source: bytes,
    source_width: int,
    source_height: int,
    target_width: int,
    target_height: int,
) -> bytes:
    require(
        len(source) == source_width * source_height,
        "alpha oracle source-plane length differs",
    )
    horizontal = alpha_axis_samples(source_width, target_width)
    vertical = alpha_axis_samples(source_height, target_height)
    intermediate: list[list[int]] = []
    for source_y in range(source_height):
        row: list[int] = []
        offset = source_y * source_width
        for indices, coefficients in horizontal:
            row.append(sum(
                source[offset + index] * coefficient
                for index, coefficient in zip(indices, coefficients)
            ))
        intermediate.append(row)
    output = bytearray()
    for indices, coefficients in vertical:
        for target_x in range(target_width):
            accumulator = sum(
                intermediate[index][target_x] * coefficient
                for index, coefficient in zip(indices, coefficients)
            )
            output.append(min(255, max(0, round_ties_to_even(accumulator, 28))))
    return bytes(output)


def validate_alpha_oracle_input(
    fixture_id: str,
    value: Any,
    capture_root: Path,
    input_pixel: Mapping[str, Any],
    output_pixel: Mapping[str, Any],
) -> list[str]:
    oracle = require_mapping(value, f"{fixture_id}.alphaOracleInput")
    require_exact_keys(
        oracle,
        {
            "schemaVersion", "artifact", "frameSHA256", "frameCount",
            "width", "height", "association",
        },
        f"{fixture_id}.alphaOracleInput",
    )
    require(
        oracle["schemaVersion"] == "mirmir-ash-v4-alpha-oracle-input-v1",
        f"{fixture_id} alpha oracle schema differs",
    )
    artifact = require_mapping(
        oracle["artifact"], f"{fixture_id}.alphaOracleInput.artifact"
    )
    require_exact_keys(
        artifact, {"path", "byteCount", "sha256"},
        f"{fixture_id}.alphaOracleInput.artifact",
    )
    path = checked_file(
        capture_root,
        artifact["path"],
        f"{fixture_id}.alphaOracleInput.artifact",
    )
    raw = path.read_bytes()
    require(
        len(raw) == require_integer(artifact["byteCount"], f"{fixture_id}.alpha.byteCount", 1)
        and sha256_bytes(raw) == require_sha256(artifact["sha256"], f"{fixture_id}.alpha.sha256"),
        f"{fixture_id} alpha oracle artifact differs",
    )
    width = require_integer(oracle["width"], f"{fixture_id}.alpha.width", 1)
    height = require_integer(oracle["height"], f"{fixture_id}.alpha.height", 1)
    frame_count = require_integer(
        oracle["frameCount"], f"{fixture_id}.alpha.frameCount", 1
    )
    frame_size = width * height
    require(len(raw) == frame_size * frame_count, f"{fixture_id} alpha oracle length differs")
    source_frame_sha = require_list(
        oracle["frameSHA256"], f"{fixture_id}.alpha.frameSHA256"
    )
    require(len(source_frame_sha) == frame_count, f"{fixture_id} alpha source frame count differs")
    for index in range(frame_count):
        expected = sha256_bytes(raw[index * frame_size:(index + 1) * frame_size])
        require(
            require_sha256(source_frame_sha[index], f"{fixture_id}.alpha.source[{index}]") == expected,
            f"{fixture_id} alpha source frame identity differs",
        )
    require(
        source_frame_sha == input_pixel["alphaFrameSHA256"],
        f"{fixture_id} independent alpha input differs from decoded source",
    )
    target_width = require_integer(output_pixel["width"], f"{fixture_id}.alpha.targetWidth", 1)
    target_height = require_integer(output_pixel["height"], f"{fixture_id}.alpha.targetHeight", 1)
    oracle_output = [
        sha256_bytes(independent_alpha_oracle(
            raw[index * frame_size:(index + 1) * frame_size],
            width,
            height,
            target_width,
            target_height,
        ))
        for index in range(frame_count)
    ]
    require(
        oracle_output
        == output_pixel["preEncodeAlphaFrameSHA256"]
        == output_pixel["repeatPreEncodeAlphaFrameSHA256"]
        == output_pixel["alphaFrameSHA256"],
        f"{fixture_id} independent scalar alpha oracle differs from production",
    )
    return oracle_output


def coverage_checks(
    fixture: Mapping[str, Any],
    observations: Mapping[str, Mapping[str, Any]],
    capture_root: Path,
) -> list[dict[str, Any]]:
    fixture_id = fixture["id"]
    coverage = set(fixture["coverage"])
    input_tracks = observations["inputTracks"]
    output_tracks = observations["outputTracks"]
    input_timing = observations["inputTiming"]
    output_timing = observations["outputTiming"]
    input_pixels = observations["inputPixels"]
    output_pixels = observations["outputPixels"]
    input_attachments = observations["inputAttachments"]
    output_attachments = observations["outputAttachments"]
    checks: list[dict[str, Any]] = []

    def checked(identifier: str, operation: Any) -> None:
        operation()
        checks.append({"id": identifier, "pass": True})

    policy = fixture["policy"]
    if policy == "process_primary_preserve_auxiliary":
        checked(
            "processed-primary-exact-auxiliary-preservation",
            lambda: compare_processed_primary_preservation(
                fixture_id,
                observations["inputTrackObservation"],
                observations["outputTrackObservation"],
                input_timing,
                output_timing,
                input_pixels,
                output_pixels,
                input_attachments,
                output_attachments,
            ),
        )
    if policy in {
        "p010_field_normalization",
        "alpha_geometry",
        "process_primary_preserve_auxiliary",
    }:
        input_video_ordinal, input_video = first_video(input_tracks, f"{fixture_id} input")
        output_video_ordinal, output_video = first_video(output_tracks, f"{fixture_id} output")
        require(input_video_ordinal in input_pixels and output_video_ordinal in output_pixels, f"{fixture_id} lacks video pixels")
        require(input_video_ordinal in input_attachments and output_video_ordinal in output_attachments, f"{fixture_id} lacks video attachments")
        checked(
            "exact-rational-geometry-transform",
            lambda: scale_geometry(
                input_attachments[input_video_ordinal],
                output_attachments[output_video_ordinal],
                input_pixels[input_video_ordinal],
                output_pixels[output_video_ordinal],
                fixture_id,
            ),
        )
        require(output_pixels[output_video_ordinal]["visibleSHA256"] == output_pixels[output_video_ordinal]["repeatVisibleSHA256"], f"{fixture_id} repeat output pixels differ")
        checks.append({"id": "repeat-output-visible-pixel-identity", "pass": True})

    if "p010_hdr_static_dynamic" in coverage:
        input_ordinal, _ = first_video(input_tracks, f"{fixture_id} input")
        output_ordinal, _ = first_video(output_tracks, f"{fixture_id} output")
        input_pixel = input_pixels[input_ordinal]
        output_pixel = output_pixels[output_ordinal]
        for side, pixel in (("input", input_pixel), ("output", output_pixel)):
            require(pixel["pixelFormat"] in {"x420", "xf20"} and pixel["bitDepth"] == 10, f"{fixture_id} {side} is not P010")
            require(pixel["lowPaddingBitViolationCount"] == 0, f"{fixture_id} {side} has nonzero P010 padding bits")
            require(pixel["uniqueSignalCodeCount"] > 256, f"{fixture_id} {side} does not prove retained 10-bit precision")
        source = input_attachments[input_ordinal]
        target = output_attachments[output_ordinal]
        require(source["colorPrimaries"] == target["colorPrimaries"] == "ITU_R_2020", f"{fixture_id} BT.2020 primaries differ")
        require(source["transferFunction"] == target["transferFunction"] == "SMPTE_ST_2084_PQ", f"{fixture_id} PQ transfer differs")
        require(source["yCbCrMatrix"] == target["yCbCrMatrix"] == "ITU_R_2020", f"{fixture_id} BT.2020 matrix differs")
        for key in ("masteringDisplaySHA256", "contentLightSHA256", "ambientViewingEnvironmentSHA256"):
            require(source[key] is not None and source[key] == target[key], f"{fixture_id} static HDR {key} differs")
        input_dynamic = source["dynamicHDRSamples"]
        output_dynamic = target["dynamicHDRSamples"]
        require(input_dynamic and len(output_dynamic) == len(input_dynamic) * 2, f"{fixture_id} dynamic HDR field replication count differs")
        for index, item in enumerate(input_dynamic):
            for duplicate in output_dynamic[index * 2 : index * 2 + 2]:
                require(duplicate["hdr10PlusSHA256"] == item["hdr10PlusSHA256"], f"{fixture_id} HDR10+ payload differs")
                require(duplicate["postDecodeSHA256"] == item["postDecodeSHA256"], f"{fixture_id} post-decode payload differs")
        checks.append({"id": "p010-static-and-frame-bound-dynamic-hdr-identity", "pass": True})

    if "interlaced_field_order_cadence" in coverage:
        input_ordinal, _ = first_video(input_tracks, f"{fixture_id} input")
        output_ordinal, _ = first_video(output_tracks, f"{fixture_id} output")
        source = input_attachments[input_ordinal]
        target = output_attachments[output_ordinal]
        require(source["fieldCount"] == 2 and source["fieldDetail"] == "temporal_top_first", f"{fixture_id} input field dominance is not TFF")
        require(source["cadence"] == "interlaced_tff_2_fields_per_sample", f"{fixture_id} input cadence differs")
        require(target["fieldCount"] == 1 and target["fieldDetail"] == "progressive", f"{fixture_id} output is not progressive")
        require(target["cadence"] == "progressive_double_rate", f"{fixture_id} output cadence differs")
        input_samples = input_timing[input_ordinal]["samples"]
        output_samples = output_timing[output_ordinal]["samples"]
        require(len(output_samples) == len(input_samples) * 2, f"{fixture_id} field-normalized sample count differs")
        for index, source_sample in enumerate(input_samples):
            duration = require_fraction(source_sample["duration"], f"{fixture_id}.source.duration")
            first, second = output_samples[index * 2 : index * 2 + 2]
            source_pts = require_fraction(source_sample["pts"], f"{fixture_id}.source.pts")
            require(require_fraction(first["pts"], f"{fixture_id}.first.pts") == source_pts, f"{fixture_id} first-field PTS differs")
            require(require_fraction(second["pts"], f"{fixture_id}.second.pts") == source_pts + duration / 2, f"{fixture_id} second-field PTS differs")
            require(require_fraction(first["duration"], f"{fixture_id}.first.duration") == duration / 2 and require_fraction(second["duration"], f"{fixture_id}.second.duration") == duration / 2, f"{fixture_id} field durations differ")
        checks.append({"id": "tff-field-order-and-double-rate-cadence", "pass": True})

    if "straight_alpha" in coverage or "premultiplied_alpha" in coverage:
        expected = "straight" if "straight_alpha" in coverage else "premultiplied"
        input_ordinal, _ = first_video(input_tracks, f"{fixture_id} input")
        output_ordinal, _ = first_video(output_tracks, f"{fixture_id} output")
        require(input_attachments[input_ordinal]["alphaAssociation"] == expected, f"{fixture_id} input alpha association differs")
        require(output_attachments[output_ordinal]["alphaAssociation"] == expected, f"{fixture_id} output alpha association differs")
        input_pixel = input_pixels[input_ordinal]
        output_pixel = output_pixels[output_ordinal]
        oracle_output = validate_alpha_oracle_input(
            fixture_id,
            fixture["alphaOracleInput"],
            capture_root,
            input_pixel,
            output_pixel,
        )
        require(
            len(oracle_output) == output_pixel["frameCount"],
            f"{fixture_id} alpha output frame count differs",
        )
        checks.append({
            "id": f"independent-scalar-prores4444-{expected}-alpha",
            "pass": True,
        })
    else:
        require(
            fixture["alphaOracleInput"] is None,
            f"{fixture_id} has unexpected alpha oracle input",
        )

    kinds = [track["kind"] for track in input_tracks.values()]
    output_kinds = [track["kind"] for track in output_tracks.values()]
    for coverage_id, kind in (
        ("subtitles", "subtitle"),
        ("captions", "caption"),
        ("chapters", "chapter"),
        ("timecode_tracks", "timecode"),
        ("timed_metadata", "timed_metadata"),
        ("auxiliary_tracks", "auxiliary"),
    ):
        if coverage_id in coverage:
            require(kind in kinds and kind in output_kinds, f"{fixture_id} lacks {kind} track")
            checks.append({"id": f"{coverage_id}-present-and-accounted", "pass": True})
    if "multiple_enabled_video_tracks" in coverage:
        require(sum(track["kind"] == "video" and track["enabled"] for track in input_tracks.values()) >= 2, f"{fixture_id} lacks multiple enabled input video tracks")
        require(sum(track["kind"] == "video" and track["enabled"] for track in output_tracks.values()) >= 2, f"{fixture_id} lacks multiple enabled output video tracks")
        checks.append({"id": "multiple-enabled-video-tracks-accounted", "pass": True})
    if "alternate_audio_tracks" in coverage:
        audio_ordinals = {ordinal for ordinal, track in input_tracks.items() if track["kind"] == "audio"}
        groups = require_list(observations["inputTrackObservation"]["groups"], f"{fixture_id}.groups")
        require(len(audio_ordinals) >= 2 and any(set(group.get("memberOrdinals", [])) <= audio_ordinals and len(group.get("memberOrdinals", [])) >= 2 for group in groups), f"{fixture_id} lacks an alternate-audio group")
        checks.append({"id": "alternate-audio-selection-group-accounted", "pass": True})
    return checks


def artifact_set_sha(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for path, identity in sorted(entries):
        digest.update(path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(identity.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def validate_packaged_media_binding(
    packaged_evidence: Path,
    capture_root: Path,
    runtime_manifest_path: Path,
    packaged_evidence_tool_path: Path,
) -> dict[str, Any]:
    specification = importlib.util.spec_from_file_location(
        "mirmir_packaged_candidate_evidence_v4",
        packaged_evidence_tool_path,
    )
    require(
        specification is not None and specification.loader is not None,
        "packaged-evidence verifier cannot be loaded",
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    repository = SCRIPT_DIRECTORY.parent.parent
    binding = module.validate_capture_binding(
        packaged_evidence,
        repository,
        runtime_manifest_path.parent,
    )
    require(binding["lane"] == "media", "packaged evidence used another lane")
    require(
        (packaged_evidence / "capture").resolve(strict=True)
        == capture_root.resolve(strict=True),
        "media capture root differs from packaged evidence",
    )
    return binding


def evaluate_capture(
    capture_root: Path,
    packaged_evidence_path: Path,
    candidate_path: Path,
    application_archive_path: Path,
    output_directory: Path,
    contract_path: Path,
    release_contract_path: Path,
    runtime_manifest_path: Path,
    release_configuration_path: Path,
    capture_source_path: Path,
    fixture_source_path: Path,
    evaluator_path: Path,
    runner_path: Path,
    packaged_evidence_tool_path: Path = PACKAGED_EVIDENCE_TOOL,
    release_archive_tool_path: Path = RELEASE_ARCHIVE_TOOL,
    observer_source_path: Path =
        SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift",
) -> dict[str, Any]:
    with snapshot_application_archive(application_archive_path) as snapshot:
        return _evaluate_capture_snapshot(
            capture_root,
            packaged_evidence_path,
            candidate_path,
            snapshot,
            output_directory,
            contract_path,
            release_contract_path,
            runtime_manifest_path,
            release_configuration_path,
            capture_source_path,
            fixture_source_path,
            evaluator_path,
            runner_path,
            packaged_evidence_tool_path,
            release_archive_tool_path,
            observer_source_path,
        )


def _evaluate_capture_snapshot(
    capture_root: Path,
    packaged_evidence_path: Path,
    candidate_path: Path,
    application_archive_path: Path,
    output_directory: Path,
    contract_path: Path,
    release_contract_path: Path,
    runtime_manifest_path: Path,
    release_configuration_path: Path,
    capture_source_path: Path,
    fixture_source_path: Path,
    evaluator_path: Path,
    runner_path: Path,
    packaged_evidence_tool_path: Path,
    release_archive_tool_path: Path,
    observer_source_path: Path,
) -> dict[str, Any]:
    contract, contract_sha = load_contract(contract_path)
    require(
        release_archive_tool_path.resolve(strict=True)
        == packaged_evidence_tool_path.resolve(strict=True).with_name(
            "release_candidate_archive_v4.py"
        ),
        "packaged-evidence provenance dependency path differs",
    )
    release_contract = require_mapping(load_json(release_contract_path), "release contract")
    require(release_contract.get("schemaVersion") == "mirmir-ash-v4-release-qualification-contract-v1", "unsupported release contract")
    release_contract_sha = sha256_file(release_contract_path)
    candidate = candidate_identity(load_json(candidate_path))
    packaged_candidate, _, attestation_bytes = inspect_packaged_candidate(
        application_archive_path,
        candidate,
    )
    packaged_binding = validate_packaged_media_binding(
        packaged_evidence_path,
        capture_root,
        runtime_manifest_path,
        packaged_evidence_tool_path,
    )
    require(
        packaged_binding["candidate"] == candidate
        and packaged_binding["packageIdentity"] == packaged_candidate,
        "packaged media candidate identity differs",
    )
    require(sha256_file(runtime_manifest_path) == candidate["runtimeManifestFileSHA256"], "candidate runtime-manifest file identity differs")
    runtime_manifest = require_mapping(
        load_json(runtime_manifest_path), "runtime manifest"
    )
    runtime_provenance = require_mapping(
        runtime_manifest.get("provenance"), "runtime manifest provenance"
    )
    runtime_manifest_sha256 = sha256_bytes(
        b"ash-p06-runtime-manifest-v4\0" + canonical_bytes(runtime_manifest)
    )
    runtime_provenance_sha256 = sha256_bytes(
        b"ash-p06-runtime-provenance-v4\0" + canonical_bytes(runtime_provenance)
    )
    require(
        runtime_manifest_sha256 == candidate["runtimeManifestSHA256"],
        "candidate runtime-manifest semantic identity differs",
    )
    require(sha256_file(release_configuration_path) == candidate["releaseConfigurationSHA256"], "candidate release configuration identity differs")
    tool_paths = {
        "captureSourceSHA256": capture_source_path,
        "fixtureSourceSHA256": fixture_source_path,
        "evaluatorSHA256": evaluator_path,
        "runnerSHA256": runner_path,
        "packagedEvidenceToolSHA256": packaged_evidence_tool_path,
        "releaseCandidateArchiveToolSHA256": release_archive_tool_path,
        "observerSourceSHA256": observer_source_path,
    }
    for key, path in tool_paths.items():
        require(sha256_file(path) == contract["capture"][key], f"locked tool identity differs: {key}")

    capture = require_mapping(load_json(capture_root / "capture.json"), "capture")
    require_exact_keys(
        capture,
        {
            "schemaVersion", "suiteID", "evidenceRequestSHA256",
            "evidenceNonceSHA256", "observerSourceSHA256",
            "laneContractSHA256", "fixtureManifestSHA256",
            "fixtureTreeSHA256", "fixtureSourceSHA256",
            "generatorSourceSHA256", "packagedCandidateIdentity",
            "buildConfiguration", "fixtures",
        },
        "capture",
    )
    require(capture["schemaVersion"] == CAPTURE_SCHEMA, "unsupported capture schema")
    require(capture["suiteID"] == contract["suiteID"], "capture suite identity differs")
    require(capture["laneContractSHA256"] == contract_sha, "capture lane contract is stale")
    require(capture["buildConfiguration"] == "Release", "capture was not built in Release")
    require(
        capture["packagedCandidateIdentity"] == packaged_candidate
        and capture["evidenceRequestSHA256"]
            == packaged_binding["requestSHA256"]
        and capture["observerSourceSHA256"]
            == packaged_binding["observerSourceSHA256"]
            == sha256_file(tool_paths["observerSourceSHA256"]),
        "capture packaged request/candidate/observer binding differs",
    )
    packaged_request = require_mapping(
        load_json(packaged_evidence_path / "observer/request.json"),
        "packaged media request",
    )
    request_environment = require_mapping(
        packaged_request.get("captureEnvironment"),
        "packaged media request environment",
    )
    require(
        capture["evidenceNonceSHA256"]
            == sha256_bytes(
                require_string(
                    packaged_request.get("nonce"), "packaged media nonce"
                ).encode("utf-8")
            )
        and capture["fixtureManifestSHA256"]
            == request_environment["MIRMIR_V4_MEDIA_FIXTURE_MANIFEST_SHA256"]
        and capture["fixtureTreeSHA256"]
            == request_environment["MIRMIR_V4_MEDIA_FIXTURE_TREE_SHA256"]
        and capture["fixtureSourceSHA256"]
            == sha256_file(fixture_source_path)
        and capture["generatorSourceSHA256"]
            == sha256_file(capture_source_path),
        "capture nonce/input-tree/source binding differs",
    )

    if output_directory.exists():
        require(output_directory.is_dir() and not any(output_directory.iterdir()), f"refusing to overwrite nonempty output directory: {output_directory}")
    output_directory.mkdir(parents=True, exist_ok=True)
    require(output_directory.name == "media_preservation", "role output directory must be named media_preservation")
    binding_directory = output_directory / "bindings"
    binding_directory.mkdir()
    binding_sources = {
        "release-qualification-contract-v1.json": release_contract_path,
        "runtime-manifest.json": runtime_manifest_path,
        "Release.xcconfig": release_configuration_path,
        "media-preservation-contract-v1.json": contract_path,
        "MediaPreservationCaptureTests.swift": capture_source_path,
        "AVFoundationTrackMigrationExecutorV4Tests.swift": fixture_source_path,
        "media_preservation_v4.py": evaluator_path,
        "packaged_candidate_evidence_v4.py": packaged_evidence_tool_path,
        "release_candidate_archive_v4.py": release_archive_tool_path,
        "MirmirApp.swift": tool_paths["observerSourceSHA256"],
        "run_media_preservation_v4.sh": runner_path,
        "candidate.json": candidate_path,
        "application-archive.zip": application_archive_path,
    }
    for name, source in binding_sources.items():
        shutil.copyfile(source, binding_directory / name)
    (binding_directory / ATTESTATION_PATH).write_bytes(attestation_bytes)
    write_json(
        binding_directory / "package-identity.json",
        packaged_candidate,
    )
    raw_capture_target = output_directory / "raw-capture"
    shutil.copytree(packaged_evidence_path, raw_capture_target)

    expected_fixtures = {fixture["id"]: fixture for fixture in contract["fixtures"]}
    capture_fixtures = require_list(capture["fixtures"], "capture.fixtures")
    require(len(capture_fixtures) == len(expected_fixtures), "capture fixture count differs")
    seen: set[str] = set()
    report_fixtures: list[dict[str, Any]] = []
    total_enabled = 0
    for index, raw_fixture in enumerate(capture_fixtures):
        fixture = require_mapping(raw_fixture, f"capture fixture {index}")
        require_exact_keys(
            fixture,
            (
                "id", "coverage", "policy", "enabledInputTrackCount",
                "accountedOutputTrackCount", "alphaOracleInput",
                "production", "input", "output",
            ),
            f"capture fixture {index}",
        )
        fixture_id = require_string(fixture["id"], f"capture fixture {index}.id")
        require(fixture_id not in seen and fixture_id in expected_fixtures, f"unexpected/repeated capture fixture: {fixture_id}")
        seen.add(fixture_id)
        expected = expected_fixtures[fixture_id]
        require(fixture["coverage"] == expected["coverage"] and fixture["policy"] == expected["policy"], f"capture fixture {fixture_id} changed locked coverage/policy")
        side_values: dict[str, dict[str, Any]] = {}
        side_manifest_paths: dict[str, Path] = {}
        fixture_output = output_directory / "fixtures" / fixture_id
        fixture_output.mkdir(parents=True)
        for side in ("input", "output"):
            side_descriptor = require_mapping(fixture[side], f"capture fixture {fixture_id}.{side}")
            require_exact_keys(side_descriptor, ("media", "trackObservation", "timingObservation", "pixels", "pixelObservation", "attachmentObservation"), f"capture fixture {fixture_id}.{side}")
            raw_paths = {name: validate_raw_descriptor(capture_root, side_descriptor[name], f"capture fixture {fixture_id}.{side}.{name}") for name in side_descriptor}
            target_side = fixture_output / side
            target_side.mkdir()
            copied: dict[str, Path] = {}
            canonical_names = {
                "media": "media.mov",
                "trackObservation": "track-observation.json",
                "timingObservation": "timing-observation.json",
                "pixels": "pixels.bin",
                "pixelObservation": "pixel-observation.json",
                "attachmentObservation": "attachment-observation.json",
            }
            for name, source in raw_paths.items():
                destination = target_side / canonical_names[name]
                shutil.copyfile(source, destination)
                copied[name] = destination
            track_observation = load_observation(copied["trackObservation"], TRACK_SCHEMA, fixture_id, side, f"{fixture_id}.{side}.track")
            timing_observation = load_observation(copied["timingObservation"], TIMING_SCHEMA, fixture_id, side, f"{fixture_id}.{side}.timing")
            pixel_observation = load_observation(copied["pixelObservation"], PIXEL_SCHEMA, fixture_id, side, f"{fixture_id}.{side}.pixel")
            attachment_observation = load_observation(copied["attachmentObservation"], ATTACHMENT_SCHEMA, fixture_id, side, f"{fixture_id}.{side}.attachment")
            tracks = validate_track_observation(track_observation, f"{fixture_id}.{side}.track")
            timing = validate_timing_observation(timing_observation, f"{fixture_id}.{side}.timing")
            pixels = validate_pixel_observation(pixel_observation, copied["pixels"], f"{fixture_id}.{side}.pixel")
            attachments = validate_attachment_observation(attachment_observation, f"{fixture_id}.{side}.attachment")
            require(set(timing) == set(tracks), f"{fixture_id}.{side} timing inventory differs from tracks")
            require(set(pixels) <= set(tracks) and set(attachments) <= set(tracks), f"{fixture_id}.{side} video observations reference missing tracks")
            side_values[side] = {
                "trackObservation": track_observation,
                "tracks": tracks,
                "timing": timing,
                "pixels": pixels,
                "attachments": attachments,
            }
            manifest = {
                "schemaVersion": SIDE_MANIFEST_SCHEMA,
                "fixtureID": fixture_id,
                "side": side,
                "enabledTrackCount": track_observation["enabledTrackCount"],
                "artifacts": {name: descriptor(path, output_directory.parent) for name, path in sorted(copied.items())},
                "semanticIdentities": {
                    "trackSHA256": sha256_bytes(canonical_bytes(track_observation)),
                    "timingSHA256": sha256_bytes(canonical_bytes(timing_observation)),
                    "pixelSHA256": sha256_bytes(canonical_bytes(pixel_observation)),
                    "attachmentSHA256": sha256_bytes(canonical_bytes(attachment_observation)),
                },
            }
            manifest_path = fixture_output / f"{side}-manifest.json"
            write_json(manifest_path, manifest)
            side_manifest_paths[side] = manifest_path

        enabled_input = require_integer(fixture["enabledInputTrackCount"], f"capture fixture {fixture_id}.enabledInputTrackCount", 1)
        accounted_output = require_integer(fixture["accountedOutputTrackCount"], f"capture fixture {fixture_id}.accountedOutputTrackCount", 1)
        require(enabled_input == side_values["input"]["trackObservation"]["enabledTrackCount"], f"capture fixture {fixture_id} enabled input count differs")
        require(accounted_output == side_values["output"]["trackObservation"]["enabledTrackCount"], f"capture fixture {fixture_id} output count differs")
        require(enabled_input == accounted_output, f"capture fixture {fixture_id} does not account for every enabled track")
        total_enabled += enabled_input
        observations = {
            "inputTrackObservation": side_values["input"]["trackObservation"],
            "outputTrackObservation": side_values["output"]["trackObservation"],
            "inputTracks": side_values["input"]["tracks"],
            "outputTracks": side_values["output"]["tracks"],
            "inputTiming": side_values["input"]["timing"],
            "outputTiming": side_values["output"]["timing"],
            "inputPixels": side_values["input"]["pixels"],
            "outputPixels": side_values["output"]["pixels"],
            "inputAttachments": side_values["input"]["attachments"],
            "outputAttachments": side_values["output"]["attachments"],
        }
        production_route_sha = validate_production_route(
            fixture_id,
            fixture["production"],
            candidate,
            capture,
            observations,
            runtime_provenance_sha256,
        )
        checks = [
            {
                "id": "video-processing-session-deterministic-v4-route",
                "pass": True,
            }
        ] + coverage_checks(fixture, observations, capture_root)
        verifier = {
            "schemaVersion": VERIFIER_SCHEMA,
            "fixtureID": fixture_id,
            "policy": fixture["policy"],
            "coverage": fixture["coverage"],
            "candidateRuntimeManifestSHA256": candidate["runtimeManifestSHA256"],
            "inputManifestSHA256": sha256_file(side_manifest_paths["input"]),
            "outputManifestSHA256": sha256_file(side_manifest_paths["output"]),
            "productionRouteProofSHA256": production_route_sha,
            "checks": checks,
            "violationCounts": {
                "unconsentedDropCount": 0,
                "silentToneMapCount": 0,
                "precisionReductionCount": 0,
                "alphaLossCount": 0,
                "geometryMismatchCount": 0,
                "metadataMismatchCount": 0,
            },
            "exactSemanticVerifierPass": True,
        }
        verifier_path = fixture_output / "semantic-verifier.json"
        write_json(verifier_path, verifier)
        report_fixtures.append(
            {
                "id": fixture_id,
                "coverage": fixture["coverage"],
                "enabledInputTrackCount": enabled_input,
                "accountedOutputTrackCount": accounted_output,
                **verifier["violationCounts"],
                "exactSemanticVerifierPass": True,
                "productionRouteProofSHA256": production_route_sha,
                "inputManifestArtifact": descriptor(side_manifest_paths["input"], output_directory.parent),
                "outputManifestArtifact": descriptor(side_manifest_paths["output"], output_directory.parent),
                "semanticVerifierArtifact": descriptor(verifier_path, output_directory.parent),
            }
        )
    require(seen == set(expected_fixtures), f"capture fixture set differs; missing={sorted(set(expected_fixtures)-seen)}")

    report = {
        "schemaVersion": REPORT_SCHEMA,
        "contractSHA256": release_contract_sha,
        "candidate": candidate,
        "releaseEligible": True,
        "evidenceBoundary": {
            "mediaExecutionProducer":
                "exact_verified_archived_mirmir_executable",
            "packagedCandidateBindingRole":
                "normative_output_execution_and_observation",
            "candidatePreparationReplayRole":
                "separate_release_candidate_preparation_replay_required",
            "mediaArchiveInspectionScope":
                "archive_extraction_executable_execution_and_tree_seal",
            "archivedExecutableExecutionClaimed": True,
            "fixtureHostRole":
                "source_fixture_generation_and_source_alpha_observation_only",
            "actualSessionReceiptRequired": True,
            "independentAlphaOracleRequired": True,
        },
        "identities": {
            "laneContractSHA256": contract_sha,
            "captureSourceSHA256": sha256_file(capture_source_path),
            "fixtureSourceSHA256": sha256_file(fixture_source_path),
            "evaluatorSHA256": sha256_file(evaluator_path),
            "runnerSHA256": sha256_file(runner_path),
            "packagedEvidenceToolSHA256": sha256_file(
                packaged_evidence_tool_path
            ),
            "releaseCandidateArchiveToolSHA256": sha256_file(
                release_archive_tool_path
            ),
            "observerSourceSHA256": sha256_file(
                tool_paths["observerSourceSHA256"]
            ),
            "packagedEvidenceRequestSHA256": packaged_binding[
                "requestSHA256"
            ],
            "packagedEvidenceCaptureTree": packaged_binding["captureTree"],
            "captureSHA256": sha256_file(capture_root / "capture.json"),
            "packagedCandidateIdentity": packaged_candidate,
        },
        "fixtures": report_fixtures,
        "accountedEnabledTrackCount": total_enabled,
        "mediaPreservationGatePass": True,
    }
    report_path = output_directory / "report.json"
    write_json(report_path, report)
    sealed_paths = sorted(path for path in output_directory.rglob("*") if path.is_file() and path.name != "sealed-manifest.json")
    sealed = {
        "schemaVersion": SEALED_MANIFEST_SCHEMA,
        "artifacts": [descriptor(path, output_directory) for path in sealed_paths],
        "artifactSetSHA256": artifact_set_sha((path.relative_to(output_directory).as_posix(), sha256_file(path)) for path in sealed_paths),
    }
    write_json(output_directory / "sealed-manifest.json", sealed)
    return report


def compare_evidence_directories(expected: Path, observed: Path) -> None:
    expected_files = {path.relative_to(expected).as_posix(): path for path in expected.rglob("*") if path.is_file()}
    observed_files = {path.relative_to(observed).as_posix(): path for path in observed.rglob("*") if path.is_file()}
    require(set(expected_files) == set(observed_files), f"evidence file set differs; missing={sorted(set(expected_files)-set(observed_files))}, unexpected={sorted(set(observed_files)-set(expected_files))}")
    for relative in sorted(expected_files):
        require(sha256_file(expected_files[relative]) == sha256_file(observed_files[relative]), f"evidence artifact differs after independent recomputation: {relative}")


def verify_evidence(evidence_directory: Path) -> dict[str, Any]:
    evidence = evidence_directory.resolve(strict=True)
    bindings = evidence / "bindings"
    packaged_capture = evidence / "raw-capture"
    raw_capture = packaged_capture / "capture"
    with tempfile.TemporaryDirectory(prefix="mirmir-media-preservation-verify-") as temporary:
        recomputed = Path(temporary) / "media_preservation"
        report = evaluate_capture(
            raw_capture,
            packaged_capture,
            bindings / "candidate.json",
            bindings / "application-archive.zip",
            recomputed,
            bindings / "media-preservation-contract-v1.json",
            bindings / "release-qualification-contract-v1.json",
            bindings / "runtime-manifest.json",
            bindings / "Release.xcconfig",
            bindings / "MediaPreservationCaptureTests.swift",
            bindings / "AVFoundationTrackMigrationExecutorV4Tests.swift",
            bindings / "media_preservation_v4.py",
            bindings / "run_media_preservation_v4.sh",
            bindings / "packaged_candidate_evidence_v4.py",
            bindings / "release_candidate_archive_v4.py",
            bindings / "MirmirApp.swift",
        )
        compare_evidence_directories(recomputed, evidence)
        return report


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    evaluate = subparsers.add_parser("evaluate")
    evaluate.add_argument("--capture", type=Path, required=True)
    evaluate.add_argument("--packaged-evidence", type=Path, required=True)
    evaluate.add_argument("--candidate", type=Path, required=True)
    evaluate.add_argument("--application-archive", type=Path, required=True)
    evaluate.add_argument("--output", type=Path, required=True)
    evaluate.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    evaluate.add_argument("--release-contract", type=Path, default=DEFAULT_RELEASE_CONTRACT)
    evaluate.add_argument("--runtime-manifest", type=Path, required=True)
    evaluate.add_argument("--release-configuration", type=Path, required=True)
    evaluate.add_argument("--capture-source", type=Path, required=True)
    evaluate.add_argument("--fixture-source", type=Path, required=True)
    evaluate.add_argument("--runner", type=Path, required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--evidence", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    parsed = arguments()
    if parsed.command == "evaluate":
        report = evaluate_capture(
            parsed.capture.expanduser().resolve(strict=True),
            parsed.packaged_evidence.expanduser().resolve(strict=True),
            parsed.candidate.expanduser().resolve(strict=True),
            parsed.application_archive.expanduser().resolve(strict=True),
            parsed.output.expanduser().resolve(),
            parsed.contract.expanduser().resolve(strict=True),
            parsed.release_contract.expanduser().resolve(strict=True),
            parsed.runtime_manifest.expanduser().resolve(strict=True),
            parsed.release_configuration.expanduser().resolve(strict=True),
            parsed.capture_source.expanduser().resolve(strict=True),
            parsed.fixture_source.expanduser().resolve(strict=True),
            Path(__file__).resolve(strict=True),
            parsed.runner.expanduser().resolve(strict=True),
        )
        print(json.dumps({"reportSHA256": sha256_bytes(canonical_bytes(report)), "fixtureCount": len(report["fixtures"]), "gatePass": True}, sort_keys=True))
        return 0
    if parsed.command == "verify":
        report = verify_evidence(parsed.evidence.expanduser().resolve(strict=True))
        print(json.dumps({"reportSHA256": sha256_bytes(canonical_bytes(report)), "fixtureCount": len(report["fixtures"]), "gatePass": True}, sort_keys=True))
        return 0
    raise AssertionError(parsed.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (EvidenceError, KeyError, OSError, TypeError, ValueError) as error:
        print(f"media-preservation qualification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
