from copy import deepcopy
from pathlib import Path
import unittest

import numpy as np

from mirmir_quality.arrays import PlanarFrame, frame_sha256
from mirmir_quality.degradation import apply_degradation, synthetic_motion_sequence
from mirmir_quality.fixtures import synthetic_planar_frame
from mirmir_quality.json_tools import read_json, validate_schema


QUALITY_ROOT = Path(__file__).resolve().parents[1]


class DeterministicDegradationTests(unittest.TestCase):
    def test_motion_translation_scales_with_each_420_plane_geometry(self) -> None:
        y = np.zeros((64, 64), dtype=np.float64)
        y[:, 32:] = 1.0
        cb = np.zeros((32, 32), dtype=np.float64)
        cb[:, 16:] = 0.5
        cr = cb.copy()
        frame = PlanarFrame(y=y, cb=cb, cr=cr)
        profile = {
            "kind": "synthetic_motion",
            "transforms": [
                {
                    "camera_translation": [2, 0],
                    "camera_rotation_degrees": 0,
                    "scene_cut": False,
                    "scene_source": "primary",
                    "object_translation": None,
                }
            ],
            "occluder": {
                "luma_rectangle": [0, 0, 2, 2],
                "normalized_values": {"Y": 0.5, "Cb": 0.0, "Cr": 0.0},
            },
        }

        sequence, _ = synthetic_motion_sequence(frame, profile)
        translated = sequence[0]
        y_crossing = int(np.flatnonzero(translated.y[32] >= 0.5)[0])
        cb_crossing = int(np.flatnonzero(translated.cb[16] >= 0.25)[0])
        cr_crossing = int(np.flatnonzero(translated.cr[16] >= 0.25)[0])

        self.assertEqual(y_crossing, 34)
        self.assertEqual(2 * cb_crossing, y_crossing)
        self.assertEqual(2 * cr_crossing, y_crossing)

    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = read_json(QUALITY_ROOT / "policies" / "degradation-policy.json")

    def test_policy_is_schema_valid(self) -> None:
        validate_schema(self.policy, QUALITY_ROOT / "schemas" / "degradation-lock.schema.json")

        incomplete = deepcopy(self.policy)
        incomplete.pop("actual_codec_fixture_required_for_gate")
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(
                incomplete,
                QUALITY_ROOT / "schemas" / "degradation-lock.schema.json",
            )

    def test_spatial_profiles_repeat_and_match_locked_hashes(self) -> None:
        for profile in self.policy["profiles"]:
            if profile["kind"] == "synthetic_motion":
                continue
            size = (192, 324) if "output_scale_numerator" in profile else 64
            frame = synthetic_planar_frame(0, size=size)
            first = apply_degradation(frame, profile)
            second = apply_degradation(frame, profile)
            digest = frame_sha256(first)
            self.assertEqual(digest, frame_sha256(second), profile["id"])
            self.assertEqual(digest, profile["expected_output_sha256"], profile["id"])

    def test_lowpass_profiles_preserve_constant_planes(self) -> None:
        profiles = [
            profile
            for profile in self.policy["profiles"]
            if profile["kind"] in {"lowpass_decimate", "camera_blur_decimate"}
        ]
        for profile in profiles:
            size = (192, 324) if "output_scale_numerator" in profile else 64
            frame = synthetic_planar_frame(0, size=size)
            frame = type(frame)(
                y=np.full_like(frame.y, 0.5),
                cb=np.full_like(frame.cb, 0.125),
                cr=np.full_like(frame.cr, -0.25),
            )
            result = apply_degradation(frame, profile)
            self.assertLessEqual(float(np.max(np.abs(result.y - 0.5))), 1.0 / 65535.0)
            self.assertLessEqual(float(np.max(np.abs(result.cb - 0.125))), 1.0 / 65535.0)
            self.assertLessEqual(float(np.max(np.abs(result.cr + 0.25))), 1.0 / 65535.0)

    def test_three_over_two_profiles_have_exact_route_geometry(self) -> None:
        frame = synthetic_planar_frame(0, size=(192, 324))
        profiles = [
            profile
            for profile in self.policy["profiles"]
            if profile.get("target_route") == "direct-3over2"
        ]
        self.assertEqual(len(profiles), 3)
        for profile in profiles:
            result = apply_degradation(frame, profile)
            self.assertEqual(result.y.shape, (128, 216), profile["id"])
            self.assertEqual(result.cb.shape, (64, 108), profile["id"])
            with self.assertRaisesRegex(ValueError, "exactly divisible"):
                apply_degradation(synthetic_planar_frame(0, size=(190, 320)), profile)

    def test_motion_sequence_has_locked_hashes_and_ledger(self) -> None:
        frame = synthetic_planar_frame(1)
        alternate = synthetic_planar_frame(2)
        profile = next(item for item in self.policy["profiles"] if item["kind"] == "synthetic_motion")
        sequence, ledger = synthetic_motion_sequence(
            frame,
            profile,
            alternate_scene=alternate,
        )

        self.assertEqual(
            [frame_sha256(item) for item in sequence],
            profile["expected_sequence_sha256"],
        )
        self.assertEqual(len(ledger), 4)
        self.assertFalse(ledger[0]["scene_cut"])
        self.assertEqual(ledger[0]["scene_source"], "primary")
        self.assertGreater(ledger[1]["newly_occluded_pixel_count_y"], 0)
        self.assertGreater(ledger[2]["newly_occluded_pixel_count_y"], 0)
        self.assertGreater(ledger[2]["revealed_pixel_count_y"], 0)
        self.assertIsNotNone(ledger[2]["camera_forward_from_previous"])
        self.assertIsNotNone(ledger[2]["object_forward_from_previous"])
        self.assertTrue(ledger[-1]["scene_cut"])
        self.assertEqual(ledger[-1]["scene_source"], "alternate")
        self.assertEqual(frame_sha256(sequence[-1]), frame_sha256(alternate))
        self.assertNotEqual(frame_sha256(sequence[-1]), frame_sha256(sequence[0]))
        self.assertEqual(ledger[-1]["newly_occluded_pixel_count_y"], 0)
        self.assertEqual(ledger[-1]["revealed_pixel_count_y"], 0)

    def test_scene_cut_refuses_missing_independent_scene_pixels(self) -> None:
        frame = synthetic_planar_frame(1)
        profile = next(item for item in self.policy["profiles"] if item["kind"] == "synthetic_motion")

        with self.assertRaisesRegex(ValueError, "alternate scene pixels"):
            synthetic_motion_sequence(frame, profile)


if __name__ == "__main__":
    unittest.main()
