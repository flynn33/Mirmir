from pathlib import Path
from copy import deepcopy
import hashlib
import json
import subprocess
import tempfile
import unittest

from mirmir_quality.json_tools import manifest_sha256, read_json, validate_schema
from mirmir_quality.production_dry_run import _verify_decoder_timing


QUALITY_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = QUALITY_ROOT / "fixtures" / "actual-h264-software-nv12-v1"
SOURCE_PATH = FIXTURE_ROOT / "source.nv12"
SOURCE_LOCK_PATH = FIXTURE_ROOT / "source-lock.json"
FIXTURE_PATH = FIXTURE_ROOT / "actual-h264-software-nv12-v1.mp4"
REPORT_PATH = FIXTURE_ROOT / "actual-codec-fixture-lock.json"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pixel_signatures(route):
    return [
        [frame["active_row_sha256"] for frame in run["frames"]]
        for run in route["runs"]
    ]


class ActualCodecFixtureTests(unittest.TestCase):
    def test_source_and_committed_fixture_are_schema_valid_and_byte_bound(self) -> None:
        source_lock = read_json(SOURCE_LOCK_PATH)
        report = read_json(REPORT_PATH)
        validate_schema(
            source_lock,
            QUALITY_ROOT / "schemas" / "actual-codec-source.schema.json",
        )
        validate_schema(
            report,
            QUALITY_ROOT / "schemas" / "actual-codec-fixture.schema.json",
        )
        self.assertEqual(SOURCE_PATH.stat().st_size, source_lock["payload_size_bytes"])
        self.assertEqual(sha256(SOURCE_PATH), source_lock["payload_sha256"])
        self.assertEqual(FIXTURE_PATH.stat().st_size, report["fixture"]["size_bytes"])
        self.assertEqual(sha256(FIXTURE_PATH), report["fixture"]["sha256"])
        self.assertEqual(sha256(SOURCE_LOCK_PATH), report["source"]["source_lock_sha256"])
        self.assertEqual(
            source_lock["pixel_layout"],
            {
                "pixel_format": "420v",
                "range": "video",
                "color_primaries": "ITU_R_709_2",
                "transfer_function": "ITU_R_709_2",
                "ycbcr_matrix": "ITU_R_709_2",
                "chroma_location_top_field": "Left",
                "chroma_location_bottom_field": "Left",
                "width": 160,
                "height": 90,
                "plane_order": ["Y", "interleaved_CbCr"],
                "row_padding": "absent",
                "active_row_hash_contract": (
                    "SHA-256 over raster-order active bytes with no row padding"
                ),
                "luma_code_range": [16, 235],
                "chroma_code_range": [16, 240],
                "rounding": (
                    "binary64 multiply/add then round to nearest, ties to even"
                ),
            },
        )
        self.assertFalse(report["encoder"]["hardware_accelerated"])
        self.assertEqual(report["encoder"]["max_key_frame_interval"], 1)
        self.assertTrue(report["encoder"]["all_frames_sync"])
        self.assertEqual(report["encoder"]["chroma_location"], "Left")
        self.assertEqual(
            report["fixture"]["format_attachments"]["chroma_location_top_field"],
            "Left",
        )
        self.assertEqual(
            report["fixture"]["format_attachments"]["chroma_location_bottom_field"],
            "Left",
        )
        self.assertFalse(report["limitations"]["cross_os_bitstream_stability_claimed"])
        self.assertFalse(report["limitations"]["regeneration_bitstream_stability_claimed"])

        center_sited_source = deepcopy(source_lock)
        center_sited_source["pixel_layout"]["chroma_location_top_field"] = "Center"
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(
                center_sited_source,
                QUALITY_ROOT / "schemas" / "actual-codec-source.schema.json",
            )

        center_sited_report = deepcopy(report)
        center_sited_report["fixture"]["format_attachments"][
            "chroma_location_bottom_field"
        ] = "Center"
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            validate_schema(
                center_sited_report,
                QUALITY_ROOT / "schemas" / "actual-codec-fixture.schema.json",
            )

    def test_locked_decode_runs_and_routes_are_pixel_identical(self) -> None:
        report = read_json(REPORT_PATH)
        software, product = report["decoder_routes"]
        software_signatures = pixel_signatures(software)
        product_signatures = pixel_signatures(product)
        self.assertEqual(len(software_signatures), 3)
        self.assertEqual(len(product_signatures), 3)
        self.assertTrue(all(item == software_signatures[0] for item in software_signatures))
        self.assertTrue(all(item == product_signatures[0] for item in product_signatures))
        self.assertEqual(software_signatures[0], product_signatures[0])
        for route in report["decoder_routes"]:
            for run in route["runs"]:
                self.assertEqual(
                    [frame["presentation_time"]["value"] for frame in run["frames"]],
                    [0, 20, 40],
                )
                self.assertEqual(
                    [frame["duration"]["value"] for frame in run["frames"]],
                    [20, 20, 20],
                )
                self.assertTrue(all(frame["pixel_format"] == "420v" for frame in run["frames"]))
                self.assertTrue(
                    all(
                        frame["attachments"]["chroma_location_top_field"] == "Left"
                        and frame["attachments"]["chroma_location_bottom_field"]
                        == "Left"
                        for frame in run["frames"]
                    )
                )

    def test_decoder_timing_is_verified_against_the_source_lock(self) -> None:
        report = read_json(REPORT_PATH)
        source_lock = read_json(SOURCE_LOCK_PATH)
        _verify_decoder_timing(report["decoder_routes"], source_lock)

        tampered = deepcopy(report["decoder_routes"])
        tampered[0]["runs"][0]["frames"][0]["presentation_time"]["value"] = 20
        with self.assertRaisesRegex(ValueError, "decoded index or timing mismatch"):
            _verify_decoder_timing(tampered, source_lock)

    def test_integration_fragments_fit_lock_and_benchmark_schemas(self) -> None:
        report = read_json(REPORT_PATH)
        degradation = read_json(QUALITY_ROOT / "policies" / "degradation-policy.json")
        validate_schema(
            degradation,
            QUALITY_ROOT / "schemas" / "degradation-lock.schema.json",
        )
        self.assertEqual(
            degradation["policy_sha256"],
            manifest_sha256(degradation, "policy_sha256"),
        )
        locked_fixture = degradation["actual_codec_fixture"]
        self.assertEqual(locked_fixture["fixture_sha256"], report["fixture"]["sha256"])
        self.assertEqual(locked_fixture["evidence_sha256"], sha256(REPORT_PATH))
        self.assertEqual(
            locked_fixture["source_profile_id"],
            report["source"]["degradation_profile_id"],
        )
        self.assertEqual(
            degradation["preintegration_policy_sha256"],
            report["source"]["degradation_policy_sha256"],
        )
        self.assertEqual(
            {profile["target_route"] for profile in degradation["common_writer_profiles"]},
            {"direct-2x", "direct-3over2"},
        )

        codec_fields = report["integration"]["benchmark_dry_run_fields"]
        benchmark = {
            "schema_version": "1.0.0",
            "run_id": "actual-codec-schema-conformance",
            "split": "development",
            "corpus_mode": "synthetic_development",
            "configuration_sha256": "0" * 64,
            "corpus_manifest_sha256": "1" * 64,
            "development_source_asset_count": 1,
            "degradation_policy_sha256": "2" * 64,
            "degradation_profile_ids": ["hq-binomial7-decimate-2x-v1"],
            "metric_policy_sha256": "3" * 64,
            "case_count": 3,
            "completed_case_count": 3,
            "resumed_from_failure": False,
            "fixture_dimensions": {"width": 160, "height": 128},
            **codec_fields,
            "holdout_accessed": False,
            "gate_status": "blocked",
            "status": "pass",
        }
        validate_schema(
            benchmark,
            QUALITY_ROOT / "schemas" / "benchmark-dry-run.schema.json",
        )

    def test_exporter_reproduces_locked_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "source.nv12"
            metadata = Path(temporary) / "source-lock.json"
            subprocess.run(
                [
                    "/usr/bin/python3",
                    str(QUALITY_ROOT / "tools" / "export_actual_codec_source.py"),
                    "--output",
                    str(output),
                    "--metadata",
                    str(metadata),
                ],
                check=True,
                cwd=QUALITY_ROOT.parents[1],
                capture_output=True,
                text=True,
            )
            self.assertEqual(output.read_bytes(), SOURCE_PATH.read_bytes())
            self.assertEqual(json.loads(metadata.read_text()), read_json(SOURCE_LOCK_PATH))

    def test_native_tool_passes_and_preserves_a_schema_valid_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            success = root / "success"
            success_result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(QUALITY_ROOT / "tools" / "run_actual_codec_fixture.py"),
                    "--output-directory",
                    str(success),
                ],
                cwd=QUALITY_ROOT.parents[1],
                capture_output=True,
                text=True,
            )
            self.assertEqual(success_result.returncode, 0, success_result.stderr)
            generated_report = read_json(success / "actual-codec-fixture-lock.json")
            validate_schema(
                generated_report,
                QUALITY_ROOT / "schemas" / "actual-codec-fixture.schema.json",
            )
            self.assertTrue(generated_report["verification"]["cross_route_pixel_identical"])

            corrupt_source = root / "corrupt-source.nv12"
            corrupt_source.write_bytes(SOURCE_PATH.read_bytes()[:-1])
            failure = root / "failure"
            failure_result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(QUALITY_ROOT / "tools" / "run_actual_codec_fixture.py"),
                    "--output-directory",
                    str(failure),
                    "--source",
                    str(corrupt_source),
                ],
                cwd=QUALITY_ROOT.parents[1],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(failure_result.returncode, 0)
            failures = list(failure.glob("actual-codec-fixture-lock.failed-*.json"))
            self.assertEqual(len(failures), 1)
            failure_record = read_json(failures[0])
            validate_schema(
                failure_record,
                QUALITY_ROOT / "schemas" / "actual-codec-fixture-failure.schema.json",
            )
            self.assertFalse((failure / "actual-codec-fixture-lock.json").exists())


if __name__ == "__main__":
    unittest.main()
