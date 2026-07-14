from copy import deepcopy
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from mirmir_quality.corpus import CorpusValidationError, create_corpus_lock
from mirmir_quality.json_tools import (
    canonical_sha256,
    manifest_sha256,
    read_json,
    validate_schema,
    write_json,
)
from mirmir_quality.samples import (
    DevelopmentSampleError,
    build_sample_record,
    create_sample_lock,
    create_development_sample_lock,
    create_validation_sample_lock,
    load_development_samples,
    load_sample_split,
    load_validation_samples,
)


QUALITY_ROOT = Path(__file__).resolve().parents[1]


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _metadata() -> dict:
    return {
        "range": "video",
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location": "left",
    }


def _source_extensions(*, include_color_triplet: bool = True) -> dict:
    extensions = {
        "CVImageBufferColorPrimaries": "ITU_R_709_2",
        "CVImageBufferTransferFunction": "ITU_R_709_2",
        "CVImageBufferYCbCrMatrix": "ITU_R_709_2",
        "CVImageBufferChromaLocationTopField": "Left",
        "CVImageBufferChromaLocationBottomField": "Left",
        "CVPixelAspectRatio": {"HorizontalSpacing": 1, "VerticalSpacing": 1},
        "FullRangeVideo": False,
    }
    if not include_color_triplet:
        del extensions["CVImageBufferColorPrimaries"]
        del extensions["CVImageBufferTransferFunction"]
        del extensions["CVImageBufferYCbCrMatrix"]
    return extensions


def _decoded_attachments() -> dict:
    return {
        "CVImageBufferColorPrimaries": "ITU_R_709_2",
        "CVImageBufferTransferFunction": "ITU_R_709_2",
        "CVImageBufferYCbCrMatrix": "ITU_R_709_2",
        "CVImageBufferChromaLocationTopField": "Left",
        "CVImageBufferChromaLocationBottomField": "Left",
        "CVImageBufferCleanAperture": None,
        "CVImageBufferPixelAspectRatio": {
            "HorizontalSpacing": 1,
            "VerticalSpacing": 1,
        },
    }


def _asset(index: int, payload: bytes, *, split: str = "development") -> dict:
    asset_id = f"asset-{index}"
    return {
        "asset_id": asset_id,
        "source_asset_id": f"source-{index}",
        "source_family_id": f"family-{index}",
        "relative_path": f"corpus/{asset_id}.mov",
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
        "split": split,
        "presentation_dimensions": [324, 192],
        "target_routes": ["direct-2x"],
        **_metadata(),
    }


def _active_payloads(index: int) -> tuple[bytes, bytes]:
    y = np.full((192, 324), 64 + index, dtype=np.uint8)
    if index == 0:
        y[0, 0] = 0
        y[0, 1] = 255
    cbcr = np.full((96, 324), 128, dtype=np.uint8)
    return y.tobytes(), cbcr.tobytes()


def _rebind_decode_evidence(sample_directory: Path) -> None:
    decode_path = sample_directory / "decode-manifest.json"
    evidence_path = sample_directory / "evidence-manifest.json"
    evidence = read_json(evidence_path)
    payload = decode_path.read_bytes()
    record = next(item for item in evidence["files"] if item["path"] == decode_path.name)
    record["sha256"] = _sha256(payload)
    record["size_bytes"] = len(payload)
    write_json(evidence_path, evidence)


def _fixture(
    root: Path,
    *,
    split: str = "development",
    sample_count: int = 6,
    include_unresolved_holdout: bool = False,
    missing_source_color_indices: frozenset[int] = frozenset(),
) -> dict:
    asset_root = root / "assets"
    sample_root = root / "samples"
    (asset_root / "corpus").mkdir(parents=True)
    sample_root.mkdir()
    assets = []
    sample_records = []
    decode_paths = {}
    for index in range(sample_count):
        media_payload = f"locked-source-media-{index}".encode()
        asset = _asset(index, media_payload, split=split)
        assets.append(asset)
        media_path = asset_root / asset["relative_path"]
        media_path.write_bytes(media_payload)
        sample_directory = sample_root / asset["asset_id"]
        sample_directory.mkdir()
        y_payload, cbcr_payload = _active_payloads(index)
        y_path = sample_directory / "frame.y.bin"
        cbcr_path = sample_directory / "frame.cbcr.bin"
        y_path.write_bytes(y_payload)
        cbcr_path.write_bytes(cbcr_payload)
        source_extensions = _source_extensions(
            include_color_triplet=index not in missing_source_color_indices
        )
        record = {
            "index": 0,
            "decoded_frame_sha256": _sha256(
                b"padded-buffer-contract" + y_payload + cbcr_payload
            ),
            "width": 324,
            "height": 192,
            "pixel_format": "420v",
            "plane_bytes_per_row": [384, 384],
            "plane_heights": [192, 96],
            "decoded_attachments": _decoded_attachments(),
            "source_format_extensions": source_extensions,
            "pts": {"value": index, "timescale": 600},
            "y_active_path": f"{asset['asset_id']}/frame.y.bin",
            "cbcr_active_path": f"{asset['asset_id']}/frame.cbcr.bin",
        }
        second = deepcopy(record)
        second["index"] = 1
        second["pts"] = {"value": index + 100, "timescale": 600}
        decode_path = sample_directory / "decode-manifest.json"
        write_json(
            decode_path,
            {
                "asset_id": asset["asset_id"],
                "split": split,
                "media_path": str(media_path.resolve(strict=True)),
                "source_format_extensions": source_extensions,
                "representative_samples": [record, second],
            },
        )
        decode_paths[asset["asset_id"]] = decode_path
        evidence_path = sample_directory / "evidence-manifest.json"
        files = []
        for path in (decode_path, y_path, cbcr_path):
            payload = path.read_bytes()
            files.append(
                {"path": path.name, "sha256": _sha256(payload), "size_bytes": len(payload)}
            )
        write_json(evidence_path, {"schema_version": "1.0.0", "files": files})
        sample_records.append(
            build_sample_record(
                asset=asset,
                target_route="direct-2x",
                sample_root=sample_root,
                asset_root=asset_root,
                decode_manifest_path=f"{asset['asset_id']}/decode-manifest.json",
                source_evidence_manifest_path=f"{asset['asset_id']}/evidence-manifest.json",
                split=split,
            )
        )
    if include_unresolved_holdout:
        assets.append(
            {
                **_asset(99, b"sealed-holdout", split="holdout"),
                "relative_path": "sealed-root/unavailable-holdout.mov",
            }
        )
    corpus = create_corpus_lock(
        corpus_id="sample-integrity-fixture",
        corpus_version="1",
        created_utc="2026-07-11T00:00:00Z",
        split_policy={"fixture": True},
        assets=assets,
        category_vocabulary_version="fixture",
    )
    if split == "development":
        lock = create_development_sample_lock(
            corpus_manifest_sha256=corpus["manifest_sha256"],
            samples=sample_records,
        )
    else:
        lock = create_validation_sample_lock(
            corpus_manifest_sha256=corpus["manifest_sha256"],
            samples=sample_records,
        )
    return {
        "asset_root": asset_root,
        "sample_root": sample_root,
        "assets": assets,
        "corpus": corpus,
        "lock": lock,
        "decode_paths": decode_paths,
    }


def _rebuild_fixture_record(fixture: dict, asset: dict) -> dict:
    return build_sample_record(
        asset=asset,
        target_route=asset["target_routes"][0],
        sample_root=fixture["sample_root"],
        asset_root=fixture["asset_root"],
        decode_manifest_path=f"{asset['asset_id']}/decode-manifest.json",
        source_evidence_manifest_path=f"{asset['asset_id']}/evidence-manifest.json",
        split=asset["split"],
    )


class DevelopmentSampleIntegrityTests(unittest.TestCase):
    def test_lock_binds_source_media_active_planes_and_explicit_range_clamping(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(Path(temporary))
            validate_schema(
                fixture["lock"],
                QUALITY_ROOT / "schemas" / "development-sample-lock.schema.json",
            )
            loaded = load_development_samples(
                fixture["lock"],
                fixture["corpus"],
                sample_root=fixture["sample_root"],
                asset_root=fixture["asset_root"],
            )
            sample = fixture["lock"]["samples"][0]
            self.assertNotEqual(sample["decoded_frame_sha256"], sample["active_planes_sha256"])
            self.assertEqual(sample["code_value_observation"]["y"]["below_nominal_count"], 1)
            self.assertEqual(sample["code_value_observation"]["y"]["above_nominal_count"], 1)
            self.assertEqual(float(np.min(loaded[0][1].y)), 0.0)
            self.assertEqual(float(np.max(loaded[0][1].y)), 1.0)

    def test_wrong_source_media_and_post_lock_media_mutation_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(Path(temporary))
            asset = fixture["assets"][0]
            decode_path = fixture["decode_paths"][asset["asset_id"]]
            decode = read_json(decode_path)
            decode["media_path"] = str(
                (
                    fixture["asset_root"]
                    / fixture["assets"][1]["relative_path"]
                ).resolve(strict=True)
            )
            write_json(decode_path, decode)
            _rebind_decode_evidence(decode_path.parent)
            with self.assertRaisesRegex(DevelopmentSampleError, "does not identify"):
                build_sample_record(
                    asset=asset,
                    target_route="direct-2x",
                    sample_root=fixture["sample_root"],
                    asset_root=fixture["asset_root"],
                    decode_manifest_path=f"{asset['asset_id']}/decode-manifest.json",
                    source_evidence_manifest_path=f"{asset['asset_id']}/evidence-manifest.json",
                )

        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(Path(temporary))
            media_path = fixture["asset_root"] / fixture["assets"][0]["relative_path"]
            media_path.write_bytes(b"changed after lock")
            with self.assertRaisesRegex(DevelopmentSampleError, "source media bytes"):
                load_development_samples(
                    fixture["lock"],
                    fixture["corpus"],
                    sample_root=fixture["sample_root"],
                    asset_root=fixture["asset_root"],
                )

    def test_locked_absolute_media_paths_survive_byte_identical_root_relocation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original_root = root / "original"
            fixture = _fixture(original_root)
            relocated_root = root / "relocated"
            relocated_assets = shutil.copytree(
                fixture["asset_root"],
                relocated_root / "assets",
            )
            relocated_samples = shutil.copytree(
                fixture["sample_root"],
                relocated_root / "samples",
            )
            shutil.rmtree(original_root)

            self.assertFalse(original_root.exists())
            loaded = load_development_samples(
                fixture["lock"],
                fixture["corpus"],
                sample_root=relocated_samples,
                asset_root=relocated_assets,
            )

            self.assertEqual(len(loaded), 6)
            self.assertEqual(
                [asset["asset_id"] for asset, _ in loaded],
                [asset["asset_id"] for asset in fixture["assets"]],
            )

    def test_absolute_media_path_with_parent_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(Path(temporary))
            asset = fixture["assets"][0]
            decode_path = fixture["decode_paths"][asset["asset_id"]]
            decode = read_json(decode_path)
            decode["media_path"] = "{}/discarded/../{}".format(
                fixture["asset_root"].as_posix(),
                asset["relative_path"],
            )
            write_json(decode_path, decode)
            _rebind_decode_evidence(decode_path.parent)

            with self.assertRaisesRegex(DevelopmentSampleError, "does not identify"):
                build_sample_record(
                    asset=asset,
                    target_route="direct-2x",
                    sample_root=fixture["sample_root"],
                    asset_root=fixture["asset_root"],
                    decode_manifest_path=f"{asset['asset_id']}/decode-manifest.json",
                    source_evidence_manifest_path=(
                        f"{asset['asset_id']}/evidence-manifest.json"
                    ),
                )

    def test_relative_media_path_remains_strictly_root_and_asset_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(Path(temporary))
            asset = fixture["assets"][0]
            decode_path = fixture["decode_paths"][asset["asset_id"]]
            decode = read_json(decode_path)

            decode["media_path"] = asset["relative_path"]
            write_json(decode_path, decode)
            _rebind_decode_evidence(decode_path.parent)
            record = _rebuild_fixture_record(fixture, asset)
            self.assertEqual(record["source_media_path"], asset["relative_path"])

            decode["media_path"] = f"../{asset['relative_path']}"
            write_json(decode_path, decode)
            _rebind_decode_evidence(decode_path.parent)
            with self.assertRaisesRegex(CorpusValidationError, "unsafe relative path"):
                _rebuild_fixture_record(fixture, asset)

            decode["media_path"] = fixture["assets"][1]["relative_path"]
            write_json(decode_path, decode)
            _rebind_decode_evidence(decode_path.parent)
            with self.assertRaisesRegex(DevelopmentSampleError, "does not identify"):
                _rebuild_fixture_record(fixture, asset)

    def test_nonfirst_selection_and_offcenter_crop_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(Path(temporary))
            lock = deepcopy(fixture["lock"])
            decode = read_json(fixture["decode_paths"][lock["samples"][0]["asset_id"]])
            lock["samples"][0]["selected_decode_record_sha256"] = canonical_sha256(
                decode["representative_samples"][1]
            )
            lock["manifest_sha256"] = manifest_sha256(lock)
            with self.assertRaisesRegex(DevelopmentSampleError, "representative_samples\[0\]"):
                load_development_samples(
                    lock,
                    fixture["corpus"],
                    sample_root=fixture["sample_root"],
                    asset_root=fixture["asset_root"],
                )

            lock = deepcopy(fixture["lock"])
            lock["samples"][0]["crop"]["x"] = 2
            lock["manifest_sha256"] = manifest_sha256(lock)
            with self.assertRaisesRegex(DevelopmentSampleError, "exact centered crop"):
                load_development_samples(
                    lock,
                    fixture["corpus"],
                    sample_root=fixture["sample_root"],
                    asset_root=fixture["asset_root"],
                )

            lock = deepcopy(fixture["lock"])
            lock["samples"][0]["source_dimensions"]["width"] = 326
            lock["manifest_sha256"] = manifest_sha256(lock)
            with self.assertRaisesRegex(
                DevelopmentSampleError,
                "corpus presentation dimensions",
            ):
                load_development_samples(
                    lock,
                    fixture["corpus"],
                    sample_root=fixture["sample_root"],
                    asset_root=fixture["asset_root"],
                )

    def test_display_geometry_active_hash_and_excursion_record_are_enforced(self) -> None:
        geometry_scenarios = (
            ("pixel-aspect-ratio", "non-square pixels"),
            ("clean-aperture", "non-full-frame clean aperture"),
            ("orientation", "non-identity orientation"),
        )
        for scenario, expected in geometry_scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                fixture = _fixture(Path(temporary))
                asset = fixture["assets"][0]
                decode_path = fixture["decode_paths"][asset["asset_id"]]
                decode = read_json(decode_path)
                if scenario == "pixel-aspect-ratio":
                    decode["representative_samples"][0]["decoded_attachments"][
                        "CVImageBufferPixelAspectRatio"
                    ] = {"HorizontalSpacing": 2, "VerticalSpacing": 1}
                elif scenario == "clean-aperture":
                    decode["representative_samples"][0]["decoded_attachments"][
                        "CVImageBufferCleanAperture"
                    ] = {
                        "Width": 320,
                        "Height": 192,
                        "HorizontalOffset": 2,
                        "VerticalOffset": 0,
                    }
                else:
                    decode["orientation"] = "rotate-90"
                write_json(decode_path, decode)
                _rebind_decode_evidence(decode_path.parent)
                with self.assertRaisesRegex(DevelopmentSampleError, expected):
                    build_sample_record(
                        asset=asset,
                        target_route="direct-2x",
                        sample_root=fixture["sample_root"],
                        asset_root=fixture["asset_root"],
                        decode_manifest_path=(
                            f"{asset['asset_id']}/decode-manifest.json"
                        ),
                        source_evidence_manifest_path=(
                            f"{asset['asset_id']}/evidence-manifest.json"
                        ),
                    )

        for scenario, field, value, expected in (
            (
                "asset-clean-aperture",
                "clean_aperture",
                {
                    "width": 300,
                    "height": 180,
                    "horizontal_offset": 12,
                    "vertical_offset": 6,
                },
                "non-full-frame clean aperture",
            ),
            (
                "asset-pixel-aspect-ratio",
                "pixel_aspect_ratio",
                {"HorizontalSpacing": 2, "VerticalSpacing": 1},
                "non-square pixels",
            ),
            ("asset-orientation", "orientation", "rotate-90", "non-identity"),
        ):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                fixture = _fixture(Path(temporary))
                asset = deepcopy(fixture["assets"][0])
                asset[field] = value
                with self.assertRaisesRegex(DevelopmentSampleError, expected):
                    build_sample_record(
                        asset=asset,
                        target_route="direct-2x",
                        sample_root=fixture["sample_root"],
                        asset_root=fixture["asset_root"],
                        decode_manifest_path=(
                            f"{asset['asset_id']}/decode-manifest.json"
                        ),
                        source_evidence_manifest_path=(
                            f"{asset['asset_id']}/evidence-manifest.json"
                        ),
                    )

        for field, mutation, expected in (
            ("active_planes_sha256", "0" * 64, "active-plane payload"),
            ("code_value_observation", {"y": {}, "cb": {}, "cr": {}}, "excursion record"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                fixture = _fixture(Path(temporary))
                lock = deepcopy(fixture["lock"])
                lock["samples"][0][field] = mutation
                lock["manifest_sha256"] = manifest_sha256(lock)
                with self.assertRaisesRegex(DevelopmentSampleError, expected):
                    load_development_samples(
                        lock,
                        fixture["corpus"],
                        sample_root=fixture["sample_root"],
                        asset_root=fixture["asset_root"],
                    )


class ValidationSampleIntegrityTests(unittest.TestCase):
    def test_validation_lock_schema_and_loader_preserve_all_sample_bindings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(
                Path(temporary),
                split="validation",
                sample_count=3,
                include_unresolved_holdout=True,
            )
            validate_schema(
                fixture["lock"],
                QUALITY_ROOT / "schemas" / "validation-sample-lock.schema.json",
            )
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(
                    fixture["lock"],
                    QUALITY_ROOT / "schemas" / "development-sample-lock.schema.json",
                )
            loaded = load_validation_samples(
                fixture["lock"],
                fixture["corpus"],
                sample_root=fixture["sample_root"],
                asset_root=fixture["asset_root"],
            )
            self.assertEqual(len(loaded), 3)
            self.assertTrue(all(asset["split"] == "validation" for asset, _ in loaded))
            self.assertEqual(float(np.min(loaded[0][1].y)), 0.0)
            self.assertEqual(float(np.max(loaded[0][1].y)), 1.0)
            self.assertNotIn("metadata_resolution", fixture["lock"]["samples"][0])

    def test_validation_resolution_records_absent_source_triplet_without_invention(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(
                Path(temporary),
                split="validation",
                sample_count=3,
                missing_source_color_indices=frozenset({0}),
            )
            resolution = fixture["lock"]["samples"][0]["metadata_resolution"]
            self.assertEqual(
                resolution["method"],
                "validation_decoded_attachment_corpus_agreement_v1",
            )
            self.assertEqual(resolution["source_color_triplet_status"], "absent")
            self.assertEqual(resolution["representative_sample_count"], 2)
            self.assertEqual(
                resolution["source_color_triplet_fields"],
                [
                    "CVImageBufferColorPrimaries",
                    "CVImageBufferTransferFunction",
                    "CVImageBufferYCbCrMatrix",
                ],
            )
            self.assertEqual(resolution["source_range_evidence"], {"FullRangeVideo": False})
            validate_schema(
                fixture["lock"],
                QUALITY_ROOT / "schemas" / "validation-sample-lock.schema.json",
            )
            loaded = load_validation_samples(
                fixture["lock"],
                fixture["corpus"],
                sample_root=fixture["sample_root"],
                asset_root=fixture["asset_root"],
            )
            self.assertEqual(len(loaded), 3)

    def test_validation_resolution_rejects_partial_mixed_and_conflicting_evidence(self) -> None:
        scenarios = (
            "partial-source-triplet",
            "mixed-decoded-triplet",
            "mixed-source-record",
            "source-full-range",
            "source-chroma-conflict",
            "duplicate-representative-index",
            "corpus-conflict",
        )
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                fixture = _fixture(
                    Path(temporary),
                    split="validation",
                    sample_count=3,
                    missing_source_color_indices=frozenset({0}),
                )
                asset = fixture["assets"][0]
                decode_path = fixture["decode_paths"][asset["asset_id"]]
                decode = read_json(decode_path)
                if scenario == "partial-source-triplet":
                    decode["source_format_extensions"][
                        "CVImageBufferColorPrimaries"
                    ] = "ITU_R_709_2"
                    for record in decode["representative_samples"]:
                        record["source_format_extensions"][
                            "CVImageBufferColorPrimaries"
                        ] = "ITU_R_709_2"
                elif scenario == "mixed-decoded-triplet":
                    decode["representative_samples"][1]["decoded_attachments"][
                        "CVImageBufferTransferFunction"
                    ] = "ITU_R_2020"
                elif scenario == "mixed-source-record":
                    decode["representative_samples"][1]["source_format_extensions"][
                        "SpatialQuality"
                    ] = 1
                elif scenario == "source-full-range":
                    decode["source_format_extensions"]["FullRangeVideo"] = True
                    for record in decode["representative_samples"]:
                        record["source_format_extensions"]["FullRangeVideo"] = True
                elif scenario == "source-chroma-conflict":
                    decode["source_format_extensions"][
                        "CVImageBufferChromaLocationTopField"
                    ] = "Center"
                    for record in decode["representative_samples"]:
                        record["source_format_extensions"][
                            "CVImageBufferChromaLocationTopField"
                        ] = "Center"
                elif scenario == "duplicate-representative-index":
                    decode["representative_samples"][1]["index"] = 0
                else:
                    asset = deepcopy(asset)
                    asset["color_primaries"] = "ITU_R_2020"
                if scenario != "corpus-conflict":
                    write_json(decode_path, decode)
                    _rebind_decode_evidence(decode_path.parent)
                with self.assertRaisesRegex(
                    DevelopmentSampleError,
                    "ambiguous|mixed|cannot support",
                ):
                    _rebuild_fixture_record(fixture, asset)

    def test_resolution_record_tampering_and_unnecessary_resolution_fail_closed(self) -> None:
        for field, value in (
            ("method", "unbound-method"),
            ("representative_sample_count", 1),
            ("representative_color_observations_sha256", "0" * 64),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                fixture = _fixture(
                    Path(temporary),
                    split="validation",
                    sample_count=3,
                    missing_source_color_indices=frozenset({0}),
                )
                lock = deepcopy(fixture["lock"])
                lock["samples"][0]["metadata_resolution"][field] = value
                lock["manifest_sha256"] = manifest_sha256(lock)
                if field == "method":
                    with self.assertRaisesRegex(ValueError, "schema validation failed"):
                        validate_schema(
                            lock,
                            QUALITY_ROOT
                            / "schemas"
                            / "validation-sample-lock.schema.json",
                        )
                with self.assertRaisesRegex(
                    DevelopmentSampleError,
                    "does not match frozen evidence",
                ):
                    load_validation_samples(
                        lock,
                        fixture["corpus"],
                        sample_root=fixture["sample_root"],
                        asset_root=fixture["asset_root"],
                    )

        with tempfile.TemporaryDirectory() as temporary:
            fixture = _fixture(Path(temporary), split="validation", sample_count=3)
            lock = deepcopy(fixture["lock"])
            lock["samples"][0]["metadata_resolution"] = {
                "method": "validation_decoded_attachment_corpus_agreement_v1"
            }
            lock["manifest_sha256"] = manifest_sha256(lock)
            with self.assertRaisesRegex(
                DevelopmentSampleError,
                "unnecessary metadata resolution",
            ):
                load_validation_samples(
                    lock,
                    fixture["corpus"],
                    sample_root=fixture["sample_root"],
                    asset_root=fixture["asset_root"],
                )

    def test_development_stays_strict_when_source_triplet_is_absent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                DevelopmentSampleError,
                "unsupported or absent source color metadata",
            ):
                _fixture(
                    Path(temporary),
                    split="development",
                    sample_count=6,
                    missing_source_color_indices=frozenset({0}),
                )

    def test_validation_loader_fails_closed_on_lock_corpus_policy_and_range(self) -> None:
        mutations = (
            (
                "self-hash",
                lambda lock: lock["samples"][0].__setitem__(
                    "target_frame_sha256", "0" * 64
                ),
                False,
                "manifest hash mismatch",
            ),
            (
                "corpus-binding",
                lambda lock: lock.__setitem__("corpus_manifest_sha256", "0" * 64),
                True,
                "corpus binding mismatch",
            ),
            (
                "split-policy",
                lambda lock: lock["sample_policy"].__setitem__("split", "development"),
                True,
                "policy mismatch",
            ),
            (
                "range-metadata",
                lambda lock: lock["samples"][0].__setitem__("range", "full"),
                True,
                "range does not match",
            ),
            (
                "active-plane-binding",
                lambda lock: lock["samples"][0].__setitem__(
                    "active_planes_sha256", "0" * 64
                ),
                True,
                "active-plane payload",
            ),
        )
        for label, mutate, rehash, expected in mutations:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                fixture = _fixture(
                    Path(temporary),
                    split="validation",
                    sample_count=3,
                )
                lock = deepcopy(fixture["lock"])
                mutate(lock)
                if rehash:
                    lock["manifest_sha256"] = manifest_sha256(lock)
                with self.assertRaisesRegex(DevelopmentSampleError, expected):
                    load_validation_samples(
                        lock,
                        fixture["corpus"],
                        sample_root=fixture["sample_root"],
                        asset_root=fixture["asset_root"],
                    )

    def test_holdout_split_is_rejected_before_any_path_binding(self) -> None:
        with patch("mirmir_quality.samples.bound_regular_file") as bind:
            with self.assertRaisesRegex(
                DevelopmentSampleError,
                "must be development or validation",
            ):
                load_sample_split(
                    {},
                    {},
                    split="holdout",
                    sample_root=Path("unavailable-sample-root"),
                    asset_root=Path("unavailable-asset-root"),
                )
            bind.assert_not_called()

        with self.assertRaisesRegex(
            DevelopmentSampleError,
            "must be development or validation",
        ):
            create_sample_lock(
                split="holdout",
                corpus_manifest_sha256="0" * 64,
                samples=[],
            )

        with patch("mirmir_quality.samples.bound_regular_file") as bind:
            with self.assertRaisesRegex(
                DevelopmentSampleError,
                "must be development or validation",
            ):
                build_sample_record(
                    asset={"split": "holdout"},
                    target_route="direct-2x",
                    sample_root=Path("unavailable-sample-root"),
                    asset_root=Path("unavailable-asset-root"),
                    decode_manifest_path="sealed/decode-manifest.json",
                    source_evidence_manifest_path="sealed/evidence-manifest.json",
                    split="holdout",
                )
            bind.assert_not_called()

    def test_validation_builder_writes_a_reloadable_lock_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = _fixture(root, split="validation", sample_count=3)
            corpus_path = root / "corpus-lock.json"
            output_path = root / "validation-sample-lock.json"
            write_json(corpus_path, fixture["corpus"])
            command = [
                sys.executable,
                str(QUALITY_ROOT / "tools" / "build_validation_sample_lock.py"),
                "--corpus-lock",
                str(corpus_path),
                "--sample-root",
                str(fixture["sample_root"]),
                "--asset-root",
                str(fixture["asset_root"]),
                "--output",
                str(output_path),
            ]
            for asset in fixture["assets"]:
                command.extend(
                    [
                        "--decode-manifest",
                        f"{asset['asset_id']}={asset['asset_id']}/decode-manifest.json",
                        "--evidence-manifest",
                        f"{asset['asset_id']}={asset['asset_id']}/evidence-manifest.json",
                    ]
                )
            result = subprocess.run(command, check=False, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sample_manifest_sha256=", result.stdout)
            built_lock = read_json(output_path)
            validate_schema(
                built_lock,
                QUALITY_ROOT / "schemas" / "validation-sample-lock.schema.json",
            )
            loaded = load_validation_samples(
                built_lock,
                fixture["corpus"],
                sample_root=fixture["sample_root"],
                asset_root=fixture["asset_root"],
            )
            self.assertEqual(len(loaded), 3)

            repeated = subprocess.run(command, check=False, capture_output=True, text=True)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn("refusing to overwrite", repeated.stderr)


if __name__ == "__main__":
    unittest.main()
