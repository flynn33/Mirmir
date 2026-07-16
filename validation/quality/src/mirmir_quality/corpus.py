"""Corpus-lock creation and semantic validation without media decoding."""

from __future__ import annotations

from copy import deepcopy
from fractions import Fraction
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import secrets
from typing import Dict, Mapping, MutableMapping, Optional, Sequence, Set

from .json_tools import canonical_json_bytes, manifest_sha256, validate_schema


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SPLITS = {"development", "validation", "holdout"}
QUALITY_CATEGORIES = {
    "flat gradients",
    "horizontal/vertical/diagonal edges",
    "corners/junctions",
    "thin lines/text",
    "near-Nyquist patterns",
    "foliage/hair/fabric",
    "skin",
    "saturated chroma edges",
    "noise/compression",
    "camera/object motion",
    "occlusion",
    "scene cuts",
}


class CorpusValidationError(ValueError):
    pass


def create_corpus_lock(
    *,
    corpus_id: str,
    corpus_version: str,
    created_utc: str,
    split_policy: Mapping[str, object],
    assets: Sequence[Mapping[str, object]],
    category_vocabulary_version: str,
    holdout_policy: Optional[Mapping[str, object]] = None,
) -> Dict[str, object]:
    manifest: Dict[str, object] = {
        "schema_version": "1.1.0",
        "corpus_id": corpus_id,
        "corpus_version": corpus_version,
        "created_utc": created_utc,
        "category_vocabulary_version": category_vocabulary_version,
        "split_policy": deepcopy(dict(split_policy)),
        "holdout_policy": deepcopy(
            dict(
                holdout_policy
                or {
                    "state": "sealed",
                    "evaluation_opened_utc": None,
                    "access_requires_complete_configuration_lock": True,
                }
            )
        ),
        "canonicalization": "sorted-key compact UTF-8 JSON",
        "hash_scope": "entire document excluding /manifest_sha256",
        "assets": [deepcopy(dict(asset)) for asset in assets],
    }
    manifest["manifest_sha256"] = manifest_sha256(manifest)
    return manifest


def _relative_path(value: str) -> bool:
    path = PurePosixPath(value)
    return not path.is_absolute() and value not in {"", "."} and ".." not in path.parts


def full_frame_clean_aperture(value: object, *, width: int, height: int) -> bool:
    if value is None:
        return True
    return value in (
        {
            "Width": width,
            "Height": height,
            "HorizontalOffset": 0,
            "VerticalOffset": 0,
        },
        {
            "width": width,
            "height": height,
            "horizontal_offset": 0,
            "vertical_offset": 0,
        },
    )


def square_pixel_aspect_ratio(value: object) -> bool:
    return value is None or value in (
        {"HorizontalSpacing": 1, "VerticalSpacing": 1},
        {"horizontal_spacing": 1, "vertical_spacing": 1},
    )


def identity_orientation(value: object) -> bool:
    if value in (None, 0, 0.0, "identity"):
        return True
    if value == [1, 0, 0, 1, 0, 0]:
        return True
    return value == {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0}


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _bound_regular_file(root: Path, relative_path: str, *, label: str) -> Path:
    if not _relative_path(relative_path):
        raise CorpusValidationError(f"{label} has an unsafe relative path")
    root_resolved = root.resolve(strict=True)
    candidate = root_resolved.joinpath(*PurePosixPath(relative_path).parts)
    current = root_resolved
    for part in PurePosixPath(relative_path).parts:
        current = current / part
        if current.is_symlink():
            raise CorpusValidationError(f"{label} traverses a symbolic link")
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root_resolved)
    except (FileNotFoundError, ValueError) as error:
        raise CorpusValidationError(f"{label} is absent or escapes its evidence root") from error
    if not resolved.is_file():
        raise CorpusValidationError(f"{label} is not a regular file")
    return resolved


def _validate_bound_bytes(
    root: Path,
    relative_path: str,
    expected_sha256: str,
    *,
    label: str,
    expected_size: Optional[int] = None,
) -> None:
    path = _bound_regular_file(root, relative_path, label=label)
    if expected_size is not None and path.stat().st_size != expected_size:
        raise CorpusValidationError(f"{label} byte size does not match the lock")
    if _sha256_file(path) != expected_sha256:
        raise CorpusValidationError(f"{label} SHA-256 does not match the lock")


def bound_regular_file(root: Path, relative_path: str, *, label: str) -> Path:
    """Resolve one regular file below a root while rejecting symlink traversal."""

    return _bound_regular_file(root, relative_path, label=label)


def sha256_file(path: Path) -> str:
    """Hash one file in bounded chunks."""

    return _sha256_file(path)


def validate_corpus_bindings_for_splits(
    manifest: Mapping[str, object],
    *,
    asset_root: Path,
    evidence_root: Path,
    asset_splits: Set[str],
    evidence_splits: Set[str],
) -> None:
    """Rehash selected split bytes without requiring a sealed holdout mount."""

    if not asset_splits.issubset(SPLITS) or not evidence_splits.issubset(SPLITS):
        raise CorpusValidationError("binding validation requested an unknown split")
    assets = manifest.get("assets")
    if not isinstance(assets, list):
        raise CorpusValidationError("corpus assets are absent")
    for asset in assets:
        if not isinstance(asset, dict):
            raise CorpusValidationError("corpus asset must be an object")
        asset_id = str(asset.get("asset_id", ""))
        split = str(asset.get("split", ""))
        if split in asset_splits:
            _validate_bound_bytes(
                asset_root,
                str(asset.get("relative_path", "")),
                str(asset.get("sha256", "")),
                label=f"asset {asset_id}",
                expected_size=int(asset.get("size_bytes", -1)),
            )
        if split in evidence_splits:
            provenance = asset.get("provenance")
            rights = asset.get("rights")
            if not isinstance(provenance, dict) or not isinstance(rights, dict):
                raise CorpusValidationError(f"asset {asset_id} lacks binding records")
            _validate_bound_bytes(
                evidence_root,
                str(rights.get("license_or_declaration_path", "")),
                str(rights.get("license_or_declaration_sha256", "")),
                label=f"asset {asset_id} rights declaration",
            )
            _validate_bound_bytes(
                evidence_root,
                str(rights.get("item_specific_exception_evidence_path", "")),
                str(rights.get("item_specific_exception_evidence_sha256", "")),
                label=f"asset {asset_id} exception review",
            )
            _validate_bound_bytes(
                evidence_root,
                str(provenance.get("evidence_path", "")),
                str(provenance.get("evidence_sha256", "")),
                label=f"asset {asset_id} provenance record",
            )


def validate_corpus_lock(
    manifest: Mapping[str, object],
    *,
    allowed_categories: Optional[Set[str]] = None,
    require_all_splits: bool = True,
    require_exact_allocation: bool = False,
    require_category_minima: bool = False,
    asset_root: Optional[Path] = None,
    evidence_root: Optional[Path] = None,
) -> None:
    if manifest.get("schema_version") != "1.1.0":
        raise CorpusValidationError("unsupported corpus-lock schema version")
    expected_hash = manifest_sha256(manifest)
    if manifest.get("manifest_sha256") != expected_hash:
        raise CorpusValidationError("corpus manifest hash mismatch")
    assets = manifest.get("assets")
    if not isinstance(assets, list) or not assets:
        raise CorpusValidationError("corpus must contain assets")

    asset_ids = set()
    sha_values = set()
    source_split: MutableMapping[str, str] = {}
    family_split: MutableMapping[str, str] = {}
    observed_splits = set()
    category_sources: MutableMapping[str, Set[str]] = {}
    split_category_sources: MutableMapping[str, MutableMapping[str, Set[str]]] = {
        split: {} for split in SPLITS
    }
    for asset in assets:
        if not isinstance(asset, dict):
            raise CorpusValidationError("corpus asset must be an object")
        asset_id = str(asset.get("asset_id", ""))
        source_id = str(asset.get("source_asset_id", ""))
        family_id = str(asset.get("source_family_id", ""))
        relative_path = str(asset.get("relative_path", ""))
        digest = str(asset.get("sha256", ""))
        split = str(asset.get("split", ""))
        categories = asset.get("categories")
        rights = asset.get("rights")
        provenance = asset.get("provenance")
        if not asset_id or asset_id in asset_ids:
            raise CorpusValidationError("asset IDs must be present and unique")
        if not source_id or not family_id:
            raise CorpusValidationError(f"asset {asset_id} lacks source grouping")
        if not _relative_path(relative_path):
            raise CorpusValidationError(f"asset {asset_id} has an unsafe relative path")
        if not SHA256_PATTERN.fullmatch(digest) or digest in sha_values:
            raise CorpusValidationError(f"asset {asset_id} has an invalid or duplicate SHA-256")
        if split not in SPLITS:
            raise CorpusValidationError(f"asset {asset_id} has an invalid split")
        if not isinstance(categories, list) or not categories:
            raise CorpusValidationError(f"asset {asset_id} lacks categories")
        if allowed_categories is not None and not set(categories).issubset(allowed_categories):
            raise CorpusValidationError(f"asset {asset_id} uses an undeclared category")
        if not isinstance(rights, dict) or rights.get("status") != "confirmed":
            raise CorpusValidationError(f"asset {asset_id} lacks confirmed rights")
        permitted_uses = rights.get("permitted_uses")
        rights_path = str(rights.get("license_or_declaration_path", ""))
        rights_digest = str(rights.get("license_or_declaration_sha256", ""))
        exception_path = str(rights.get("item_specific_exception_evidence_path", ""))
        exception_digest = str(rights.get("item_specific_exception_evidence_sha256", ""))
        if (
            not rights_path
            or not SHA256_PATTERN.fullmatch(rights_digest)
            or not exception_path
            or not SHA256_PATTERN.fullmatch(exception_digest)
            or not permitted_uses
        ):
            raise CorpusValidationError(f"asset {asset_id} lacks rights evidence")
        if rights.get("item_specific_exception_status") not in {
            "none_found",
            "not_applicable_project_owned",
        }:
            raise CorpusValidationError(f"asset {asset_id} has a disqualifying rights exception")
        if (
            "local-project-testing" not in permitted_uses
            or rights.get("derivative_artifacts_permitted") is not True
        ):
            raise CorpusValidationError(f"asset {asset_id} rights do not permit benchmark use")
        if not isinstance(provenance, dict):
            raise CorpusValidationError(f"asset {asset_id} lacks provenance evidence")
        provenance_path = str(provenance.get("evidence_path", ""))
        provenance_digest = str(provenance.get("evidence_sha256", ""))
        if not provenance_path or not SHA256_PATTERN.fullmatch(provenance_digest):
            raise CorpusValidationError(f"asset {asset_id} lacks provenance evidence")
        if asset.get("native_target") is not True or asset.get("derived") is not False:
            raise CorpusValidationError(f"asset {asset_id} is not a native, non-derived target")
        dimensions = asset.get("presentation_dimensions")
        routes = asset.get("target_routes")
        if not isinstance(dimensions, list) or len(dimensions) != 2 or not isinstance(routes, list):
            raise CorpusValidationError(f"asset {asset_id} lacks route geometry")
        width, height = (int(dimensions[0]), int(dimensions[1]))
        if "direct-2x" in routes and (width % 2 != 0 or height % 2 != 0):
            raise CorpusValidationError(f"asset {asset_id} cannot form an exact direct-2x route")
        if "direct-3over2" in routes and (width % 3 != 0 or height % 3 != 0):
            raise CorpusValidationError(f"asset {asset_id} cannot form an exact direct-3over2 route")
        if require_exact_allocation:
            required_metadata = {
                "pixel_format": "420v",
                "range": "video",
                "color_primaries": "ITU_R_709_2",
                "transfer_function": "ITU_R_709_2",
                "ycbcr_matrix": "ITU_R_709_2",
                "chroma_location": "left",
            }
            for field, required_value in required_metadata.items():
                if asset.get(field) != required_value:
                    raise CorpusValidationError(
                        f"asset {asset_id} has unsupported or absent {field} metadata"
                    )
            canonical_route = {
                (3840, 2160): ["direct-2x"],
                (1920, 1080): ["direct-3over2"],
            }.get((width, height))
            if canonical_route is None or routes != canonical_route:
                raise CorpusValidationError(
                    f"asset {asset_id} does not use one canonical project route"
                )
            if not full_frame_clean_aperture(
                asset.get("clean_aperture"),
                width=width,
                height=height,
            ):
                raise CorpusValidationError(
                    f"asset {asset_id} has a non-full-frame clean aperture"
                )
            if not square_pixel_aspect_ratio(asset.get("pixel_aspect_ratio")):
                raise CorpusValidationError(f"asset {asset_id} has non-square pixels")
            if not identity_orientation(asset.get("orientation")):
                raise CorpusValidationError(
                    f"asset {asset_id} has a non-identity orientation"
                )

        if asset_root is not None:
            _validate_bound_bytes(
                asset_root,
                relative_path,
                digest,
                label=f"asset {asset_id}",
                expected_size=int(asset.get("size_bytes", -1)),
            )
        if evidence_root is not None:
            _validate_bound_bytes(
                evidence_root,
                rights_path,
                rights_digest,
                label=f"asset {asset_id} rights declaration",
            )
            _validate_bound_bytes(
                evidence_root,
                exception_path,
                exception_digest,
                label=f"asset {asset_id} exception review",
            )
            _validate_bound_bytes(
                evidence_root,
                provenance_path,
                provenance_digest,
                label=f"asset {asset_id} provenance record",
            )

        previous = source_split.setdefault(source_id, split)
        if previous != split:
            raise CorpusValidationError(f"source asset {source_id} leaks across splits")
        family_previous = family_split.setdefault(family_id, split)
        if family_previous != split:
            raise CorpusValidationError(f"source family {family_id} leaks across splits")
        asset_ids.add(asset_id)
        sha_values.add(digest)
        observed_splits.add(split)
        for category in categories:
            category_name = str(category)
            category_sources.setdefault(category_name, set()).add(source_id)
            split_category_sources[split].setdefault(category_name, set()).add(source_id)

    if require_all_splits and observed_splits != SPLITS:
        raise CorpusValidationError("development, validation, and holdout must all be populated")

    split_policy = manifest.get("split_policy")
    if not isinstance(split_policy, dict):
        raise CorpusValidationError("corpus split policy is absent")
    if require_exact_allocation:
        allocation = split_policy.get("allocation")
        if not isinstance(allocation, dict) or set(allocation) != SPLITS:
            raise CorpusValidationError("split allocation is incomplete")
        family_counts = {
            split: sum(1 for value in family_split.values() if value == split)
            for split in SPLITS
        }
        total_families = sum(family_counts.values())
        for split in SPLITS:
            required = Fraction(str(allocation[split])) * total_families
            if required.denominator != 1 or family_counts[split] != required.numerator:
                raise CorpusValidationError("source-family counts do not match the exact split allocation")
        declared_counts = split_policy.get("expected_family_counts")
        if not isinstance(declared_counts, dict) or set(declared_counts) != SPLITS:
            raise CorpusValidationError("expected_family_counts is required for an exact allocation")
        if family_counts != declared_counts:
            raise CorpusValidationError("source-family counts do not match expected_family_counts")

    if require_category_minima:
        minima = split_policy.get("minimum_category_counts")
        minima_by_split = split_policy.get("minimum_category_counts_by_split")
        if not isinstance(minima, dict) or not minima:
            raise CorpusValidationError("overall category minima are absent")
        if not isinstance(minima_by_split, dict) or set(minima_by_split) != SPLITS:
            raise CorpusValidationError("per-split category minima are absent")
        if allowed_categories is not None and set(minima) != allowed_categories:
            raise CorpusValidationError("category minima do not cover the locked vocabulary")
        for category, minimum in minima.items():
            if len(category_sources.get(str(category), set())) < int(minimum):
                raise CorpusValidationError(f"category {category} is below its overall minimum")
        for split in SPLITS:
            split_minima = minima_by_split[split]
            if not isinstance(split_minima, dict):
                raise CorpusValidationError(f"category minima for {split} are invalid")
            if allowed_categories is not None and set(split_minima) != allowed_categories:
                raise CorpusValidationError(f"category minima for {split} do not cover the locked vocabulary")
            for category, minimum in split_minima.items():
                observed = len(split_category_sources[split].get(str(category), set()))
                if observed < int(minimum):
                    raise CorpusValidationError(
                        f"category {category} is below its {split} minimum"
                    )


def seal_corpus_lock(
    manifest: Mapping[str, object],
    destination: Path,
    *,
    allowed_categories: Set[str],
    asset_root: Path,
    evidence_root: Path,
    schema_path: Path,
) -> str:
    """Validate and atomically publish one immutable, byte-bound production lock."""

    validate_schema(dict(manifest), schema_path)
    validate_corpus_lock(
        manifest,
        allowed_categories=allowed_categories,
        require_all_splits=True,
        require_exact_allocation=True,
        require_category_minima=True,
        asset_root=asset_root,
        evidence_root=evidence_root,
    )
    encoded = canonical_json_bytes(dict(manifest)) + b"\n"
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(
        f".{destination.name}.{os.getpid()}.{secrets.token_hex(8)}.partial"
    )
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)
    try:
        os.link(temporary, destination)
        directory = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)
    if destination.read_bytes() != encoded:
        raise CorpusValidationError("sealed corpus-lock bytes differ from the validated payload")
    return hashlib.sha256(encoded).hexdigest()
