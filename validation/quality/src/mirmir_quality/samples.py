"""Byte-bound native calibration samples derived from locked decoded frames."""

from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path, PurePosixPath
from typing import Dict, List, Mapping, Sequence, Tuple

import numpy as np

from .arrays import PlanarFrame, frame_sha256, normalize_code_plane
from .corpus import (
    bound_regular_file,
    full_frame_clean_aperture,
    identity_orientation,
    square_pixel_aspect_ratio,
)
from .json_tools import canonical_sha256, manifest_sha256


class DevelopmentSampleError(ValueError):
    pass


_SAMPLE_POLICY_TEMPLATE = {
    "selection": "representative_samples[0] with index 0 per source asset",
    "crop_dimensions": {"width": 324, "height": 192},
    "crop_alignment": "exact centered crop with even x/y origin for 4:2:0",
    "source_media_binding": (
        "decode media path resolves to the regular non-symlink corpus asset bytes"
    ),
    "decoded_frame_binding": (
        "retain upstream padded-buffer SHA-256 and independently hash active Y||CbCr bytes"
    ),
    "display_geometry": (
        "full-frame clean aperture, square pixels, and identity orientation only"
    ),
    "pixel_normalization": (
        "420v clamp Y to 16..235 and Cb/Cr to 16..240 before normalization; "
        "record every target-crop nominal-range excursion"
    ),
}

_SAMPLE_SPLIT_COUNTS = {
    "development": 6,
    "validation": 3,
}


def _require_calibration_split(split: str) -> int:
    try:
        return _SAMPLE_SPLIT_COUNTS[split]
    except KeyError as error:
        raise DevelopmentSampleError(
            "sample split must be development or validation"
        ) from error


def _sample_policy(split: str) -> Dict[str, object]:
    _require_calibration_split(split)
    return {"split": split, **deepcopy(_SAMPLE_POLICY_TEMPLATE)}


SAMPLE_POLICY = _sample_policy("development")
VALIDATION_SAMPLE_POLICY = _sample_policy("validation")

_COLOR_TRIPLET_ATTACHMENTS = {
    "CVImageBufferColorPrimaries": "ITU_R_709_2",
    "CVImageBufferTransferFunction": "ITU_R_709_2",
    "CVImageBufferYCbCrMatrix": "ITU_R_709_2",
}
_CHROMA_ATTACHMENTS = {
    "CVImageBufferChromaLocationTopField": "Left",
    "CVImageBufferChromaLocationBottomField": "Left",
}
_DECODED_COLOR_ATTACHMENTS = {
    **_COLOR_TRIPLET_ATTACHMENTS,
    **_CHROMA_ATTACHMENTS,
}
_CORPUS_COLOR_VALUES = {
    "color_primaries": "ITU_R_709_2",
    "transfer_function": "ITU_R_709_2",
    "ycbcr_matrix": "ITU_R_709_2",
    "range": "video",
    "chroma_location": "left",
}
_VALIDATION_COLOR_RESOLUTION_METHOD = (
    "validation_decoded_attachment_corpus_agreement_v1"
)
_VALIDATION_COLOR_OBSERVATION_HASH_SCOPE = (
    "canonical JSON of ordered representative index and required decoded attachment values"
)


def create_sample_lock(
    *,
    split: str,
    corpus_manifest_sha256: str,
    samples: Sequence[Mapping[str, object]],
) -> Dict[str, object]:
    _require_calibration_split(split)
    lock: Dict[str, object] = {
        "schema_version": "1.1.0",
        "corpus_manifest_sha256": corpus_manifest_sha256,
        "sample_policy": _sample_policy(split),
        "samples": [dict(sample) for sample in samples],
    }
    lock["manifest_sha256"] = manifest_sha256(lock)
    return lock


def create_development_sample_lock(
    *,
    corpus_manifest_sha256: str,
    samples: Sequence[Mapping[str, object]],
) -> Dict[str, object]:
    return create_sample_lock(
        split="development",
        corpus_manifest_sha256=corpus_manifest_sha256,
        samples=samples,
    )


def create_validation_sample_lock(
    *,
    corpus_manifest_sha256: str,
    samples: Sequence[Mapping[str, object]],
) -> Dict[str, object]:
    return create_sample_lock(
        split="validation",
        corpus_manifest_sha256=corpus_manifest_sha256,
        samples=samples,
    )


def _read_bound_payload(
    root: Path,
    relative_path: str,
    expected_sha256: str,
    expected_size: int,
    *,
    label: str,
) -> bytes:
    path = bound_regular_file(root, relative_path, label=label)
    payload = path.read_bytes()
    if len(payload) != expected_size:
        raise DevelopmentSampleError(f"{label} byte size does not match the lock")
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise DevelopmentSampleError(f"{label} SHA-256 does not match the lock")
    return payload


def _read_bound_json(
    root: Path,
    relative_path: str,
    expected_sha256: str,
    *,
    label: str,
) -> Tuple[Path, Mapping[str, object]]:
    path = bound_regular_file(root, relative_path, label=label)
    payload = path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise DevelopmentSampleError(f"{label} SHA-256 does not match the lock")
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DevelopmentSampleError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(document, dict):
        raise DevelopmentSampleError(f"{label} must contain a JSON object")
    return path, document


def _find_decode_record(
    decode_manifest: Mapping[str, object],
    expected_sha256: str,
) -> Mapping[str, object]:
    records = decode_manifest.get("representative_samples")
    if not isinstance(records, list) or not records:
        raise DevelopmentSampleError("decode manifest lacks representative samples")
    record = records[0]
    if not isinstance(record, dict):
        raise DevelopmentSampleError("first representative sample is not an object")
    if record.get("index") != 0:
        raise DevelopmentSampleError("selected decode record must have index 0")
    if canonical_sha256(record) != expected_sha256:
        raise DevelopmentSampleError(
            "selected decode record must be representative_samples[0]"
        )
    return record


def _validate_display_geometry(
    decode_manifest: Mapping[str, object],
    record: Mapping[str, object],
    *,
    width: int,
    height: int,
    asset_id: object,
) -> None:
    decoded = record.get("decoded_attachments")
    source = record.get("source_format_extensions")
    top_source = decode_manifest.get("source_format_extensions")
    if not isinstance(decoded, dict) or not isinstance(source, dict):
        raise DevelopmentSampleError(f"asset {asset_id} lacks display geometry metadata")
    if top_source != source:
        raise DevelopmentSampleError(
            f"asset {asset_id} top-level and selected source formats differ"
        )
    if not full_frame_clean_aperture(
        decoded.get("CVImageBufferCleanAperture"),
        width=width,
        height=height,
    ):
        raise DevelopmentSampleError(f"asset {asset_id} has a non-full-frame clean aperture")
    if not square_pixel_aspect_ratio(
        decoded.get("CVImageBufferPixelAspectRatio")
    ) or not square_pixel_aspect_ratio(source.get("CVPixelAspectRatio")):
        raise DevelopmentSampleError(f"asset {asset_id} has non-square pixels")
    for container in (decode_manifest, record, decoded, source):
        for key, value in container.items():
            normalized_key = "".join(
                character for character in str(key).lower() if character.isalnum()
            )
            if "cleanaperture" in normalized_key and not full_frame_clean_aperture(
                value,
                width=width,
                height=height,
            ):
                raise DevelopmentSampleError(
                    f"asset {asset_id} has a non-full-frame clean aperture"
                )
            if "pixelaspectratio" in normalized_key and not square_pixel_aspect_ratio(
                value
            ):
                raise DevelopmentSampleError(f"asset {asset_id} has non-square pixels")
            if any(token in normalized_key for token in ("orientation", "rotation", "transform")):
                if not identity_orientation(value):
                    raise DevelopmentSampleError(
                        f"asset {asset_id} has a non-identity orientation"
                    )


def _validate_asset_display_geometry(
    asset: Mapping[str, object],
    *,
    width: int,
    height: int,
) -> None:
    asset_id = asset.get("asset_id")
    if not full_frame_clean_aperture(
        asset.get("clean_aperture"),
        width=width,
        height=height,
    ):
        raise DevelopmentSampleError(
            f"asset {asset_id} has a non-full-frame clean aperture"
        )
    if not square_pixel_aspect_ratio(asset.get("pixel_aspect_ratio")):
        raise DevelopmentSampleError(f"asset {asset_id} has non-square pixels")
    if not identity_orientation(asset.get("orientation")):
        raise DevelopmentSampleError(f"asset {asset_id} has a non-identity orientation")


def _bound_decode_media(
    decode_manifest: Mapping[str, object],
    *,
    asset_root: Path,
    asset: Mapping[str, object],
) -> Path:
    asset_id = asset.get("asset_id")
    expected_relative = str(asset.get("relative_path", ""))
    asset_path = bound_regular_file(
        asset_root,
        expected_relative,
        label=f"asset {asset_id} source media",
    )
    media_value = decode_manifest.get("media_path")
    if not isinstance(media_value, str) or not media_value:
        raise DevelopmentSampleError(f"asset {asset_id} decode manifest lacks media_path")
    if "\x00" in media_value:
        raise DevelopmentSampleError(
            f"asset {asset_id} decode media path does not identify the corpus asset"
        )
    media_path = PurePosixPath(media_value)
    if media_path.is_absolute():
        expected_path = PurePosixPath(expected_relative)
        expected_parts = expected_path.parts
        normalized_media = media_path.as_posix()
        if (
            not expected_parts
            or expected_path.is_absolute()
            or expected_path.as_posix() != expected_relative
            or normalized_media != media_value
            or media_value.startswith("//")
            or "\\" in media_value
            or ".." in media_path.parts
            or len(media_path.parts) <= len(expected_parts)
            or media_path.parts[-len(expected_parts) :] != expected_parts
        ):
            raise DevelopmentSampleError(
                f"asset {asset_id} decode media path does not identify the corpus asset"
            )
        relative_media = expected_relative
    else:
        relative_media = media_path.as_posix()
    decoded_media_path = bound_regular_file(
        asset_root,
        relative_media,
        label=f"asset {asset_id} decoded source media",
    )
    if decoded_media_path != asset_path:
        raise DevelopmentSampleError(
            f"asset {asset_id} decode media path does not identify the corpus asset"
        )
    return asset_path


def _validate_source_media_bytes(
    path: Path,
    *,
    asset: Mapping[str, object],
    sample: Mapping[str, object],
) -> None:
    expected_path = str(asset.get("relative_path", ""))
    expected_sha256 = str(asset.get("sha256", ""))
    expected_size = int(asset.get("size_bytes", -1))
    if (
        sample.get("source_media_path") != expected_path
        or sample.get("source_media_sha256") != expected_sha256
        or sample.get("source_media_size_bytes") != expected_size
    ):
        raise DevelopmentSampleError("sample source-media binding does not match the corpus")
    payload = path.read_bytes()
    if len(payload) != expected_size or hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise DevelopmentSampleError("source media bytes do not match the corpus lock")


def _validate_decode_record_color_metadata(
    record: Mapping[str, object],
    *,
    asset_id: object,
) -> None:
    decoded = record.get("decoded_attachments")
    source = record.get("source_format_extensions")
    if not isinstance(decoded, dict) or any(
        decoded.get(field) != value
        for field, value in _DECODED_COLOR_ATTACHMENTS.items()
    ):
        raise DevelopmentSampleError(
            f"asset {asset_id} decode record has unsupported or absent decoded color metadata"
        )
    if (
        not isinstance(source, dict)
        or any(
            source.get(field) != value
            for field, value in _DECODED_COLOR_ATTACHMENTS.items()
        )
        or source.get("FullRangeVideo") is not False
    ):
        raise DevelopmentSampleError(
            f"asset {asset_id} decode record has unsupported or absent source color metadata"
        )


def _validation_color_resolution(
    decode_manifest: Mapping[str, object],
    asset: Mapping[str, object],
) -> Dict[str, object] | None:
    source = decode_manifest.get("source_format_extensions")
    if not isinstance(source, dict):
        raise DevelopmentSampleError(
            "validation decode manifest lacks source color metadata"
        )
    triplet_presence = [field in source for field in _COLOR_TRIPLET_ATTACHMENTS]
    if all(triplet_presence):
        return None
    if any(triplet_presence):
        raise DevelopmentSampleError(
            "validation source color triplet is partially present and ambiguous"
        )
    if (
        source.get("FullRangeVideo") is not False
        or any(source.get(field) != value for field, value in _CHROMA_ATTACHMENTS.items())
    ):
        raise DevelopmentSampleError(
            "validation source range or chroma metadata cannot support color resolution"
        )
    if any(asset.get(field) != value for field, value in _CORPUS_COLOR_VALUES.items()):
        raise DevelopmentSampleError(
            "validation corpus color metadata cannot support color resolution"
        )

    records = decode_manifest.get("representative_samples")
    if not isinstance(records, list) or not records:
        raise DevelopmentSampleError(
            "validation color resolution lacks representative decode records"
        )
    observations = []
    observed_indexes = set()
    for record in records:
        if not isinstance(record, dict):
            raise DevelopmentSampleError(
                "validation color resolution has a non-object representative record"
            )
        index = record.get("index")
        if not isinstance(index, int) or index in observed_indexes:
            raise DevelopmentSampleError(
                "validation color resolution has ambiguous representative indexes"
            )
        if record.get("source_format_extensions") != source:
            raise DevelopmentSampleError(
                "validation representative source color metadata is mixed"
            )
        decoded = record.get("decoded_attachments")
        if (
            not isinstance(decoded, dict)
            or record.get("pixel_format") != "420v"
            or any(
                decoded.get(field) != value
                for field, value in _DECODED_COLOR_ATTACHMENTS.items()
            )
        ):
            raise DevelopmentSampleError(
                "validation representative decoded color metadata is mixed or unsupported"
            )
        observations.append(
            {
                "index": index,
                "decoded_attachments": {
                    field: decoded[field] for field in _DECODED_COLOR_ATTACHMENTS
                },
            }
        )
        observed_indexes.add(index)

    return {
        "method": _VALIDATION_COLOR_RESOLUTION_METHOD,
        "source_color_triplet_status": "absent",
        "source_color_triplet_fields": list(_COLOR_TRIPLET_ATTACHMENTS),
        "source_range_evidence": {"FullRangeVideo": False},
        "source_chroma_evidence": deepcopy(_CHROMA_ATTACHMENTS),
        "decoded_attachment_values": deepcopy(_DECODED_COLOR_ATTACHMENTS),
        "corpus_values": deepcopy(_CORPUS_COLOR_VALUES),
        "representative_sample_count": len(observations),
        "representative_color_observations_hash_scope": (
            _VALIDATION_COLOR_OBSERVATION_HASH_SCOPE
        ),
        "representative_color_observations_sha256": canonical_sha256(observations),
    }


def _validate_and_resolve_color_metadata(
    decode_manifest: Mapping[str, object],
    record: Mapping[str, object],
    asset: Mapping[str, object],
    *,
    split: str,
) -> Dict[str, object] | None:
    if split == "development":
        _validate_decode_record_color_metadata(
            record,
            asset_id=asset.get("asset_id"),
        )
        return None
    resolution = _validation_color_resolution(decode_manifest, asset)
    if resolution is None:
        _validate_decode_record_color_metadata(
            record,
            asset_id=asset.get("asset_id"),
        )
    return resolution


def _verify_evidence_manifest_entry(
    evidence_manifest: Mapping[str, object],
    manifest_root: Path,
    bound_path: Path,
    expected_sha256: str,
    expected_size: int,
) -> None:
    try:
        relative_path = bound_path.relative_to(manifest_root).as_posix()
    except ValueError as error:
        raise DevelopmentSampleError("sample evidence escapes its frozen manifest root") from error
    files = evidence_manifest.get("files")
    if not isinstance(files, list):
        raise DevelopmentSampleError("source evidence manifest lacks file records")
    matches = [
        record
        for record in files
        if isinstance(record, dict) and record.get("path") == relative_path
    ]
    if len(matches) != 1:
        raise DevelopmentSampleError(
            "sample evidence is absent or ambiguous in its frozen manifest"
        )
    record = matches[0]
    if record.get("sha256") != expected_sha256 or record.get("size_bytes") != expected_size:
        raise DevelopmentSampleError(
            "frozen evidence-manifest binding does not match the sample"
        )


def _bound_record_plane(
    *,
    sample_root: Path,
    decode_root: Path,
    record_relative_path: object,
    label: str,
) -> Path:
    if not isinstance(record_relative_path, str):
        raise DevelopmentSampleError(f"{label} path is absent")
    try:
        decode_relative = decode_root.relative_to(sample_root.resolve(strict=True))
    except ValueError as error:
        raise DevelopmentSampleError("decode evidence escapes the sample root") from error
    combined = (decode_relative / record_relative_path).as_posix()
    return bound_regular_file(sample_root, combined, label=label)


def _plane_observation(codes: np.ndarray, *, minimum: int, maximum: int) -> Dict[str, int]:
    return {
        "minimum": int(np.min(codes)),
        "maximum": int(np.max(codes)),
        "below_nominal_count": int(np.count_nonzero(codes < minimum)),
        "above_nominal_count": int(np.count_nonzero(codes > maximum)),
    }


def _code_value_observation(
    y_codes: np.ndarray,
    cb_codes: np.ndarray,
    cr_codes: np.ndarray,
) -> Dict[str, object]:
    return {
        "y": _plane_observation(y_codes, minimum=16, maximum=235),
        "cb": _plane_observation(cb_codes, minimum=16, maximum=240),
        "cr": _plane_observation(cr_codes, minimum=16, maximum=240),
    }


def _target_frame(
    y_payload: bytes,
    cbcr_payload: bytes,
    *,
    source_width: int,
    source_height: int,
    crop: Mapping[str, object],
) -> Tuple[PlanarFrame, Dict[str, object]]:
    if len(y_payload) != source_width * source_height:
        raise DevelopmentSampleError("active Y byte count does not match source geometry")
    if len(cbcr_payload) != source_width * source_height // 2:
        raise DevelopmentSampleError("active CbCr byte count does not match 4:2:0 geometry")
    x = int(crop["x"])
    y = int(crop["y"])
    width = int(crop["width"])
    height = int(crop["height"])
    if x % 2 != 0 or y % 2 != 0 or width % 2 != 0 or height % 2 != 0:
        raise DevelopmentSampleError("4:2:0 crop geometry must be even")
    if x + width > source_width or y + height > source_height:
        raise DevelopmentSampleError("crop leaves the decoded source extent")

    y_codes = np.frombuffer(y_payload, dtype=np.uint8).reshape(source_height, source_width)
    uv_codes = np.frombuffer(cbcr_payload, dtype=np.uint8).reshape(
        source_height // 2,
        source_width,
    )
    cb_codes = uv_codes[:, 0::2]
    cr_codes = uv_codes[:, 1::2]
    chroma_x = x // 2
    chroma_y = y // 2
    chroma_width = width // 2
    chroma_height = height // 2
    cropped_y = y_codes[y : y + height, x : x + width]
    cropped_cb = cb_codes[
        chroma_y : chroma_y + chroma_height,
        chroma_x : chroma_x + chroma_width,
    ]
    cropped_cr = cr_codes[
        chroma_y : chroma_y + chroma_height,
        chroma_x : chroma_x + chroma_width,
    ]
    observation = _code_value_observation(cropped_y, cropped_cb, cropped_cr)
    frame = PlanarFrame(
        y=normalize_code_plane(np.clip(cropped_y, 16, 235), 16.0, 235.0),
        cb=normalize_code_plane(
            np.clip(cropped_cb, 16, 240),
            16.0,
            240.0,
            centered=True,
        ),
        cr=normalize_code_plane(
            np.clip(cropped_cr, 16, 240),
            16.0,
            240.0,
            centered=True,
        ),
    )
    return frame, observation


def load_sample_split(
    lock: Mapping[str, object],
    corpus: Mapping[str, object],
    *,
    split: str,
    sample_root: Path,
    asset_root: Path | None = None,
) -> List[Tuple[Mapping[str, object], PlanarFrame]]:
    expected_count = _require_calibration_split(split)
    if lock.get("schema_version") != "1.1.0":
        raise DevelopmentSampleError(f"unsupported {split} sample schema version")
    if lock.get("manifest_sha256") != manifest_sha256(lock):
        raise DevelopmentSampleError(f"{split} sample manifest hash mismatch")
    if lock.get("corpus_manifest_sha256") != corpus.get("manifest_sha256"):
        raise DevelopmentSampleError(f"{split} sample corpus binding mismatch")
    if lock.get("sample_policy") != _sample_policy(split):
        raise DevelopmentSampleError(f"{split} sample policy mismatch")
    media_root = asset_root if asset_root is not None else sample_root
    corpus_assets = corpus.get("assets")
    samples = lock.get("samples")
    if not isinstance(corpus_assets, list) or not isinstance(samples, list):
        raise DevelopmentSampleError("sample or corpus assets are absent")
    split_assets = {
        str(asset["source_asset_id"]): asset
        for asset in corpus_assets
        if isinstance(asset, dict) and asset.get("split") == split
    }
    if len(split_assets) != expected_count:
        raise DevelopmentSampleError(
            f"production {split} split must contain {expected_count} source assets"
        )
    if len(samples) != expected_count:
        raise DevelopmentSampleError(
            f"sample lock must contain {expected_count} {split} samples"
        )

    loaded: List[Tuple[Mapping[str, object], PlanarFrame]] = []
    observed = set()
    for sample in samples:
        if not isinstance(sample, dict):
            raise DevelopmentSampleError(f"{split} sample must be an object")
        source_id = str(sample.get("source_asset_id", ""))
        if source_id in observed or source_id not in split_assets:
            raise DevelopmentSampleError(
                f"sample source IDs must uniquely cover {split}"
            )
        asset = split_assets[source_id]
        if sample.get("asset_id") != asset.get("asset_id"):
            raise DevelopmentSampleError("sample asset ID does not match the corpus")
        route = str(sample.get("target_route", ""))
        if route not in asset.get("target_routes", []):
            raise DevelopmentSampleError("sample route is not declared by its corpus asset")
        for metadata_field in (
            "range",
            "color_primaries",
            "transfer_function",
            "ycbcr_matrix",
            "chroma_location",
        ):
            if sample.get(metadata_field) != asset.get(metadata_field):
                raise DevelopmentSampleError(
                    f"sample {metadata_field} does not match the corpus asset"
                )
        presentation_dimensions = asset.get("presentation_dimensions")
        if not isinstance(presentation_dimensions, list) or len(presentation_dimensions) != 2:
            raise DevelopmentSampleError("corpus asset lacks presentation dimensions")
        asset_width, asset_height = (int(value) for value in presentation_dimensions)
        if sample.get("source_dimensions") != {
            "width": asset_width,
            "height": asset_height,
        }:
            raise DevelopmentSampleError(
                "sample source dimensions do not match corpus presentation dimensions"
            )
        _validate_asset_display_geometry(
            asset,
            width=asset_width,
            height=asset_height,
        )
        if sample.get("display_geometry") != {
            "clean_aperture": "full_frame",
            "pixel_aspect_ratio": "1:1",
            "orientation": "identity",
        }:
            raise DevelopmentSampleError("sample display geometry binding mismatch")

        evidence_manifest_path, evidence_manifest = _read_bound_json(
            sample_root,
            str(sample["source_evidence_manifest_path"]),
            str(sample["source_evidence_manifest_sha256"]),
            label=f"sample {source_id} frozen evidence manifest",
        )
        evidence_manifest_root = evidence_manifest_path.parent
        decode_path, decode_manifest = _read_bound_json(
            sample_root,
            str(sample["decode_manifest_path"]),
            str(sample["decode_manifest_sha256"]),
            label=f"sample {source_id} decode manifest",
        )
        if (
            decode_manifest.get("asset_id") != sample.get("asset_id")
            or decode_manifest.get("split") != split
        ):
            raise DevelopmentSampleError("decode manifest asset ID mismatch")
        source_media_path = _bound_decode_media(
            decode_manifest,
            asset_root=media_root,
            asset=asset,
        )
        _validate_source_media_bytes(source_media_path, asset=asset, sample=sample)
        decode_record = _find_decode_record(
            decode_manifest,
            str(sample["selected_decode_record_sha256"]),
        )
        color_resolution = _validate_and_resolve_color_metadata(
            decode_manifest,
            decode_record,
            asset,
            split=split,
        )
        if color_resolution is None:
            if "metadata_resolution" in sample:
                raise DevelopmentSampleError(
                    "sample declares an unnecessary metadata resolution"
                )
        elif sample.get("metadata_resolution") != color_resolution:
            raise DevelopmentSampleError(
                "validation metadata resolution does not match frozen evidence"
            )
        _validate_display_geometry(
            decode_manifest,
            decode_record,
            width=asset_width,
            height=asset_height,
            asset_id=sample["asset_id"],
        )
        for field in ("decoded_frame_sha256", "width", "height", "pixel_format"):
            expected = sample.get(field)
            if field == "width":
                expected = sample["source_dimensions"]["width"]
            elif field == "height":
                expected = sample["source_dimensions"]["height"]
            if decode_record.get(field) != expected:
                raise DevelopmentSampleError(f"decode record {field} mismatch")
        if decode_record.get("plane_heights") != [asset_height, asset_height // 2]:
            raise DevelopmentSampleError("decode record plane heights mismatch")
        plane_bytes_per_row = decode_record.get("plane_bytes_per_row")
        if (
            not isinstance(plane_bytes_per_row, list)
            or len(plane_bytes_per_row) != 2
            or any(int(value) < asset_width for value in plane_bytes_per_row)
            or sample.get("plane_bytes_per_row") != plane_bytes_per_row
            or sample.get("plane_heights") != decode_record.get("plane_heights")
        ):
            raise DevelopmentSampleError("decode record plane storage geometry mismatch")
        if (
            decode_record.get("pts", {}).get("value")
            != sample["presentation_time"]["value"]
        ):
            raise DevelopmentSampleError("decode record presentation time value mismatch")
        if (
            decode_record.get("pts", {}).get("timescale")
            != sample["presentation_time"]["timescale"]
        ):
            raise DevelopmentSampleError("decode record presentation time timescale mismatch")

        expected_crop = {
            "x": ((asset_width - 324) // 2) & ~1,
            "y": ((asset_height - 192) // 2) & ~1,
            "width": 324,
            "height": 192,
        }
        if sample.get("crop") != expected_crop:
            raise DevelopmentSampleError("sample crop is not the exact centered crop")

        decode_root = decode_path.parent.parent
        y_path = bound_regular_file(
            sample_root,
            str(sample["y_active_path"]),
            label=f"sample {source_id} active Y",
        )
        cbcr_path = bound_regular_file(
            sample_root,
            str(sample["cbcr_active_path"]),
            label=f"sample {source_id} active CbCr",
        )
        expected_y_path = _bound_record_plane(
            sample_root=sample_root,
            decode_root=decode_root,
            record_relative_path=decode_record.get("y_active_path"),
            label=f"sample {source_id} decode-record Y",
        )
        expected_cbcr_path = _bound_record_plane(
            sample_root=sample_root,
            decode_root=decode_root,
            record_relative_path=decode_record.get("cbcr_active_path"),
            label=f"sample {source_id} decode-record CbCr",
        )
        if y_path != expected_y_path or cbcr_path != expected_cbcr_path:
            raise DevelopmentSampleError("active-plane path does not match the decode record")
        _verify_evidence_manifest_entry(
            evidence_manifest,
            evidence_manifest_root,
            decode_path,
            str(sample["decode_manifest_sha256"]),
            decode_path.stat().st_size,
        )
        _verify_evidence_manifest_entry(
            evidence_manifest,
            evidence_manifest_root,
            y_path,
            str(sample["y_active_sha256"]),
            int(sample["y_active_size_bytes"]),
        )
        _verify_evidence_manifest_entry(
            evidence_manifest,
            evidence_manifest_root,
            cbcr_path,
            str(sample["cbcr_active_sha256"]),
            int(sample["cbcr_active_size_bytes"]),
        )

        y_payload = _read_bound_payload(
            sample_root,
            str(sample["y_active_path"]),
            str(sample["y_active_sha256"]),
            int(sample["y_active_size_bytes"]),
            label=f"sample {source_id} active Y",
        )
        cbcr_payload = _read_bound_payload(
            sample_root,
            str(sample["cbcr_active_path"]),
            str(sample["cbcr_active_sha256"]),
            int(sample["cbcr_active_size_bytes"]),
            label=f"sample {source_id} active CbCr",
        )
        active_planes_sha256 = hashlib.sha256(y_payload + cbcr_payload).hexdigest()
        if sample.get("active_planes_sha256") != active_planes_sha256:
            raise DevelopmentSampleError("active-plane payload SHA-256 mismatch")
        target, observation = _target_frame(
            y_payload,
            cbcr_payload,
            source_width=int(sample["source_dimensions"]["width"]),
            source_height=int(sample["source_dimensions"]["height"]),
            crop=sample["crop"],
        )
        if sample.get("code_value_observation") != observation:
            raise DevelopmentSampleError("code-value excursion record mismatch")
        if frame_sha256(target) != sample["target_frame_sha256"]:
            raise DevelopmentSampleError("normalized target frame SHA-256 mismatch")
        _validate_source_media_bytes(source_media_path, asset=asset, sample=sample)
        observed.add(source_id)
        loaded.append((asset, target))

    if observed != set(split_assets):
        raise DevelopmentSampleError(
            f"sample lock does not cover every {split} source"
        )
    return loaded


def load_development_samples(
    lock: Mapping[str, object],
    corpus: Mapping[str, object],
    *,
    sample_root: Path,
    asset_root: Path | None = None,
) -> List[Tuple[Mapping[str, object], PlanarFrame]]:
    return load_sample_split(
        lock,
        corpus,
        split="development",
        sample_root=sample_root,
        asset_root=asset_root,
    )


def load_validation_samples(
    lock: Mapping[str, object],
    corpus: Mapping[str, object],
    *,
    sample_root: Path,
    asset_root: Path | None = None,
) -> List[Tuple[Mapping[str, object], PlanarFrame]]:
    return load_sample_split(
        lock,
        corpus,
        split="validation",
        sample_root=sample_root,
        asset_root=asset_root,
    )


def build_sample_record(
    *,
    asset: Mapping[str, object],
    target_route: str,
    sample_root: Path,
    decode_manifest_path: str,
    source_evidence_manifest_path: str,
    asset_root: Path | None = None,
    split: str = "development",
) -> Dict[str, object]:
    _require_calibration_split(split)
    if asset.get("split") != split:
        raise DevelopmentSampleError(
            "asset does not belong to the requested calibration split"
        )
    media_root = asset_root if asset_root is not None else sample_root
    evidence_manifest_path = bound_regular_file(
        sample_root,
        source_evidence_manifest_path,
        label=f"asset {asset['asset_id']} frozen evidence manifest",
    )
    evidence_payload = evidence_manifest_path.read_bytes()
    try:
        evidence_manifest = json.loads(evidence_payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DevelopmentSampleError("frozen evidence manifest is not valid JSON") from error
    if not isinstance(evidence_manifest, dict):
        raise DevelopmentSampleError("frozen evidence manifest must be an object")
    manifest_path = bound_regular_file(
        sample_root,
        decode_manifest_path,
        label=f"asset {asset['asset_id']} decode manifest",
    )
    decode_payload = manifest_path.read_bytes()
    try:
        decode_manifest = json.loads(decode_payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DevelopmentSampleError("decode manifest is not valid JSON") from error
    if not isinstance(decode_manifest, dict):
        raise DevelopmentSampleError("decode manifest must be an object")
    records = decode_manifest.get("representative_samples")
    if (
        decode_manifest.get("asset_id") != asset.get("asset_id")
        or decode_manifest.get("split") != split
        or not isinstance(records, list)
        or not records
    ):
        raise DevelopmentSampleError("decode manifest does not match the corpus asset")
    record = records[0]
    if (
        not isinstance(record, dict)
        or record.get("index") != 0
        or record.get("pixel_format") != "420v"
    ):
        raise DevelopmentSampleError(
            "decode manifest representative_samples[0] is not an eligible index-0 420v frame"
        )
    dimensions = asset.get("presentation_dimensions")
    if not isinstance(dimensions, list) or len(dimensions) != 2:
        raise DevelopmentSampleError("corpus asset lacks presentation dimensions")
    source_width, source_height = (int(value) for value in dimensions)
    _validate_asset_display_geometry(
        asset,
        width=source_width,
        height=source_height,
    )
    if record.get("width") != source_width or record.get("height") != source_height:
        raise DevelopmentSampleError(
            "decode dimensions do not match corpus presentation dimensions"
        )
    if source_width < 324 or source_height < 192:
        raise DevelopmentSampleError("decoded source is smaller than the locked crop")
    if record.get("plane_heights") != [source_height, source_height // 2]:
        raise DevelopmentSampleError("decode record plane heights mismatch")
    plane_bytes_per_row = record.get("plane_bytes_per_row")
    if (
        not isinstance(plane_bytes_per_row, list)
        or len(plane_bytes_per_row) != 2
        or any(int(value) < source_width for value in plane_bytes_per_row)
    ):
        raise DevelopmentSampleError("decode record plane storage geometry mismatch")
    color_resolution = _validate_and_resolve_color_metadata(
        decode_manifest,
        record,
        asset,
        split=split,
    )
    _validate_display_geometry(
        decode_manifest,
        record,
        width=source_width,
        height=source_height,
        asset_id=asset["asset_id"],
    )
    source_media_path = _bound_decode_media(
        decode_manifest,
        asset_root=media_root,
        asset=asset,
    )
    source_media_payload = source_media_path.read_bytes()
    if (
        len(source_media_payload) != int(asset.get("size_bytes", -1))
        or hashlib.sha256(source_media_payload).hexdigest() != asset.get("sha256")
    ):
        raise DevelopmentSampleError("source media bytes do not match the corpus lock")
    decode_root = manifest_path.parent.parent
    y_path = _bound_record_plane(
        sample_root=sample_root,
        decode_root=decode_root,
        record_relative_path=record.get("y_active_path"),
        label=f"asset {asset['asset_id']} decode-record Y",
    )
    cbcr_path = _bound_record_plane(
        sample_root=sample_root,
        decode_root=decode_root,
        record_relative_path=record.get("cbcr_active_path"),
        label=f"asset {asset['asset_id']} decode-record CbCr",
    )
    try:
        y_relative = y_path.relative_to(sample_root.resolve(strict=True)).as_posix()
        cbcr_relative = cbcr_path.relative_to(sample_root.resolve(strict=True)).as_posix()
    except ValueError as error:
        raise DevelopmentSampleError("decoded sample escapes the sample root") from error
    crop_x = ((source_width - 324) // 2) & ~1
    crop_y = ((source_height - 192) // 2) & ~1
    y_payload = y_path.read_bytes()
    cbcr_payload = cbcr_path.read_bytes()
    crop = {"x": crop_x, "y": crop_y, "width": 324, "height": 192}
    target, observation = _target_frame(
        y_payload,
        cbcr_payload,
        source_width=source_width,
        source_height=source_height,
        crop=crop,
    )
    evidence_manifest_root = evidence_manifest_path.parent
    _verify_evidence_manifest_entry(
        evidence_manifest,
        evidence_manifest_root,
        manifest_path,
        hashlib.sha256(decode_payload).hexdigest(),
        len(decode_payload),
    )
    _verify_evidence_manifest_entry(
        evidence_manifest,
        evidence_manifest_root,
        y_path,
        hashlib.sha256(y_payload).hexdigest(),
        len(y_payload),
    )
    _verify_evidence_manifest_entry(
        evidence_manifest,
        evidence_manifest_root,
        cbcr_path,
        hashlib.sha256(cbcr_payload).hexdigest(),
        len(cbcr_payload),
    )
    expected_metadata = {
        "range": "video",
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location": "left",
    }
    for field, expected in expected_metadata.items():
        if asset.get(field) != expected:
            raise DevelopmentSampleError(
                f"asset {asset['asset_id']} has unsupported or absent {field} metadata"
            )
    if source_media_path.read_bytes() != source_media_payload:
        raise DevelopmentSampleError("source media changed while building the sample lock")
    sample = {
        "asset_id": asset["asset_id"],
        "source_asset_id": asset["source_asset_id"],
        "target_route": target_route,
        "source_media_path": asset["relative_path"],
        "source_media_sha256": asset["sha256"],
        "source_media_size_bytes": asset["size_bytes"],
        "source_evidence_manifest_path": source_evidence_manifest_path,
        "source_evidence_manifest_sha256": hashlib.sha256(evidence_payload).hexdigest(),
        "decode_manifest_path": decode_manifest_path,
        "decode_manifest_sha256": hashlib.sha256(decode_payload).hexdigest(),
        "selected_decode_record_sha256": canonical_sha256(record),
        "decoded_frame_sha256": record["decoded_frame_sha256"],
        "active_planes_sha256": hashlib.sha256(y_payload + cbcr_payload).hexdigest(),
        "y_active_path": y_relative,
        "y_active_sha256": hashlib.sha256(y_payload).hexdigest(),
        "y_active_size_bytes": len(y_payload),
        "cbcr_active_path": cbcr_relative,
        "cbcr_active_sha256": hashlib.sha256(cbcr_payload).hexdigest(),
        "cbcr_active_size_bytes": len(cbcr_payload),
        "source_dimensions": {"width": source_width, "height": source_height},
        "plane_bytes_per_row": [int(value) for value in plane_bytes_per_row],
        "plane_heights": [source_height, source_height // 2],
        "pixel_format": "420v",
        **expected_metadata,
        "presentation_time": {
            "value": int(record["pts"]["value"]),
            "timescale": int(record["pts"]["timescale"]),
        },
        "crop": crop,
        "display_geometry": {
            "clean_aperture": "full_frame",
            "pixel_aspect_ratio": "1:1",
            "orientation": "identity",
        },
        "code_value_observation": observation,
        "target_frame_sha256": frame_sha256(target),
    }
    if color_resolution is not None:
        sample["metadata_resolution"] = color_resolution
    return sample
