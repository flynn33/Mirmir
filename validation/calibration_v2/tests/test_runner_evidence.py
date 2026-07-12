from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from validation.calibration_v2 import runner
from validation.quality.src.mirmir_quality.arrays import PlanarFrame
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
)


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
CONTROL_KEYS = (
    "full_ash",
    "best_fixed",
    "conventional",
    "non_ash_selector",
    "state_only",
    "state_plus_branch",
    "h07_direct_3_over_2",
    "nearest_same_writer",
    "current_production_ash",
)


def _corpus_metrics(y_psnr: float, y_ms_ssim: float = 0.9) -> dict[str, object]:
    return {
        "y_psnr_db": y_psnr,
        "cb_psnr_db": y_psnr - 1.0,
        "cr_psnr_db": y_psnr - 2.0,
        "y_ssim": 0.9,
        "cb_ssim": 0.8,
        "cr_ssim": 0.7,
        "y_ms_ssim": y_ms_ssim,
        "cb_ms_ssim": 0.75,
        "cr_ms_ssim": 0.65,
        "writer_y_psnr_contribution_db": None,
    }


def _artifact_metrics(**values: float | None) -> dict[str, float | None]:
    result: dict[str, float | None] = {
        "edge_location_error_pixels": None,
        "ringing_overshoot": None,
        "ringing_undershoot": None,
        "alias_forbidden_band_ratio": None,
        "thin_line_retention_ratio": None,
        "thin_line_false_side_lobe_energy": None,
        "chroma_displacement_pixels": None,
    }
    result.update(values)
    return result


class AggregationAndSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tolerances = json.loads(
            (
                CALIBRATION_ROOT
                / "contracts/metric-performance-tolerances-v1.json"
            ).read_text(encoding="utf-8")
        )
        cls.tolerances["quality"]["paired_bootstrap"]["replicates"] = 64

    def _corpus_rows(self) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for source_id, family, route, full_y, baseline_y in (
            ("asset-a", "family-a", "direct-2x", 11.0, 10.0),
            ("asset-b", "family-b", "direct-3over2", 23.0, 20.0),
        ):
            for profile in ("profile-0", "profile-1", "profile-2"):
                metrics = {
                    key: _corpus_metrics(
                        full_y if key in {"full_ash", "state_plus_branch"} else baseline_y,
                        0.9 if key in {"full_ash", "state_plus_branch"} else 0.8,
                    )
                    for key in CONTROL_KEYS
                }
                if route == "direct-2x":
                    metrics["h07_direct_3_over_2"] = None
                rows.append(
                    {
                        "source_asset_id": source_id,
                        "source_family_id": family,
                        "categories": ["natural_detail"],
                        "target_route": route,
                        "degradation_profile_id": profile,
                        "metrics_by_control": metrics,
                    }
                )
        return rows

    def _fixture_rows(self) -> list[dict[str, object]]:
        fixtures = (
            (
                "ringing",
                _artifact_metrics(ringing_overshoot=0.04, ringing_undershoot=0.03),
                _artifact_metrics(ringing_overshoot=0.03, ringing_undershoot=0.02),
            ),
            (
                "alias",
                _artifact_metrics(alias_forbidden_band_ratio=0.04),
                _artifact_metrics(alias_forbidden_band_ratio=0.03),
            ),
            (
                "chroma_displacement",
                _artifact_metrics(chroma_displacement_pixels=0.20),
                _artifact_metrics(chroma_displacement_pixels=0.15),
            ),
        )
        return [
            {
                "fixture_kind": kind,
                "metrics_by_control": {
                    "full_ash": candidate,
                    "conventional": conventional,
                },
            }
            for kind, candidate, conventional in fixtures
        ]

    def test_three_profiles_aggregate_per_source_before_bootstrap(self) -> None:
        summary = runner._summarize_domain(
            self._corpus_rows(),
            self._fixture_rows(),
            {
                "performance": {
                    "preregistered_production_estimate_dispatch_cost": 4.0
                }
            },
            self.tolerances,
        )
        bootstrap = summary["bootstraps"]["y_vs_conventional"]
        self.assertEqual(bootstrap["asset_count"], 2)
        self.assertEqual(bootstrap["asset_ids"], ["asset-a", "asset-b"])
        self.assertEqual(bootstrap["asset_deltas"], [1.0, 3.0])
        self.assertEqual(bootstrap["point_delta"], 2.0)
        self.assertEqual(summary["mean_y_psnr_delta_vs_conventional_db"], 2.0)
        self.assertEqual(summary["maximum_ringing_excursion"], 0.04)
        self.assertEqual(summary["maximum_alias_ratio"], 0.04)
        self.assertEqual(summary["maximum_chroma_displacement_pixels"], 0.20)

    def test_profile_omission_is_rejected_before_summary(self) -> None:
        rows = self._corpus_rows()
        rows.pop(0)
        with self.assertRaisesRegex(runner.CalibrationError, "exactly three"):
            runner._summarize_domain(
                rows,
                self._fixture_rows(),
                {
                    "performance": {
                        "preregistered_production_estimate_dispatch_cost": 4.0
                    }
                },
                self.tolerances,
            )

    def test_control_selection_is_lexicographic_with_stable_id_tie_break(self) -> None:
        results = [
            {"stable_id": "z", "engine_raw_corpus_mean_tuple": [10, 2, 3, 4, 5]},
            {"stable_id": "b", "engine_raw_corpus_mean_tuple": [10, 3, 0, 0, 0]},
            {"stable_id": "a", "engine_raw_corpus_mean_tuple": [10, 3, 0, 0, 0]},
        ]
        self.assertEqual(
            runner._lexicographic_control_winner(results, id_field="stable_id"),
            "a",
        )
    def _route_quality_inputs(
        self,
    ) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
        corpus_rows = []
        for domain in ("engine_raw", "container_decoded"):
            for profile in ("p0", "p1", "p2"):
                corpus_rows.append(
                    {
                        "source_asset_id": "asset-a",
                        "target_route": "direct-2x",
                        "degradation_profile_id": profile,
                        "comparison_domain": domain,
                        "metrics_by_control": {
                            "full_ash": {"y_psnr_db": 10.0},
                            "conventional": {"y_psnr_db": 10.0},
                        },
                    }
                )
        raw = [
            {
                "target_route": "direct-2x",
                "comparison_domain": "engine_raw",
                "fixture_kind": "ringing",
                "metrics_by_control": {
                    "full_ash": _artifact_metrics(
                        ringing_overshoot=0.04,
                        ringing_undershoot=0.03,
                    ),
                    "conventional": _artifact_metrics(
                        ringing_overshoot=0.035,
                        ringing_undershoot=0.025,
                    ),
                },
            },
            {
                "target_route": "direct-2x",
                "comparison_domain": "engine_raw",
                "fixture_kind": "alias",
                "metrics_by_control": {
                    "full_ash": _artifact_metrics(
                        alias_forbidden_band_ratio=0.04
                    ),
                    "conventional": _artifact_metrics(
                        alias_forbidden_band_ratio=0.035
                    ),
                },
            },
            {
                "target_route": "direct-2x",
                "comparison_domain": "engine_raw",
                "fixture_kind": "chroma_displacement",
                "metrics_by_control": {
                    "full_ash": _artifact_metrics(
                        chroma_displacement_pixels=0.20
                    ),
                    "conventional": _artifact_metrics(
                        chroma_displacement_pixels=0.15
                    ),
                },
            },
        ]
        decoded = [
            {**copy.deepcopy(row), "comparison_domain": "container_decoded"}
            for row in raw
        ]
        return corpus_rows, raw + decoded

    def test_route_quality_rejects_each_artifact_limit_independently(self) -> None:
        corpus_rows, fixture_rows = self._route_quality_inputs()
        _, passed = runner._route_quality_record_and_pass(
            "direct-2x",
            corpus_rows=corpus_rows,
            fixture_rows=fixture_rows,
            quality=self.tolerances["quality"],
        )
        self.assertTrue(passed)

        mutations = {
            "ringing_absolute": ("ringing", "ringing_overshoot", 0.051, 0.051),
            "ringing_increase": ("ringing", "ringing_overshoot", 0.04, 0.02),
            "alias_absolute": ("alias", "alias_forbidden_band_ratio", 0.051, 0.051),
            "alias_increase": ("alias", "alias_forbidden_band_ratio", 0.04, 0.02),
            "chroma_absolute": (
                "chroma_displacement",
                "chroma_displacement_pixels",
                0.251,
                0.251,
            ),
            "chroma_increase": (
                "chroma_displacement",
                "chroma_displacement_pixels",
                0.20,
                0.05,
            ),
        }
        for name, (kind, field, candidate_value, conventional_value) in mutations.items():
            with self.subTest(limit=name):
                changed = copy.deepcopy(fixture_rows)
                row = next(
                    row
                    for row in changed
                    if row["comparison_domain"] == "engine_raw"
                    and row["fixture_kind"] == kind
                )
                row["metrics_by_control"]["full_ash"][field] = candidate_value
                row["metrics_by_control"]["conventional"][field] = conventional_value
                _, passed = runner._route_quality_record_and_pass(
                    "direct-2x",
                    corpus_rows=corpus_rows,
                    fixture_rows=changed,
                    quality=self.tolerances["quality"],
                )
                self.assertFalse(passed)


class DegradationCachePolicyBindingTests(unittest.TestCase):
    def test_real_policy_cache_uses_semantic_self_hash_not_file_hash(self) -> None:
        policy_path = (
            CALIBRATION_ROOT.parent
            / "quality/policies/degradation-policy.json"
        )
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
        file_sha256 = hashlib.sha256(policy_path.read_bytes()).hexdigest()
        semantic_sha256 = policy["policy_sha256"]
        self.assertNotEqual(file_sha256, semantic_sha256)
        self.assertEqual(
            semantic_sha256,
            canonical_sha256(
                {
                    key: value
                    for key, value in policy.items()
                    if key != "policy_sha256"
                }
            ),
        )
        bound = type(
            "BoundPolicyFixture",
            (),
            {"documents": {"degradation_policy": policy}},
        )()
        cache = runner.LockedDegradationCache(
            runner._degradation_policy_cache_sha256(bound)
        )
        self.assertEqual(cache.degradation_policy_sha256, semantic_sha256)
        self.assertNotEqual(cache.degradation_policy_sha256, file_sha256)


class _ControlCallable:
    def __init__(self) -> None:
        self.control_count = 0
        self.preparation_records = (
            {
                "artifact_kind": "p06_native_non_ash_cache_preparation",
                "record_sha256": "a" * 64,
            },
        )

    @staticmethod
    def _output(context: CandidateContext) -> PlanarFrame:
        return PlanarFrame(
            y=np.zeros(context.y_shape, dtype=np.float64),
            cb=np.zeros(context.cb_shape, dtype=np.float64),
            cr=np.zeros(context.cr_shape, dtype=np.float64),
        )

    def __call__(self, _frame: PlanarFrame, context: CandidateContext) -> PlanarFrame:
        return self._output(context)

    def reconstruct_control(
        self,
        _request: dict[str, object],
        _frame: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        self.control_count += 1
        return self._output(context)

    def non_ash_cache_preparation_records(
        self,
    ) -> tuple[dict[str, object], ...]:
        return self.preparation_records


class _CachedFixedCallable:
    def __init__(self, *, tamper_record_hash: bool = False) -> None:
        self.records: list[dict[str, object]] = []
        self.control_records: list[dict[str, object]] = []
        self.tamper_record_hash = tamper_record_hash

    def __call__(self, _frame: PlanarFrame, context: CandidateContext) -> PlanarFrame:
        return _ControlCallable._output(context)

    def reconstruct_fixed_cached(
        self,
        cache_token: str,
        descriptor_id: int,
    ) -> PlanarFrame:
        output = PlanarFrame(
            y=np.full((4, 4), descriptor_id / 255.0, dtype=np.float64),
            cb=np.zeros((2, 2), dtype=np.float64),
            cr=np.zeros((2, 2), dtype=np.float64),
        )
        bank = "b" * 64
        request: dict[str, object] = {
            "schema_version": "1.0.0",
            "operation": "reconstruct_control",
            "control_key": f"fixed_descriptor_{descriptor_id:02d}",
            "control_mode": "fixed_descriptor_uniform",
            "configuration_sha256": "c" * 64,
            "shared_bank_configuration_sha256": bank,
            "parameters": {"descriptor_id": descriptor_id},
        }
        request["request_sha256"] = canonical_sha256(request)
        record: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_native_fixed_cached_reconstruction",
            "cache_token": cache_token,
            "cache_manifest_sha256": cache_token,
            "descriptor_id": descriptor_id,
            "shared_bank_configuration_sha256": bank,
            "input_frame_sha256": "d" * 64,
            "output_frame_sha256": runner.frame_sha256(output),
            "target_route": "direct-2x",
            "control_request": request,
            "stateful_lut_lookup_count": 0,
            "spatial_operator_recompute_count": 0,
            "analysis_grid_invocation_count": 0,
        }
        record["record_sha256"] = canonical_sha256(record)
        if self.tamper_record_hash:
            record["record_sha256"] = "f" * 64
        self.records.append(record)
        control_record: dict[str, object] = {
            "control_key": request["control_key"],
            "control_mode": request["control_mode"],
            "request_sha256": request["request_sha256"],
            "configuration_sha256": request["configuration_sha256"],
            "shared_bank_configuration_sha256": request[
                "shared_bank_configuration_sha256"
            ],
            "input_frame_sha256": record["input_frame_sha256"],
            "output_frame_sha256": record["output_frame_sha256"],
            "target_route": record["target_route"],
            "parameters": request["parameters"],
            "parameters_sha256": canonical_sha256(request["parameters"]),
            "fixed_cache_record_sha256": record["record_sha256"],
        }
        control_record["record_sha256"] = canonical_sha256(control_record)
        self.control_records.append(control_record)
        return output

    def fixed_cache_records(self) -> tuple[dict[str, object], ...]:
        return tuple(copy.deepcopy(record) for record in self.records)

    def fixed_cache_records_count(self) -> int:
        return len(self.records)

    def fixed_cache_records_record(self, index: int) -> dict[str, object]:
        return copy.deepcopy(self.records[index])

    def control_runtime_records(self) -> tuple[dict[str, object], ...]:
        return tuple(copy.deepcopy(record) for record in self.control_records)

    def control_runtime_records_count(self) -> int:
        return len(self.control_records)

    def control_runtime_records_record(self, index: int) -> dict[str, object]:
        return copy.deepcopy(self.control_records[index])


class _OutputCacheEvidenceCallable:
    def __init__(self, *, reused: bool) -> None:
        self.bank = "b" * 64
        self.configuration_id = "output-cache-evidence-test"
        self.token = "a" * 64
        preparation: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_non_ash_cache_preparation_evidence",
            "identity_sha256": "1" * 64,
            "cache_token": self.token,
            "cache_origin_manifest_sha256": "2" * 64,
            "requesting_configuration_id": self.configuration_id,
            "shared_bank_configuration_sha256": self.bank,
            "cache_reused": reused,
            "preparation_analysis_grid_invocation_count": 0 if reused else 1,
            "preparation_spatial_operator_evaluation_count": 0 if reused else 16,
            "cache_artifact_sha256": "3" * 64,
            "cache_artifact_size_bytes": 4096,
            "feature_tensor_q15_sha256": "4" * 64,
            "descriptor_output_frame_sha256_values": [
                f"{index:x}" * 64 for index in range(16)
            ],
        }
        preparation["record_sha256"] = canonical_sha256(preparation)
        self.preparation = [preparation]

        descriptor_id = 7
        request: dict[str, object] = {
            "schema_version": "1.0.0",
            "operation": "reconstruct_control",
            "control_key": "fixed_descriptor_07",
            "control_mode": "fixed_descriptor_uniform",
            "configuration_sha256": canonical_sha256(
                {
                    "control_id": "fixed-descriptor-uniform-v1",
                    "descriptor_id": descriptor_id,
                    "shared_bank_configuration_sha256": self.bank,
                }
            ),
            "shared_bank_configuration_sha256": self.bank,
            "parameters": {"descriptor_id": descriptor_id},
        }
        request["request_sha256"] = canonical_sha256(request)
        fixed: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_native_fixed_cached_reconstruction",
            "cache_token": self.token,
            "cache_manifest_sha256": self.token,
            "descriptor_id": descriptor_id,
            "shared_bank_configuration_sha256": self.bank,
            "input_frame_sha256": "5" * 64,
            "output_frame_sha256": "6" * 64,
            "target_route": "direct-2x",
            "control_request": request,
            "stateful_lut_lookup_count": 0,
            "spatial_operator_recompute_count": 0,
            "analysis_grid_invocation_count": 0,
        }
        fixed["record_sha256"] = canonical_sha256(fixed)
        self.fixed = [fixed]
        self.non_ash: list[dict[str, object]] = []

        control: dict[str, object] = {
            "control_key": request["control_key"],
            "control_mode": request["control_mode"],
            "request_sha256": request["request_sha256"],
            "configuration_sha256": request["configuration_sha256"],
            "shared_bank_configuration_sha256": self.bank,
            "input_frame_sha256": fixed["input_frame_sha256"],
            "output_frame_sha256": fixed["output_frame_sha256"],
            "target_route": fixed["target_route"],
            "parameters": request["parameters"],
            "parameters_sha256": canonical_sha256(request["parameters"]),
            "fixed_cache_record_sha256": fixed["record_sha256"],
            "control_cache_reused": reused,
            "control_cache_origin_manifest_sha256": "7" * 64,
            "control_cache_origin_proof_sha256": "8" * 64,
            "current_call_analysis_grid_invocation_count": 0,
            "current_call_spatial_operator_evaluation_count": 0,
        }
        control["record_sha256"] = canonical_sha256(control)
        self.controls = [control]

    def __call__(self, _frame: PlanarFrame, context: CandidateContext) -> PlanarFrame:
        return _ControlCallable._output(context)

    def non_ash_cache_preparation_records(self) -> tuple[dict[str, object], ...]:
        return tuple(copy.deepcopy(record) for record in self.preparation)

    def fixed_cache_records(self) -> tuple[dict[str, object], ...]:
        return tuple(copy.deepcopy(record) for record in self.fixed)

    def non_ash_cache_records(self) -> tuple[dict[str, object], ...]:
        return tuple(copy.deepcopy(record) for record in self.non_ash)

    def control_runtime_records(self) -> tuple[dict[str, object], ...]:
        return tuple(copy.deepcopy(record) for record in self.controls)


class _CompilerEvidenceCallable:
    def __init__(self, evidence: dict[str, object]) -> None:
        self.evidence = evidence

    def __call__(self, _frame: PlanarFrame, context: CandidateContext) -> PlanarFrame:
        return _ControlCallable._output(context)

    def candidate_compiler_evidence(self) -> dict[str, object]:
        return copy.deepcopy(self.evidence)


class _EvidenceBound:
    def __init__(self) -> None:
        names = (
            "p00_baseline_reproduction",
            "p05_cpu_reference",
            "p05_operator_discrimination",
            "p05_state_causality",
            "p05_state_fixtures",
        )
        self.documents = {
            "candidate_evidence_policy": {
                "source_evidence": {name: {} for name in names}
            }
        }
        self._records = {
            "candidate_evidence_policy": {"sha256": "a" * 64},
            **{
                f"candidate_evidence_source_{name}": {
                    "sha256": f"{index + 1:x}" * 64
                }
                for index, name in enumerate(names)
            },
        }

    def record(self, identifier: str) -> dict[str, object]:
        return self._records[identifier]


class RuntimeEvidenceTests(unittest.TestCase):
    @staticmethod
    def _output_cache_adapter(
        *,
        reused: bool,
    ) -> tuple[CandidateAdapter, _OutputCacheEvidenceCallable]:
        callable_value = _OutputCacheEvidenceCallable(reused=reused)
        configuration = {
            "implementation_role": "production_swift",
            "configuration_id": callable_value.configuration_id,
            "shared_bank_configuration_sha256": callable_value.bank,
        }
        return (
            CandidateAdapter(
                candidate_id="output-cache-evidence-test",
                configuration=configuration,
                configuration_sha256=canonical_sha256(configuration),
                callable=callable_value,
            ),
            callable_value,
        )

    def test_output_cache_evidence_recomputes_miss_and_reuse_proofs(self) -> None:
        for reused in (False, True):
            with self.subTest(reused=reused):
                adapter, callable_value = self._output_cache_adapter(
                    reused=reused
                )
                output_cache = {
                    "preparation_records": copy.deepcopy(
                        callable_value.preparation
                    ),
                    "preparation_records_sha256": canonical_sha256(
                        callable_value.preparation
                    ),
                    "fixed_reconstruction_proof": (
                        runner._cache_reconstruction_proof_binding(
                            "fixed",
                            callable_value.fixed,
                        )
                    ),
                    "non_ash_reconstruction_proof": (
                        runner._cache_reconstruction_proof_binding(
                            "non_ash",
                            callable_value.non_ash,
                        )
                    ),
                    "control_reconstruction_proof": (
                        runner._cache_reconstruction_proof_binding(
                            "control",
                            callable_value.controls,
                        )
                    ),
                }
                runner._validate_output_cache_evidence(
                    output_cache,
                    adapter=adapter,
                    expected_preparation_count=1,
                )

                stale = copy.deepcopy(output_cache)
                stale["control_reconstruction_proof"]["record_count"] += 1
                with self.assertRaisesRegex(
                    runner.CalibrationError,
                    "control-cache proof binding",
                ):
                    runner._validate_output_cache_evidence(
                        stale,
                        adapter=adapter,
                        expected_preparation_count=1,
                    )

    def test_output_cache_evidence_rejects_candidate_bound_cache_decoration(
        self,
    ) -> None:
        adapter, callable_value = self._output_cache_adapter(reused=True)
        decorated = copy.deepcopy(callable_value.controls[0])
        decorated["control_mode"] = "state_only"
        decorated_without_hash = dict(decorated)
        decorated_without_hash.pop("record_sha256")
        decorated["record_sha256"] = canonical_sha256(decorated_without_hash)
        callable_value.controls = [decorated]
        output_cache = {
            "preparation_records": copy.deepcopy(callable_value.preparation),
            "preparation_records_sha256": canonical_sha256(
                callable_value.preparation
            ),
            "fixed_reconstruction_proof": runner._cache_reconstruction_proof_binding(
                "fixed",
                callable_value.fixed,
            ),
            "non_ash_reconstruction_proof": runner._cache_reconstruction_proof_binding(
                "non_ash",
                callable_value.non_ash,
            ),
            "control_reconstruction_proof": runner._cache_reconstruction_proof_binding(
                "control",
                callable_value.controls,
            ),
        }
        with self.assertRaisesRegex(
            runner.CalibrationError,
            "forbidden cache decoration",
        ):
            runner._validate_output_cache_evidence(
                output_cache,
                adapter=adapter,
                expected_preparation_count=1,
            )

    def test_selected_result_labels_map_to_exact_native_control_keys(self) -> None:
        identities = {
            "best_fixed": {"descriptor_id": 7},
            "conventional": {"algorithm_id": "lanczos3-separable-v1"},
        }
        self.assertEqual(
            runner._native_control_key_for_result("best_fixed", identities),
            "fixed_descriptor_07",
        )
        self.assertEqual(
            runner._native_control_key_for_result("conventional", identities),
            "conventional_2",
        )
        self.assertEqual(
            runner._native_control_key_for_result("state_only", identities),
            "state_only",
        )
        with self.assertRaisesRegex(runner.CalibrationError, "invalid descriptor"):
            runner._native_control_key_for_result(
                "best_fixed",
                {**identities, "best_fixed": {"descriptor_id": 16}},
            )
        with self.assertRaisesRegex(runner.CalibrationError, "invalid algorithm"):
            runner._native_control_key_for_result(
                "conventional",
                {**identities, "conventional": {"algorithm_id": "unknown"}},
            )

    def test_candidate_evidence_headers_reject_stale_policy_and_source(self) -> None:
        bound = _EvidenceBound()
        evidence = {
            "candidate_evidence_policy_sha256": "a" * 64,
            "source_sha256_bindings": runner._candidate_evidence_source_bindings(
                bound
            ),
        }
        runner._validate_candidate_evidence_header(
            evidence,
            bound=bound,
            label="test",
        )
        stale_policy = copy.deepcopy(evidence)
        stale_policy["candidate_evidence_policy_sha256"] = "f" * 64
        with self.assertRaisesRegex(runner.CalibrationError, "bindings are stale"):
            runner._validate_candidate_evidence_header(
                stale_policy,
                bound=bound,
                label="test",
            )
        stale_source = copy.deepcopy(evidence)
        stale_source["source_sha256_bindings"][0]["sha256"] = "f" * 64
        with self.assertRaisesRegex(runner.CalibrationError, "bindings are stale"):
            runner._validate_candidate_evidence_header(
                stale_source,
                bound=bound,
                label="test",
            )

    def test_compiler_evidence_rejects_stale_route_hash(self) -> None:
        compiler_document = {"schema_version": "test"}
        vector_hash = "1" * 64
        route_hashes = {
            "direct-2x": ("2" * 64, "3" * 64, 4096),
            "direct-3over2": ("4" * 64, "5" * 64, 9216),
        }
        routes = []
        for route, (whole, payload, entries) in route_hashes.items():
            sensitivity = [
                {
                    "coordinate": coordinate,
                    "differing_dispatch_pair_count": 1,
                    "first_witness": {
                        "first_signature_sha256": "6" * 64,
                        "second_signature_sha256": "7" * 64,
                    },
                }
                for coordinate in (1, 2, 3, 4, 5, 6, 8)
            ]
            conditioning = {
                "target_route": route,
                "whole_file_sha256": whole,
                "payload_sha256": payload,
                "entry_count": entries,
                "maximum_operator_evaluations": 2,
                "coordinate_sensitivity": sensitivity,
                "state_conditioned": True,
                "oracle_validation_passed": True,
            }
            routes.append(
                {
                    "target_route": route,
                    "lut_whole_file_sha256": whole,
                    "lut_payload_sha256": payload,
                    "state_conditioning_evidence": conditioning,
                    "state_conditioning_evidence_sha256": canonical_sha256(
                        conditioning
                    ),
                }
            )
        configuration = {
            "configuration_id": "compiler-test",
            "serialized_candidate_vector_sha256": vector_hash,
            "compiler_inputs_sha256": "8" * 64,
            "compiler_input_document": compiler_document,
            "candidate_lut_runtime_manifest_sha256": "9" * 64,
            "swift_cli": {
                "executable_sha256": "a" * 64,
                "source_manifest_sha256": "b" * 64,
            },
            "route_luts": {
                route: {
                    "whole_file_sha256": values[0],
                    "payload_sha256": values[1],
                }
                for route, values in route_hashes.items()
            },
        }
        evidence: dict[str, object] = {
            "configuration_id": "compiler-test",
            "candidate_vector_sha256": vector_hash,
            "compiler_inputs_sha256": "8" * 64,
            "compiler_input_document_file_sha256": hashlib.sha256(
                runner.canonical_json_bytes(compiler_document)
            ).hexdigest(),
            "candidate_lut_runtime_manifest_sha256": "9" * 64,
            "native_executable_sha256": "a" * 64,
            "native_source_manifest_sha256": "b" * 64,
            "routes": routes,
            "maximum_operator_evaluations": 2,
        }
        self.assertNotEqual(
            evidence["compiler_input_document_file_sha256"],
            hashlib.sha256(
                runner.canonical_json_bytes(compiler_document) + b"\n"
            ).hexdigest(),
        )
        evidence["evidence_sha256"] = canonical_sha256(evidence)
        callable_value = _CompilerEvidenceCallable(evidence)
        adapter = CandidateAdapter(
            candidate_id="compiler-evidence-test",
            configuration=configuration,
            configuration_sha256=canonical_sha256(configuration),
            callable=callable_value,
        )
        self.assertEqual(
            runner._validate_candidate_compiler_evidence(
                evidence,
                adapter=adapter,
            ),
            2,
        )
        stale = copy.deepcopy(evidence)
        stale["routes"][0]["lut_whole_file_sha256"] = "f" * 64
        callable_value.evidence = stale
        stale_without_hash = dict(stale)
        stale_without_hash.pop("evidence_sha256")
        stale["evidence_sha256"] = canonical_sha256(stale_without_hash)
        callable_value.evidence = stale
        with self.assertRaisesRegex(runner.CalibrationError, "oracle evidence"):
            runner._validate_candidate_compiler_evidence(stale, adapter=adapter)

    def test_analytic_pre_and_post_420_hashes_are_distinct_and_reproducible(self) -> None:
        manifest = json.loads(
            (
                CALIBRATION_ROOT.parent
                / "quality/reference/analytic-fixtures-v2.json"
            ).read_text(encoding="utf-8")
        )
        degradation = json.loads(
            (
                CALIBRATION_ROOT.parent
                / "quality/policies/degradation-policy.json"
            ).read_text(encoding="utf-8")
        )
        definition = manifest["fixtures"][0]
        _, degraded, _ = runner.locked_analytic_fixture_frames(
            definition,
            degradation,
        )
        _, native_input = runner._round_trip_locked_bt709_video_range_nv12(
            degraded
        )
        self.assertEqual(
            runner.frame_sha256(degraded),
            definition["low_resolution_frame_sha256"],
        )
        self.assertEqual(
            runner.frame_sha256(native_input),
            "5faf69d74df194cc07ac355922d9d19f97fb6175f18d6a4cb49b76eb3bb6817c",
        )
        self.assertNotEqual(
            runner.frame_sha256(degraded),
            runner.frame_sha256(native_input),
        )

        row = {
            "degraded_reference_frame_sha256": runner.frame_sha256(degraded),
            "input_frame_sha256": runner.frame_sha256(native_input),
        }
        runner._validate_analytic_fixture_frame_hashes(
            row,
            definition=definition,
            degradation_policy=degradation,
        )

        stale_reference = copy.deepcopy(row)
        stale_reference["degraded_reference_frame_sha256"] = "f" * 64
        with self.assertRaisesRegex(
            runner.CalibrationError,
            "pre-420 bytes",
        ):
            runner._validate_analytic_fixture_frame_hashes(
                stale_reference,
                definition=definition,
                degradation_policy=degradation,
            )

        stale_native_input = copy.deepcopy(row)
        stale_native_input["input_frame_sha256"] = "e" * 64
        with self.assertRaisesRegex(
            runner.CalibrationError,
            "post-420 native bytes",
        ):
            runner._validate_analytic_fixture_frame_hashes(
                stale_native_input,
                definition=definition,
                degradation_policy=degradation,
            )

    def test_candidate_evidence_policy_reopens_every_source_binding(self) -> None:
        repository_root = CALIBRATION_ROOT.parents[1]
        policy = json.loads(
            (
                CALIBRATION_ROOT
                / "contracts/candidate-evidence-policy-v1.json"
            ).read_text(encoding="utf-8")
        )
        records, documents = runner._bind_candidate_evidence_sources(
            repository_root,
            policy,
        )
        self.assertEqual(len(records), 5)
        self.assertEqual(
            [record["id"] for record in records],
            [
                f"candidate_evidence_source_{name}"
                for name in policy["source_evidence"]
            ],
        )
        self.assertEqual(set(documents), set(policy["source_evidence"]))

        stale = copy.deepcopy(policy)
        stale["source_evidence"]["p05_cpu_reference"]["file_sha256"] = (
            "f" * 64
        )
        with self.assertRaisesRegex(
            runner.CalibrationBindingError,
            "hash differs",
        ):
            runner._bind_candidate_evidence_sources(repository_root, stale)

    def test_holdout_sampling_plan_is_exactly_derived_without_pixels(self) -> None:
        plan = json.loads(
            (
                CALIBRATION_ROOT
                / "contracts/holdout-sampling-plan-v1.json"
            ).read_text(encoding="utf-8")
        )
        corpus = json.loads(
            (
                CALIBRATION_ROOT.parent
                / "quality/locks/corpus-lock.json"
            ).read_text(encoding="utf-8")
        )
        runner._validate_holdout_sampling_plan(plan, corpus)
        self.assertFalse(plan["target_pixel_hashes_known_before_p07"])
        self.assertFalse(plan["holdout_accessed"])
        self.assertNotIn("path", plan)
        self.assertNotIn('"pixel_sha256"', json.dumps(plan, sort_keys=True))

        for mutation, message in (
            (("crop", "x", 2), "metadata differs"),
            (("source_sha256", None, "f" * 64), "metadata differs"),
            (("frame_range", "duration", 1), "metadata differs"),
        ):
            stale = copy.deepcopy(plan)
            field, child, value = mutation
            if field == "crop":
                stale["assets"][0][field][child] += value
            elif field == "frame_range":
                stale["assets"][0][field][child] = value
            else:
                stale["assets"][0][field] = value
            stale["manifest_sha256"] = runner.manifest_sha256(stale)
            with self.subTest(mutation=mutation):
                with self.assertRaisesRegex(runner.CalibrationBindingError, message):
                    runner._validate_holdout_sampling_plan(stale, corpus)

    def test_corpus_lock_is_self_hashed_and_bound_to_seal_attestation(self) -> None:
        corpus_path = CALIBRATION_ROOT.parent / "quality/locks/corpus-lock.json"
        corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
        attestation = json.loads(
            (
                CALIBRATION_ROOT.parent
                / "quality/locks/holdout-seal-attestation.no-pixel.json"
            ).read_text(encoding="utf-8")
        )
        binding = {
            "sha256": hashlib.sha256(corpus_path.read_bytes()).hexdigest(),
        }
        runner._validate_corpus_lock_metadata(
            corpus,
            binding=binding,
            attestation=attestation,
        )

        stale = copy.deepcopy(corpus)
        stale["assets"][0]["categories"] = ["undeclared"]
        stale["manifest_sha256"] = runner.manifest_sha256(stale)
        stale_binding = {
            "sha256": hashlib.sha256(
                runner.canonical_json_bytes(stale)
            ).hexdigest(),
        }
        with self.assertRaisesRegex(
            runner.CalibrationBindingError,
            "metadata or self-hash",
        ):
            runner._validate_corpus_lock_metadata(
                stale,
                binding=stale_binding,
                attestation=attestation,
            )

        wrong_attestation = copy.deepcopy(attestation)
        wrong_attestation["production_corpus_lock"]["file_sha256"] = "f" * 64
        with self.assertRaisesRegex(
            runner.CalibrationBindingError,
            "seal attestation",
        ):
            runner._validate_corpus_lock_metadata(
                corpus,
                binding=binding,
                attestation=wrong_attestation,
            )

    def test_control_tracker_preserves_declared_and_document_hashes(self) -> None:
        callable_value = _ControlCallable()
        configuration = {"implementation_role": "analytic_test_fixture"}
        adapter = CandidateAdapter(
            candidate_id="control-tracker-test",
            configuration=configuration,
            configuration_sha256=canonical_sha256(configuration),
            callable=callable_value,
        )
        tracked = runner._TrackedCandidateCallable(adapter, [], [])
        self.assertEqual(
            tracked.non_ash_cache_preparation_records(),
            callable_value.preparation_records,
        )
        self.assertEqual(tracked.control_calls, [])
        self.assertEqual(tracked.control_runtime_records(), ())
        request: dict[str, object] = {
            "control_key": "best_fixed",
            "configuration_sha256": "a" * 64,
            "parameters": {"descriptor_id": 3},
        }
        request["request_sha256"] = canonical_sha256(request)
        frame = PlanarFrame(
            y=np.zeros((2, 2), dtype=np.float64),
            cb=np.zeros((1, 1), dtype=np.float64),
            cr=np.zeros((1, 1), dtype=np.float64),
        )
        context = CandidateContext(
            y_shape=(4, 4),
            cb_shape=(2, 2),
            cr_shape=(2, 2),
            target_route="direct-2x",
        )
        tracked.reconstruct_control(request, frame, context)
        self.assertEqual(callable_value.control_count, 1)
        self.assertEqual(tracked.control_calls[0]["request_sha256"], request["request_sha256"])
        self.assertEqual(
            tracked.control_calls[0]["request_document_sha256"],
            hashlib.sha256(runner.canonical_json_bytes(request)).hexdigest(),
        )

        stale = copy.deepcopy(request)
        stale["parameters"]["descriptor_id"] = 4
        with self.assertRaisesRegex(runner.CalibrationError, "self-hash"):
            tracked.reconstruct_control(stale, frame, context)
        self.assertEqual(callable_value.control_count, 1)

    def test_cached_fixed_tracker_publishes_equivalent_control_call_and_native_record(
        self,
    ) -> None:
        callable_value = _CachedFixedCallable()
        configuration = {
            "implementation_role": "production_swift",
            "shared_bank_configuration_sha256": "b" * 64,
        }
        adapter = CandidateAdapter(
            candidate_id="cached-fixed-tracker-test",
            configuration=configuration,
            configuration_sha256=canonical_sha256(configuration),
            callable=callable_value,
        )
        tracked = runner._TrackedCandidateCallable(adapter, [], [])
        cache_token = "a" * 64
        output = tracked.reconstruct_fixed_cached(cache_token, 7)

        self.assertEqual(len(tracked.control_calls), 1)
        self.assertEqual(len(tracked.control_runtime_records()), 1)
        call = tracked.control_calls[0]
        record = tracked.control_runtime_records()[0]
        cache_record = callable_value.fixed_cache_records()[0]
        self.assertEqual(call["request"], cache_record["control_request"])
        self.assertEqual(call["request_sha256"], call["request"]["request_sha256"])
        self.assertEqual(call["input_frame_sha256"], record["input_frame_sha256"])
        self.assertEqual(call["output_frame_sha256"], runner.frame_sha256(output))
        self.assertEqual(call["target_route"], "direct-2x")
        self.assertEqual(
            record["fixed_cache_record_sha256"],
            cache_record["record_sha256"],
        )
        self.assertEqual(
            call["request_document_sha256"],
            hashlib.sha256(
                runner.canonical_json_bytes(call["request"])
            ).hexdigest(),
        )

    def test_cached_fixed_tracker_rejects_a_tampered_native_record(self) -> None:
        callable_value = _CachedFixedCallable(tamper_record_hash=True)
        configuration = {
            "implementation_role": "production_swift",
            "shared_bank_configuration_sha256": "b" * 64,
        }
        adapter = CandidateAdapter(
            candidate_id="cached-fixed-tamper-test",
            configuration=configuration,
            configuration_sha256=canonical_sha256(configuration),
            callable=callable_value,
        )
        tracked = runner._TrackedCandidateCallable(adapter, [], [])
        with self.assertRaisesRegex(runner.CalibrationError, "self-hash"):
            tracked.reconstruct_fixed_cached("a" * 64, 7)
        self.assertEqual(tracked.control_calls, [])
        self.assertEqual(tracked.control_runtime_records(), ())

    def test_attempt_ledger_detects_byte_tamper(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-attempt-ledger-") as value:
            path = Path(value) / "attempts.ndjson"
            ledger = runner.AttemptLedger(path)
            ledger.append({"status": "feasible", "split": "development"})
            ledger.append({"status": "infeasible", "split": "validation"})
            ledger.close()
            self.assertEqual(len(runner.verify_attempt_ledger(path)), 2)
            payload = path.read_bytes()
            path.write_bytes(b"X" + payload[1:])
            with self.assertRaises(runner.CalibrationError):
                runner.verify_attempt_ledger(path)


if __name__ == "__main__":
    unittest.main()
