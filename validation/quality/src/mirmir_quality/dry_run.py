"""Development-only benchmark dry run with atomic finalization and failure preservation."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from .arrays import PlanarFrame, frame_sha256, resize_bilinear
from .bootstrap import paired_bootstrap
from .conformance import run_metric_conformance
from .corpus import create_corpus_lock, validate_corpus_lock
from .degradation import apply_degradation
from .fixtures import synthetic_planar_frame
from .json_tools import (
    canonical_sha256,
    manifest_sha256,
    read_json,
    validate_schema,
    write_json,
)
from .metrics import channel_psnr, ms_ssim, psnr, ssim


class DryRunInterrupted(RuntimeError):
    def __init__(self, message: str, failure_path: Path) -> None:
        super().__init__(message)
        self.failure_path = failure_path


def _validate_run_id(run_id: object) -> str:
    if (
        not isinstance(run_id, str)
        or not run_id
        or run_id in {".", ".."}
        or Path(run_id).is_absolute()
        or Path(run_id).name != run_id
        or "/" in run_id
        or "\\" in run_id
    ):
        raise ValueError("run ID must be one safe filename component")
    return run_id


def _nearest(image: np.ndarray, output_shape: Tuple[int, int]) -> np.ndarray:
    output_height, output_width = output_shape
    source_height, source_width = image.shape
    y = np.minimum(
        (np.arange(output_height, dtype=np.int64) * source_height) // output_height,
        source_height - 1,
    )
    x = np.minimum(
        (np.arange(output_width, dtype=np.int64) * source_width) // output_width,
        source_width - 1,
    )
    return image[y[:, None], x[None, :]]


def _reconstruct(frame: PlanarFrame, target: PlanarFrame, *, bilinear: bool) -> PlanarFrame:
    resize = resize_bilinear if bilinear else _nearest
    return PlanarFrame(
        y=resize(frame.y, target.y.shape),
        cb=resize(frame.cb, target.cb.shape),
        cr=resize(frame.cr, target.cr.shape),
    )


def _synthetic_assets(
    frames: Sequence[PlanarFrame],
    *,
    evidence_sha256: str,
) -> List[Dict[str, object]]:
    categories = (
        ["horizontal/vertical/diagonal edges", "thin lines/text", "saturated chroma edges"],
        ["near-Nyquist patterns", "noise/compression", "corners/junctions"],
    )
    assets = []
    for index, frame in enumerate(frames):
        assets.append(
            {
                "asset_id": f"synthetic-development-{index}",
                "source_asset_id": f"synthetic-source-{index}",
                "source_family_id": f"synthetic-family-{index}",
                "relative_path": f"synthetic/development-{index}.planar",
                "sha256": frame_sha256(frame),
                "size_bytes": int(frame.y.nbytes + frame.cb.nbytes + frame.cr.nbytes),
                "media_type": "image",
                "native_target": True,
                "derived": False,
                "split": "development",
                "encoded_dimensions": [int(frame.y.shape[1]), int(frame.y.shape[0])],
                "presentation_dimensions": [int(frame.y.shape[1]), int(frame.y.shape[0])],
                "frame_range": {"start": 0, "duration": 1, "timescale": 1},
                "frame_count": 1,
                "target_routes": ["direct-2x", "direct-3over2"],
                "pixel_format": "normalized-planar-f64",
                "range": "normalized",
                "color_primaries": "synthetic-linear",
                "transfer_function": "synthetic-linear",
                "ycbcr_matrix": "synthetic-independent-planes",
                "chroma_location": "synthetic-centered",
                "categories": categories[index],
                "provenance": {
                    "origin_kind": "project-test-fixture",
                    "creator": "Mirmir validation suite",
                    "source_uri": None,
                    "original_filename": f"development-{index}.planar",
                    "acquired_utc": "2026-07-11T00:00:00Z",
                    "capture_or_creation_metadata": {
                        "fixture_function": "synthetic_planar_frame",
                        "fixture_index": index
                    },
                    "evidence_path": "validation/quality/README.md",
                    "evidence_sha256": evidence_sha256,
                },
                "rights": {
                    "status": "confirmed",
                    "basis": "project-test-fixture",
                    "license_id": None,
                    "license_or_declaration_path": "validation/quality/README.md",
                    "license_or_declaration_sha256": evidence_sha256,
                    "item_specific_exception_status": "not_applicable_project_owned",
                    "item_specific_exception_evidence_path": "validation/quality/README.md",
                    "item_specific_exception_evidence_sha256": evidence_sha256,
                    "permitted_uses": ["local-project-testing", "derived-test-artifacts"],
                    "derivative_artifacts_permitted": True,
                    "redistribution_permitted": True,
                    "confirmed_by": "project-test-contract",
                    "confirmed_utc": "2026-07-11T00:00:00Z",
                    "expires_utc": None
                },
                "sensitive_metadata_present": False
            }
        )
    return assets


class DevelopmentDryRun:
    def __init__(
        self,
        *,
        output_root: Path,
        run_id: str,
        quality_root: Path,
    ) -> None:
        self.output_root = output_root
        self.run_id = _validate_run_id(run_id)
        self.quality_root = quality_root
        self.schemas = quality_root / "schemas"
        self.metric_policy_path = quality_root / "policies" / "metric-policy.json"
        self.degradation_policy_path = quality_root / "policies" / "degradation-policy.json"

    def _failure_destination(self) -> Path:
        attempt = 1
        while True:
            destination = self.output_root / f"{self.run_id}.failed-{attempt}"
            if not destination.exists():
                return destination
            attempt += 1

    def _preserve_failure(self, partial: Path, error: BaseException) -> Path:
        write_json(
            partial / "failure.json",
            {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "failure_type": type(error).__name__,
                "message": str(error),
                "partial_preserved": True,
                "holdout_accessed": False,
            },
        )
        destination = self._failure_destination()
        os.replace(partial, destination)
        return destination

    def run(
        self,
        *,
        resume_from: Optional[Path] = None,
        fail_after_cases: Optional[int] = None,
    ) -> Path:
        if fail_after_cases is not None and fail_after_cases <= 0:
            raise ValueError("fail_after_cases must be positive")
        self.output_root.mkdir(parents=True, exist_ok=True)
        partial = self.output_root / f".{self.run_id}.partial"
        final = self.output_root / self.run_id
        if partial.exists() or final.exists():
            raise FileExistsError("run ID already has a partial or final directory")
        partial.mkdir()

        try:
            metric_policy = read_json(self.metric_policy_path)
            degradation_policy = read_json(self.degradation_policy_path)
            if metric_policy["policy_sha256"] != manifest_sha256(metric_policy, "policy_sha256"):
                raise ValueError("metric policy hash mismatch")
            if degradation_policy["policy_sha256"] != manifest_sha256(
                degradation_policy, "policy_sha256"
            ):
                raise ValueError("degradation policy hash mismatch")
            metric_vector_path = self.quality_root / "reference" / "metric-vectors-v1.json"
            metric_vector_sha256 = hashlib.sha256(metric_vector_path.read_bytes()).hexdigest()
            if metric_vector_sha256 != metric_policy["independent_oracle"]["vector_sha256"]:
                raise ValueError("independent metric-vector file hash mismatch")
            validate_schema(metric_policy, self.schemas / "metric-policy.schema.json")
            validate_schema(
                degradation_policy,
                self.schemas / "degradation-lock.schema.json",
            )

            frames = [
                synthetic_planar_frame(0, size=(192, 324)),
                synthetic_planar_frame(1, size=(192, 324)),
            ]
            readme_sha256 = hashlib.sha256(
                (self.quality_root / "README.md").read_bytes()
            ).hexdigest()
            corpus = create_corpus_lock(
                corpus_id="synthetic-development-dry-run",
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
                    "algorithm": "development-only synthetic dry run; production split not assigned",
                    "seed": None,
                    "rounding_rule": "not applicable to development-only synthetic fixtures",
                    "minimum_category_counts": {},
                },
                assets=_synthetic_assets(frames, evidence_sha256=readme_sha256),
                category_vocabulary_version="quality-gate-policy-1.1.0",
            )
            validate_corpus_lock(corpus, require_all_splits=False)
            validate_schema(corpus, self.schemas / "corpus-lock.schema.json")

            configuration_sha256 = canonical_sha256(
                {
                    "candidate": "bilinear-development-control-v1",
                    "metric_policy_sha256": metric_policy["policy_sha256"],
                    "degradation_policy_sha256": degradation_policy["policy_sha256"],
                    "corpus_manifest_sha256": corpus["manifest_sha256"],
                }
            )
            metric_conformance = run_metric_conformance(metric_policy["policy_sha256"])
            validate_schema(
                metric_conformance,
                self.schemas / "metric-conformance.schema.json",
            )
            if metric_conformance["status"] != "pass":
                raise ValueError("metric conformance failed")

            write_json(partial / "corpus-lock.json", corpus)
            write_json(partial / "degradation-lock.json", degradation_policy)
            write_json(partial / "metric-conformance.json", metric_conformance)

            spatial_profiles = [
                profile
                for profile in degradation_policy["profiles"]
                if profile["kind"] != "synthetic_motion"
            ]
            expected_results: Dict[str, Dict[str, object]] = {}
            for asset, target in zip(corpus["assets"], frames):
                for profile in spatial_profiles:
                    case_id = f"{asset['source_asset_id']}::{profile['id']}"
                    low_resolution = apply_degradation(target, profile)
                    candidate = _reconstruct(low_resolution, target, bilinear=True)
                    baseline = _reconstruct(low_resolution, target, bilinear=False)
                    candidate_psnr = channel_psnr(target, candidate)
                    baseline_y_psnr = psnr(target.y, baseline.y)
                    expected_results[case_id] = {
                        "source_asset_id": asset["source_asset_id"],
                        "categories": asset["categories"],
                        "degradation_profile": profile["id"],
                        "input_sha256": frame_sha256(low_resolution),
                        "candidate_sha256": frame_sha256(candidate),
                        "metrics": {
                            "channel_psnr": candidate_psnr,
                            "Y_SSIM": ssim(target.y, candidate.y),
                            "Y_MS_SSIM": ms_ssim(target.y, candidate.y),
                            "nearest_Y_PSNR": baseline_y_psnr,
                        },
                        "status": "pass",
                    }

            expected_order = sorted(expected_results)
            expected_case_ids = set(expected_order)
            total_cases = len(expected_order)
            if total_cases != len(frames) * len(spatial_profiles):
                raise ValueError("synthetic dry-run case IDs are not unique")

            completed: Dict[str, Dict[str, object]] = {}
            resumed = resume_from is not None
            if resume_from is not None:
                checkpoint = read_json(resume_from / "checkpoint.json")
                if checkpoint.get("checkpoint_sha256") != manifest_sha256(
                    checkpoint,
                    "checkpoint_sha256",
                ):
                    raise ValueError("resume checkpoint hash mismatch")
                if checkpoint.get("run_id") != self.run_id:
                    raise ValueError("resume checkpoint run ID mismatch")
                if checkpoint.get("configuration_sha256") != configuration_sha256:
                    raise ValueError("resume checkpoint configuration mismatch")
                checkpoint_results = checkpoint.get("completed")
                if (
                    not isinstance(checkpoint_results, dict)
                    or not set(checkpoint_results).issubset(expected_case_ids)
                ):
                    raise ValueError("resume checkpoint contains an invalid case set")
                for case_id, result in checkpoint_results.items():
                    if result != expected_results[case_id]:
                        raise ValueError("resume checkpoint result does not reproduce")
                completed = dict(checkpoint_results)

            for case_id in expected_order:
                if case_id in completed:
                    continue
                completed[case_id] = expected_results[case_id]
                checkpoint = {
                    "schema_version": "1.0.0",
                    "run_id": self.run_id,
                    "configuration_sha256": configuration_sha256,
                    "completed": completed,
                }
                checkpoint["checkpoint_sha256"] = manifest_sha256(
                    checkpoint,
                    "checkpoint_sha256",
                )
                write_json(partial / "checkpoint.json", checkpoint)
                if fail_after_cases is not None and len(completed) >= fail_after_cases:
                    raise RuntimeError("injected development dry-run interruption")

            if set(completed) != expected_case_ids:
                raise ValueError("synthetic dry-run case coverage is incomplete")
            final_checkpoint = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "configuration_sha256": configuration_sha256,
                "completed": completed,
            }
            final_checkpoint["checkpoint_sha256"] = manifest_sha256(
                final_checkpoint,
                "checkpoint_sha256",
            )
            write_json(partial / "checkpoint.json", final_checkpoint)

            results = [completed[key] for key in expected_order]
            bootstrap_records = []
            for result in results:
                candidate_value = result["metrics"]["channel_psnr"]["Y"]["value"]
                baseline_value = result["metrics"]["nearest_Y_PSNR"]["value"]
                if candidate_value is None or baseline_value is None:
                    raise ValueError("dry-run bootstrap requires finite PSNR values")
                bootstrap_records.append(
                    {
                        "source_asset_id": result["source_asset_id"],
                        "candidate": candidate_value,
                        "baseline": baseline_value,
                        "categories": result["categories"],
                    }
                )
            bootstrap = paired_bootstrap(bootstrap_records)
            write_json(partial / "paired-bootstrap.json", bootstrap)

            quality_result = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "configuration_sha256": configuration_sha256,
                "corpus_manifest_sha256": corpus["manifest_sha256"],
                "split": "development",
                "comparison_domain": "engine_raw",
                "asset_results": results,
                "status": "pass",
                "holdout_opened_utc": None,
                "configuration_files_modified_after_holdout": False,
            }
            validate_schema(quality_result, self.schemas / "quality-result.schema.json")
            write_json(partial / "quality-result.json", quality_result)

            benchmark_result = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "split": "development",
                "corpus_mode": "synthetic_development",
                "configuration_sha256": configuration_sha256,
                "corpus_manifest_sha256": corpus["manifest_sha256"],
                "development_source_asset_count": len(frames),
                "degradation_policy_sha256": degradation_policy["policy_sha256"],
                "degradation_profile_ids": [
                    profile["id"] for profile in spatial_profiles
                ],
                "metric_policy_sha256": metric_policy["policy_sha256"],
                "case_count": total_cases,
                "completed_case_count": len(results),
                "resumed_from_failure": resumed,
                "fixture_dimensions": {"width": 324, "height": 192},
                "comparison_domains_executed": ["engine_raw"],
                "actual_codec_fixture_used": False,
                "holdout_accessed": False,
                "gate_status": "blocked",
                "status": "pass",
            }
            validate_schema(benchmark_result, self.schemas / "benchmark-dry-run.schema.json")
            write_json(partial / "benchmark-dry-run.json", benchmark_result)

            artifacts = []
            for path in sorted(partial.iterdir()):
                if path.is_file() and path.name != "artifact-manifest.json":
                    content = path.read_bytes()
                    artifacts.append(
                        {
                            "path": path.name,
                            "sha256": hashlib.sha256(content).hexdigest(),
                            "size_bytes": len(content),
                        }
                    )
            artifact_manifest = {
                "schema_version": "1.0.0",
                "run_id": self.run_id,
                "artifacts": artifacts,
            }
            artifact_manifest["manifest_sha256"] = manifest_sha256(
                artifact_manifest
            )
            validate_schema(
                artifact_manifest,
                self.schemas / "artifact-manifest.schema.json",
            )
            write_json(partial / "artifact-manifest.json", artifact_manifest)
            os.replace(partial, final)
            return final
        except BaseException as error:
            if partial.exists():
                failure_path = self._preserve_failure(partial, error)
                raise DryRunInterrupted(str(error), failure_path) from error
            raise
