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
from fractions import Fraction
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
from typing import Any, Iterable, Mapping


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIRECTORY / "media-preservation-contract-v1.json"
DEFAULT_RELEASE_CONTRACT = SCRIPT_DIRECTORY / "release-qualification-contract-v1.json"
CONTRACT_SCHEMA = "mirmir-ash-v4-media-preservation-contract-v1"
CAPTURE_SCHEMA = "mirmir-ash-v4-media-preservation-capture-v1"
REPORT_SCHEMA = "mirmir-ash-v4-media-preservation-report-v1"
SIDE_MANIFEST_SCHEMA = "mirmir-ash-v4-media-side-manifest-v1"
VERIFIER_SCHEMA = "mirmir-ash-v4-media-semantic-verifier-v1"
SEALED_MANIFEST_SCHEMA = "mirmir-ash-v4-media-preservation-sealed-manifest-v1"
TRACK_SCHEMA = "mirmir-ash-v4-track-observation-v1"
TIMING_SCHEMA = "mirmir-ash-v4-timing-observation-v1"
PIXEL_SCHEMA = "mirmir-ash-v4-pixel-observation-v1"
ATTACHMENT_SCHEMA = "mirmir-ash-v4-attachment-observation-v1"
HEX = frozenset("0123456789abcdef")


class EvidenceError(ValueError):
    """Evidence is stale, malformed, incomplete, or semantically incorrect."""


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value: str) -> None:
    raise EvidenceError(f"non-finite JSON number is forbidden: {value}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
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
        require(fixture["policy"] in {"p010_field_normalization", "alpha_geometry", "exact_pass_through"}, f"contract fixture {identifier} policy is invalid")
    require("combined_p010_hdr_interlaced" in covered and "combined_alpha_geometry" in covered, "mandatory combined fixtures are absent")
    capture = require_mapping(contract.get("capture"), "contract.capture")
    require(capture.get("buildConfiguration") == "Release", "capture must be Release")
    for key in ("captureSourceSHA256", "evaluatorSHA256", "fixtureSourceSHA256", "runnerSHA256"):
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
                "ordinal", "kind", "enabled", "mediaTypeID", "codecID", "languageCode",
                "extendedLanguageTag", "roleIDs", "timebase", "timeRangeSHA256", "editsSHA256",
                "formatSHA256", "metadataSHA256",
            ),
            f"{label}.track[{ordinal}]",
        )
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
                "visibleSHA256", "repeatVisibleSHA256", "alphaSHA256", "preEncodeAlphaSHA256",
                "decodedAlphaSHA256", "uniqueSignalCodeCount", "lowPaddingBitViolationCount",
            ),
            f"{label}.track[{ordinal}]",
        )
        for key in ("kind", "pixelFormat"):
            require_string(track[key], f"{label}.track[{ordinal}].{key}")
        for key in ("bitDepth", "width", "height", "frameCount", "uniqueSignalCodeCount", "lowPaddingBitViolationCount"):
            require_integer(track[key], f"{label}.track[{ordinal}].{key}")
        require_sha256(track["visibleSHA256"], f"{label}.track[{ordinal}].visibleSHA256")
        require_sha256(track["repeatVisibleSHA256"], f"{label}.track[{ordinal}].repeatVisibleSHA256")
        for key in ("alphaSHA256", "preEncodeAlphaSHA256", "decodedAlphaSHA256"):
            if track[key] is not None:
                require_sha256(track[key], f"{label}.track[{ordinal}].{key}")
    return tracks


def validate_attachment_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(value, ("schemaVersion", "fixtureID", "side", "tracks"), label)
    tracks = index_tracks(value, label)
    required = (
        "ordinal", "kind", "fieldCount", "fieldDetail", "cadence", "pixelAspectRatio",
        "cleanAperture", "preferredTransform", "colorPrimaries", "transferFunction",
        "yCbCrMatrix", "masteringDisplaySHA256", "contentLightSHA256", "dynamicHDRSamples",
        "alphaAssociation",
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
        for key in ("colorPrimaries", "transferFunction", "yCbCrMatrix", "masteringDisplaySHA256", "contentLightSHA256", "alphaAssociation"):
            if track[key] is not None:
                require_string(track[key], f"{label}.track[{ordinal}].{key}")
        for key in ("masteringDisplaySHA256", "contentLightSHA256"):
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


def compare_exact_pass_through(
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
    # The observation envelope records which side was inspected.  Side is not
    # media semantics, so compare exact observations after normalizing only
    # that provenance field.
    normalized_input_track = {**input_track, "side": "normalized"}
    normalized_output_track = {**output_track, "side": "normalized"}
    require(canonical_bytes(normalized_input_track) == canonical_bytes(normalized_output_track), f"{fixture_id} track semantics differ")
    require(set(input_timing) == set(output_timing), f"{fixture_id} timing track inventory differs")
    for ordinal in input_timing:
        require(input_timing[ordinal]["timingSHA256"] == output_timing[ordinal]["timingSHA256"], f"{fixture_id} track {ordinal} timing differs")
        require(input_timing[ordinal]["encodedPayloadSHA256"] == output_timing[ordinal]["encodedPayloadSHA256"], f"{fixture_id} track {ordinal} encoded samples differ")
    require(set(input_attachments) == set(output_attachments), f"{fixture_id} attachment inventory differs")
    for ordinal in input_attachments:
        require(canonical_bytes(input_attachments[ordinal]) == canonical_bytes(output_attachments[ordinal]), f"{fixture_id} track {ordinal} attachments differ")
    require(set(input_pixels) == set(output_pixels), f"{fixture_id} decoded-pixel inventory differs")
    for ordinal in input_pixels:
        require(input_pixels[ordinal]["visibleSHA256"] == output_pixels[ordinal]["visibleSHA256"], f"{fixture_id} track {ordinal} decoded pixels differ")


def coverage_checks(
    fixture: Mapping[str, Any],
    observations: Mapping[str, Mapping[str, Any]],
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
    if policy == "exact_pass_through":
        checked(
            "exact-track-timing-pixel-attachment-pass-through",
            lambda: compare_exact_pass_through(
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
    else:
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
        for key in ("masteringDisplaySHA256", "contentLightSHA256"):
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
        output_pixel = output_pixels[output_ordinal]
        require(output_pixel["preEncodeAlphaSHA256"] is not None, f"{fixture_id} lacks pre-encode alpha identity")
        require(output_pixel["preEncodeAlphaSHA256"] == output_pixel["decodedAlphaSHA256"] == output_pixel["alphaSHA256"], f"{fixture_id} ProRes 4444 alpha bytes differ")
        checks.append({"id": f"exact-prores4444-{expected}-alpha", "pass": True})

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


def evaluate_capture(
    capture_root: Path,
    candidate_path: Path,
    output_directory: Path,
    contract_path: Path,
    release_contract_path: Path,
    runtime_manifest_path: Path,
    release_configuration_path: Path,
    capture_source_path: Path,
    fixture_source_path: Path,
    evaluator_path: Path,
    runner_path: Path,
) -> dict[str, Any]:
    contract, contract_sha = load_contract(contract_path)
    release_contract = require_mapping(load_json(release_contract_path), "release contract")
    require(release_contract.get("schemaVersion") == "mirmir-ash-v4-release-qualification-contract-v1", "unsupported release contract")
    release_contract_sha = sha256_file(release_contract_path)
    candidate = candidate_identity(load_json(candidate_path))
    require(sha256_file(runtime_manifest_path) == candidate["runtimeManifestFileSHA256"], "candidate runtime-manifest file identity differs")
    require(sha256_file(release_configuration_path) == candidate["releaseConfigurationSHA256"], "candidate release configuration identity differs")
    tool_paths = {
        "captureSourceSHA256": capture_source_path,
        "fixtureSourceSHA256": fixture_source_path,
        "evaluatorSHA256": evaluator_path,
        "runnerSHA256": runner_path,
    }
    for key, path in tool_paths.items():
        require(sha256_file(path) == contract["capture"][key], f"locked tool identity differs: {key}")

    capture = require_mapping(load_json(capture_root / "capture.json"), "capture")
    require_exact_keys(capture, ("schemaVersion", "suiteID", "laneContractSHA256", "releaseContractSHA256", "candidate", "identities", "buildConfiguration", "fixtures"), "capture")
    require(capture["schemaVersion"] == CAPTURE_SCHEMA, "unsupported capture schema")
    require(capture["suiteID"] == contract["suiteID"], "capture suite identity differs")
    require(capture["laneContractSHA256"] == contract_sha, "capture lane contract is stale")
    require(capture["releaseContractSHA256"] == release_contract_sha, "capture release contract is stale")
    require(capture["candidate"] == candidate, "capture belongs to another candidate")
    require(capture["buildConfiguration"] == "Release", "capture was not built in Release")
    identities = require_mapping(capture["identities"], "capture.identities")
    expected_identities = {
        **{key: sha256_file(path) for key, path in tool_paths.items()},
        "sourceCommit": candidate["sourceCommit"],
        "sourceTreeIdentitySHA256": candidate["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": candidate["runtimeManifestFileSHA256"],
        "runtimeArtifactSetSHA256": candidate["runtimeArtifactSetSHA256"],
        "runtimeSourceRevision": candidate["runtimeSourceRevision"],
        "releaseConfigurationSHA256": candidate["releaseConfigurationSHA256"],
    }
    require(identities == expected_identities, "capture identities differ from exact candidate/tools")

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
        "run_media_preservation_v4.sh": runner_path,
        "candidate.json": candidate_path,
    }
    for name, source in binding_sources.items():
        shutil.copyfile(source, binding_directory / name)
    raw_capture_target = output_directory / "raw-capture"
    shutil.copytree(capture_root, raw_capture_target)

    expected_fixtures = {fixture["id"]: fixture for fixture in contract["fixtures"]}
    capture_fixtures = require_list(capture["fixtures"], "capture.fixtures")
    require(len(capture_fixtures) == len(expected_fixtures), "capture fixture count differs")
    seen: set[str] = set()
    report_fixtures: list[dict[str, Any]] = []
    total_enabled = 0
    for index, raw_fixture in enumerate(capture_fixtures):
        fixture = require_mapping(raw_fixture, f"capture fixture {index}")
        require_exact_keys(fixture, ("id", "coverage", "policy", "enabledInputTrackCount", "accountedOutputTrackCount", "production", "input", "output"), f"capture fixture {index}")
        fixture_id = require_string(fixture["id"], f"capture fixture {index}.id")
        require(fixture_id not in seen and fixture_id in expected_fixtures, f"unexpected/repeated capture fixture: {fixture_id}")
        seen.add(fixture_id)
        expected = expected_fixtures[fixture_id]
        require(fixture["coverage"] == expected["coverage"] and fixture["policy"] == expected["policy"], f"capture fixture {fixture_id} changed locked coverage/policy")
        production = require_mapping(fixture["production"], f"capture fixture {fixture_id}.production")
        require_exact_keys(production, ("releaseQualifiedRuntimeLoaded", "runtimeManifestSHA256", "trustRootConfigured", "requestedRouteExecutedWithoutFallback", "migrationConformant", "repeatedOutputIdentityPass"), f"capture fixture {fixture_id}.production")
        for key in ("releaseQualifiedRuntimeLoaded", "trustRootConfigured", "requestedRouteExecutedWithoutFallback", "migrationConformant", "repeatedOutputIdentityPass"):
            require_bool(production[key], f"capture fixture {fixture_id}.production.{key}", True)
        require(production["runtimeManifestSHA256"] == candidate["runtimeManifestSHA256"], f"capture fixture {fixture_id} used another runtime")

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
        checks = coverage_checks(fixture, observations)
        verifier = {
            "schemaVersion": VERIFIER_SCHEMA,
            "fixtureID": fixture_id,
            "policy": fixture["policy"],
            "coverage": fixture["coverage"],
            "candidateRuntimeManifestSHA256": candidate["runtimeManifestSHA256"],
            "inputManifestSHA256": sha256_file(side_manifest_paths["input"]),
            "outputManifestSHA256": sha256_file(side_manifest_paths["output"]),
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
        "identities": {
            "laneContractSHA256": contract_sha,
            "captureSourceSHA256": sha256_file(capture_source_path),
            "fixtureSourceSHA256": sha256_file(fixture_source_path),
            "evaluatorSHA256": sha256_file(evaluator_path),
            "runnerSHA256": sha256_file(runner_path),
            "captureSHA256": sha256_file(capture_root / "capture.json"),
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
    raw_capture = evidence / "raw-capture"
    with tempfile.TemporaryDirectory(prefix="mirmir-media-preservation-verify-") as temporary:
        recomputed = Path(temporary) / "media_preservation"
        report = evaluate_capture(
            raw_capture,
            bindings / "candidate.json",
            recomputed,
            bindings / "media-preservation-contract-v1.json",
            bindings / "release-qualification-contract-v1.json",
            bindings / "runtime-manifest.json",
            bindings / "Release.xcconfig",
            bindings / "MediaPreservationCaptureTests.swift",
            bindings / "AVFoundationTrackMigrationExecutorV4Tests.swift",
            bindings / "media_preservation_v4.py",
            bindings / "run_media_preservation_v4.sh",
        )
        compare_evidence_directories(recomputed, evidence)
        return report


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    evaluate = subparsers.add_parser("evaluate")
    evaluate.add_argument("--capture", type=Path, required=True)
    evaluate.add_argument("--candidate", type=Path, required=True)
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
            parsed.candidate.expanduser().resolve(strict=True),
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
