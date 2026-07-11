from copy import deepcopy
import hashlib
from pathlib import Path
import tempfile
import unittest

import numpy as np

from mirmir_quality.corpus import create_corpus_lock
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
    create_development_sample_lock,
    load_development_samples,
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


def _source_extensions() -> dict:
    return {
        "CVImageBufferColorPrimaries": "ITU_R_709_2",
        "CVImageBufferTransferFunction": "ITU_R_709_2",
        "CVImageBufferYCbCrMatrix": "ITU_R_709_2",
        "CVImageBufferChromaLocationTopField": "Left",
        "CVImageBufferChromaLocationBottomField": "Left",
        "CVPixelAspectRatio": {"HorizontalSpacing": 1, "VerticalSpacing": 1},
        "FullRangeVideo": False,
    }


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


def _asset(index: int, payload: bytes) -> dict:
    asset_id = f"asset-{index}"
    return {
        "asset_id": asset_id,
        "source_asset_id": f"source-{index}",
        "source_family_id": f"family-{index}",
        "relative_path": f"corpus/{asset_id}.mov",
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
        "split": "development",
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


def _fixture(root: Path) -> dict:
    asset_root = root / "assets"
    sample_root = root / "samples"
    (asset_root / "corpus").mkdir(parents=True)
    sample_root.mkdir()
    assets = []
    sample_records = []
    decode_paths = {}
    for index in range(6):
        media_payload = f"locked-source-media-{index}".encode()
        asset = _asset(index, media_payload)
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
            "source_format_extensions": _source_extensions(),
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
                "split": "development",
                "media_path": str(media_path.resolve(strict=True)),
                "source_format_extensions": _source_extensions(),
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
            )
        )
    corpus = create_corpus_lock(
        corpus_id="sample-integrity-fixture",
        corpus_version="1",
        created_utc="2026-07-11T00:00:00Z",
        split_policy={"fixture": True},
        assets=assets,
        category_vocabulary_version="fixture",
    )
    lock = create_development_sample_lock(
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


if __name__ == "__main__":
    unittest.main()
