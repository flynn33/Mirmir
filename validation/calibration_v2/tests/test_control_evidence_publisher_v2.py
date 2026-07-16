from __future__ import annotations

import json
from pathlib import Path
from typing import Mapping

import numpy as np

import validation.calibration_v2.control_authorization_v2 as authorization
from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    ControlAuthorizationScopeV2,
    ControlAuthorizationVerifierV2,
    ControlExecutionSemanticContextV2,
    TypedArtifactBindingV2,
    canonical_json_bytes_v2,
)
from validation.calibration_v2.control_evidence_publisher_v2 import (
    RawControlAuthorizationArtifactPublisherV2,
)
from validation.calibration_v2.production_evaluator import (
    ControlExecutionProducerIdentityV2,
    MemoryEvidenceStore,
    ProductionCandidateEvaluator,
    _PreparedControlCase,
    canonical_control_measurement_frame_bytes_v2,
    conventional_control_request,
    decode_control_measurement_frame_bytes_v2,
    degradation_native_input,
)
from validation.quality.src.mirmir_quality.arrays import (
    PlanarFrame,
    frame_sha256,
    resize_bilinear,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_sha256,
    read_json,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _round_trip_locked_bt709_video_range_nv12,
)


ROOT = Path(__file__).resolve().parents[3]
DEGRADATION_POLICY = read_json(
    ROOT / "validation" / "quality" / "policies" / "degradation-policy.json"
)
BANK = "1" * 64
RUN_ID = "raw-control-publication-integration"
ALGORITHM = "bilinear-separable-v1"


def _boundary_frame(frame: PlanarFrame) -> PlanarFrame:
    _, reopened = _round_trip_locked_bt709_video_range_nv12(frame)
    return reopened


def _native_reconstruct(
    low_resolution: PlanarFrame,
    context: CandidateContext,
) -> PlanarFrame:
    reconstructed = PlanarFrame(
        y=np.clip(resize_bilinear(low_resolution.y, context.y_shape), 0.0, 1.0),
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
    return _boundary_frame(reconstructed)


class _TrackedConventionalControl:
    def __init__(self) -> None:
        self.records: list[Mapping[str, object]] = []

    def __call__(
        self,
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        return _native_reconstruct(frame, context)

    def control_runtime_records(self):
        return tuple(self.records)

    def reconstruct_control(
        self,
        request: Mapping[str, object],
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        output = _native_reconstruct(frame, context)
        parameters = dict(request["parameters"])
        record = {
            "control_key": request["control_key"],
            "control_mode": request["control_mode"],
            "request_sha256": request["request_sha256"],
            "configuration_sha256": request["configuration_sha256"],
            "shared_bank_configuration_sha256": request[
                "shared_bank_configuration_sha256"
            ],
            "input_frame_sha256": frame_sha256(frame),
            "output_frame_sha256": frame_sha256(output),
            "target_route": context.target_route,
            "parameters": parameters,
            "parameters_sha256": canonical_sha256(parameters),
        }
        record["record_sha256"] = canonical_sha256(record)
        self.records.append(record)
        return output


def _producer_identity(adapter_configuration_sha256: str):
    physical_items = [[f"field_{index:02d}", index] for index in range(48)]
    adapter_identity = {
        "adapter_configuration_sha256": adapter_configuration_sha256,
        "native_source_manifest_sha256": "2" * 64,
        "native_executable_sha256": "3" * 64,
        "native_implementation_source_sha256": "4" * 64,
    }
    return ControlExecutionProducerIdentityV2(
        physical_candidate_items_bytes=canonical_json_bytes_v2(physical_items),
        candidate_vector_sha256=canonical_sha256(
            [item[1] for item in physical_items]
        ),
        adapter_configuration_sha256=adapter_configuration_sha256,
        authenticated_adapter_identity_bytes=canonical_json_bytes_v2(
            adapter_identity
        ),
    )


def _prepared_cases() -> tuple[_PreparedControlCase, ...]:
    values = []
    for source_index, route in enumerate(("direct-2x", "direct-3over2")):
        target_size = 128 if route == "direct-2x" else 96
        input_size = 64
        y_index, x_index = np.indices((target_size, target_size), dtype=np.float64)
        y = 0.2 + 0.55 * (
            (3.0 * x_index + 5.0 * y_index + source_index) % 47.0
        ) / 46.0
        chroma_size = target_size // 2
        cy, cx = np.indices((chroma_size, chroma_size), dtype=np.float64)
        target = _boundary_frame(
            PlanarFrame(
                y=y,
                cb=0.09 * np.sin((cx + source_index) / 7.0),
                cr=0.08 * np.cos((cy + source_index) / 9.0),
            )
        )
        context = CandidateContext(
            y_shape=target.y.shape,
            cb_shape=target.cb.shape,
            cr_shape=target.cr.shape,
            target_route=route,
        )
        profiles = [
            profile
            for profile in DEGRADATION_POLICY["profiles"]
            if profile.get("target_route") == route
        ][:3]
        assert len(profiles) == 3
        for profile in profiles:
            low_resolution = degradation_native_input(target, profile)
            assert low_resolution.y.shape == (input_size, input_size)
            values.append(
                _PreparedControlCase(
                    metadata={
                        "source_asset_id": f"source-{source_index}",
                        "source_family_id": f"family-{source_index}",
                        "categories": ["natural", f"route-{source_index}"],
                        "target_route": route,
                    },
                    profile=profile,
                    target=target,
                    low_resolution=low_resolution,
                    context=context,
                )
            )
    return tuple(values)


def test_uniform_control_publishes_raw_v2_closure_and_replays_without_writer() -> None:
    configuration = {"shared_bank_configuration_sha256": BANK}
    configuration_sha256 = canonical_sha256(configuration)
    producer_identity = _producer_identity(configuration_sha256)
    native = _TrackedConventionalControl()
    adapter = CandidateAdapter(
        candidate_id="raw-control-publication-adapter",
        configuration=configuration,
        configuration_sha256=configuration_sha256,
        callable=native,
    )
    publisher = RawControlAuthorizationArtifactPublisherV2(
        run_id=RUN_ID,
        control_execution_producer_identity=producer_identity,
    )
    evaluator = object.__new__(ProductionCandidateEvaluator)
    evaluator.degradation_policy = dict(DEGRADATION_POLICY)
    evaluator.evidence_store = MemoryEvidenceStore()
    evaluator._control_authorization_artifact_publisher_v2 = publisher
    request = conventional_control_request(ALGORITHM, BANK)

    aggregate = evaluator._uniform_control_evidence(
        adapter=adapter,
        prepared=_prepared_cases(),
        request=request,
        split="development",
        stable_id=ALGORITHM,
    )
    publication = aggregate.authorization_v2
    assert publication is not None
    assert publication["comparison_domains"] == ["engine_raw"]
    assert len(native.records) == 6
    snapshot = publisher.snapshot_for(publication)
    dependencies = publisher.dependency_bindings_for(publication)
    assert isinstance(snapshot, AuthenticatedClosureSnapshotV2)

    observed_contexts = []

    def authenticate_execution(
        binding: TypedArtifactBindingV2,
        document: Mapping[str, object],
        context: ControlExecutionSemanticContextV2,
    ) -> Mapping[str, object]:
        observed_contexts.append(context)
        assert context.expected_control_request_bytes == canonical_json_bytes_v2(
            request
        )
        assert (
            context.authenticated_adapter_identity_bytes
            == producer_identity.authenticated_adapter_identity_bytes
        )
        assert (
            context.physical_candidate_items_bytes
            == producer_identity.physical_candidate_items_bytes
        )
        assert canonical_json_bytes_v2(document) == context.raw_output_frame_bytes[:0] + snapshot.payload(
            binding.closure_binding()
        )
        identity = json.loads(context.source_profile_identity_bytes)
        profile_record = json.loads(context.degradation_profile_bytes)
        assert profile_record["profile_definition"]["id"] == identity[
            "degradation_profile_id"
        ]
        low_resolution = decode_control_measurement_frame_bytes_v2(
            context.low_resolution_input_frame_bytes
        )
        raw_output = decode_control_measurement_frame_bytes_v2(
            context.raw_output_frame_bytes
        )
        replay_context = CandidateContext(
            y_shape=raw_output.y.shape,
            cb_shape=raw_output.cb.shape,
            cr_shape=raw_output.cr.shape,
            target_route=identity["target_route"],
        )
        replay = _native_reconstruct(low_resolution, replay_context)
        assert (
            canonical_control_measurement_frame_bytes_v2(replay)
            == context.raw_output_frame_bytes
        )
        return dict(document)

    resolver = authorization._SnapshotResolverV2(snapshot, dependencies)
    verifier = ControlAuthorizationVerifierV2(
        control_execution_semantic_verifier=authenticate_execution,
        control_execution_producer_identity=producer_identity,
    )
    scope = ControlAuthorizationScopeV2(
        run_id=RUN_ID,
        split="development",
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=str(DEGRADATION_POLICY["policy_sha256"]),
        source_profile_matrix_sha256=str(
            publication["source_profile_matrix_sha256"]
        ),
    )
    objective = verifier._aggregate_from_bindings(
        objective_binding=TypedArtifactBindingV2.from_document(
            publication["objective_summary"]
        ),
        output_binding=TypedArtifactBindingV2.from_document(
            publication["output_manifest"]
        ),
        resolver=resolver,
        scope=scope,
        expected_family="conventional",
        expected_split="development",
        expected_stable_id=ALGORITHM,
        expected_control_configuration_sha256=str(
            request["configuration_sha256"]
        ),
        expected_control_request=request,
    )
    resolver.finish()
    assert objective == aggregate.objective_means
    assert len(observed_contexts) == 6
