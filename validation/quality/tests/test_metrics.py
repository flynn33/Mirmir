from copy import deepcopy
from pathlib import Path
import hashlib
import math
import subprocess
import sys
import unittest

import numpy as np

from mirmir_quality.conformance import run_metric_conformance
from mirmir_quality.json_tools import manifest_sha256, read_json, validate_schema
from mirmir_quality.metrics import (
    alias_energy,
    chroma_edge_displacement,
    ms_ssim,
    ms_ssim_detail,
    psnr,
    ssim,
)


QUALITY_ROOT = Path(__file__).resolve().parents[1]


class MetricConformanceTests(unittest.TestCase):
    def test_complete_analytic_conformance_is_schema_valid(self) -> None:
        policy = read_json(QUALITY_ROOT / "policies" / "metric-policy.json")
        validate_schema(policy, QUALITY_ROOT / "schemas" / "metric-policy.schema.json")
        result = run_metric_conformance(policy["policy_sha256"])

        validate_schema(result, QUALITY_ROOT / "schemas" / "metric-conformance.schema.json")
        self.assertEqual(result["status"], "pass")
        self.assertGreaterEqual(len(result["cases"]), 16)
        self.assertTrue(all(case["pass"] for case in result["cases"]))
        self.assertIn(
            "independent-nonidentical-ms-ssim",
            {case["case_id"] for case in result["cases"]},
        )
        chroma_case = next(
            case for case in result["cases"]
            if case["case_id"] == "direct-2x.left-sited-chroma-edge-v2"
        )
        self.assertEqual(chroma_case["actual"]["displacement"], {"Cb": 0.0, "Cr": 0.0})
        self.assertAlmostEqual(
            chroma_case["actual"]["Cb-only"]["Cb"]["mse"],
            0.25,
            places=15,
        )

    def test_analytic_fixture_manifest_and_alias_mask_are_byte_bound(self) -> None:
        policy = read_json(QUALITY_ROOT / "policies" / "metric-policy.json")
        binding = policy["analytic_fixture_manifest"]
        path = QUALITY_ROOT / binding["path"]
        payload = path.read_bytes()
        self.assertEqual(hashlib.sha256(payload).hexdigest(), binding["file_sha256"])
        fixture = read_json(path)
        validate_schema(
            fixture,
            QUALITY_ROOT / "schemas" / "analytic-fixtures-v2.schema.json",
        )
        self.assertEqual(
            manifest_sha256(fixture),
            binding["manifest_sha256"],
        )
        definitions = [
            definition
            for definition in fixture["fixtures"]
            if definition["fixture_kind"] == "alias"
        ]
        self.assertEqual(len(definitions), 2)
        definition = definitions[0]
        mask = np.zeros(tuple(definition["target_geometry"]["y"]), dtype=bool)
        support = definition["measurement_support"]
        for row, column in support["true_coordinates"]:
            mask[row, column] = True
        packed = np.packbits(mask.reshape(-1), bitorder="big").tobytes()
        self.assertEqual(
            hashlib.sha256(packed).hexdigest(),
            support["packed_sha256"],
        )

    def test_result_schemas_reject_false_pass_documents(self) -> None:
        policy = read_json(QUALITY_ROOT / "policies" / "metric-policy.json")
        metric_result = run_metric_conformance(policy["policy_sha256"])
        metric_schema = QUALITY_ROOT / "schemas" / "metric-conformance.schema.json"
        false_metric_pass = deepcopy(metric_result)
        for case in false_metric_pass["cases"]:
            case["pass"] = False
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(false_metric_pass, metric_schema)

        incomplete_metric_pass = deepcopy(metric_result)
        incomplete_metric_pass["cases"].pop()
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(incomplete_metric_pass, metric_schema)

        quality_schema = QUALITY_ROOT / "schemas" / "quality-result.schema.json"
        quality_result = {
            "schema_version": "1.0.0",
            "run_id": "schema-adversary",
            "configuration_sha256": "0" * 64,
            "corpus_manifest_sha256": "1" * 64,
            "split": "development",
            "comparison_domain": "engine_raw",
            "asset_results": [],
            "status": "pass",
        }
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(quality_result, quality_schema)

        quality_result["asset_results"] = [
            {
                "source_asset_id": "source-0",
                "degradation_profile": "profile-0",
                "metrics": {},
                "status": "pass",
            }
        ]
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(quality_result, quality_schema)

        quality_result["asset_results"] = [
            {
                "source_asset_id": "source-0",
                "degradation_profile": "profile-0",
                "metrics": {},
                "status": "fail",
            }
        ]
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(quality_result, quality_schema)

    def test_constant_offset_psnr_has_analytic_value(self) -> None:
        reference = np.full((32, 32), 0.25)
        candidate = reference + 0.125
        result = psnr(reference, candidate)

        self.assertFalse(result["exact_match"])
        self.assertAlmostEqual(result["mse"], 0.125**2, places=15)
        self.assertAlmostEqual(result["value"], 10.0 * math.log10(64.0), places=12)

    def test_constant_image_ssim_matches_luminance_formula(self) -> None:
        reference = np.full((32, 32), 0.25)
        candidate = np.full((32, 32), 0.50)
        c1 = 0.01**2
        expected = (2.0 * 0.25 * 0.50 + c1) / (0.25**2 + 0.50**2 + c1)

        self.assertAlmostEqual(ssim(reference, candidate), expected, places=12)

    def test_identical_five_scale_result_is_one(self) -> None:
        yy, xx = np.indices((64, 64), dtype=np.float64)
        fixture = ((xx + 3.0 * yy) % 17.0) / 16.0

        self.assertAlmostEqual(ms_ssim(fixture, fixture.copy()), 1.0, places=12)

    def test_alias_metric_rejects_an_empty_forbidden_mask(self) -> None:
        with self.assertRaisesRegex(ValueError, "select at least one"):
            alias_energy(np.ones((8, 8)), np.zeros((8, 8), dtype=bool))

    def test_chroma_displacement_uses_centered_zero_crossings(self) -> None:
        y = np.asarray([0.0, 0.0, 1.0, 1.0])
        cb = np.asarray([-0.5, -0.5, 0.5, 0.5])
        cr = np.asarray([-0.5, -0.5, -0.5, 0.5])
        self.assertEqual(
            chroma_edge_displacement(y, cb, cr),
            {"Cb": 0.0, "Cr": 1.0},
        )

    def test_independent_nonidentical_vectors_reproduce_and_cover_all_scales(self) -> None:
        vector_path = QUALITY_ROOT / "reference" / "metric-vectors-v1.json"
        result = subprocess.run(
            [
                sys.executable,
                str(QUALITY_ROOT / "reference" / "metric_oracle.py"),
                "--check",
                str(vector_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        yy, xx = np.indices((96, 96), dtype=np.float64)
        reference = np.clip(
            0.50 * xx / 95.0
            + 0.25 * yy / 95.0
            + 0.25 * ((xx // 4 + yy // 6) % 2),
            0.0,
            1.0,
        )
        candidate = np.roll(reference, shift=(1, -1), axis=(0, 1))
        candidate = np.clip(
            0.965 * candidate
            + 0.0175
            + 0.0125 * np.sin((3.0 * xx + 5.0 * yy) * 2.0 * np.pi / 37.0),
            0.0,
            1.0,
        )
        detail = ms_ssim_detail(reference, candidate)
        self.assertEqual(len(detail["scale_contrast_structure_means"]), 5)
        self.assertEqual(len(detail["scale_ssim_means"]), 5)
        self.assertTrue(all(value < 1.0 for value in detail["scale_ssim_means"]))


if __name__ == "__main__":
    unittest.main()
