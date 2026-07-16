from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import unittest

from jsonschema import Draft202012Validator, ValidationError

from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
RECEIPT_PATH = (
    REPOSITORY_ROOT
    / "analysis/ash-failure-patterns/evidence/coordinate-anisotropy-diagnostic-receipt-v1.json"
)
SCHEMA_PATH = (
    CALIBRATION_ROOT
    / "schemas/coordinate-anisotropy-diagnostic-receipt-v1.schema.json"
)

EXPECTED_SOURCE_ARTIFACTS = (
    (
        "coordinate_anisotropy_diagnostic",
        "Artifacts/ASH/20260713-p06-corrective-5c6ace2c-6501-40e4-b393-0db03f200c47/published/coordinate-anisotropy-diagnostic.json",
        "artifact_sha256",
        "bf070a0727c21f0d755c513ab6277e55beeb776ddf9f5b4174e6746eaca85551",
        "10423973fd469e09e3e8bf148545d846ef509bb2334d5ff65b5c4e15c0397b0c",
        2_390_065,
    ),
    (
        "risk_state_diagnostic",
        "Artifacts/ASH/20260713-p06-corrective-5c6ace2c-6501-40e4-b393-0db03f200c47/published/risk-state-diagnostic.json",
        "artifact_sha256",
        "3e47dd3e3698e420e94fb87b49f997c68e49d4dc8f682ad628793517f6f40463",
        "38e08f6c8d00d640a82829111bb2fa231555b2eb11b0fdaec65f6985a764f31c",
        1_419_825,
    ),
    (
        "corrective_diagnostic_envelope",
        "Artifacts/ASH/20260713-p06-corrective-5c6ace2c-6501-40e4-b393-0db03f200c47/published/corrective-diagnostic-envelope.json",
        "envelope_sha256",
        "871582a430905dc86ef68a4fcc6f1964037f49689a91ec70d52df5846905ffae",
        "064e2c4b6aa596c4a2e4ddfb860f41365c32508cbafc6d5c9940b226a12147bc",
        760,
    ),
)

EXPECTED_MEASURED_DELTAS = {
    "direct_2x_coordinate_source_aligned_minus_half_pixel_at_zero_anisotropy": {
        "left_block": {
            "block_id": "direct_2x-SS-00",
            "json_pointer": "/route_cell_blocks/12",
        },
        "right_block": {
            "block_id": "direct_2x-HH-00",
            "json_pointer": "/route_cell_blocks/0",
        },
        "observation_count": 12,
        "metrics": {
            "y_psnr_db": 1.970768927341,
            "y_ssim": 0.012562306335,
            "y_ms_ssim": 0.007032063228,
            "cb_psnr_db": 0.646447796827,
            "cb_ssim": 0.001305669893,
            "cb_ms_ssim": 0.000330488567,
            "cr_psnr_db": 0.822324319249,
            "cr_ssim": 0.002744420352,
            "cr_ms_ssim": 0.000879350258,
        },
        "improved_observation_count_by_metric": {
            "y_psnr_db": 12,
            "y_ssim": 12,
            "y_ms_ssim": 12,
            "cb_psnr_db": 12,
            "cb_ssim": 12,
            "cb_ms_ssim": 12,
            "cr_psnr_db": 12,
            "cr_ssim": 12,
            "cr_ms_ssim": 12,
        },
    },
    "direct_2x_anisotropy_3072_minus_zero_at_source_aligned": {
        "left_block": {
            "block_id": "direct_2x-SS-33",
            "json_pointer": "/route_cell_blocks/15",
        },
        "right_block": {
            "block_id": "direct_2x-SS-00",
            "json_pointer": "/route_cell_blocks/12",
        },
        "observation_count": 12,
        "metrics": {
            "y_psnr_db": -0.387117097971,
            "y_ssim": -0.005989714776,
            "y_ms_ssim": -0.001853278265,
            "cb_psnr_db": -0.569358651840,
            "cb_ssim": -0.000909986049,
            "cb_ms_ssim": -0.000103875330,
            "cr_psnr_db": -0.616292853328,
            "cr_ssim": -0.002614701293,
            "cr_ms_ssim": -0.000403530911,
        },
    },
    "direct_3_over_2_luma_half_pixel_minus_source_aligned_at_zero_anisotropy": {
        "left_block": {
            "block_id": "direct_3_over_2-HS-00",
            "json_pointer": "/route_cell_blocks/20",
        },
        "right_block": {
            "block_id": "direct_3_over_2-SS-00",
            "json_pointer": "/route_cell_blocks/28",
        },
        "observation_count": 6,
        "metrics": {
            "y_psnr_db": 0.430047651058,
            "y_ssim": 0.000835969353,
            "y_ms_ssim": 0.000615560194,
        },
        "improved_observation_count_by_metric": {
            "y_psnr_db": 5,
            "y_ssim": 3,
            "y_ms_ssim": 5,
        },
    },
    "direct_3_over_2_luma_anisotropy_3072_minus_zero_at_source_aligned": {
        "left_block": {
            "block_id": "direct_3_over_2-SS-30",
            "json_pointer": "/route_cell_blocks/30",
        },
        "right_block": {
            "block_id": "direct_3_over_2-SS-00",
            "json_pointer": "/route_cell_blocks/28",
        },
        "observation_count": 6,
        "metrics": {
            "y_psnr_db": -0.334681745492,
            "y_ssim": -0.001922066702,
            "y_ms_ssim": -0.000233450443,
        },
        "improved_observation_count_by_metric": {
            "y_psnr_db": 0,
            "y_ssim": 0,
            "y_ms_ssim": 0,
        },
    },
    "direct_3_over_2_chroma_source_aligned_minus_half_pixel_at_zero_anisotropy": {
        "left_block": {
            "block_id": "direct_3_over_2-HS-00",
            "json_pointer": "/route_cell_blocks/20",
        },
        "right_block": {
            "block_id": "direct_3_over_2-HH-00",
            "json_pointer": "/route_cell_blocks/16",
        },
        "observation_count": 6,
        "metrics": {
            "cb_psnr_db": -0.097151744932,
            "cb_ssim": -0.000100385303,
            "cb_ms_ssim": -0.000079350861,
            "cr_psnr_db": 0.048452814591,
            "cr_ssim": 0.000087679949,
            "cr_ms_ssim": -0.000011613639,
        },
    },
    "direct_3_over_2_chroma_anisotropy_3072_minus_zero_at_half_pixel": {
        "left_block": {
            "block_id": "direct_3_over_2-HH-03",
            "json_pointer": "/route_cell_blocks/17",
        },
        "right_block": {
            "block_id": "direct_3_over_2-HH-00",
            "json_pointer": "/route_cell_blocks/16",
        },
        "observation_count": 6,
        "metrics": {
            "cb_psnr_db": 0.041932232878,
            "cb_ssim": 0.000022177652,
            "cb_ms_ssim": 0.000021498849,
            "cr_psnr_db": -0.007504777145,
            "cr_ssim": 0.000020992716,
            "cr_ms_ssim": 0.000027460897,
        },
    },
    "direct_3_over_2_chroma_anisotropy_3072_minus_zero_at_source_aligned": {
        "left_block": {
            "block_id": "direct_3_over_2-SS-03",
            "json_pointer": "/route_cell_blocks/29",
        },
        "right_block": {
            "block_id": "direct_3_over_2-SS-00",
            "json_pointer": "/route_cell_blocks/28",
        },
        "observation_count": 6,
        "metrics": {
            "cb_psnr_db": -0.059990331888,
            "cb_ssim": -0.000061008550,
            "cb_ms_ssim": 0.000009805903,
            "cr_psnr_db": -0.029998530569,
            "cr_ssim": -0.000008530145,
            "cr_ms_ssim": 0.000011871900,
        },
    },
}


class CoordinateAnisotropyDiagnosticReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw_receipt = RECEIPT_PATH.read_bytes()
        cls.receipt = json.loads(cls.raw_receipt)
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.validator = Draft202012Validator(cls.schema)

    def test_schema_canonical_bytes_and_self_hash(self) -> None:
        Draft202012Validator.check_schema(self.schema)
        self.validator.validate(self.receipt)
        self.assertEqual(
            self.raw_receipt,
            canonical_json_bytes(self.receipt) + b"\n",
        )
        payload = dict(self.receipt)
        observed = payload.pop("receipt_sha256")
        self.assertEqual(
            observed,
            hashlib.sha256(canonical_json_bytes(payload)).hexdigest(),
        )

    def test_exact_source_bindings_are_relative_and_bounded(self) -> None:
        observed = tuple(
            (
                row["role"],
                row["path"],
                row["self_hash_field"],
                row["self_sha256"],
                row["file_sha256"],
                row["size_bytes"],
            )
            for row in self.receipt["source_artifacts"]
        )
        self.assertEqual(observed, EXPECTED_SOURCE_ARTIFACTS)
        for row in self.receipt["source_artifacts"]:
            path = PurePosixPath(row["path"])
            self.assertFalse(path.is_absolute())
            self.assertNotIn("..", path.parts)
            self.assertEqual(path.parts[0:2], ("Artifacts", "ASH"))
        serialized = self.raw_receipt.decode("utf-8").lower()
        self.assertNotIn("/users/", serialized)

    def test_exact_scope_counts_references_and_source_limit(self) -> None:
        self.assertEqual(
            self.receipt["source_scope"],
            {
                "source_status": "development_diagnostic_no_selection",
                "split": "development",
                "selected_winner": None,
                "validation_accessed": False,
                "holdout_accessed": False,
            },
        )
        self.assertEqual(
            self.receipt["evidence_counts"],
            {
                "route_cell_block_count": 32,
                "full_corpus_composition_count": 31,
                "native_record_count": 18,
                "production_reference_observation_count": 18,
                "plane_record_count": 864,
                "numerical_fallback_count": 0,
            },
        )
        self.assertEqual(
            self.receipt["reference_bindings"],
            {
                "production_v2_exact_output_matches": [
                    {
                        "route": "direct_2x",
                        "block_id": "direct_2x-HH-00",
                        "json_pointer": "/route_cell_blocks/0",
                    },
                    {
                        "route": "direct_3_over_2",
                        "block_id": "direct_3_over_2-SS-00",
                        "json_pointer": "/route_cell_blocks/28",
                    },
                ],
                "comparison_baseline": {
                    "composition_id": "baseline",
                    "json_pointer": "/full_corpus_compositions/0",
                    "direct_2x_block_id": "direct_2x-SS-33",
                    "direct_3_over_2_block_id": "direct_3_over_2-SS-33",
                    "selected_winner": False,
                },
            },
        )
        comparison = self.receipt["current_source_comparison"]
        self.assertEqual(
            comparison["comparison_head_commit"],
            "30d9456b4464965bf38c624b89a234bd07f303fc",
        )
        self.assertFalse(comparison["current_source_equivalence_established"])
        manifest = comparison["native_source_manifest"]
        self.assertEqual(
            (
                manifest["file_sha256"],
                manifest["source_file_count"],
                manifest["matching_current_source_file_count"],
                manifest["mismatching_current_source_file_count"],
                manifest["source_commit_binding_present"],
            ),
            (
                "8d42b85ee4d9a13adf929f3e1376ad04f8b5d870a6c4fe90dbc49633bb0de04b",
                39,
                23,
                16,
                False,
            ),
        )
        manifest_path = PurePosixPath(manifest["path"])
        self.assertFalse(manifest_path.is_absolute())
        self.assertNotIn("..", manifest_path.parts)

    def test_exact_measurements_and_evidence_boundary(self) -> None:
        self.assertEqual(
            self.receipt["measurement_contract"],
            {
                "comparison_domain": "engine_raw",
                "aggregation": "arithmetic_mean_of_paired_per_observation_metric_deltas",
                "rounding_decimal_places": 12,
                "delta_direction": "left_block_minus_right_block",
                "higher_metric_value_is_better": True,
            },
        )
        self.assertEqual(self.receipt["measured_deltas"], EXPECTED_MEASURED_DELTAS)
        self.assertEqual(
            self.receipt["claims"],
            {
                "route_and_plane_coordinate_policy_effect_evidenced": True,
                "fixed_anisotropy_strength_q12_3072_authorized": False,
                "formal_gate_result_established": False,
                "winner_selected": False,
                "current_source_equivalence_established": False,
                "required_next_evidence": "fresh_current_source_formal_gate_evaluation",
            },
        )

    def test_schema_rejects_prohibited_claims_and_path_expansion(self) -> None:
        for field in (
            "fixed_anisotropy_strength_q12_3072_authorized",
            "formal_gate_result_established",
            "winner_selected",
            "current_source_equivalence_established",
        ):
            altered = copy.deepcopy(self.receipt)
            altered["claims"][field] = True
            with self.subTest(field=field), self.assertRaises(ValidationError):
                self.validator.validate(altered)

        altered = copy.deepcopy(self.receipt)
        altered["source_scope"]["selected_winner"] = "candidate"
        with self.assertRaises(ValidationError):
            self.validator.validate(altered)

        altered = copy.deepcopy(self.receipt)
        altered["source_artifacts"][0]["path"] = "/tmp/diagnostic.json"
        with self.assertRaises(ValidationError):
            self.validator.validate(altered)

        altered = copy.deepcopy(self.receipt)
        altered["unexpected_claim"] = True
        with self.assertRaises(ValidationError):
            self.validator.validate(altered)


if __name__ == "__main__":
    unittest.main()
