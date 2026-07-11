from pathlib import Path
import hashlib
import tempfile
import unittest

from mirmir_quality.dry_run import DevelopmentDryRun, DryRunInterrupted
from mirmir_quality.json_tools import (
    manifest_sha256,
    read_json,
    validate_schema,
    write_json,
)


QUALITY_ROOT = Path(__file__).resolve().parents[1]


class DevelopmentDryRunTests(unittest.TestCase):
    def test_failure_is_preserved_and_resume_finalizes_schema_valid_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_root = Path(temporary)
            runner = DevelopmentDryRun(
                output_root=output_root,
                run_id="development-conformance",
                quality_root=QUALITY_ROOT,
            )
            with self.assertRaises(DryRunInterrupted) as interrupted:
                runner.run(fail_after_cases=2)
            failure_path = interrupted.exception.failure_path
            self.assertTrue(failure_path.is_dir())
            self.assertTrue((failure_path / "failure.json").is_file())
            self.assertTrue((failure_path / "checkpoint.json").is_file())

            final_path = runner.run(resume_from=failure_path)
            self.assertTrue(failure_path.is_dir(), "failed evidence must remain preserved")
            self.assertTrue(final_path.is_dir())

            benchmark = read_json(final_path / "benchmark-dry-run.json")
            quality = read_json(final_path / "quality-result.json")
            metric = read_json(final_path / "metric-conformance.json")
            corpus = read_json(final_path / "corpus-lock.json")
            degradation = read_json(final_path / "degradation-lock.json")
            validate_schema(benchmark, QUALITY_ROOT / "schemas" / "benchmark-dry-run.schema.json")
            validate_schema(quality, QUALITY_ROOT / "schemas" / "quality-result.schema.json")
            validate_schema(metric, QUALITY_ROOT / "schemas" / "metric-conformance.schema.json")
            validate_schema(corpus, QUALITY_ROOT / "schemas" / "corpus-lock.schema.json")
            validate_schema(degradation, QUALITY_ROOT / "schemas" / "degradation-lock.schema.json")

            self.assertEqual(benchmark["status"], "pass")
            self.assertEqual(benchmark["gate_status"], "blocked")
            self.assertTrue(benchmark["resumed_from_failure"])
            self.assertFalse(benchmark["holdout_accessed"])
            self.assertEqual(benchmark["fixture_dimensions"], {"width": 324, "height": 192})
            self.assertEqual(benchmark["comparison_domains_executed"], ["engine_raw"])
            self.assertFalse(benchmark["actual_codec_fixture_used"])
            self.assertEqual(benchmark["case_count"], benchmark["completed_case_count"])
            self.assertTrue((final_path / "artifact-manifest.json").is_file())
            self.assertTrue((final_path / "paired-bootstrap.json").is_file())
            artifact_manifest = read_json(final_path / "artifact-manifest.json")
            validate_schema(
                artifact_manifest,
                QUALITY_ROOT / "schemas" / "artifact-manifest.schema.json",
            )
            for artifact in artifact_manifest["artifacts"]:
                content = (final_path / artifact["path"]).read_bytes()
                self.assertEqual(len(content), artifact["size_bytes"])
                self.assertEqual(hashlib.sha256(content).hexdigest(), artifact["sha256"])

    def test_resume_recomputes_cases_and_rejects_a_self_rehashed_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_root = Path(temporary)
            runner = DevelopmentDryRun(
                output_root=output_root,
                run_id="forged-development-resume",
                quality_root=QUALITY_ROOT,
            )
            with self.assertRaises(DryRunInterrupted) as interrupted:
                runner.run(fail_after_cases=1)
            failure_path = interrupted.exception.failure_path
            checkpoint = read_json(failure_path / "checkpoint.json")
            first_result = next(iter(checkpoint["completed"].values()))
            first_result["metrics"]["channel_psnr"]["Y"]["value"] = 999.0
            checkpoint["checkpoint_sha256"] = manifest_sha256(
                checkpoint,
                "checkpoint_sha256",
            )
            write_json(failure_path / "checkpoint.json", checkpoint)

            with self.assertRaisesRegex(
                DryRunInterrupted,
                "checkpoint result does not reproduce",
            ):
                runner.run(resume_from=failure_path)

    def test_unsafe_run_id_is_rejected_before_output_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "one safe filename component"):
                DevelopmentDryRun(
                    output_root=root / "runs",
                    run_id="../escape",
                    quality_root=QUALITY_ROOT,
                )
            self.assertFalse((root / "runs").exists())


if __name__ == "__main__":
    unittest.main()
