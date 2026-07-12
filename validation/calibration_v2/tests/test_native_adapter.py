from __future__ import annotations

from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

import numpy as np

from validation.calibration_v2.native_adapter.factory import (
    NativeAdapterError,
    NativeCandidateCallable,
    NativeSwiftSession,
    _ensure_directory,
    _normalize_p00_compatibility_output,
    _write_new_deferred,
    make_native_candidate_adapter_factory,
)
from validation.calibration_v2.production_evaluator import (
    MemoryEvidenceStore,
    NON_ASH_COORDINATES,
    _control_request,
    conventional_control_request,
    fixed_control_request,
    non_ash_control_request,
)
from validation.calibration_v2.production_evidence import (
    PolicyEvaluationEvidenceProvider,
)
from validation.calibration_v2.runner import (
    _TrackedCandidateCallable,
    _validate_output_cache_evidence,
    _validate_runtime_adapter,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateContext,
    _planar_to_video_range_nv12,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class _BoundStub:
    _PATHS = {
        "calibration_plan": "validation/calibration_v2/contracts/calibration-plan-v1.json",
        "mapping_seed": "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json",
        "operator_bank_seed": "Mirmir/Resources/ASH/operator_bank_v2.seed.json",
        "metric_policy_seed": "validation/quality/policies/metric-policy.json",
        "metric_performance_tolerances": (
            "validation/calibration_v2/contracts/metric-performance-tolerances-v1.json"
        ),
        "quality_gate_policy_seed": (
            "validation/calibration_v2/contracts/quality-gate-policy-v1.seed.json"
        ),
        "compiler_contract": "validation/calibration_v2/contracts/compiler-contract-v1.json",
        "corpus_lock": "validation/quality/locks/corpus-lock.json",
        "holdout_sampling_plan": (
            "validation/calibration_v2/contracts/holdout-sampling-plan-v1.json"
        ),
        "development_sample_lock": "validation/quality/locks/development-sample-lock.json",
        "validation_sample_lock": "validation/quality/locks/validation-sample-lock.json",
        "degradation_policy": "validation/quality/policies/degradation-policy.json",
        "holdout_access_ledger_sealed_copy": (
            "validation/quality/locks/holdout-access-ledger.sealed-copy.json"
        ),
        "holdout_preopen_anchor": (
            "validation/quality/locks/holdout-seal-attestation.no-pixel.json"
        ),
    }

    def __init__(self) -> None:
        self.records = []
        self.documents = {}
        for identifier, relative in self._PATHS.items():
            payload = (REPOSITORY_ROOT / relative).read_bytes()
            self.records.append(
                {
                    "id": identifier,
                    "path": relative,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
            self.documents[identifier] = json.loads(payload)
        self.live_holdout_preopen_verification = {
            "verification_receipt_sha256": "a" * 64,
            "access_status": "unopened",
            "access_count": 0,
            "open_intent_anchor_present": False,
            "pixel_content_included": False,
        }

    def record(self, identifier: str) -> dict[str, object]:
        return next(record for record in self.records if record["id"] == identifier)

    def verify_unchanged(self) -> None:
        return None


def _fixture() -> PlanarFrame:
    return PlanarFrame(
        y=np.array(
            [
                [0.0, 0.25, 0.5, 1.0],
                [0.1, 0.3, 0.7, 0.9],
                [0.2, 0.4, 0.6, 0.8],
                [1.0, 0.5, 0.25, 0.0],
            ],
            dtype=np.float64,
        ),
        cb=np.array([[-0.5, -0.25], [0.25, 0.5]], dtype=np.float64),
        cr=np.array([[0.5, 0.25], [-0.25, -0.5]], dtype=np.float64),
    )


def _context(route: str) -> CandidateContext:
    return (
        CandidateContext(
            y_shape=(8, 8),
            cb_shape=(4, 4),
            cr_shape=(4, 4),
            target_route=route,
        )
        if route == "direct-2x"
        else CandidateContext(
            y_shape=(6, 6),
            cb_shape=(3, 3),
            cr_shape=(3, 3),
            target_route=route,
        )
    )


class NativeAdapterIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-native-adapter-tests-",
            dir="/private/tmp",
        )
        cls.cache = Path(cls.temporary.name) / "cache"
        cls.bound = _BoundStub()
        cls.factory = make_native_candidate_adapter_factory(
            REPOSITORY_ROOT,
            cache_root=cls.cache,
            timeout_seconds=300,
            bound_inputs=cls.bound,
        )
        cls.vector = dict(cls.factory.plan["search"]["initial_vector_values"])

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def test_both_routes_are_native_deterministic_and_common_nv12_quantized(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        frame = _fixture()
        direct2x_first = adapter.reconstruct(frame, _context("direct-2x"))
        direct2x_second = adapter.reconstruct(frame, _context("direct-2x"))
        direct3 = adapter.reconstruct(frame, _context("direct-3over2"))
        self.assertEqual(frame_sha256(direct2x_first), frame_sha256(direct2x_second))
        self.assertEqual(direct2x_first.y.shape, (8, 8))
        self.assertEqual(direct3.y.shape, (6, 6))
        self.assertEqual(direct3.cb.shape, (3, 3))
        for output in (direct2x_first, direct3):
            self.assertTrue(np.allclose(output.y * 219.0 + 16.0, np.rint(output.y * 219.0 + 16.0)))
            self.assertTrue(
                np.allclose(
                    (output.cb + 0.5) * 224.0 + 16.0,
                    np.rint((output.cb + 0.5) * 224.0 + 16.0),
                )
            )
        records = adapter.callable.runtime_records()
        self.assertEqual(len(records), 3)
        self.assertEqual([record["target_route"] for record in records], [
            "direct-2x",
            "direct-2x",
            "direct-3over2",
        ])
        for record in records:
            self.assertEqual(record["cpu_reference_analysis_traversals"], 1)
            self.assertEqual(record["cpu_reference_full_frame_loop_count"], 3)
            self.assertEqual(record["loaded_lut_instance_count"], 1)
            self.assertEqual(record["session_loaded_lut_instance_count"], 2)
            self.assertEqual(record["per_frame_lut_load_count"], 0)
            self.assertEqual(record["runtime_leaf_tree_generations"], 0)
            self.assertEqual(record["runtime_path_generations"], 0)
            self.assertFalse(record["production_metal_constraint_satisfied"])

    def test_factory_configuration_passes_runner_identity_validation(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        _validate_runtime_adapter(
            adapter,
            self.vector,
            self.factory.plan,
            self.bound,
            analytic_test_mode=False,
        )

    def test_candidate_compiler_evidence_reopens_exact_native_luts_with_oracle(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        evidence = adapter.callable.candidate_compiler_evidence()
        self.assertEqual(
            evidence["evidence_sha256"],
            canonical_sha256(
                {key: value for key, value in evidence.items() if key != "evidence_sha256"}
            ),
        )
        self.assertEqual(evidence["configuration_id"], adapter.configuration["configuration_id"])
        self.assertEqual(
            evidence["compiler_input_document_file_sha256"],
            hashlib.sha256(
                adapter.callable.session.configuration.compiler_input_path.read_bytes()
            ).hexdigest(),
        )
        self.assertEqual(evidence["maximum_operator_evaluations"], 2)
        self.assertFalse(evidence["holdout_accessed"])
        self.assertEqual(
            [row["target_route"] for row in evidence["routes"]],
            ["direct-2x", "direct-3over2"],
        )
        for row in evidence["routes"]:
            oracle = row["state_conditioning_evidence"]
            self.assertEqual(
                row["state_conditioning_evidence_sha256"], canonical_sha256(oracle)
            )
            self.assertTrue(oracle["oracle_validation_passed"])
            self.assertTrue(oracle["state_conditioned"])
            self.assertEqual(oracle["active_spatial_coordinates"], [1, 2, 3, 4, 5, 6, 8])
            self.assertEqual(
                [entry["coordinate"] for entry in oracle["coordinate_sensitivity"]],
                [1, 2, 3, 4, 5, 6, 8],
            )
            self.assertTrue(
                all(
                    entry["differing_dispatch_pair_count"] > 0
                    and entry["first_witness"] is not None
                    for entry in oracle["coordinate_sensitivity"]
                )
            )

    def test_one_native_batch_preserves_order_for_both_routes(self) -> None:
        adapter = self.factory(self.vector, "validation")
        self.addCleanup(adapter.callable.close)
        outputs = adapter.callable.reconstruct_batch(
            (
                (_fixture(), _context("direct-3over2")),
                (_fixture(), _context("direct-2x")),
            )
        )
        self.assertEqual([output.y.shape for output in outputs], [(6, 6), (8, 8)])
        self.assertEqual(
            [record["target_route"] for record in adapter.callable.runtime_records()],
            ["direct-3over2", "direct-2x"],
        )

    def test_validation_dispatch_projection_is_native_bound_and_alternating(self) -> None:
        adapter = self.factory(self.vector, "validation")
        self.addCleanup(adapter.callable.close)
        frame = _fixture()
        context = _context("direct-2x")
        expected = adapter.reconstruct(frame, context)
        profile = {"degradation_profile_id": "native-fixture-profile"}
        profile_sha256 = hashlib.sha256(
            json.dumps(profile, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        sample = adapter.callable.measure_dispatch_projection(
            frame,
            context,
            source_asset_id="native-fixture-source",
            degradation_profile_id="native-fixture-profile",
            degradation_profile_sha256=profile_sha256,
        )
        self.assertEqual(sample["source_asset_id"], "native-fixture-source")
        self.assertEqual(sample["degradation_profile_id"], "native-fixture-profile")
        self.assertEqual(sample["degradation_profile_sha256"], profile_sha256)
        self.assertEqual(sample["input_frame_sha256"], frame_sha256(frame))
        self.assertEqual(sample["full_output_sha256"], frame_sha256(expected))
        self.assertEqual(sample["control_output_sha256"], frame_sha256(expected))
        self.assertEqual(
            sample["lut_whole_file_sha256"],
            adapter.configuration["route_luts"]["direct-2x"]["whole_file_sha256"],
        )
        repetitions = sample["repetitions"]
        self.assertEqual(len(repetitions), 10)
        self.assertEqual(
            [row["order"] for row in repetitions],
            [
                "full_then_control" if index % 2 == 0 else "control_then_full"
                for index in range(10)
            ],
        )
        self.assertEqual(sample["measurement_domain"], "native_cpu_reference_projection_not_metal")
        self.assertFalse(sample["production_metal_constraint_satisfied"])
        self.assertEqual(sample["warmup_repetition_count"], 3)
        self.assertEqual(sample["measured_repetition_count"], 10)
        self.assertEqual(
            set(sample["input_bindings"]),
            {
                "configuration_id",
                "candidate_vector_sha256",
                "shared_bank_configuration_sha256",
                "mapping_sha256",
                "operator_bank_sha256",
                "metric_policy_sha256",
                "compiler_inputs_sha256",
                "calibration_plan_sha256",
                "corpus_lock_bundle_sha256",
                "validation_sample_lock_sha256",
                "degradation_policy_sha256",
                "raw_output_contract_sha256",
                "full_control_configuration_sha256",
            },
        )
        for row in repetitions:
            self.assertEqual(
                set(row),
                {
                    "index",
                    "order",
                    "full_analysis_nanoseconds",
                    "full_dispatch_nanoseconds",
                    "full_reconstruction_nanoseconds",
                    "control_reconstruction_nanoseconds",
                },
            )
        environment = adapter.callable.dispatch_environment()
        self.assertEqual(
            environment["executable_sha256"],
            adapter.configuration["swift_cli"]["executable_sha256"],
        )
        self.assertEqual(
            environment["source_manifest_sha256"],
            adapter.configuration["swift_cli"]["source_manifest_sha256"],
        )
        self.assertGreater(environment["logical_cpu_count"], 0)
        self.assertGreater(environment["physical_memory_bytes"], 0)

    def test_development_dispatch_projection_is_rejected_before_native_request(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        with self.assertRaisesRegex(NativeAdapterError, "only for the validation split"):
            adapter.callable.measure_dispatch_projection(
                _fixture(),
                _context("direct-2x"),
                source_asset_id="native-fixture-source",
                degradation_profile_id="native-fixture-profile",
                degradation_profile_sha256="a" * 64,
            )
        self.assertEqual(adapter.callable._measurement_invocation_count, 0)

    def test_native_control_modes_emit_exact_self_bound_records(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        bank = adapter.configuration["shared_bank_configuration_sha256"]
        vector_hash = adapter.configuration["serialized_candidate_vector_sha256"]
        zero_rule = {name: 0 for name in NON_ASH_COORDINATES}
        state_configuration = canonical_sha256(
            {
                "control_id": "ash-state-only-base-descriptor-v1",
                "candidate_vector_sha256": vector_hash,
            }
        )
        nearest_configuration = canonical_sha256(
            {
                "control_id": "nearest-same-writer-420v-v1",
                "shared_bank_configuration_sha256": bank,
            }
        )
        h07_configuration = canonical_sha256(
            {
                "control_id": "direct2x-then-lanczos3-control-v1",
                "candidate_adapter_configuration_sha256": adapter.configuration_sha256,
            }
        )
        requests = [
            (
                _control_request(
                    control_key="full_ash",
                    control_mode="full_ash",
                    configuration_sha256=adapter.configuration_sha256,
                    shared_bank_configuration_sha256=bank,
                    parameters={
                        "control_id": "ash-state-plus-branch-compiler-v1",
                        "candidate_vector_sha256": vector_hash,
                    },
                ),
                _context("direct-2x"),
            ),
            (fixed_control_request(7, bank), _context("direct-2x")),
            (
                conventional_control_request("bilinear-separable-v1", bank),
                _context("direct-2x"),
            ),
            (non_ash_control_request(zero_rule, bank), _context("direct-2x")),
            (
                _control_request(
                    control_key="state_only",
                    control_mode="state_only",
                    configuration_sha256=state_configuration,
                    shared_bank_configuration_sha256=bank,
                    parameters={
                        "control_id": "ash-state-only-base-descriptor-v1",
                        "candidate_vector_sha256": vector_hash,
                    },
                ),
                _context("direct-2x"),
            ),
            (
                _control_request(
                    control_key="nearest_same_writer",
                    control_mode="nearest_uniform",
                    configuration_sha256=nearest_configuration,
                    shared_bank_configuration_sha256=bank,
                    parameters={"control_id": "nearest-same-writer-420v-v1"},
                ),
                _context("direct-2x"),
            ),
            (
                _control_request(
                    control_key="h07_direct_3_over_2",
                    control_mode="h07_direct2x_then_lanczos3",
                    configuration_sha256=h07_configuration,
                    shared_bank_configuration_sha256=bank,
                    parameters={
                        "experiment_id": "H07",
                        "direct_id": "direct3over2-locked-route-v1",
                        "control_id": "direct2x-then-lanczos3-control-v1",
                        "candidate_adapter_configuration_sha256": (
                            adapter.configuration_sha256
                        ),
                    },
                ),
                _context("direct-3over2"),
            ),
        ]
        for request, context in requests:
            output = adapter.callable.reconstruct_control(request, _fixture(), context)
            self.assertEqual(output.y.shape, context.y_shape)
        records = adapter.callable.control_runtime_records()
        self.assertEqual(len(records), len(requests))
        for record, (request, context) in zip(records, requests):
            self.assertEqual(record["control_key"], request["control_key"])
            self.assertEqual(record["control_mode"], request["control_mode"])
            self.assertEqual(record["request_sha256"], request["request_sha256"])
            self.assertEqual(record["parameters"], request["parameters"])
            self.assertEqual(
                record["parameters_sha256"], canonical_sha256(request["parameters"])
            )
            self.assertEqual(record["target_route"], context.target_route)
            if request["control_mode"] in {"full_ash", "state_only"}:
                summary = record["locked_runtime_summary"]
                self.assertEqual(
                    set(summary),
                    {
                        "state_histogram",
                        "operator_histogram",
                        "maximum_operator_evaluations",
                        "analysis_cell_count",
                        "dispatch_record_count",
                        "exact_decode_count",
                        "corrected_decode_count",
                        "rejected_decode_count",
                    },
                )
                self.assertEqual(
                    summary["state_histogram"],
                    sorted(
                        summary["state_histogram"],
                        key=lambda row: row["state_raw_value"],
                    ),
                )
            if request["control_mode"] == "h07_direct2x_then_lanczos3":
                h07_summary = record["h07_runtime_summary"]
                self.assertEqual(
                    h07_summary["summary_sha256"],
                    canonical_sha256(
                        {
                            key: value
                            for key, value in h07_summary.items()
                            if key != "summary_sha256"
                        }
                    ),
                )
                self.assertEqual(
                    h07_summary["direct2_analysis_cell_count"],
                    record["h07_direct2_runtime_summary"]["analysis_cell_count"],
                )
                self.assertEqual(
                    h07_summary["total_work_item_count"],
                    h07_summary["direct2_operator_work_item_count"]
                    + h07_summary["lanczos3_work_item_count"],
                )
            self.assertEqual(
                record["record_sha256"],
                canonical_sha256(
                    {key: value for key, value in record.items() if key != "record_sha256"}
                ),
            )

    def test_non_ash_cache_reuses_analysis_and_matches_legacy_control_bytes(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        bank = adapter.configuration["shared_bank_configuration_sha256"]
        profile = {"id": "native-cache-profile"}
        profile_sha256 = canonical_sha256(profile)
        for route in ("direct-2x", "direct-3over2"):
            context = _context(route)
            prepared = adapter.callable.prepare_non_ash_cache(
                _fixture(),
                context,
                source_asset_id=f"native-cache-{route}",
                degradation_profile_id="native-cache-profile",
                degradation_profile_sha256=profile_sha256,
            )
            repeated = adapter.callable.prepare_non_ash_cache(
                _fixture(),
                context,
                source_asset_id=f"native-cache-{route}",
                degradation_profile_id="native-cache-profile",
                degradation_profile_sha256=profile_sha256,
            )
            self.assertEqual(repeated["cache_token"], prepared["cache_token"])
            self.assertEqual(repeated["cache_manifest"], prepared["cache_manifest"])
            self.assertEqual(
                repeated["cache_origin_manifest_sha256"],
                prepared["cache_origin_manifest_sha256"],
            )
            self.assertFalse(prepared["cache_reused"])
            self.assertEqual(
                prepared["preparation_analysis_grid_invocation_count"], 1
            )
            self.assertEqual(
                prepared["preparation_spatial_operator_evaluation_count"], 16
            )
            self.assertTrue(repeated["cache_reused"])
            self.assertEqual(
                repeated["preparation_analysis_grid_invocation_count"], 0
            )
            self.assertEqual(
                repeated["preparation_spatial_operator_evaluation_count"], 0
            )
            token = prepared["cache_token"]
            manifest = prepared["cache_manifest"]
            self.assertEqual(token, manifest["cache_manifest_sha256"])
            self.assertEqual(
                token,
                canonical_sha256(
                    {
                        key: value
                        for key, value in manifest.items()
                        if key != "cache_manifest_sha256"
                    }
                ),
            )
            self.assertEqual(manifest["analysis_grid_invocation_count"], 1)
            self.assertEqual(
                [row["descriptor_id"] for row in manifest["descriptor_outputs"]],
                list(range(16)),
            )

            for descriptor_id in (0, 7, 15):
                cached = adapter.callable.reconstruct_fixed_cached(
                    token,
                    descriptor_id,
                )
                legacy = adapter.callable.reconstruct_control(
                    fixed_control_request(descriptor_id, bank),
                    _fixture(),
                    context,
                )
                self.assertEqual(frame_sha256(cached), frame_sha256(legacy))

            for value in (-384, -256, -128, 0, 128, 256, 384):
                rule = {name: 0 for name in NON_ASH_COORDINATES}
                rule["weight_orientation_cos_q8_8"] = value
                cached = adapter.callable.reconstruct_non_ash_cached(token, rule)
                legacy = adapter.callable.reconstruct_control(
                    non_ash_control_request(rule, bank),
                    _fixture(),
                    context,
                )
                self.assertEqual(frame_sha256(cached), frame_sha256(legacy))

        for record in (
            *adapter.callable.fixed_cache_records(),
            *adapter.callable.non_ash_cache_records(),
        ):
            self.assertEqual(record["stateful_lut_lookup_count"], 0)
            self.assertEqual(record["spatial_operator_recompute_count"], 0)
            self.assertEqual(record["analysis_grid_invocation_count"], 0)
            self.assertEqual(
                record["record_sha256"],
                canonical_sha256(
                    {key: value for key, value in record.items() if key != "record_sha256"}
                ),
            )

    def test_same_bank_compiler_neighbor_reopens_cache_after_first_session_closes(
        self,
    ) -> None:
        second_vector = dict(self.vector)
        second_vector["support_radius_step_q8_8"] = 96
        profile = {"id": "cross-candidate-cache-profile"}
        profile_sha256 = canonical_sha256(profile)
        context = _context("direct-2x")

        first = self.factory(self.vector, "development")
        try:
            first_preparation = first.callable.prepare_non_ash_cache(
                _fixture(),
                context,
                source_asset_id="cross-candidate-cache-direct2x",
                degradation_profile_id=profile["id"],
                degradation_profile_sha256=profile_sha256,
            )
            first_outputs = tuple(
                _planar_to_video_range_nv12(
                    first.callable.reconstruct_fixed_cached(
                        first_preparation["cache_token"],
                        descriptor_id,
                    )
                )
                for descriptor_id in range(16)
            )
            first_record = first.callable.non_ash_cache_preparation_records()[-1]
            first_process = first.callable.session.process
            first_bank = first.configuration["shared_bank_configuration_sha256"]
            first_vector_sha256 = first.configuration[
                "serialized_candidate_vector_sha256"
            ]
        finally:
            first.callable.close()
        self.assertIsNotNone(first_process.poll())

        second = self.factory(second_vector, "development")
        self.addCleanup(second.callable.close)
        self.assertEqual(
            second.configuration["shared_bank_configuration_sha256"],
            first_bank,
        )
        self.assertNotEqual(
            second.configuration["serialized_candidate_vector_sha256"],
            first_vector_sha256,
        )
        second_preparation = second.callable.prepare_non_ash_cache(
            _fixture(),
            context,
            source_asset_id="cross-candidate-cache-direct2x",
            degradation_profile_id=profile["id"],
            degradation_profile_sha256=profile_sha256,
        )
        second_outputs = tuple(
            _planar_to_video_range_nv12(
                second.callable.reconstruct_fixed_cached(
                    second_preparation["cache_token"],
                    descriptor_id,
                )
            )
            for descriptor_id in range(16)
        )
        second_record = second.callable.non_ash_cache_preparation_records()[-1]

        self.assertFalse(first_preparation["cache_reused"])
        self.assertEqual(
            first_preparation["preparation_analysis_grid_invocation_count"],
            1,
        )
        self.assertEqual(
            first_preparation[
                "preparation_spatial_operator_evaluation_count"
            ],
            16,
        )
        self.assertTrue(second_preparation["cache_reused"])
        self.assertEqual(
            second_preparation["preparation_analysis_grid_invocation_count"],
            0,
        )
        self.assertEqual(
            second_preparation[
                "preparation_spatial_operator_evaluation_count"
            ],
            0,
        )
        self.assertEqual(
            second_preparation["cache_token"],
            first_preparation["cache_token"],
        )
        self.assertEqual(
            second_preparation["cache_origin_manifest_sha256"],
            first_preparation["cache_origin_manifest_sha256"],
        )
        self.assertEqual(second_preparation["cache_manifest"], first_preparation["cache_manifest"])
        self.assertEqual(second_outputs, first_outputs)
        self.assertEqual(
            first_preparation["cache_reopen_evidence_sha256"],
            first_record["record_sha256"],
        )
        self.assertEqual(
            second_preparation["cache_reopen_evidence_sha256"],
            second_record["record_sha256"],
        )
        for record in (first_record, second_record):
            self.assertEqual(
                record["record_sha256"],
                canonical_sha256(
                    {
                        key: value
                        for key, value in record.items()
                        if key != "record_sha256"
                    }
                ),
            )
        evidence_provider = PolicyEvaluationEvidenceProvider(
            metric_performance_tolerances=self.bound.documents[
                "metric_performance_tolerances"
            ],
            measurement_evidence_root=self.cache / "cross-candidate-evidence",
            evidence_store=MemoryEvidenceStore(),
        )
        second_output_cache_evidence = evidence_provider._output_cache_evidence(
            adapter=second,
            native_control_records=second.callable.control_runtime_records(),
        )
        self.assertEqual(
            second_output_cache_evidence["preparation_records"],
            [second_record],
        )
        self.assertTrue(
            all(
                record["cache_reused"] is True
                and record["preparation_analysis_grid_invocation_count"] == 0
                and record[
                    "preparation_spatial_operator_evaluation_count"
                ]
                == 0
                for record in second_output_cache_evidence[
                    "preparation_records"
                ]
            )
        )
        self.assertEqual(
            second_output_cache_evidence["fixed_reconstruction_proof"][
                "record_count"
            ],
            16,
        )
        self.assertEqual(
            second_output_cache_evidence["control_reconstruction_proof"][
                "record_count"
            ],
            16,
        )
        self.assertTrue(
            all(
                record["control_cache_reused"] is True
                and record["current_call_analysis_grid_invocation_count"] == 0
                and record[
                    "current_call_spatial_operator_evaluation_count"
                ]
                == 0
                for record in second.callable.control_runtime_records()
            )
        )
        _validate_output_cache_evidence(
            second_output_cache_evidence,
            adapter=second,
            expected_preparation_count=1,
        )

    def test_second_session_non_ash_recombines_from_compact_exact_proof(self) -> None:
        context = _context("direct-2x")
        profile = {"id": "non-ash-second-session-profile"}
        rule = {name: 0 for name in NON_ASH_COORDINATES}
        rule["weight_texture_q8_8"] = 256
        source_asset_id = "non-ash-second-session-source"

        first = self.factory(self.vector, "development")
        self.addCleanup(first.callable.close)
        prepared = first.callable.prepare_non_ash_cache(
            _fixture(),
            context,
            source_asset_id=source_asset_id,
            degradation_profile_id=profile["id"],
            degradation_profile_sha256=canonical_sha256(profile),
        )
        first_output = first.callable.reconstruct_non_ash_cached(
            prepared["cache_token"],
            rule,
        )
        first_payload = _planar_to_video_range_nv12(first_output)
        first_specialized = first.callable.non_ash_cache_records()[-1]
        first_control = first.callable.control_runtime_records()[-1]
        first_bindings = first.callable._non_ash_cached_reconstruction_bindings(
            prepared["cache_token"],
            rule,
        )
        first_origin_path = (
            first.callable._non_ash_reconstruction_proof_origin_path(
                first_bindings
            )
        )
        staged_origin = first.callable._pending_control_cache_files[
            first_origin_path
        ][3]
        self.assertIsNotNone(staged_origin)
        self.assertFalse(first_origin_path.exists())
        assert staged_origin is not None
        self.assertTrue(staged_origin.exists())
        self.assertFalse(first_control["control_cache_reused"])
        self.assertEqual(len(first.callable._pending_control_cache_files), 3)
        self.assertEqual(
            {binding[2] for binding in first.callable._pending_control_cache_files.values()},
            {"payload", "dependency_origin", "origin"},
        )
        self.assertTrue(first.callable._pending_control_cache_directories)
        roles_by_identity = {
            (os.stat(binding[3] or path, follow_symlinks=False).st_dev,
             os.stat(binding[3] or path, follow_symlinks=False).st_ino): binding[2]
            for path, binding in first.callable._pending_control_cache_files.items()
        }
        observed: list[str] = []
        real_fsync = os.fsync

        def observe_fsync(descriptor: int) -> None:
            metadata = os.fstat(descriptor)
            if stat.S_ISREG(metadata.st_mode):
                observed.append(roles_by_identity[(metadata.st_dev, metadata.st_ino)])
            elif stat.S_ISDIR(metadata.st_mode):
                observed.append("directory")
            real_fsync(descriptor)

        with mock.patch(
            "validation.calibration_v2.native_adapter.factory.os.fsync",
            side_effect=observe_fsync,
        ):
            durability_commit = first.callable.flush_control_cache_durability()
        self.assertEqual(
            observed[:3],
            ["payload", "dependency_origin", "origin"],
        )
        self.assertTrue(all(role == "directory" for role in observed[3:]))
        self.assertTrue(first_origin_path.exists())
        self.assertFalse(staged_origin.exists())
        self.assertEqual(
            set(durability_commit),
            {
                "schema_version",
                "artifact_kind",
                "split",
                "requesting_configuration_id",
                "shared_bank_configuration_sha256",
                "native_executable_sha256",
                "native_source_manifest_sha256",
                "pending_file_count",
                "pending_directory_count",
                "ordered_file_bindings_sha256",
                "ordered_directory_identities_sha256",
                "committed",
                "record_sha256",
            },
        )
        self.assertEqual(durability_commit["pending_file_count"], 3)
        self.assertTrue(durability_commit["committed"])
        self.assertEqual(
            durability_commit["record_sha256"],
            canonical_sha256(
                {
                    key: value
                    for key, value in durability_commit.items()
                    if key != "record_sha256"
                }
            ),
        )
        self.assertEqual(first.callable._pending_control_cache_files, {})
        self.assertEqual(first.callable._pending_control_cache_directories, set())
        first.callable.close()

        second = self.factory(self.vector, "development")
        self.addCleanup(second.callable.close)
        reopened_preparation = second.callable.prepare_non_ash_cache(
            _fixture(),
            context,
            source_asset_id=source_asset_id,
            degradation_profile_id=profile["id"],
            degradation_profile_sha256=canonical_sha256(profile),
        )
        self.assertTrue(reopened_preparation["cache_reused"])
        self.assertEqual(
            reopened_preparation["cache_token"],
            prepared["cache_token"],
        )
        tracked = _TrackedCandidateCallable(second, [], [])
        with mock.patch.object(
            second.callable.session,
            "reconstruct_non_ash_cached",
            wraps=second.callable.session.reconstruct_non_ash_cached,
        ) as swift_recombination, mock.patch.object(
            second.callable,
            "non_ash_cache_records",
            side_effect=AssertionError("tracker must use indexed non-ASH records"),
        ), mock.patch.object(
            second.callable,
            "control_runtime_records",
            side_effect=AssertionError("tracker must use indexed control records"),
        ):
            normal_reopen = tracked.reconstruct_non_ash_cached(
                prepared["cache_token"],
                rule,
            )
            aggregate_reopen = tracked.reopen_non_ash_cached(
                prepared["cache_token"],
                rule,
            )
        self.assertEqual(swift_recombination.call_count, 2)

        self.assertEqual(_planar_to_video_range_nv12(normal_reopen), first_payload)
        self.assertEqual(_planar_to_video_range_nv12(aggregate_reopen), first_payload)
        self.assertEqual(
            second.callable.non_ash_cache_records(),
            (first_specialized, first_specialized),
        )
        bindings = second.callable._non_ash_cached_reconstruction_bindings(
            prepared["cache_token"],
            rule,
        )
        origin_path = second.callable._non_ash_reconstruction_proof_origin_path(
            bindings
        )
        origin = json.loads(origin_path.read_bytes())
        self.assertEqual(
            {path.name for path in origin_path.parent.iterdir()},
            {"origin.json"},
        )
        expected_control = second.callable._decorated_control_cache_record(
            origin,
            reused=True,
            current_analysis_count=0,
            current_operator_count=0,
        )
        self.assertEqual(
            second.callable.control_runtime_records(),
            (expected_control, expected_control),
        )
        self.assertEqual(tracked.control_runtime_records(), (expected_control, expected_control))
        self.assertEqual(len(tracked.control_calls), 2)
        with mock.patch.object(
            second.callable,
            "_flush_deferred_control_cache_durability",
            wraps=second.callable._flush_deferred_control_cache_durability,
        ) as durability_flush:
            second.callable.close()
        durability_flush.assert_called_once_with()

    def test_reopen_only_non_ash_fails_for_missing_or_corrupt_origins(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        context = _context("direct-2x")
        rule = {name: 0 for name in NON_ASH_COORDINATES}
        profile = {"id": "non-ash-reopen-negative-profile"}

        for damage in ("missing", "corrupt"):
            with self.subTest(damage=damage):
                prepared = adapter.callable.prepare_non_ash_cache(
                    _fixture(),
                    context,
                    source_asset_id="non-ash-reopen-negative-source",
                    degradation_profile_id=profile["id"],
                    degradation_profile_sha256=canonical_sha256(profile),
                )
                adapter.callable.reconstruct_non_ash_cached(
                    prepared["cache_token"],
                    rule,
                )
                adapter.callable.flush_control_cache_durability()
                bindings = adapter.callable._non_ash_cached_reconstruction_bindings(
                    prepared["cache_token"],
                    rule,
                )
                origin_path = adapter.callable._non_ash_reconstruction_proof_origin_path(
                    bindings
                )
                original_origin_payload = origin_path.read_bytes()
                if damage == "missing":
                    origin_path.unlink()
                else:
                    origin = json.loads(original_origin_payload)
                    origin["origin_manifest_sha256"] = "f" * 64
                    origin_path.write_bytes(canonical_json_bytes(origin))
                try:
                    with mock.patch.object(
                        adapter.callable.session,
                        "reconstruct_non_ash_cached",
                        side_effect=AssertionError(
                            "reopen-only must not invoke Swift"
                        ),
                    ) as swift_recombination:
                        with self.assertRaises(NativeAdapterError):
                            adapter.callable.reopen_non_ash_cached(
                                prepared["cache_token"],
                                rule,
                            )
                    swift_recombination.assert_not_called()
                finally:
                    origin_path.write_bytes(original_origin_payload)

    def test_compact_non_ash_proof_rejects_rehashed_cross_binding_tamper(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        context = _context("direct-2x")
        rule = {name: 0 for name in NON_ASH_COORDINATES}
        rule["bias_descriptor_03_q8_8"] = 128
        profile = {"id": "compact-proof-tamper-profile"}
        prepared = adapter.callable.prepare_non_ash_cache(
            _fixture(),
            context,
            source_asset_id="compact-proof-tamper-source",
            degradation_profile_id=profile["id"],
            degradation_profile_sha256=canonical_sha256(profile),
        )
        adapter.callable.reconstruct_non_ash_cached(prepared["cache_token"], rule)
        adapter.callable.flush_control_cache_durability()
        bindings = adapter.callable._non_ash_cached_reconstruction_bindings(
            prepared["cache_token"],
            rule,
        )
        origin_path = adapter.callable._non_ash_reconstruction_proof_origin_path(
            bindings
        )
        original_payload = origin_path.read_bytes()
        original = json.loads(original_payload)

        def rehash(document: dict[str, object], field: str) -> None:
            unhashed = dict(document)
            unhashed.pop(field, None)
            document[field] = canonical_sha256(unhashed)

        for damage in (
            "proof_extra_field",
            "proof_schema",
            "proof_kind",
            "proof_input_frame",
            "proof_output_frame",
            "request",
            "base_input_frame",
            "specialized_record_link",
        ):
            with self.subTest(damage=damage):
                damaged = json.loads(json.dumps(original))
                proof = damaged["origin_proof"]
                base = damaged["origin_native_control_record"]
                if damage == "proof_extra_field":
                    proof["unexpected"] = "forbidden"
                elif damage == "proof_schema":
                    proof["schema_version"] = "2.0.0"
                elif damage == "proof_kind":
                    proof["artifact_kind"] = "wrong-kind"
                elif damage == "proof_input_frame":
                    proof["input_frame_sha256"] = "c" * 64
                elif damage == "proof_output_frame":
                    proof["output_frame_sha256"] = "d" * 64
                elif damage == "request":
                    damaged["control_request"]["control_key"] = "wrong-control"
                    rehash(damaged["control_request"], "request_sha256")
                elif damage == "base_input_frame":
                    base["input_frame_sha256"] = "e" * 64
                    rehash(base, "record_sha256")
                    proof["origin_native_control_record_sha256"] = base[
                        "record_sha256"
                    ]
                else:
                    base["non_ash_cache_record_sha256"] = "f" * 64
                    rehash(base, "record_sha256")
                    proof["origin_native_control_record_sha256"] = base[
                        "record_sha256"
                    ]
                rehash(proof, "proof_sha256")
                rehash(damaged, "origin_manifest_sha256")
                origin_path.write_bytes(canonical_json_bytes(damaged))
                try:
                    with mock.patch.object(
                        adapter.callable.session,
                        "reconstruct_non_ash_cached",
                        side_effect=AssertionError(
                            "tampered compact proof must fail before Swift"
                        ),
                    ) as swift_recombination:
                        with self.assertRaises(NativeAdapterError):
                            adapter.callable.reopen_non_ash_cached(
                                prepared["cache_token"],
                                rule,
                            )
                    swift_recombination.assert_not_called()
                finally:
                    origin_path.write_bytes(original_payload)

    def test_operator_origin_producer_hashes_are_current_and_exact(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        profile = {"id": "producer-binding-profile"}
        prepared = adapter.callable.prepare_non_ash_cache(
            _fixture(),
            _context("direct-2x"),
            source_asset_id="producer-binding-source",
            degradation_profile_id=profile["id"],
            degradation_profile_sha256=canonical_sha256(profile),
        )
        root = adapter.callable._non_ash_cache_roots[prepared["cache_token"]]
        origin_path = root / "origin.json"
        original_payload = origin_path.read_bytes()
        origin = json.loads(original_payload)
        identity = origin["identity"]
        self.assertEqual(
            identity["native_executable_sha256"],
            adapter.configuration["swift_cli"]["executable_sha256"],
        )
        self.assertEqual(
            identity["native_source_manifest_sha256"],
            adapter.configuration["swift_cli"]["source_manifest_sha256"],
        )
        self.assertEqual(
            origin["origin_native_executable_sha256"],
            identity["native_executable_sha256"],
        )
        self.assertEqual(
            origin["origin_native_source_manifest_sha256"],
            identity["native_source_manifest_sha256"],
        )
        old_source_identity = dict(identity)
        old_source_identity["native_source_manifest_sha256"] = "e" * 64
        self.assertNotEqual(
            canonical_sha256(old_source_identity),
            canonical_sha256(identity),
        )
        self.assertNotEqual(
            root,
            root.parent / canonical_sha256(old_source_identity),
        )
        origin["origin_native_source_manifest_sha256"] = "f" * 64
        origin.pop("origin_manifest_sha256")
        origin["origin_manifest_sha256"] = canonical_sha256(origin)
        origin_path.write_bytes(canonical_json_bytes(origin))
        try:
            with self.assertRaises(NativeAdapterError):
                adapter.callable._non_ash_cached_reconstruction_bindings(
                    prepared["cache_token"],
                    {name: 0 for name in NON_ASH_COORDINATES},
                )
        finally:
            origin_path.write_bytes(original_payload)

    def test_lexical_parent_symlink_and_real_cache_root_replacement_are_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir=self.cache) as temporary:
            root = Path(temporary)
            actual = root / "actual"
            actual.mkdir()
            symbolic = root / "symbolic"
            symbolic.symlink_to(actual, target_is_directory=True)
            with self.assertRaises(NativeAdapterError):
                _ensure_directory(symbolic / "child")
            self.assertFalse((actual / "child").exists())

            adapter = self.factory(self.vector, "development")
            self.addCleanup(adapter.callable.close)
            pinned_root = root / "pinned-cache-root"
            pinned_root.mkdir()
            pinned_descriptor = os.open(
                pinned_root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            pinned_metadata = os.fstat(pinned_descriptor)
            old_path = adapter.callable._native_cache_root
            old_descriptor = adapter.callable._native_cache_root_descriptor
            old_identity = adapter.callable._native_cache_root_identity
            adapter.callable._native_cache_root = pinned_root
            adapter.callable._native_cache_root_descriptor = pinned_descriptor
            adapter.callable._native_cache_root_identity = (
                pinned_metadata.st_dev,
                pinned_metadata.st_ino,
            )
            moved = root / "moved-pinned-cache-root"
            pinned_root.rename(moved)
            pinned_root.mkdir()
            try:
                with self.assertRaisesRegex(
                    NativeAdapterError,
                    "native cache root was replaced",
                ):
                    adapter.callable.reconstruct_batch(
                        ((_fixture(), _context("direct-2x")),)
                    )
            finally:
                adapter.callable._native_cache_root = old_path
                adapter.callable._native_cache_root_descriptor = old_descriptor
                adapter.callable._native_cache_root_identity = old_identity
                os.close(pinned_descriptor)

    def test_atomic_publication_hides_partial_and_recovers_only_uncommitted_payload(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir=self.cache) as temporary:
            root = Path(temporary)
            interrupted = root / "atomic" / "origin.json"
            interrupted.parent.mkdir()
            real_write = os.write
            write_count = 0

            def interrupted_write(descriptor: int, payload: bytes) -> int:
                nonlocal write_count
                write_count += 1
                if write_count == 1:
                    return real_write(descriptor, payload[:1])
                raise OSError("injected publication interruption")

            with mock.patch(
                "validation.calibration_v2.native_adapter.factory.os.write",
                side_effect=interrupted_write,
            ):
                with self.assertRaisesRegex(
                    OSError,
                    "injected publication interruption",
                ):
                    _write_new_deferred(interrupted, b"complete-origin")
            self.assertFalse(interrupted.exists())
            self.assertEqual(list(interrupted.parent.iterdir()), [])

        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        bank = str(adapter.configuration["shared_bank_configuration_sha256"])
        root = (
            adapter.callable.failure_root.parent
            / "control-output-cache-v1"
            / "development"
            / bank
            / ("f" * 64)
        )
        adapter.callable._prepare_deferred_control_cache_directory(root)
        expected = b"complete-uncommitted-payload"
        payload_path = root / f"output-{hashlib.sha256(expected).hexdigest()}.nv12"
        payload_path.write_bytes(b"partial")
        adapter.callable._write_or_verify_deferred_control_cache(
            payload_path,
            expected,
            role="payload",
        )
        self.assertEqual(payload_path.read_bytes(), expected)

        (root / "origin.json").write_bytes(b"committed-origin-present")
        payload_path.unlink()
        payload_path.write_bytes(b"tampered")
        try:
            with self.assertRaisesRegex(
                NativeAdapterError,
                "committed cache payload differs",
            ):
                adapter.callable._write_or_verify_deferred_control_cache(
                    payload_path,
                    expected,
                    role="payload",
                )
        finally:
            payload_path.unlink()
            _write_new_deferred(payload_path, expected)
            (root / "origin.json").unlink()

    def test_close_preserves_primary_cleanup_error_and_unmodified_session_error(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir=self.cache) as temporary:
            for primary in (
                KeyboardInterrupt("primary cache verification interruption"),
                None,
            ):
                with self.subTest(primary=type(primary).__name__):
                    callable_value = object.__new__(NativeCandidateCallable)
                    callable_value._closed = False
                    callable_value._pending_control_cache_files = {}
                    callable_value._pending_control_cache_directories = (
                        {Path(temporary)} if primary is not None else set()
                    )
                    descriptor = os.open(
                        temporary,
                        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                    )
                    callable_value._native_cache_root_descriptor = descriptor
                    session_error = SystemExit(73)
                    callable_value.session = mock.Mock()
                    callable_value.session.close.side_effect = session_error
                    callable_value._verify_native_cache_root = mock.Mock()
                    callable_value._flush_deferred_control_cache_durability = (
                        mock.Mock(side_effect=primary)
                        if primary is not None
                        else mock.Mock()
                    )
                    if primary is None:
                        expected = session_error
                    else:
                        expected = primary

                    with self.assertRaises(type(expected)) as raised:
                        callable_value.close()
                    self.assertIs(raised.exception, expected)
                    callable_value.session.close.assert_called_once_with()
                    if primary is not None:
                        flush = (
                            callable_value
                            ._flush_deferred_control_cache_durability
                        )
                        flush.assert_called_once_with()
                    self.assertTrue(callable_value._closed)
                    with self.assertRaises(OSError):
                        os.fstat(descriptor)

    def test_durability_flush_orders_payload_before_origin_and_directories(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        source = _fixture()
        y = np.array(source.y, copy=True)
        y[0, 1] = 0.123456
        frame = PlanarFrame(y=y, cb=source.cb, cr=source.cr)
        request = conventional_control_request(
            "bilinear-separable-v1",
            adapter.configuration["shared_bank_configuration_sha256"],
        )
        adapter.callable.reconstruct_control(
            request,
            frame,
            _context("direct-2x"),
        )
        pending = dict(adapter.callable._pending_control_cache_files)
        self.assertEqual({binding[2] for binding in pending.values()}, {"payload", "origin"})
        origin_path, origin_binding = next(
            (path, binding)
            for path, binding in pending.items()
            if binding[2] == "origin"
        )
        staged_origin = origin_binding[3]
        self.assertIsNotNone(staged_origin)
        assert staged_origin is not None
        self.assertFalse(origin_path.exists())
        staged_metadata = os.stat(staged_origin, follow_symlinks=False)
        real_fsync = os.fsync

        def interrupt_origin_flush(descriptor: int) -> None:
            metadata = os.fstat(descriptor)
            if (
                metadata.st_dev,
                metadata.st_ino,
            ) == (staged_metadata.st_dev, staged_metadata.st_ino):
                raise OSError("injected staged-origin fsync interruption")
            real_fsync(descriptor)

        with mock.patch(
            "validation.calibration_v2.native_adapter.factory.os.fsync",
            side_effect=interrupt_origin_flush,
        ):
            with self.assertRaisesRegex(
                OSError,
                "injected staged-origin fsync interruption",
            ):
                adapter.callable.flush_control_cache_durability()
        self.assertFalse(origin_path.exists())
        self.assertTrue(staged_origin.exists())
        self.assertEqual(len(adapter.callable._pending_control_cache_files), 2)

        roles_by_identity = {
            (os.stat(binding[3] or path, follow_symlinks=False).st_dev,
             os.stat(binding[3] or path, follow_symlinks=False).st_ino): binding[2]
            for path, binding in pending.items()
        }
        observed: list[str] = []

        def observe_fsync(descriptor: int) -> None:
            metadata = os.fstat(descriptor)
            if stat.S_ISREG(metadata.st_mode):
                observed.append(roles_by_identity[(metadata.st_dev, metadata.st_ino)])
            elif stat.S_ISDIR(metadata.st_mode):
                observed.append("directory")
            real_fsync(descriptor)

        with mock.patch(
            "validation.calibration_v2.native_adapter.factory.os.fsync",
            side_effect=observe_fsync,
        ):
            commit = adapter.callable.flush_control_cache_durability()
        self.assertEqual(observed[:2], ["payload", "origin"])
        self.assertTrue(all(role == "directory" for role in observed[2:]))
        self.assertEqual(commit["pending_file_count"], 2)
        self.assertTrue(origin_path.exists())
        self.assertFalse(staged_origin.exists())

    def test_control_origin_proof_rejects_exact_field_and_cross_binding_tamper(
        self,
    ) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        source = _fixture()
        y = np.array(source.y, copy=True)
        y[1, 0] = 0.234567
        frame = PlanarFrame(y=y, cb=source.cb, cr=source.cr)
        context = _context("direct-2x")
        request = conventional_control_request(
            "bilinear-separable-v1",
            adapter.configuration["shared_bank_configuration_sha256"],
        )
        adapter.callable.reconstruct_control(request, frame, context)
        adapter.callable.flush_control_cache_durability()
        payload = _planar_to_video_range_nv12(frame)
        identity = adapter.callable._control_cache_identity(
            request=request,
            input_frame_sha256=frame_sha256(frame),
            input_nv12_sha256=hashlib.sha256(payload).hexdigest(),
            route=context.target_route,
            input_luma_dimensions=frame.y.shape,
            input_chroma_dimensions=frame.cb.shape,
            output_luma_dimensions=context.y_shape,
            output_chroma_dimensions=context.cb_shape,
        )
        origin_path = adapter.callable._control_output_cache_origin_path(
            request,
            identity,
        )
        original_payload = origin_path.read_bytes()
        original = json.loads(original_payload)

        def rehash(document: dict[str, object], field: str) -> None:
            unhashed = dict(document)
            unhashed.pop(field, None)
            document[field] = canonical_sha256(unhashed)

        for damage in (
            "proof_extra_field",
            "proof_schema",
            "proof_kind",
            "proof_input_nv12",
            "proof_output_frame",
            "request",
            "base_output_frame",
        ):
            with self.subTest(damage=damage):
                damaged = json.loads(json.dumps(original))
                proof = damaged["origin_proof"]
                base = damaged["origin_native_control_record"]
                if damage == "proof_extra_field":
                    proof["unexpected"] = "forbidden"
                elif damage == "proof_schema":
                    proof["schema_version"] = "2.0.0"
                elif damage == "proof_kind":
                    proof["artifact_kind"] = "wrong-kind"
                elif damage == "proof_input_nv12":
                    proof["input_nv12_sha256"] = "a" * 64
                elif damage == "proof_output_frame":
                    proof["output_frame_sha256"] = "b" * 64
                elif damage == "request":
                    damaged["control_request"]["control_key"] = "wrong-control"
                    rehash(damaged["control_request"], "request_sha256")
                    proof["control_request_sha256"] = damaged["control_request"][
                        "request_sha256"
                    ]
                else:
                    base["output_frame_sha256"] = "c" * 64
                    rehash(base, "record_sha256")
                    proof["origin_native_control_record_sha256"] = base[
                        "record_sha256"
                    ]
                rehash(proof, "proof_sha256")
                rehash(damaged, "origin_manifest_sha256")
                origin_path.write_bytes(canonical_json_bytes(damaged))
                try:
                    with mock.patch.object(
                        adapter.callable.session,
                        "control",
                        side_effect=AssertionError(
                            "tampered control proof must fail before Swift"
                        ),
                    ) as native_control:
                        with self.assertRaises(NativeAdapterError):
                            adapter.callable.reconstruct_control(
                                request,
                                frame,
                                context,
                            )
                    native_control.assert_not_called()
                finally:
                    origin_path.write_bytes(original_payload)

    def test_tracker_fixed_capture_uses_o1_indexed_records_only(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        profile = {"id": "fixed-indexed-capture-profile"}
        prepared = adapter.callable.prepare_non_ash_cache(
            _fixture(),
            _context("direct-2x"),
            source_asset_id="fixed-indexed-capture-source",
            degradation_profile_id=profile["id"],
            degradation_profile_sha256=canonical_sha256(profile),
        )
        tracked = _TrackedCandidateCallable(adapter, [], [])
        with mock.patch.object(
            adapter.callable,
            "non_ash_cache_preparation_records",
            side_effect=AssertionError(
                "indexed preparation capture must not snapshot the full stream"
            ),
        ):
            self.assertEqual(
                tracked.non_ash_cache_preparation_records_count(),
                1,
            )
            self.assertEqual(
                tracked.non_ash_cache_preparation_records_record(0)[
                    "cache_token"
                ],
                prepared["cache_token"],
            )
        with mock.patch.object(
            adapter.callable,
            "fixed_cache_records",
            side_effect=AssertionError("tracker must use indexed fixed records"),
        ), mock.patch.object(
            adapter.callable,
            "control_runtime_records",
            side_effect=AssertionError("tracker must use indexed control records"),
        ):
            output = tracked.reconstruct_fixed_cached(
                prepared["cache_token"],
                5,
            )
        self.assertIsInstance(output, PlanarFrame)
        self.assertEqual(tracked.fixed_cache_records_count(), 1)
        self.assertEqual(tracked.control_runtime_records_count(), 1)

    def test_same_bank_selected_controls_reopen_without_native_recompute(self) -> None:
        second_vector = dict(self.vector)
        second_vector["support_radius_step_q8_8"] = 96
        source = _fixture()
        y = np.array(source.y, copy=True)
        y[0, 0] = 0.05
        frame = PlanarFrame(y=y, cb=source.cb, cr=source.cr)
        context = _context("direct-2x")
        zero_rule = {name: 0 for name in NON_ASH_COORDINATES}

        first = self.factory(self.vector, "development")
        first_bank = first.configuration["shared_bank_configuration_sha256"]
        first_vector_hash = first.configuration["serialized_candidate_vector_sha256"]
        nearest_configuration = canonical_sha256(
            {
                "control_id": "nearest-same-writer-420v-v1",
                "shared_bank_configuration_sha256": first_bank,
            }
        )
        nearest = _control_request(
            control_key="nearest_same_writer",
            control_mode="nearest_uniform",
            configuration_sha256=nearest_configuration,
            shared_bank_configuration_sha256=first_bank,
            parameters={"control_id": "nearest-same-writer-420v-v1"},
        )
        p00_parameters = {
            "control_id": "p00-current-production-ash-baseline-v1",
            **first.callable.p00_identity(),
            "p00_backend_reset_before_frame": True,
            "p00_prior_frame_count": 0,
        }
        p00 = _control_request(
            control_key="current_production_ash",
            control_mode="p00_current_production_ash",
            configuration_sha256=canonical_sha256(first.callable.p00_identity()),
            shared_bank_configuration_sha256=first_bank,
            parameters=p00_parameters,
        )
        conventional = conventional_control_request("bilinear-separable-v1", first_bank)
        try:
            prepared = first.callable.prepare_non_ash_cache(
                frame,
                context,
                source_asset_id="selected-control-cross-candidate",
                degradation_profile_id="selected-control-profile",
                degradation_profile_sha256=canonical_sha256(
                    {"id": "selected-control-profile"}
                ),
            )
            first.callable.reconstruct_fixed_cached(prepared["cache_token"], 7)
            first.callable.reconstruct_non_ash_cached(
                prepared["cache_token"], zero_rule
            )
            for request in (conventional, nearest, p00):
                first.callable.reconstruct_control(request, frame, context)
            first_process = first.callable.session.process
        finally:
            first.callable.close()
        self.assertIsNotNone(first_process.poll())

        second = self.factory(second_vector, "development")
        self.addCleanup(second.callable.close)
        self.assertEqual(
            second.configuration["shared_bank_configuration_sha256"], first_bank
        )
        self.assertNotEqual(
            second.configuration["serialized_candidate_vector_sha256"],
            first_vector_hash,
        )
        fixed = fixed_control_request(7, first_bank)
        non_ash = non_ash_control_request(zero_rule, first_bank)
        for request in (fixed, non_ash, conventional, nearest, p00):
            second.callable.reconstruct_control(request, frame, context)
        reused_records = second.callable.control_runtime_records()
        self.assertEqual(len(reused_records), 5)
        for index, record in enumerate(reused_records):
            expected_reuse = index != 1
            self.assertEqual(record["control_cache_reused"], expected_reuse)
            self.assertEqual(
                record["current_call_analysis_grid_invocation_count"],
                0 if expected_reuse else 1,
            )
            self.assertEqual(
                record["current_call_spatial_operator_evaluation_count"], 0
                if expected_reuse
                else 1,
            )
            self.assertEqual(
                record["record_sha256"],
                canonical_sha256(
                    {key: value for key, value in record.items() if key != "record_sha256"}
                ),
            )

        state_configuration = canonical_sha256(
            {
                "control_id": "ash-state-only-base-descriptor-v1",
                "candidate_vector_sha256": second.configuration[
                    "serialized_candidate_vector_sha256"
                ],
            }
        )
        state = _control_request(
            control_key="state_only",
            control_mode="state_only",
            configuration_sha256=state_configuration,
            shared_bank_configuration_sha256=first_bank,
            parameters={
                "control_id": "ash-state-only-base-descriptor-v1",
                "candidate_vector_sha256": second.configuration[
                    "serialized_candidate_vector_sha256"
                ],
            },
        )
        second.callable.reconstruct_control(state, frame, context)
        state_record = second.callable.control_runtime_records()[-1]
        self.assertNotIn("control_cache_reused", state_record)
        self.assertEqual(
            state_record["configuration_sha256"], state["configuration_sha256"]
        )

    def test_persisted_cache_import_rejects_tampered_or_mismatched_artifacts(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        prepared = adapter.callable.prepare_non_ash_cache(
            _fixture(),
            _context("direct-2x"),
            source_asset_id="cache-import-negative",
            degradation_profile_id="cache-import-negative-profile",
            degradation_profile_sha256=canonical_sha256(
                {"id": "cache-import-negative-profile"}
            ),
        )
        token = prepared["cache_token"]
        root = adapter.callable._non_ash_cache_roots[token]
        origin = json.loads((root / "origin.json").read_bytes())
        artifact_path = root / origin["cache_artifact_filename"]
        artifact = artifact_path.read_bytes()
        configuration = adapter.configuration

        def request(path: Path, payload_sha256: str, manifest: dict[str, object]) -> dict[str, object]:
            return {
                "schema_version": "1.0.0",
                "operation": "import_non_ash_cache",
                "configuration_id": configuration["configuration_id"],
                "shared_bank_configuration_sha256": configuration[
                    "shared_bank_configuration_sha256"
                ],
                "cache_token": manifest["cache_manifest_sha256"],
                "cache_manifest": manifest,
                "cache_artifact_path": str(path),
                "cache_artifact_sha256": payload_sha256,
            }

        def rebound_manifest(**changes: object) -> dict[str, object]:
            manifest = json.loads(json.dumps(prepared["cache_manifest"]))
            manifest.update(changes)
            manifest.pop("cache_manifest_sha256")
            manifest["cache_manifest_sha256"] = canonical_sha256(manifest)
            return manifest

        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            temporary_root = Path(temporary)
            missing = temporary_root / "missing.bin"
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(
                    request(missing, origin["cache_artifact_sha256"], prepared["cache_manifest"])
                )

            symbolic = temporary_root / "symbolic.bin"
            symbolic.symlink_to(artifact_path)
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(
                    request(symbolic, origin["cache_artifact_sha256"], prepared["cache_manifest"])
                )

            feature_tamper = bytearray(artifact)
            feature_offset = (
                len(b"MIRMIR-NON-ASH-CACHE-V1\0") + 1 + 32 + 32 + 11 * 4 + 4
            )
            feature_tamper[feature_offset] ^= 0x01
            feature_path = temporary_root / "feature-tamper.bin"
            feature_path.write_bytes(feature_tamper)
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(
                    request(
                        feature_path,
                        hashlib.sha256(feature_tamper).hexdigest(),
                        prepared["cache_manifest"],
                    )
                )

            descriptor_tamper = bytearray(artifact)
            descriptor_tamper[-1] ^= 0x01
            descriptor_path = temporary_root / "descriptor-tamper.bin"
            descriptor_path.write_bytes(descriptor_tamper)
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(
                    request(
                        descriptor_path,
                        hashlib.sha256(descriptor_tamper).hexdigest(),
                        prepared["cache_manifest"],
                    )
                )

            wrong_input = rebound_manifest(input_frame_sha256="b" * 64)
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(
                    request(artifact_path, origin["cache_artifact_sha256"], wrong_input)
                )
            wrong_route = rebound_manifest(route="direct-3over2")
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(
                    request(artifact_path, origin["cache_artifact_sha256"], wrong_route)
                )
            wrong_dimensions = json.loads(json.dumps(prepared["cache_manifest"]))
            wrong_dimensions["dimensions"]["output_luma"][0] += 2
            wrong_dimensions.pop("cache_manifest_sha256")
            wrong_dimensions["cache_manifest_sha256"] = canonical_sha256(
                wrong_dimensions
            )
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(
                    request(
                        artifact_path,
                        origin["cache_artifact_sha256"],
                        wrong_dimensions,
                    )
                )

            wrong_bank_request = request(
                artifact_path,
                origin["cache_artifact_sha256"],
                prepared["cache_manifest"],
            )
            wrong_bank_request["shared_bank_configuration_sha256"] = "c" * 64
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.prepare_non_ash_cache(wrong_bank_request)

    def test_p00_compatibility_boundary_is_deterministic_and_fail_closed(self) -> None:
        payload = bytes(
            (0, 15, 16, 235, 236, 255, 100, 200, 0, 0, 255, 255)
        )
        first = _normalize_p00_compatibility_output(
            payload,
            width=4,
            height=2,
            route="direct-3over2",
        )
        second = _normalize_p00_compatibility_output(
            payload,
            width=4,
            height=2,
            route="direct-3over2",
        )
        self.assertEqual(first, second)
        normalized, evidence = first
        self.assertEqual(
            normalized,
            bytes((16, 16, 16, 235, 235, 235, 100, 200, 16, 16, 240, 240)),
        )
        self.assertEqual(normalized[8:][0::2], bytes((16, 240)))
        self.assertEqual(normalized[8:][1::2], bytes((16, 240)))
        self.assertEqual(
            evidence["clipped_sample_counts"],
            {
                "y_below_16": 2,
                "y_above_235": 2,
                "cb_below_16": 1,
                "cb_above_240": 1,
                "cr_below_16": 1,
                "cr_above_240": 1,
            },
        )
        self.assertEqual(evidence["total_clipped_sample_count"], 8)
        legal = bytes((16, 17, 234, 235, 16, 240))
        direct2, direct2_evidence = _normalize_p00_compatibility_output(
            legal,
            width=2,
            height=2,
            route="direct-2x",
        )
        self.assertEqual(direct2, legal)
        self.assertEqual(direct2_evidence["total_clipped_sample_count"], 0)
        direct2_excursion = bytes((15, 16, 235, 236, 16, 240))
        direct2_clipped, direct2_clip_evidence = (
            _normalize_p00_compatibility_output(
                direct2_excursion,
                width=2,
                height=2,
                route="direct-2x",
            )
        )
        self.assertEqual(direct2_clipped, bytes((16, 16, 235, 235, 16, 240)))
        self.assertEqual(
            [
                index
                for index, (raw, clipped) in enumerate(
                    zip(direct2_excursion, direct2_clipped)
                )
                if raw != clipped
            ],
            [0, 3],
        )
        self.assertEqual(
            direct2_clip_evidence["direct_2x_postprocess_behavior"],
            "unchanged exact 2x; compatibility normalization only clips "
            "nominal-range excursions",
        )
        for invalid in (
            (bytes(6), 3, 2, "direct-2x"),
            (bytes(6), 2, 0, "direct-2x"),
            (bytes(5), 2, 2, "direct-2x"),
            (bytes(6), 2, 2, "foreign-route"),
        ):
            with self.subTest(invalid=invalid):
                with self.assertRaises(NativeAdapterError):
                    _normalize_p00_compatibility_output(
                        invalid[0],
                        width=invalid[1],
                        height=invalid[2],
                        route=invalid[3],
                    )

    def test_p00_control_is_commit_pinned_reset_per_frame_and_route_complete(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        identity = adapter.callable.p00_identity()
        self.assertEqual(
            identity["commit"], "20dc1a9e8057d25b0430bfcd4c09e7806dc22d0a"
        )
        self.assertEqual(
            identity["backend_source_sha256"],
            "3c3a0652441fe6f1848e096358d6631c64611827f5fdfd03f5e8045b365d3343",
        )
        parameters = {
            "control_id": "p00-current-production-ash-baseline-v1",
            **identity,
            "p00_backend_reset_before_frame": True,
            "p00_prior_frame_count": 0,
        }
        request = _control_request(
            control_key="current_production_ash",
            control_mode="p00_current_production_ash",
            configuration_sha256=canonical_sha256(identity),
            shared_bank_configuration_sha256=adapter.configuration[
                "shared_bank_configuration_sha256"
            ],
            parameters=parameters,
        )
        first = adapter.callable.reconstruct_control(
            request, _fixture(), _context("direct-2x")
        )
        second = adapter.callable.reconstruct_control(
            request, _fixture(), _context("direct-2x")
        )
        direct3 = adapter.callable.reconstruct_control(
            request, _fixture(), _context("direct-3over2")
        )
        self.assertEqual(frame_sha256(first), frame_sha256(second))
        self.assertEqual(direct3.y.shape, (6, 6))
        records = adapter.callable.control_runtime_records()
        self.assertEqual(len(records), 3)
        for record in records:
            self.assertTrue(record["p00_backend_reset_before_frame"])
            self.assertEqual(record["p00_prior_frame_count"], 0)
            self.assertEqual(record["p00_commit"], identity["commit"])
            self.assertEqual(
                record["p00_executable_sha256"], identity["executable_sha256"]
            )
            self.assertRegex(record["p00_adapter_source_sha256"], "^[0-9a-f]{64}$")
            self.assertTrue(record["p00_execution_compatibility_wrapper"])
            self.assertFalse(record["p00_source_byte_identical_claimed_for_adapter"])
            self.assertEqual(
                record["p00_lanczos_synchronization_delta"],
                "commit_then_waitUntilCompleted_no_post_commit_handler",
            )
            normalization = record[
                "p00_compatibility_boundary_normalization"
            ]
            self.assertEqual(
                normalization["method"],
                "p00_compatibility_nominal_video_range_clip_v1",
            )
            self.assertRegex(
                normalization["raw_payload_sha256"],
                "^[0-9a-f]{64}$",
            )
            self.assertRegex(
                normalization["normalized_payload_sha256"],
                "^[0-9a-f]{64}$",
            )
            self.assertEqual(
                normalization["raw_payload_size_bytes"],
                normalization["normalized_payload_size_bytes"],
            )
            for plane, nominal in (
                ("y", (16, 235)),
                ("cb", (16, 240)),
                ("cr", (16, 240)),
            ):
                observed = normalization["normalized_code_ranges"][plane]
                self.assertGreaterEqual(observed[0], nominal[0])
                self.assertLessEqual(observed[1], nominal[1])
            if record["target_route"] == "direct-2x":
                self.assertEqual(
                    record["p00_invocation_postprocess"],
                    "not_applicable_exact_2x",
                )
                self.assertEqual(
                    normalization["direct_2x_postprocess_behavior"],
                    "unchanged exact 2x; compatibility normalization only "
                    "clips nominal-range excursions",
                )
            else:
                self.assertEqual(
                    record["p00_invocation_postprocess"],
                    "baseline_MPSImageLanczosScale_after_exact_2x",
                )
            self.assertEqual(
                record["record_sha256"],
                canonical_sha256(
                    {key: value for key, value in record.items() if key != "record_sha256"}
                ),
            )

    def test_executable_and_candidate_luts_are_cache_hits_for_second_factory(self) -> None:
        first = self.factory(self.vector, "development")
        first.callable.close()
        second_factory = make_native_candidate_adapter_factory(
            REPOSITORY_ROOT,
            cache_root=self.cache,
            timeout_seconds=300,
            bound_inputs=self.bound,
        )
        self.assertFalse(second_factory.builder.executable.compiled_now)
        second = second_factory(self.vector, "development")
        self.addCleanup(second.callable.close)
        self.assertEqual(second_factory.builder.candidate_compile_invocation_count, 0)
        second.reconstruct(_fixture(), _context("direct-2x"))

    def test_symlink_input_is_rejected_without_output_publication(self) -> None:
        adapter = self.factory(self.vector, "development")
        self.addCleanup(adapter.callable.close)
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            target = root / "target.nv12"
            target.write_bytes(_planar_to_video_range_nv12(_fixture()))
            symbolic = root / "input.nv12"
            symbolic.symlink_to(target.name)
            output = root / "output.nv12"
            configuration = adapter.configuration
            request = {
                "schema_version": "1.0.0",
                "operation": "process_batch",
                "configuration_id": configuration["configuration_id"],
                "compiler_inputs_sha256": configuration["compiler_inputs_sha256"],
                "frames": [
                    {
                        "request_id": "symlink-rejection",
                        "route": "direct-2x",
                        "input_path": str(symbolic),
                        "input_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                        "input_width": 4,
                        "input_height": 4,
                        "output_path": str(output),
                        "output_width": 8,
                        "output_height": 8,
                        "pixel_format": "420v",
                        "matrix": "BT.709",
                        "range": "video",
                        "chroma_siting": "left",
                    }
                ],
            }
            with self.assertRaises(NativeAdapterError):
                adapter.callable.session.request(request)
            self.assertFalse(output.exists())

    def test_symlink_lut_is_rejected_before_session_publication(self) -> None:
        native = self.factory.builder.ensure_configuration(
            vector=self.vector,
            plan=self.factory.plan,
            bound=self.bound,
        )
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            symbolic = Path(temporary) / "route.ashlut"
            symbolic.symlink_to(native.route_paths["direct-2x"])
            substituted = replace(
                native,
                route_paths={**native.route_paths, "direct-2x": symbolic},
            )
            with self.assertRaises(NativeAdapterError):
                NativeSwiftSession(
                    self.factory.builder.executable,
                    substituted,
                    timeout_seconds=30,
                )


if __name__ == "__main__":
    unittest.main()
