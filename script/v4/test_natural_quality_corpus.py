#!/usr/bin/env python3
"""Determinism and fail-closed tests for the locked natural corpus builder."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "build_natural_quality_corpus",
    SCRIPT_DIRECTORY / "build_natural_quality_corpus.py",
)
assert SPEC is not None and SPEC.loader is not None
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class NaturalQualityCorpusTests(unittest.TestCase):
    def testSignedDivisionUsesNearestTiesToEven(self) -> None:
        values = np.asarray([-15, -10, -5, -4, -1, 0, 1, 4, 5, 10, 15])
        result = builder.rounded_divide_signed(values, 10)
        np.testing.assert_array_equal(
            result,
            np.asarray([-2, -1, 0, 0, 0, 0, 0, 0, 0, 1, 2]),
        )

    def testBoxDownsampleUsesNearestTiesToEven(self) -> None:
        plane = np.asarray(
            [
                [0, 1, 0, 1],
                [1, 0, 1, 2],
                [2, 2, 3, 3],
                [2, 2, 3, 4],
            ],
            dtype=np.uint8,
        )
        np.testing.assert_array_equal(
            builder.box_downsample_ties_even(plane),
            np.asarray([[0, 1], [2, 3]], dtype=np.uint8),
        )

    def testRgbConversionLocksFullAndVideoRangeEndpoints(self) -> None:
        black = np.zeros((2, 2, 3), dtype=np.uint8)
        white = np.full((2, 2, 3), 255, dtype=np.uint8)
        full_black_luma, full_black_chroma = builder.rgb_to_nv12(black, "420f")
        video_black_luma, video_black_chroma = builder.rgb_to_nv12(black, "420v")
        full_white_luma, full_white_chroma = builder.rgb_to_nv12(white, "420f")
        video_white_luma, video_white_chroma = builder.rgb_to_nv12(white, "420v")
        self.assertTrue(np.all(full_black_luma == 0))
        self.assertTrue(np.all(video_black_luma == 16))
        self.assertTrue(np.all(full_white_luma == 255))
        self.assertTrue(np.all(video_white_luma == 235))
        for chroma in (
            full_black_chroma,
            video_black_chroma,
            full_white_chroma,
            video_white_chroma,
        ):
            np.testing.assert_array_equal(
                chroma,
                np.asarray([[[128, 128]]], dtype=np.uint8),
            )

    def testSourceValidationRejectsTamperAndUnsafeNames(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-natural-source-test-") as temporary:
            path = Path(temporary) / "source.bin"
            path.write_bytes(b"verified-source")
            record = {
                "id": "fixture",
                "byteCount": path.stat().st_size,
                "sha256": builder.sha256(path),
            }
            builder.validate_source(path, record)
            path.write_bytes(b"tampered-source")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                builder.validate_source(path, record)
        for unsafe in ("", ".", "..", "../source.mov", "folder/source.mov"):
            with self.assertRaisesRegex(ValueError, "unsafe source filename"):
                builder.require_safe_filename(unsafe)

    def testDeclaredSourceAndLicenseSetsAreStable(self) -> None:
        selection = json.loads(
            (SCRIPT_DIRECTORY / "natural-quality-sources-v1.json").read_text()
        )
        self.assertEqual(
            builder.source_asset_set_sha(selection["assets"]),
            "88556f6bd16c363ae1c76d98d2a6017b78b15da78936b76dfaea7e790488af00",
        )
        self.assertEqual(
            builder.source_license_set_sha(selection["assets"]),
            "30ee1b9d1cbb391c2134cfac685d9f7b3da0aa256487ea3ec5466b15abfed345",
        )

    def testReleaseLockBindsEveryReproducibilityInput(self) -> None:
        lock = json.loads(
            (SCRIPT_DIRECTORY / "natural-quality-corpus-lock-v2.json").read_text()
        )
        self.assertEqual(
            lock["schemaVersion"],
            "mirmir-ash-v4-natural-quality-corpus-lock-v2",
        )
        self.assertTrue(lock["releaseEligible"])
        self.assertEqual(lock["clipCount"], 28)
        self.assertEqual(lock["caseCount"], 168)
        self.assertEqual(
            lock["sourceSelectionSHA256"],
            file_sha256(SCRIPT_DIRECTORY / "natural-quality-sources-v1.json"),
        )
        self.assertEqual(
            lock["qualityContractSHA256"],
            file_sha256(SCRIPT_DIRECTORY / "quality-gate-release-contract-v2.json"),
        )
        self.assertEqual(
            lock["builderSourceSHA256"],
            file_sha256(SCRIPT_DIRECTORY / "build_natural_quality_corpus.py"),
        )
        for field in (
            "manifestSHA256",
            "artifactSetSHA256",
            "sourceAssetSetSHA256",
            "sourceLicenseSetSHA256",
            "sourceSelectionSHA256",
            "qualityContractSHA256",
            "builderSourceSHA256",
        ):
            self.assertRegex(lock[field], r"^[0-9a-f]{64}$")


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
