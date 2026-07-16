from pathlib import Path
from copy import deepcopy
import hashlib
import tempfile
import unittest

import numpy as np

from mirmir_quality.common_writer import (
    CommonWriterExecutionError,
    CommonWriterInputFrame,
    RationalTime,
    compile_common_writer,
    compile_production_writer,
    run_common_writer,
    run_common_writer_locked,
    run_isolated_production_writer_cases,
    run_production_writer,
    run_production_writer_locked,
    write_common_writer_source,
)
from mirmir_quality.json_tools import read_json, validate_schema


QUALITY_ROOT = Path(__file__).resolve().parents[1]
WIDTH = 324
HEIGHT = 192
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _nv12_frame(index: int) -> bytes:
    yy, xx = np.indices((HEIGHT, WIDTH), dtype=np.int64)
    luma = (16 + ((3 * xx + 5 * yy + 17 * index) % 220)).astype(np.uint8)
    cy, cx = np.indices((HEIGHT // 2, WIDTH // 2), dtype=np.int64)
    chroma_blue = (16 + ((7 * cx + 11 * cy + 13 * index) % 225)).astype(np.uint8)
    chroma_red = (16 + ((13 * cx + 3 * cy + 19 * index) % 225)).astype(np.uint8)
    chroma = np.empty((HEIGHT // 2, WIDTH), dtype=np.uint8)
    chroma[:, 0::2] = chroma_blue
    chroma[:, 1::2] = chroma_red
    return luma.tobytes(order="C") + chroma.tobytes(order="C")


def _frames(count: int = 4) -> tuple:
    return tuple(
        CommonWriterInputFrame(
            case_id=f"case-{index:02d}",
            nv12=_nv12_frame(index),
            presentation_time=RationalTime(index * 20, 600),
            duration=RationalTime(20, 600),
        )
        for index in range(count)
    )


def _active_hashes(payload: bytes) -> dict:
    luma_size = WIDTH * HEIGHT
    chroma = payload[luma_size:]
    return {
        "Y": _sha256(payload[:luma_size]),
        "Cb": _sha256(chroma[0::2]),
        "Cr": _sha256(chroma[1::2]),
    }


class CommonWriterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build_temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-common-writer-test-build-"
        )
        cls.executable = compile_common_writer(
            Path(cls.build_temporary.name) / "common-writer"
        )
        cls.production_executable = compile_production_writer(
            Path(cls.build_temporary.name) / "production-writer"
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.build_temporary.cleanup()

    def test_multiple_324x192_frames_preserve_order_timing_and_bytes(self) -> None:
        frames = _frames()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = run_common_writer(
                frames=frames,
                width=WIDTH,
                height=HEIGHT,
                output_directory=root / "first",
                source_id="common-writer-multiple-frame-test",
                executable=self.executable,
            )
            second = run_common_writer(
                frames=frames,
                width=WIDTH,
                height=HEIGHT,
                output_directory=root / "second",
                source_id="common-writer-multiple-frame-test",
                executable=self.executable,
            )

            report = first.report
            validate_schema(report, QUALITY_ROOT / "schemas" / "common-writer.schema.json")
            center_sited_source = deepcopy(read_json(first.source_lock_path))
            center_sited_source["pixel_layout"][
                "chroma_location_top_field"
            ] = "Center"
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(
                    center_sited_source,
                    QUALITY_ROOT / "schemas" / "common-writer-source.schema.json",
                )
            center_sited_report = deepcopy(report)
            center_sited_report["decoder"]["frames"][0]["attachments"][
                "chroma_location_bottom_field"
            ] = "Center"
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(
                    center_sited_report,
                    QUALITY_ROOT / "schemas" / "common-writer.schema.json",
                )
            self.assertEqual(report["source"]["frame_count"], 4)
            self.assertEqual(report["encoded"]["container"], "mp4")
            self.assertEqual(report["encoded"]["codec"], "avc1")
            self.assertEqual(
                [report["encoded"]["width"], report["encoded"]["height"]],
                [WIDTH, HEIGHT],
            )
            self.assertEqual(report["decoder"]["frame_count"], 4)
            self.assertEqual(report["decoder"]["pixel_format"], "420v")
            self.assertEqual(
                report["decoder"]["payload_layout"],
                "active_row_nv12_without_padding",
            )
            self.assertEqual(
                [frame["case_id"] for frame in report["decoder"]["frames"]],
                [frame.case_id for frame in frames],
            )
            self.assertEqual(
                [frame["index"] for frame in report["decoder"]["frames"]],
                list(range(4)),
            )
            self.assertEqual(
                [frame["presentation_time"]["value"] for frame in report["decoder"]["frames"]],
                [0, 20, 40, 60],
            )
            self.assertEqual(
                [frame["presentation_time"]["timescale"] for frame in report["decoder"]["frames"]],
                [600, 600, 600, 600],
            )
            self.assertEqual(
                [frame["duration"]["value"] for frame in report["decoder"]["frames"]],
                [20, 20, 20, 20],
            )
            self.assertEqual(
                [frame["duration"]["timescale"] for frame in report["decoder"]["frames"]],
                [600, 600, 600, 600],
            )
            self.assertEqual(
                [frame["frame_nv12_sha256"] for frame in report["source"]["frames"]],
                [_sha256(frame.nv12) for frame in frames],
            )
            for index, payload in enumerate(first.decoded_frames):
                evidence = report["decoder"]["frames"][index]
                self.assertEqual(len(payload), FRAME_SIZE)
                self.assertEqual(_sha256(payload), evidence["payload_sha256"])
                self.assertEqual(_active_hashes(payload), evidence["active_row_sha256"])
                self.assertEqual(evidence["width"], WIDTH)
                self.assertEqual(evidence["height"], HEIGHT)
            self.assertEqual(report["encoder"]["encoder_name"], "Apple H.264 (SW)")
            self.assertEqual(report["encoder"]["chroma_location"], "Left")
            self.assertEqual(
                report["source"]["pixel_layout"]["chroma_location_top_field"],
                "Left",
            )
            self.assertEqual(
                report["source"]["pixel_layout"]["chroma_location_bottom_field"],
                "Left",
            )
            self.assertEqual(
                report["encoded"]["format_attachments"]["chroma_location_top_field"],
                "Left",
            )
            self.assertEqual(
                report["encoded"]["format_attachments"]["chroma_location_bottom_field"],
                "Left",
            )
            self.assertFalse(report["encoder"]["hardware_accelerated"])
            self.assertFalse(report["encoder"]["allow_frame_reordering"])
            self.assertFalse(report["encoder"]["allow_temporal_compression"])
            self.assertEqual(report["encoder"]["max_key_frame_interval"], 1)
            self.assertTrue(report["encoder"]["all_frames_sync"])
            self.assertTrue(all(report["verification"].values()))
            self.assertFalse(
                report["limitations"]["mp4_byte_identity_across_runs_claimed"]
            )

            first_decoded_hashes = [_sha256(payload) for payload in first.decoded_frames]
            second_decoded_hashes = [_sha256(payload) for payload in second.decoded_frames]
            self.assertEqual(first_decoded_hashes, second_decoded_hashes)
            for frame in report["decoder"]["frames"]:
                self.assertEqual(
                    frame["attachments"]["chroma_location_top_field"],
                    "Left",
                )
                self.assertEqual(
                    frame["attachments"]["chroma_location_bottom_field"],
                    "Left",
                )

    def test_single_frame_is_supported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = run_common_writer(
                frames=_frames(1),
                width=WIDTH,
                height=HEIGHT,
                output_directory=Path(temporary) / "single",
                source_id="common-writer-single-frame-test",
                executable=self.executable,
            )
            self.assertEqual(len(result.decoded_frames), 1)
            self.assertEqual(result.report["source"]["frame_count"], 1)
            self.assertEqual(result.report["encoded"]["frame_count"], 1)
            self.assertEqual(result.report["decoder"]["frame_count"], 1)

    def test_production_writer_uses_shared_hevc_settings_and_left_chroma(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = run_production_writer(
                frames=_frames(1),
                width=WIDTH,
                height=HEIGHT,
                output_directory=Path(temporary) / "production",
                source_id="production-writer-parity-test",
                executable=self.production_executable,
            )
            report = result.report
            validate_schema(
                report,
                QUALITY_ROOT / "schemas" / "production-writer.schema.json",
            )
            self.assertEqual(report["artifact_kind"], "production_writer_actual_codec")
            self.assertIn(report["encoded"]["codec"], {"hvc1", "hev1"})
            self.assertEqual(report["encoder"]["requested_codec"], "hevc")
            self.assertEqual(report["encoder"]["requested_average_bit_rate"], 2_000_000)
            self.assertGreater(report["encoder"]["observed_estimated_data_rate"], 0)
            self.assertEqual(
                report["encoder"]["product_settings_source"]["path"],
                "MediaTypes.swift",
            )
            self.assertEqual(len(result.decoded_frames), 1)
            self.assertEqual(
                [frame["case_id"] for frame in report["decoder"]["frames"]],
                [frame.case_id for frame in _frames(1)],
            )
            self.assertEqual(
                report["container_scope"],
                {
                    "frame_count": 1,
                    "single_frame_container": True,
                    "neighbor_frames_present": False,
                    "metric_role": "isolated_metric_case",
                },
            )
            self.assertTrue(all(report["verification"].values()))
            for frame in report["decoder"]["frames"]:
                self.assertEqual(
                    frame["attachments"]["chroma_location_top_field"],
                    "Left",
                )
                self.assertEqual(frame["attachments"]["range"], "video")
            self.assertEqual(
                report["source"]["pixel_layout"]["chroma_location_top_field"],
                "Left",
            )
            self.assertEqual(
                report["source"]["pixel_layout"]["chroma_location_bottom_field"],
                "Left",
            )
            self.assertFalse(
                report["limitations"]["mp4_byte_identity_across_runs_claimed"]
            )

    def test_isolated_production_writer_is_order_and_neighbor_invariant(self) -> None:
        frames = _frames(3)

        def decoded_hashes(results) -> dict:
            return {
                item.case_id: _sha256(item.result.decoded_frames[0])
                for item in results
            }

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            solo = run_isolated_production_writer_cases(
                frames=(frames[0],),
                width=WIDTH,
                height=HEIGHT,
                output_directory=root / "solo",
                source_id="isolated-solo",
                executable=self.production_executable,
            )
            with_neighbors = run_isolated_production_writer_cases(
                frames=(frames[1], frames[0], frames[2]),
                width=WIDTH,
                height=HEIGHT,
                output_directory=root / "with-neighbors",
                source_id="isolated-with-neighbors",
                executable=self.production_executable,
            )
            reordered = run_isolated_production_writer_cases(
                frames=(frames[2], frames[1], frames[0]),
                width=WIDTH,
                height=HEIGHT,
                output_directory=root / "reordered",
                source_id="isolated-reordered",
                executable=self.production_executable,
            )

            solo_hashes = decoded_hashes(solo)
            neighbor_hashes = decoded_hashes(with_neighbors)
            reordered_hashes = decoded_hashes(reordered)
            self.assertEqual(solo_hashes[frames[0].case_id], neighbor_hashes[frames[0].case_id])
            self.assertEqual(neighbor_hashes, reordered_hashes)
            for item in (*solo, *with_neighbors, *reordered):
                self.assertEqual(
                    item.result.report["container_scope"]["metric_role"],
                    "isolated_metric_case",
                )
                self.assertFalse(
                    item.result.report["container_scope"]["neighbor_frames_present"]
                )

    def test_multi_frame_production_writer_is_non_metric_smoke_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = run_production_writer(
                frames=_frames(3),
                width=WIDTH,
                height=HEIGHT,
                output_directory=Path(temporary) / "smoke",
                source_id="production-writer-smoke-test",
                executable=self.production_executable,
            )
            validate_schema(
                result.report,
                QUALITY_ROOT / "schemas" / "production-writer.schema.json",
            )
            self.assertEqual(
                result.report["container_scope"],
                {
                    "frame_count": 3,
                    "single_frame_container": False,
                    "neighbor_frames_present": True,
                    "metric_role": "non_metric_smoke_only",
                },
            )
            false_metric_evidence = deepcopy(result.report)
            false_metric_evidence["container_scope"] = {
                "frame_count": 1,
                "single_frame_container": True,
                "neighbor_frames_present": False,
                "metric_role": "isolated_metric_case",
            }
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(
                    false_metric_evidence,
                    QUALITY_ROOT / "schemas" / "production-writer.schema.json",
                )

    def test_source_tamper_is_rejected_and_failures_are_preserved(self) -> None:
        frames = _frames(3)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_path = root / "input" / "source.nv12"
            source_lock_path = root / "input" / "source-lock.json"
            write_common_writer_source(
                frames=frames,
                width=WIDTH,
                height=HEIGHT,
                source_path=source_path,
                source_lock_path=source_lock_path,
                source_id="common-writer-tamper-test",
            )
            payload = bytearray(source_path.read_bytes())
            payload[WIDTH + 7] ^= 0x01
            source_path.write_bytes(payload)
            output = root / "failure"

            with self.assertRaises(CommonWriterExecutionError) as first_context:
                run_common_writer_locked(
                    source_path=source_path,
                    source_lock_path=source_lock_path,
                    output_directory=output,
                    executable=self.executable,
                )
            first_failure = first_context.exception.failure_paths[0]
            first_failure_payload = first_failure.read_bytes()
            first_record = read_json(first_failure)
            validate_schema(
                first_record,
                QUALITY_ROOT / "schemas" / "common-writer-failure.schema.json",
            )
            self.assertIn("does not match its lock", first_record["message"])

            with self.assertRaises(CommonWriterExecutionError) as second_context:
                run_common_writer_locked(
                    source_path=source_path,
                    source_lock_path=source_lock_path,
                    output_directory=output,
                    executable=self.executable,
                )
            self.assertEqual(first_failure.read_bytes(), first_failure_payload)
            self.assertEqual(len(second_context.exception.failure_paths), 2)
            self.assertNotEqual(
                second_context.exception.failure_paths[0],
                second_context.exception.failure_paths[1],
            )
            self.assertFalse((output / "common-writer.mp4").exists())
            self.assertFalse((output / "common-writer-report.json").exists())
            self.assertFalse((output / "common-writer-decoded").exists())

    def test_production_writer_rejects_tampered_locked_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_path = root / "input" / "source.nv12"
            source_lock_path = root / "input" / "source-lock.json"
            write_common_writer_source(
                frames=_frames(1),
                width=WIDTH,
                height=HEIGHT,
                source_path=source_path,
                source_lock_path=source_lock_path,
                source_id="production-writer-tamper-test",
            )
            payload = bytearray(source_path.read_bytes())
            payload[WIDTH + 7] ^= 0x01
            source_path.write_bytes(payload)
            output = root / "failure"
            with self.assertRaises(CommonWriterExecutionError) as context:
                run_production_writer_locked(
                    source_path=source_path,
                    source_lock_path=source_lock_path,
                    output_directory=output,
                    executable=self.production_executable,
                )
            self.assertEqual(len(context.exception.failure_paths), 1)
            failure = read_json(context.exception.failure_paths[0])
            validate_schema(
                failure,
                QUALITY_ROOT / "schemas" / "common-writer-failure.schema.json",
            )
            self.assertIn("does not match its lock", failure["message"])
            self.assertFalse((output / "production-writer.mp4").exists())


if __name__ == "__main__":
    unittest.main()
