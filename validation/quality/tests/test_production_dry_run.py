from copy import deepcopy
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

import mirmir_quality.production_dry_run as production_dry_run_module
from mirmir_quality.arrays import PlanarFrame, frame_sha256, resize_bilinear
from mirmir_quality.common_writer import (
    compile_common_writer,
    compile_production_writer,
)
from mirmir_quality.corpus import QUALITY_CATEGORIES, create_corpus_lock
from mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
    read_json,
    validate_schema,
    write_json,
)
from mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    ENGINE_RAW_PIXEL_REPRESENTATION,
    ProductionDevelopmentDryRun,
    ProductionDryRunInterrupted,
    _case_result,
    _container_result,
    _planar_to_video_range_nv12,
    _video_range_nv12_to_planar,
)
from mirmir_quality.samples import (
    build_sample_record,
    create_development_sample_lock,
)


QUALITY_ROOT = Path(__file__).resolve().parents[1]
_COMPILED_WRITER = None
_COMPILED_PRODUCTION_WRITER = None


@contextmanager
def _temporary_directory():
    with tempfile.TemporaryDirectory() as temporary:
        try:
            yield temporary
        finally:
            root = Path(temporary)
            directories = [
                root,
                *(
                    path
                    for path in root.rglob("*")
                    if path.is_dir() and not path.is_symlink()
                ),
            ]
            for directory in sorted(directories, key=lambda item: len(item.parts)):
                flags = os.stat(directory, follow_symlinks=False).st_flags
                if flags & stat.UF_IMMUTABLE:
                    os.chflags(
                        directory,
                        flags & ~stat.UF_IMMUTABLE,
                        follow_symlinks=False,
                    )
                directory.chmod(0o755)
            for path in root.rglob("*"):
                if path.is_symlink() or not path.is_file():
                    continue
                flags = os.stat(path, follow_symlinks=False).st_flags
                if flags & stat.UF_IMMUTABLE:
                    os.chflags(
                        path,
                        flags & ~stat.UF_IMMUTABLE,
                        follow_symlinks=False,
                    )


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _asset(
    *,
    index: int,
    split: str,
    route: str,
    payload: bytes,
    evidence_payload: bytes,
) -> dict:
    asset_id = f"asset-{index:02d}"
    evidence_path = f"records/{asset_id}.txt"
    dimensions = [3840, 2160] if route == "direct-2x" else [1920, 1080]
    return {
        "asset_id": asset_id,
        "source_asset_id": f"source-{index:02d}",
        "source_family_id": f"family-{index:02d}",
        "relative_path": f"corpus/{asset_id}.mov",
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
        "media_type": "video",
        "native_target": True,
        "derived": False,
        "split": split,
        "encoded_dimensions": dimensions,
        "presentation_dimensions": dimensions,
        "frame_range": {"start": 0, "duration": 60, "timescale": 60},
        "frame_count": 60,
        "target_routes": [route],
        "pixel_format": "420v",
        "range": "video",
        "color_primaries": "ITU_R_709_2",
        "transfer_function": "ITU_R_709_2",
        "ycbcr_matrix": "ITU_R_709_2",
        "chroma_location": "left",
        "categories": sorted(QUALITY_CATEGORIES),
        "provenance": {
            "origin_kind": "project-test-fixture",
            "creator": "Mirmir validation suite",
            "source_uri": None,
            "original_filename": f"{asset_id}.mov",
            "acquired_utc": "2026-07-11T00:00:00Z",
            "capture_or_creation_metadata": {"fixture_index": index},
            "evidence_path": evidence_path,
            "evidence_sha256": _sha256(evidence_payload),
        },
        "rights": {
            "status": "confirmed",
            "basis": "project-owned test fixture",
            "license_id": None,
            "license_or_declaration_path": evidence_path,
            "license_or_declaration_sha256": _sha256(evidence_payload),
            "item_specific_exception_status": "not_applicable_project_owned",
            "item_specific_exception_evidence_path": evidence_path,
            "item_specific_exception_evidence_sha256": _sha256(evidence_payload),
            "permitted_uses": ["local-project-testing"],
            "derivative_artifacts_permitted": True,
            "redistribution_permitted": False,
            "confirmed_by": "fixture owner",
            "confirmed_utc": "2026-07-11T00:00:00Z",
            "expires_utc": None,
        },
        "sensitive_metadata_present": False,
    }


def _sample_bytes(index: int, *, width: int, height: int) -> tuple:
    xx = np.arange(width, dtype=np.uint16)[None, :]
    yy = np.arange(height, dtype=np.uint16)[:, None]
    y = (16 + ((3 * xx + 5 * yy + 17 * index) % 220)).astype(np.uint8)
    cx = np.arange(width // 2, dtype=np.uint16)[None, :]
    cy = np.arange(height // 2, dtype=np.uint16)[:, None]
    cb = (16 + ((7 * cx + 11 * cy + 13 * index) % 225)).astype(np.uint8)
    cr = (16 + ((13 * cx + 3 * cy + 19 * index) % 225)).astype(np.uint8)
    cbcr = np.empty((height // 2, width), dtype=np.uint8)
    cbcr[:, 0::2] = cb
    cbcr[:, 1::2] = cr
    return y.tobytes(order="C"), cbcr.tobytes(order="C")


def _build_inputs(root: Path) -> dict:
    asset_root = root / "assets"
    evidence_root = root / "evidence"
    sample_root = root / "samples"
    (asset_root / "corpus").mkdir(parents=True)
    (evidence_root / "records").mkdir(parents=True)
    sample_root.mkdir()

    assignments = ["development"] * 6 + ["validation"] * 3 + ["holdout"] * 3
    assets = []
    for index, split in enumerate(assignments):
        payload = f"native-target-payload-{index:02d}".encode("utf-8")
        evidence_payload = f"rights-and-provenance-{index:02d}".encode("utf-8")
        route = "direct-2x" if index % 2 == 0 else "direct-3over2"
        record = _asset(
            index=index,
            split=split,
            route=route,
            payload=payload,
            evidence_payload=evidence_payload,
        )
        assets.append(record)
        (evidence_root / record["provenance"]["evidence_path"]).write_bytes(
            evidence_payload
        )
        if split != "holdout":
            (asset_root / record["relative_path"]).write_bytes(payload)

    exact_overall = {category: 4 for category in QUALITY_CATEGORIES}
    exact_by_split = {
        split: {category: 1 for category in QUALITY_CATEGORIES}
        for split in ("development", "validation", "holdout")
    }
    corpus = create_corpus_lock(
        corpus_id="production-test-corpus",
        corpus_version="1.0.0",
        created_utc="2026-07-11T00:00:00Z",
        split_policy={
            "unit": "source_asset",
            "group_key": "source_family_id",
            "allocation": {
                "development": 0.5,
                "validation": 0.25,
                "holdout": 0.25,
            },
            "algorithm": "fixed test assignment before dry-run execution",
            "seed": 20260711,
            "rounding_rule": "exact 6/3/3 family allocation",
            "expected_family_counts": {
                "development": 6,
                "validation": 3,
                "holdout": 3,
            },
            "minimum_category_counts": exact_overall,
            "minimum_category_counts_by_split": exact_by_split,
        },
        assets=assets,
        category_vocabulary_version="quality-gate-policy-1.1.0",
    )
    corpus_path = root / "corpus-lock.json"
    corpus_path.write_bytes(canonical_json_bytes(corpus) + b"\n")

    sample_records = []
    for index, asset in enumerate(assets[:6]):
        sample_directory = sample_root / asset["asset_id"]
        sample_directory.mkdir()
        width, height = asset["presentation_dimensions"]
        y_payload, cbcr_payload = _sample_bytes(
            index,
            width=width,
            height=height,
        )
        y_path = sample_directory / "frame.y.bin"
        cbcr_path = sample_directory / "frame.cbcr.bin"
        y_path.write_bytes(y_payload)
        cbcr_path.write_bytes(cbcr_payload)
        record = {
            "index": 0,
            "decoded_frame_sha256": _sha256(y_payload + cbcr_payload),
            "width": width,
            "height": height,
            "pixel_format": "420v",
            "plane_bytes_per_row": [width, width],
            "plane_heights": [height, height // 2],
            "decoded_attachments": {
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
            },
            "source_format_extensions": {
                "CVImageBufferColorPrimaries": "ITU_R_709_2",
                "CVImageBufferTransferFunction": "ITU_R_709_2",
                "CVImageBufferYCbCrMatrix": "ITU_R_709_2",
                "CVImageBufferChromaLocationTopField": "Left",
                "CVImageBufferChromaLocationBottomField": "Left",
                "FullRangeVideo": False,
                "CVPixelAspectRatio": {
                    "HorizontalSpacing": 1,
                    "VerticalSpacing": 1,
                },
            },
            "pts": {"value": index, "timescale": 600},
            "y_active_path": f"{asset['asset_id']}/frame.y.bin",
            "cbcr_active_path": f"{asset['asset_id']}/frame.cbcr.bin",
        }
        decode_manifest_path = sample_directory / "decode-manifest.json"
        write_json(
            decode_manifest_path,
            {
                "asset_id": asset["asset_id"],
                "split": "development",
                "media_path": str(
                    (asset_root / asset["relative_path"]).resolve(strict=True)
                ),
                "source_format_extensions": record["source_format_extensions"],
                "representative_samples": [record],
            },
        )
        evidence_manifest_path = sample_directory / "evidence-manifest.json"
        evidence_files = []
        for path in (decode_manifest_path, y_path, cbcr_path):
            payload = path.read_bytes()
            evidence_files.append(
                {
                    "path": path.name,
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
        write_json(
            evidence_manifest_path,
            {
                "schema_version": "1.0.0",
                "files": evidence_files,
            },
        )
        sample_records.append(
            build_sample_record(
                asset=asset,
                target_route=asset["target_routes"][0],
                sample_root=sample_root,
                asset_root=asset_root,
                decode_manifest_path=(
                    f"{asset['asset_id']}/decode-manifest.json"
                ),
                source_evidence_manifest_path=(
                    f"{asset['asset_id']}/evidence-manifest.json"
                ),
            )
        )
    sample_lock = create_development_sample_lock(
        corpus_manifest_sha256=corpus["manifest_sha256"],
        samples=sample_records,
    )
    sample_lock_path = root / "development-sample-lock.json"
    write_json(sample_lock_path, sample_lock)
    return {
        "asset_root": asset_root,
        "evidence_root": evidence_root,
        "sample_root": sample_root,
        "corpus_path": corpus_path,
        "sample_lock_path": sample_lock_path,
        "corpus": corpus,
    }


def _runner(
    root: Path,
    inputs: dict,
    run_id: str,
    *,
    candidate_adapter: CandidateAdapter = None,
) -> ProductionDevelopmentDryRun:
    return ProductionDevelopmentDryRun(
        output_root=root / "runs",
        run_id=run_id,
        quality_root=QUALITY_ROOT,
        corpus_lock_path=inputs["corpus_path"],
        asset_root=inputs["asset_root"],
        evidence_root=inputs["evidence_root"],
        development_sample_lock_path=inputs["sample_lock_path"],
        sample_root=inputs["sample_root"],
        candidate_adapter=candidate_adapter,
        common_writer_executable=_COMPILED_WRITER,
        production_writer_executable=_COMPILED_PRODUCTION_WRITER,
    )


class ProductionDryRunTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        global _COMPILED_PRODUCTION_WRITER, _COMPILED_WRITER
        cls.writer_build = tempfile.TemporaryDirectory(
            prefix="mirmir-production-writer-build-"
        )
        _COMPILED_WRITER = compile_common_writer(
            Path(cls.writer_build.name) / "common-writer"
        )
        _COMPILED_PRODUCTION_WRITER = compile_production_writer(
            Path(cls.writer_build.name) / "production-writer"
        )

    @classmethod
    def tearDownClass(cls) -> None:
        global _COMPILED_PRODUCTION_WRITER, _COMPILED_WRITER
        _COMPILED_WRITER = None
        _COMPILED_PRODUCTION_WRITER = None
        cls.writer_build.cleanup()

    def test_production_dry_run_is_schema_valid_hash_bound_and_route_matched(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            runner = _runner(root, inputs, "production-pass")
            verify = runner._verify_artifacts_before_publish
            semantic_verify = runner._verify_artifact_semantics
            detach = production_dry_run_module._detach_and_freeze_artifact_files
            racing_writer_statuses = []
            semantic_snapshots = []
            held_descriptors = []
            detached_inode_pairs = []
            held_descriptor_race_triggered = []

            def detach_with_preopened_writer(root_path):
                target = root_path / "actual-codec-evidence.json"
                descriptor = os.open(target, os.O_RDWR)
                held_descriptors.append(descriptor)
                old_metadata = os.fstat(descriptor)
                detach(root_path)
                new_metadata = os.stat(target, follow_symlinks=False)
                detached_inode_pairs.append(
                    (
                        (old_metadata.st_dev, old_metadata.st_ino),
                        (new_metadata.st_dev, new_metadata.st_ino),
                    )
                )

            def verify_while_external_writer_attempts(root_path, **keywords):
                target = root_path / "scope.json"
                process = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        (
                            "from pathlib import Path; import sys; "
                            "p=Path(sys.argv[1]); p.write_bytes(p.read_bytes()+b' changed')"
                        ),
                        str(target),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                racing_writer_statuses.append(process.returncode)
                if held_descriptors and not held_descriptor_race_triggered:
                    original_read_bytes = Path.read_bytes

                    def read_while_old_descriptor_writes(path):
                        payload = original_read_bytes(path)
                        if path.name == "benchmark-dry-run.json":
                            os.lseek(held_descriptors[0], 0, os.SEEK_SET)
                            os.write(held_descriptors[0], b"detached old inode changed")
                            os.fsync(held_descriptors[0])
                            held_descriptor_race_triggered.append(True)
                        return payload

                    with patch.object(
                        Path,
                        "read_bytes",
                        new=read_while_old_descriptor_writes,
                    ):
                        return verify(root_path, **keywords)
                return verify(root_path, **keywords)

            def capture_semantic_snapshot(root_path, *, expected):
                semantic_snapshots.append(deepcopy(expected))
                return semantic_verify(root_path, expected=expected)

            try:
                with patch.object(
                    production_dry_run_module,
                    "_detach_and_freeze_artifact_files",
                    side_effect=detach_with_preopened_writer,
                ), patch.object(
                    runner,
                    "_verify_artifacts_before_publish",
                    side_effect=verify_while_external_writer_attempts,
                ), patch.object(
                    runner,
                    "_verify_artifact_semantics",
                    side_effect=capture_semantic_snapshot,
                ):
                    final = runner.run()
            finally:
                for descriptor in held_descriptors:
                    os.close(descriptor)
            self.assertEqual(len(racing_writer_statuses), 2)
            self.assertTrue(all(status != 0 for status in racing_writer_statuses))
            self.assertEqual(len(semantic_snapshots), 2)
            self.assertEqual(held_descriptor_race_triggered, [True])
            self.assertEqual(len(detached_inode_pairs), 1)
            self.assertNotEqual(*detached_inode_pairs[0])

            benchmark = read_json(final / "benchmark-dry-run.json")
            engine = read_json(final / "quality-result-engine-raw.json")
            container = read_json(final / "quality-result-container-decoded.json")
            artifact_manifest = read_json(final / "artifact-manifest.json")
            validate_schema(
                benchmark,
                QUALITY_ROOT / "schemas" / "benchmark-dry-run.schema.json",
            )
            validate_schema(
                engine,
                QUALITY_ROOT / "schemas" / "quality-result.schema.json",
            )
            validate_schema(
                container,
                QUALITY_ROOT / "schemas" / "quality-result.schema.json",
            )
            validate_schema(
                artifact_manifest,
                QUALITY_ROOT / "schemas" / "artifact-manifest.schema.json",
            )
            self.assertEqual(benchmark["corpus_mode"], "production_locked")
            self.assertEqual(benchmark["gate_status"], "pass")
            self.assertEqual(benchmark["case_count"], 24)
            self.assertEqual(benchmark["completed_case_count"], 24)
            self.assertEqual(
                benchmark["comparison_domains_executed"],
                ["engine_raw", "container_decoded"],
            )
            self.assertTrue(benchmark["actual_codec_fixture_used"])
            self.assertTrue(benchmark["actual_codec_fixture_conformance_only"])
            self.assertFalse(benchmark["holdout_accessed"])
            self.assertEqual(len(engine["asset_results"]), 24)
            self.assertEqual(len(container["asset_results"]), 24)
            self.assertEqual(
                [result["case_id"] for result in engine["asset_results"]],
                [result["case_id"] for result in container["asset_results"]],
            )
            self.assertEqual(
                [result["source_asset_id"] for result in engine["asset_results"]],
                [result["source_asset_id"] for result in container["asset_results"]],
            )
            self.assertEqual(
                [result["degradation_profile"] for result in engine["asset_results"]],
                [
                    result["degradation_profile"]
                    for result in container["asset_results"]
                ],
            )
            for engine_result, container_result in zip(
                engine["asset_results"],
                container["asset_results"],
            ):
                self.assertEqual(
                    engine_result["pixel_representation"],
                    ENGINE_RAW_PIXEL_REPRESENTATION,
                )
                self.assertEqual(
                    container_result["pixel_representation"],
                    ENGINE_RAW_PIXEL_REPRESENTATION,
                )
                self.assertEqual(
                    container_result["preencode_candidate_sha256"],
                    engine_result["candidate_sha256"],
                )
                self.assertTrue(container_result["preencode_matches_engine_raw"])
            self.assertNotIn(
                benchmark["actual_codec_fixture_id"],
                {result["source_asset_id"] for result in container["asset_results"]},
            )

            degradation_policy = read_json(
                QUALITY_ROOT / "policies" / "degradation-policy.json"
            )
            profile_routes = {
                profile["id"]: profile.get("target_route")
                for profile in (
                    degradation_policy["profiles"]
                    + degradation_policy["common_writer_profiles"]
                )
            }
            for result in engine["asset_results"]:
                self.assertEqual(
                    result["target_route"],
                    profile_routes[result["degradation_profile"]],
                )
                self.assertIn("no algorithm-quality claim", result["interpretation"])
            scope = read_json(final / "scope.json")
            self.assertFalse(scope["algorithm_quality_claimed"])
            self.assertEqual(
                scope["candidate_input_pixel_representation"],
                ENGINE_RAW_PIXEL_REPRESENTATION,
            )
            self.assertEqual(
                benchmark["candidate_input_pixel_representation"],
                ENGINE_RAW_PIXEL_REPRESENTATION,
            )
            bindings = read_json(final / "input-bindings.json")
            self.assertTrue(bindings["development_and_validation_media_rehashed"])
            self.assertTrue(bindings["all_split_evidence_rehashed"])
            self.assertFalse(bindings["holdout_media_rehashed"])
            self.assertFalse(bindings["holdout_accessed"])
            corpus_evidence = bindings["corpus_lock_evidence"]
            corpus_payload = (final / corpus_evidence["path"]).read_bytes()
            self.assertEqual(_sha256(corpus_payload), corpus_evidence["sha256"])
            self.assertEqual(len(corpus_payload), corpus_evidence["size_bytes"])
            self.assertEqual(
                corpus_evidence["sha256"],
                bindings["corpus_lock"]["sha256"],
            )
            self.assertEqual(
                corpus_evidence["size_bytes"],
                bindings["corpus_lock"]["size_bytes"],
            )
            configuration_inputs = read_json(final / "configuration-inputs.json")
            self.assertEqual(
                _sha256(
                    canonical_json_bytes(configuration_inputs["configuration"])
                ),
                configuration_inputs["configuration_sha256"],
            )
            self.assertEqual(
                configuration_inputs["configuration_sha256"],
                benchmark["configuration_sha256"],
            )
            configuration_binding = bindings["configuration_inputs"]
            configuration_payload = (
                final / configuration_binding["path"]
            ).read_bytes()
            self.assertEqual(
                _sha256(configuration_payload),
                configuration_binding["sha256"],
            )
            self.assertEqual(
                len(configuration_payload),
                configuration_binding["size_bytes"],
            )
            for input_name in ("metric_policy", "metric_vectors"):
                source = bindings[f"{input_name}_source"]
                evidence = bindings[f"{input_name}_evidence"]
                payload = (final / evidence["path"]).read_bytes()
                self.assertEqual(_sha256(payload), evidence["sha256"])
                self.assertEqual(len(payload), evidence["size_bytes"])
                self.assertEqual(evidence["sha256"], source["sha256"])
                self.assertEqual(evidence["size_bytes"], source["size_bytes"])
                self.assertEqual(
                    configuration_inputs["configuration"][f"{input_name}_source"],
                    source,
                )
            bootstrap = read_json(final / "paired-bootstrap-engine-raw.json")
            self.assertEqual(bootstrap["asset_count"], 6)

            self.assertEqual(len(benchmark["common_writer_runs"]), 26)
            self.assertEqual(
                benchmark["production_output_writer_id"],
                "mirmir-product-hevc-avassetwriter-v1",
            )
            self.assertEqual(
                benchmark["postencode_isolation_mode"],
                "one-case-per-product-hevc-container",
            )
            self.assertEqual(benchmark["postencode_isolated_container_count"], 24)
            self.assertTrue(
                benchmark["postencode_metric_rows_from_isolated_containers"]
            )
            self.assertFalse(benchmark["postencode_smoke_batch_executed"])
            production_runs = benchmark["common_writer_runs"][2:]
            self.assertEqual(
                [run["case_id"] for run in production_runs],
                [result["case_id"] for result in container["asset_results"]],
            )
            for production_run, container_row in zip(
                production_runs,
                container["asset_results"],
            ):
                self.assertEqual(
                    production_run["writer_id"],
                    "mirmir-product-hevc-avassetwriter-v1",
                )
                self.assertEqual(
                    production_run["purpose"],
                    "candidate_postencode_isolated",
                )
                self.assertEqual(production_run["frame_count"], 1)
                self.assertTrue(production_run["metric_eligible"])
                self.assertEqual(
                    production_run["container_scope"],
                    {
                        "frame_count": 1,
                        "single_frame_container": True,
                        "neighbor_frames_present": False,
                        "metric_role": "isolated_metric_case",
                    },
                )
                self.assertEqual(production_run["requested_codec"], "hevc")
                self.assertIn(
                    production_run["reopened_codec"],
                    {"hvc1", "hev1"},
                )
                self.assertEqual(
                    production_run["requested_average_bit_rate"],
                    2_000_000,
                )
                self.assertGreater(
                    production_run["observed_estimated_data_rate"],
                    0,
                )
                self.assertEqual(
                    production_run["decoded_payload"]["sha256"],
                    container_row["decoded_candidate_sha256"],
                )
                self.assertEqual(
                    production_run["validated_attachments"],
                    {
                        "color_primaries": "ITU_R_709_2",
                        "transfer_function": "ITU_R_709_2",
                        "ycbcr_matrix": "ITU_R_709_2",
                        "chroma_location_top_field": "Left",
                        "range": "video",
                    },
                )
            self.assertEqual(benchmark["low_resolution_actual_codec_frame_count"], 6)
            settings_evidence = benchmark["product_settings_evidence"]
            settings_payload = (final / settings_evidence["path"]).read_bytes()
            self.assertEqual(_sha256(settings_payload), settings_evidence["sha256"])
            self.assertEqual(len(settings_payload), settings_evidence["size_bytes"])
            self.assertEqual(
                settings_evidence["sha256"],
                benchmark["product_settings_source"]["sha256"],
            )
            for binding_name in ("engine_raw_result", "container_decoded_result"):
                binding = benchmark[binding_name]
                payload = (final / binding["path"]).read_bytes()
                self.assertEqual(_sha256(payload), binding["sha256"])
                self.assertEqual(len(payload), binding["size_bytes"])
            artifact_paths = {item["path"] for item in artifact_manifest["artifacts"]}
            self.assertTrue(any(path.endswith(".mp4") for path in artifact_paths))
            self.assertTrue(any("-decoded/frame-" in path for path in artifact_paths))
            self.assertTrue(any(path.endswith("-report.json") for path in artifact_paths))
            self.assertTrue(any(path.endswith("-source.nv12") for path in artifact_paths))
            self.assertTrue(any(path.endswith("-source-lock.json") for path in artifact_paths))

            for artifact in artifact_manifest["artifacts"]:
                content = (final / artifact["path"]).read_bytes()
                self.assertEqual(len(content), artifact["size_bytes"])
                self.assertEqual(_sha256(content), artifact["sha256"])

            benchmark_schema = (
                QUALITY_ROOT / "schemas" / "benchmark-dry-run.schema.json"
            )
            incomplete = deepcopy(benchmark)
            incomplete["case_count"] = 23
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(incomplete, benchmark_schema)
            incomplete = deepcopy(benchmark)
            incomplete["degradation_profile_ids"] = incomplete[
                "degradation_profile_ids"
            ][:-1]
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(incomplete, benchmark_schema)
            incomplete = deepcopy(benchmark)
            incomplete["common_writer_runs"] = incomplete["common_writer_runs"][:-1]
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(incomplete, benchmark_schema)
            incomplete = deepcopy(benchmark)
            incomplete["low_resolution_actual_codec_frame_count"] = 5
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(incomplete, benchmark_schema)
            unsafe_manifest = deepcopy(artifact_manifest)
            unsafe_manifest["artifacts"][0]["path"] = "../escape"
            with self.assertRaisesRegex(ValueError, "schema validation failed"):
                validate_schema(
                    unsafe_manifest,
                    QUALITY_ROOT / "schemas" / "artifact-manifest.schema.json",
                )

            engine_path = final / "quality-result-engine-raw.json"
            benchmark_path = final / "benchmark-dry-run.json"
            manifest_path = final / "artifact-manifest.json"
            fabricated_engine = read_json(engine_path)
            fabricated_engine["asset_results"][0], fabricated_engine["asset_results"][1] = (
                fabricated_engine["asset_results"][1],
                fabricated_engine["asset_results"][0],
            )
            validate_schema(
                fabricated_engine,
                QUALITY_ROOT / "schemas" / "quality-result.schema.json",
            )
            for path in (engine_path, benchmark_path, manifest_path):
                flags = os.stat(path, follow_symlinks=False).st_flags
                os.chflags(
                    path,
                    flags & ~stat.UF_IMMUTABLE,
                    follow_symlinks=False,
                )
                path.chmod(0o600)
            engine_path.write_bytes(canonical_json_bytes(fabricated_engine) + b"\n")
            fabricated_benchmark = read_json(benchmark_path)
            fabricated_benchmark["engine_raw_result"] = {
                "path": "quality-result-engine-raw.json",
                "sha256": _sha256(engine_path.read_bytes()),
                "size_bytes": engine_path.stat().st_size,
            }
            benchmark_path.write_bytes(
                canonical_json_bytes(fabricated_benchmark) + b"\n"
            )
            fabricated_manifest = read_json(manifest_path)
            for record in fabricated_manifest["artifacts"]:
                if record["path"] == "quality-result-engine-raw.json":
                    record["sha256"] = _sha256(engine_path.read_bytes())
                    record["size_bytes"] = engine_path.stat().st_size
                elif record["path"] == "benchmark-dry-run.json":
                    record["sha256"] = _sha256(benchmark_path.read_bytes())
                    record["size_bytes"] = benchmark_path.stat().st_size
            fabricated_manifest["manifest_sha256"] = manifest_sha256(
                fabricated_manifest
            )
            manifest_path.write_bytes(
                canonical_json_bytes(fabricated_manifest) + b"\n"
            )
            for path in (engine_path, benchmark_path, manifest_path):
                path.chmod(0o400)
                flags = os.stat(path, follow_symlinks=False).st_flags
                os.chflags(
                    path,
                    flags | stat.UF_IMMUTABLE,
                    follow_symlinks=False,
                )
            runner._verify_artifacts_before_publish(
                final,
                require_directory_immutable=True,
            )
            with self.assertRaisesRegex(ValueError, "semantic snapshot differs"):
                semantic_verify(final, expected=semantic_snapshots[0])

            scope_path = final / "scope.json"
            with self.assertRaises(OSError):
                scope_path.write_bytes(scope_path.read_bytes() + b" ")
            scope_flags = os.stat(scope_path, follow_symlinks=False).st_flags
            os.chflags(
                scope_path,
                scope_flags & ~stat.UF_IMMUTABLE,
                follow_symlinks=False,
            )
            scope_path.chmod(0o600)
            scope_path.write_bytes(scope_path.read_bytes() + b" ")
            with self.assertRaisesRegex(ValueError, "artifact bytes changed before publish"):
                runner._verify_artifacts_before_publish(final)

    def test_nv12_boundary_collapses_subcode_input_and_output_differences(self) -> None:
        full_code_nv12 = bytes((0, 255, 16, 235, 0, 255))
        full_code_frame = _video_range_nv12_to_planar(
            full_code_nv12,
            width=2,
            height=2,
        )
        self.assertEqual(
            _planar_to_video_range_nv12(full_code_frame),
            full_code_nv12,
        )

        height = 32
        width = 32
        y_value = (100.0 - 16.0) / 219.0
        cb_value = (120.0 - 16.0) / 224.0 - 0.5
        cr_value = (130.0 - 16.0) / 224.0 - 0.5
        target = PlanarFrame(
            y=np.zeros((height, width)),
            cb=np.zeros((height // 2, width // 2)),
            cr=np.zeros((height // 2, width // 2)),
        )
        asset = {
            "source_asset_id": "source-subquantization",
            "categories": ["subquantization-test"],
        }
        profile = {
            "id": "subquantization-profile",
            "target_route": "direct-2x",
        }

        def execute(delta_in_codes: float) -> tuple:
            low_resolution = PlanarFrame(
                y=np.full((height // 2, width // 2), y_value + delta_in_codes / 219.0),
                cb=np.full(
                    (height // 4, width // 4),
                    cb_value + delta_in_codes / 224.0,
                ),
                cr=np.full(
                    (height // 4, width // 4),
                    cr_value + delta_in_codes / 224.0,
                ),
            )
            configuration = {
                "algorithm": "subquantization-constant",
                "delta_in_codes": delta_in_codes,
                "version": "1.0.0",
            }

            def candidate(
                _low_resolution: PlanarFrame,
                context: CandidateContext,
            ) -> PlanarFrame:
                return PlanarFrame(
                    y=np.full(
                        context.y_shape,
                        y_value + delta_in_codes / 219.0,
                    ),
                    cb=np.full(
                        context.cb_shape,
                        cb_value + delta_in_codes / 224.0,
                    ),
                    cr=np.full(
                        context.cr_shape,
                        cr_value + delta_in_codes / 224.0,
                    ),
                )

            adapter = CandidateAdapter(
                candidate_id=f"subquantization-{delta_in_codes}",
                configuration=configuration,
                configuration_sha256=_sha256(canonical_json_bytes(configuration)),
                callable=candidate,
            )
            return _case_result(
                asset,
                target,
                profile,
                low_resolution,
                adapter,
            )

        exact_result, exact_candidate = execute(0.0)
        perturbed_result, perturbed_candidate = execute(0.24)
        self.assertEqual(
            exact_result["input_sha256"],
            perturbed_result["input_sha256"],
        )
        self.assertEqual(
            exact_result["candidate_sha256"],
            perturbed_result["candidate_sha256"],
        )
        self.assertEqual(
            exact_result["nearest_baseline_sha256"],
            perturbed_result["nearest_baseline_sha256"],
        )
        self.assertEqual(
            exact_result["metrics"]["candidate"],
            perturbed_result["metrics"]["candidate"],
        )
        self.assertEqual(
            exact_result["metrics"]["nearest_baseline"],
            perturbed_result["metrics"]["nearest_baseline"],
        )
        for exact_plane, perturbed_plane in zip(
            (exact_candidate.y, exact_candidate.cb, exact_candidate.cr),
            (perturbed_candidate.y, perturbed_candidate.cb, perturbed_candidate.cr),
        ):
            np.testing.assert_array_equal(exact_plane, perturbed_plane)

        preencode_nv12 = _planar_to_video_range_nv12(exact_candidate)
        self.assertEqual(
            exact_result["candidate_sha256"],
            _sha256(preencode_nv12),
        )
        zero_delta_container = _container_result(
            exact_result,
            target,
            exact_candidate,
            preencode_nv12,
        )
        self.assertEqual(
            zero_delta_container["preencode_candidate_sha256"],
            exact_result["candidate_sha256"],
        )
        self.assertEqual(
            zero_delta_container["decoded_candidate_sha256"],
            exact_result["candidate_sha256"],
        )
        self.assertEqual(
            zero_delta_container["metrics"]["candidate"],
            exact_result["metrics"]["candidate"],
        )

        decoded_with_codec_delta = bytearray(preencode_nv12)
        decoded_with_codec_delta[0] += 1
        nonzero_delta_container = _container_result(
            exact_result,
            target,
            exact_candidate,
            bytes(decoded_with_codec_delta),
        )
        self.assertEqual(
            nonzero_delta_container["preencode_candidate_sha256"],
            exact_result["candidate_sha256"],
        )
        self.assertNotEqual(
            nonzero_delta_container["decoded_candidate_sha256"],
            exact_result["candidate_sha256"],
        )
        self.assertNotEqual(
            nonzero_delta_container["metrics"]["candidate"],
            exact_result["metrics"]["candidate"],
        )

    def test_injected_failure_is_preserved_and_resume_completes(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            runner = _runner(root, inputs, "production-resume")
            with self.assertRaises(ProductionDryRunInterrupted) as interrupted:
                runner.run(fail_after_cases=2)
            failed = interrupted.exception.failure_path
            self.assertTrue((failed / "failure.json").is_file())
            self.assertTrue((failed / "checkpoint.json").is_file())
            self.assertFalse(read_json(failed / "failure.json")["holdout_accessed"])
            failed_writer_artifacts = {
                path.relative_to(failed).as_posix(): _sha256(path.read_bytes())
                for path in failed.rglob("*")
                if path.is_file()
                and (
                    "common-writer" in path.as_posix()
                    or "production-writer" in path.as_posix()
                )
            }
            self.assertTrue(any(path.endswith(".mp4") for path in failed_writer_artifacts))
            self.assertTrue(
                any(
                    "candidate-postencode-isolated" in path
                    and "-decoded/frame-" in path
                    for path in failed_writer_artifacts
                )
            )

            final = runner.run(resume_from=failed)
            self.assertTrue(failed.is_dir())
            self.assertEqual(
                failed_writer_artifacts,
                {
                    path.relative_to(failed).as_posix(): _sha256(path.read_bytes())
                    for path in failed.rglob("*")
                    if path.is_file()
                    and (
                        "common-writer" in path.as_posix()
                        or "production-writer" in path.as_posix()
                    )
                },
            )
            benchmark = read_json(final / "benchmark-dry-run.json")
            self.assertTrue(benchmark["resumed_from_failure"])
            self.assertEqual(benchmark["resume_checkpoint_semantics"], "recomputed")
            self.assertTrue(benchmark["actual_codec_fixture_reverified"])
            self.assertTrue(benchmark["postencode_results_recomputed"])
            self.assertEqual(benchmark["case_count"], 24)
            self.assertEqual(benchmark["completed_case_count"], 24)

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            runner = _runner(root, inputs, "forged-resume")
            with self.assertRaises(ProductionDryRunInterrupted) as interrupted:
                runner.run(fail_after_cases=1)
            failed = interrupted.exception.failure_path
            checkpoint = read_json(failed / "checkpoint.json")
            completed = next(iter(checkpoint["completed"].values()))
            completed["metrics"]["candidate"]["channel_psnr"]["Y"][
                "value"
            ] = 999.0
            checkpoint["checkpoint_sha256"] = manifest_sha256(
                checkpoint,
                "checkpoint_sha256",
            )
            write_json(failed / "checkpoint.json", checkpoint)
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "checkpoint result does not reproduce",
            ):
                runner.run(resume_from=failed)

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            runner = _runner(root, inputs, "stale-process")
            partial = root / "runs" / ".stale-process.partial"
            partial.mkdir(parents=True)
            (partial / "checkpoint.json").write_text("{}\n")
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "recovered an interrupted process",
            ) as recovered:
                runner.run()
            self.assertFalse(partial.exists())
            self.assertTrue((recovered.exception.failure_path / "failure.json").is_file())

    def test_candidate_adapter_substitution_is_hash_bound_and_geometry_checked(self) -> None:
        configuration = {
            "algorithm": "scaled-bilinear-test-candidate",
            "scale": 0.99,
            "version": "1.0.0",
        }
        observed_contexts = []
        pre_mutation_input_hashes = []

        def scaled_bilinear(
            low_resolution: PlanarFrame,
            context: CandidateContext,
        ) -> PlanarFrame:
            observed_contexts.append(context)
            self.assertFalse(hasattr(context, "target"))
            self.assertFalse(hasattr(context, "y"))
            pre_mutation_input_hashes.append(
                _sha256(_planar_to_video_range_nv12(low_resolution))
            )
            for plane in (low_resolution.y, low_resolution.cb, low_resolution.cr):
                plane.setflags(write=True)
            low_resolution.y[0, 0] = (
                0.0 if low_resolution.y[0, 0] != 0.0 else 1.0
            )
            return PlanarFrame(
                y=np.clip(
                    resize_bilinear(low_resolution.y, context.y_shape) * 0.99,
                    0.0,
                    1.0,
                ),
                cb=np.clip(
                    resize_bilinear(low_resolution.cb, context.cb_shape),
                    -0.5,
                    0.5,
                ),
                cr=np.clip(
                    resize_bilinear(low_resolution.cr, context.cr_shape),
                    -0.5,
                    0.5,
                ),
            )

        adapter = CandidateAdapter(
            candidate_id="scaled-bilinear-test-v1",
            configuration=configuration,
            configuration_sha256=_sha256(canonical_json_bytes(configuration)),
            callable=scaled_bilinear,
        )
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            final = _runner(
                root,
                inputs,
                "candidate-adapter",
                candidate_adapter=adapter,
            ).run()
            benchmark = read_json(final / "benchmark-dry-run.json")
            engine = read_json(final / "quality-result-engine-raw.json")
            self.assertEqual(benchmark["candidate_id"], adapter.candidate_id)
            self.assertEqual(
                benchmark["candidate_configuration_sha256"],
                adapter.configuration_sha256,
            )
            self.assertEqual(
                {result["candidate_id"] for result in engine["asset_results"]},
                {adapter.candidate_id},
            )
            self.assertEqual(len(observed_contexts), 24)
            self.assertEqual(
                {context.target_route for context in observed_contexts},
                {"direct-2x", "direct-3over2"},
            )
            self.assertEqual(
                {context.y_shape for context in observed_contexts},
                {(192, 324)},
            )
            self.assertEqual(
                [result["input_sha256"] for result in engine["asset_results"]],
                pre_mutation_input_hashes,
            )

        low = PlanarFrame(
            y=np.zeros((2, 2)),
            cb=np.zeros((1, 1)),
            cr=np.zeros((1, 1)),
        )
        context = CandidateContext(
            y_shape=(4, 4),
            cb_shape=(2, 2),
            cr_shape=(2, 2),
            target_route="direct-2x",
        )
        broken_configuration = {"algorithm": "wrong-geometry", "version": "1.0.0"}
        broken = CandidateAdapter(
            candidate_id="wrong-geometry-v1",
            configuration=broken_configuration,
            configuration_sha256=_sha256(canonical_json_bytes(broken_configuration)),
            callable=lambda _low, _target: low,
        )
        with self.assertRaisesRegex(ValueError, "wrong output geometry"):
            broken.reconstruct(low, context)

        out_of_range_configuration = {
            "algorithm": "out-of-range",
            "version": "1.0.0",
        }
        out_of_range = CandidateAdapter(
            candidate_id="out-of-range-v1",
            configuration=out_of_range_configuration,
            configuration_sha256=_sha256(
                canonical_json_bytes(out_of_range_configuration)
            ),
            callable=lambda _low, candidate_context: PlanarFrame(
                y=np.full(candidate_context.y_shape, 1.01),
                cb=np.zeros(candidate_context.cb_shape),
                cr=np.zeros(candidate_context.cr_shape),
            ),
        )
        with self.assertRaisesRegex(ValueError, "outside normalized ranges"):
            out_of_range.reconstruct(low, context)

    def test_input_mutation_during_candidate_is_preserved_as_failure(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            mutation_performed = False

            def mutating_candidate(
                low_resolution: PlanarFrame,
                context: CandidateContext,
            ) -> PlanarFrame:
                nonlocal mutation_performed
                if not mutation_performed:
                    inputs["corpus_path"].write_bytes(
                        inputs["corpus_path"].read_bytes() + b"\n"
                    )
                    mutation_performed = True
                return PlanarFrame(
                    y=np.clip(
                        resize_bilinear(low_resolution.y, context.y_shape),
                        0.0,
                        1.0,
                    ),
                    cb=np.clip(
                        resize_bilinear(low_resolution.cb, context.cb_shape),
                        -0.5,
                        0.5,
                    ),
                    cr=np.clip(
                        resize_bilinear(low_resolution.cr, context.cr_shape),
                        -0.5,
                        0.5,
                    ),
                )

            configuration = {
                "algorithm": "mutate-corpus-after-validation",
                "version": "1.0.0",
            }
            adapter = CandidateAdapter(
                candidate_id="input-toctou-test-v1",
                configuration=configuration,
                configuration_sha256=_sha256(canonical_json_bytes(configuration)),
                callable=mutating_candidate,
            )
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "not the canonical sealed byte artifact",
            ) as interrupted:
                _runner(
                    root,
                    inputs,
                    "input-toctou",
                    candidate_adapter=adapter,
                ).run()
            self.assertTrue(mutation_performed)
            self.assertFalse((root / "runs" / "input-toctou").exists())
            failure = read_json(interrupted.exception.failure_path / "failure.json")
            self.assertTrue(failure["partial_preserved"])
            self.assertFalse(failure["holdout_accessed"])

    def test_run_id_and_mutated_candidate_configuration_fail_before_execution(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            unsafe_ids = (
                "",
                ".",
                "..",
                "../escape",
                "nested/run",
                "nested\\run",
                "nul\x00run",
                str(root / "absolute-run"),
            )
            for unsafe_id in unsafe_ids:
                with self.subTest(run_id=unsafe_id):
                    with self.assertRaisesRegex(
                        ValueError,
                        "one safe filename component",
                    ):
                        _runner(root, inputs, unsafe_id)
            self.assertFalse((root / "escape").exists())

            configuration = {"algorithm": "mutable-test", "version": "1.0.0"}
            adapter = CandidateAdapter(
                candidate_id="mutable-test-v1",
                configuration=configuration,
                configuration_sha256=_sha256(canonical_json_bytes(configuration)),
                callable=lambda _low, context: PlanarFrame(
                    y=np.zeros(context.y_shape),
                    cb=np.zeros(context.cb_shape),
                    cr=np.zeros(context.cr_shape),
                ),
            )
            configuration["version"] = "mutated"
            with self.assertRaisesRegex(
                ValueError,
                "candidate configuration SHA-256 mismatch",
            ):
                _runner(
                    root,
                    inputs,
                    "mutated-candidate-configuration",
                    candidate_adapter=adapter,
                ).run()
            self.assertFalse((root / "runs").exists())

    def test_common_writer_report_tamper_fails_closed_and_preserves_evidence(self) -> None:
        from mirmir_quality import production_dry_run as production_module

        real_run_common_writer = production_module.run_common_writer

        def tampered_writer(**kwargs):
            result = real_run_common_writer(**kwargs)
            result.report_path.write_text("{}\n", encoding="utf-8")
            return result

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            with patch(
                "mirmir_quality.production_dry_run.run_common_writer",
                side_effect=tampered_writer,
            ):
                with self.assertRaisesRegex(
                    ProductionDryRunInterrupted,
                    "report file changed after verification",
                ) as interrupted:
                    _runner(root, inputs, "writer-report-tamper").run()
            failed = interrupted.exception.failure_path
            self.assertTrue((failed / "failure.json").is_file())
            self.assertTrue(any(path.suffix == ".mp4" for path in failed.rglob("*")))
            self.assertTrue(
                any("-decoded" in path.as_posix() for path in failed.rglob("*") if path.is_file())
            )

        def wrong_common_chroma_writer(**kwargs):
            result = real_run_common_writer(**kwargs)
            result.report["decoder"]["frames"][0]["attachments"][
                "chroma_location_top_field"
            ] = "Center"
            write_json(result.report_path, result.report)
            return result

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            with patch(
                "mirmir_quality.production_dry_run.run_common_writer",
                side_effect=wrong_common_chroma_writer,
            ):
                with self.assertRaisesRegex(
                    ProductionDryRunInterrupted,
                    "does not prove Left-sited metadata",
                ) as interrupted:
                    _runner(root, inputs, "common-writer-metadata-tamper").run()
            failed = interrupted.exception.failure_path
            self.assertTrue((failed / "failure.json").is_file())
            self.assertTrue(any(path.suffix == ".mp4" for path in failed.rglob("*")))
            self.assertFalse(read_json(failed / "failure.json")["holdout_accessed"])

        real_run_isolated_writers = (
            production_module.run_isolated_production_writer_cases
        )

        def wrong_chroma_writer(**kwargs):
            results = real_run_isolated_writers(**kwargs)
            result = results[0].result
            result.report["decoder"]["frames"][0]["attachments"][
                "chroma_location_top_field"
            ] = "Center"
            write_json(result.report_path, result.report)
            return results

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            with patch(
                (
                    "mirmir_quality.production_dry_run."
                    "run_isolated_production_writer_cases"
                ),
                side_effect=wrong_chroma_writer,
            ):
                with self.assertRaisesRegex(
                    ProductionDryRunInterrupted,
                    "decoded metadata mismatch",
                ) as interrupted:
                    _runner(root, inputs, "production-metadata-tamper").run()
            failed = interrupted.exception.failure_path
            self.assertTrue((failed / "failure.json").is_file())
            self.assertTrue(any(path.suffix == ".mp4" for path in failed.rglob("*")))
            self.assertFalse(read_json(failed / "failure.json")["holdout_accessed"])

    def test_checkpoint_and_validation_media_tampering_fail_closed(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            runner = _runner(root, inputs, "checkpoint-tamper")
            with self.assertRaises(ProductionDryRunInterrupted) as interrupted:
                runner.run(fail_after_cases=1)
            failed = interrupted.exception.failure_path
            checkpoint = read_json(failed / "checkpoint.json")
            checkpoint["configuration_sha256"] = "0" * 64
            write_json(failed / "checkpoint.json", checkpoint)
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "checkpoint hash mismatch",
            ):
                runner.run(resume_from=failed)

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            validation_asset = next(
                asset
                for asset in inputs["corpus"]["assets"]
                if asset["split"] == "validation"
            )
            path = inputs["asset_root"] / validation_asset["relative_path"]
            path.write_bytes(path.read_bytes() + b"tampered")
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "byte size does not match",
            ) as interrupted:
                _runner(root, inputs, "media-tamper").run()
            failure = read_json(interrupted.exception.failure_path / "failure.json")
            self.assertFalse(failure["holdout_accessed"])

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            sample_lock = read_json(inputs["sample_lock_path"])
            sample_lock["samples"][0]["y_active_path"] = sample_lock["samples"][1][
                "y_active_path"
            ]
            sample_lock["manifest_sha256"] = manifest_sha256(sample_lock)
            write_json(inputs["sample_lock_path"], sample_lock)
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "active-plane path does not match the decode record",
            ):
                _runner(root, inputs, "sample-path-tamper").run()

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            sample_lock = read_json(inputs["sample_lock_path"])
            sample = sample_lock["samples"][0]
            y_path = inputs["sample_root"] / sample["y_active_path"]
            y_path.write_bytes(y_path.read_bytes()[:-1] + b"\x10")
            asset = inputs["corpus"]["assets"][0]
            with self.assertRaisesRegex(
                ValueError,
                "frozen evidence-manifest binding does not match",
            ):
                build_sample_record(
                    asset=asset,
                    target_route=sample["target_route"],
                    sample_root=inputs["sample_root"],
                    asset_root=inputs["asset_root"],
                    decode_manifest_path=sample["decode_manifest_path"],
                    source_evidence_manifest_path=sample[
                        "source_evidence_manifest_path"
                    ],
                )

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            sample_lock = read_json(inputs["sample_lock_path"])
            del sample_lock["samples"][0]["chroma_location"]
            sample_lock["manifest_sha256"] = manifest_sha256(sample_lock)
            write_json(inputs["sample_lock_path"], sample_lock)
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "schema validation failed",
            ):
                _runner(root, inputs, "missing-sample-color-metadata").run()

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            asset = deepcopy(inputs["corpus"]["assets"][0])
            asset["ycbcr_matrix"] = "unspecified"
            with self.assertRaisesRegex(
                ValueError,
                "unsupported or absent ycbcr_matrix metadata",
            ):
                build_sample_record(
                    asset=asset,
                    target_route=asset["target_routes"][0],
                    sample_root=inputs["sample_root"],
                    asset_root=inputs["asset_root"],
                    decode_manifest_path=(
                        f"{asset['asset_id']}/decode-manifest.json"
                    ),
                    source_evidence_manifest_path=(
                        f"{asset['asset_id']}/evidence-manifest.json"
                    ),
                )

    def test_sample_record_requires_exact_decode_color_evidence(self) -> None:
        scenarios = (
            ("tampered-decoded-matrix", "decoded", "decoded color metadata"),
            ("missing-full-range-flag", "source", "source color metadata"),
        )
        for label, evidence_kind, expected_error in scenarios:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                inputs = _build_inputs(root)
                asset = inputs["corpus"]["assets"][0]
                sample_directory = inputs["sample_root"] / asset["asset_id"]
                decode_manifest_path = sample_directory / "decode-manifest.json"
                decode_manifest = read_json(decode_manifest_path)
                record = decode_manifest["representative_samples"][0]
                if evidence_kind == "decoded":
                    record["decoded_attachments"][
                        "CVImageBufferYCbCrMatrix"
                    ] = "ITU_R_2020"
                else:
                    del record["source_format_extensions"]["FullRangeVideo"]
                write_json(decode_manifest_path, decode_manifest)

                evidence_manifest_path = sample_directory / "evidence-manifest.json"
                evidence_manifest = read_json(evidence_manifest_path)
                decode_payload = decode_manifest_path.read_bytes()
                decode_binding = next(
                    item
                    for item in evidence_manifest["files"]
                    if item["path"] == "decode-manifest.json"
                )
                decode_binding["sha256"] = _sha256(decode_payload)
                decode_binding["size_bytes"] = len(decode_payload)
                write_json(evidence_manifest_path, evidence_manifest)

                with self.assertRaisesRegex(ValueError, expected_error):
                    build_sample_record(
                        asset=asset,
                        target_route=asset["target_routes"][0],
                        sample_root=inputs["sample_root"],
                        asset_root=inputs["asset_root"],
                        decode_manifest_path=(
                            f"{asset['asset_id']}/decode-manifest.json"
                        ),
                        source_evidence_manifest_path=(
                            f"{asset['asset_id']}/evidence-manifest.json"
                        ),
                    )

    def test_category_minima_must_be_exactly_four_and_one(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            corpus = deepcopy(inputs["corpus"])
            category = sorted(QUALITY_CATEGORIES)[0]
            corpus["split_policy"]["minimum_category_counts"][category] = 3
            corpus["manifest_sha256"] = manifest_sha256(corpus)
            inputs["corpus_path"].write_bytes(canonical_json_bytes(corpus) + b"\n")
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "exact overall minimum of four",
            ):
                _runner(root, inputs, "weak-minima").run()

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            corpus = deepcopy(inputs["corpus"])
            category = sorted(QUALITY_CATEGORIES)[0]
            corpus["split_policy"]["minimum_category_counts_by_split"][
                "holdout"
            ][category] = 2
            corpus["manifest_sha256"] = manifest_sha256(corpus)
            inputs["corpus_path"].write_bytes(canonical_json_bytes(corpus) + b"\n")
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "exact per-split minimum of one",
            ):
                _runner(root, inputs, "wrong-split-minima").run()

    def test_route_must_be_unique_and_match_native_target_geometry(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            corpus = deepcopy(inputs["corpus"])
            corpus["assets"][0]["target_routes"] = ["direct-3over2"]
            corpus["manifest_sha256"] = manifest_sha256(corpus)
            inputs["corpus_path"].write_bytes(canonical_json_bytes(corpus) + b"\n")
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "does not use one canonical project route",
            ):
                _runner(root, inputs, "route-geometry").run()

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            corpus = deepcopy(inputs["corpus"])
            for asset in corpus["assets"]:
                asset["target_routes"] = ["direct-2x"]
                asset["encoded_dimensions"] = [3840, 2160]
                asset["presentation_dimensions"] = [3840, 2160]
            corpus["manifest_sha256"] = manifest_sha256(corpus)
            inputs["corpus_path"].write_bytes(canonical_json_bytes(corpus) + b"\n")
            sample_lock = read_json(inputs["sample_lock_path"])
            sample_lock["corpus_manifest_sha256"] = corpus["manifest_sha256"]
            for sample in sample_lock["samples"]:
                sample["target_route"] = "direct-2x"
            sample_lock["manifest_sha256"] = manifest_sha256(sample_lock)
            write_json(inputs["sample_lock_path"], sample_lock)
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "sample source dimensions do not match corpus presentation dimensions",
            ):
                _runner(root, inputs, "one-route-only").run()

    def test_unsealed_corpus_bytes_and_degradation_lineage_fail_closed(self) -> None:
        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            write_json(inputs["corpus_path"], inputs["corpus"])
            with self.assertRaisesRegex(
                ProductionDryRunInterrupted,
                "not the canonical sealed byte artifact",
            ):
                _runner(root, inputs, "unsealed-corpus").run()

        degradation_path = QUALITY_ROOT / "policies" / "degradation-policy.json"
        original_read_json = read_json

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            unlocked = deepcopy(original_read_json(degradation_path))
            unlocked["status"] = "development_seed"
            unlocked["policy_sha256"] = manifest_sha256(unlocked, "policy_sha256")

            def read_with_unlocked_policy(path: Path):
                if Path(path) == degradation_path:
                    return deepcopy(unlocked)
                return original_read_json(path)

            with patch(
                "mirmir_quality.production_dry_run.read_json",
                side_effect=read_with_unlocked_policy,
            ):
                with self.assertRaisesRegex(
                    ProductionDryRunInterrupted,
                    "status must be locked",
                ):
                    _runner(root, inputs, "unlocked-degradation").run()

        with _temporary_directory() as temporary:
            root = Path(temporary)
            inputs = _build_inputs(root)
            broken_lineage = deepcopy(original_read_json(degradation_path))
            broken_lineage["preintegration_policy_sha256"] = "0" * 64
            broken_lineage["policy_sha256"] = manifest_sha256(
                broken_lineage,
                "policy_sha256",
            )

            def read_with_broken_lineage(path: Path):
                if Path(path) == degradation_path:
                    return deepcopy(broken_lineage)
                return original_read_json(path)

            with patch(
                "mirmir_quality.production_dry_run.read_json",
                side_effect=read_with_broken_lineage,
            ):
                with self.assertRaisesRegex(
                    ProductionDryRunInterrupted,
                    "pre-integration policy lineage hash mismatch",
                ):
                    _runner(root, inputs, "broken-lineage").run()


if __name__ == "__main__":
    unittest.main()
