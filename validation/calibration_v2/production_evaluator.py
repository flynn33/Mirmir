"""Production-only P06 quality evaluation and same-bank control selection.

This module owns no corpus paths.  Target pixels arrive through a split-scoped,
one-use capability.  Native control pixels arrive through the callable attached
to the tracked ``CandidateAdapter``.  Writer artifacts are accessed through a
hash-addressed capability.  Missing capabilities or evidence fail closed.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
from typing import Callable, Dict, Mapping, MutableMapping, Optional, Protocol, Sequence, Tuple

import numpy as np

from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.degradation import apply_degradation
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
    validate_schema,
)
from validation.quality.src.mirmir_quality.metrics import (
    channel_psnr,
    ms_ssim_detail,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _isolated_candidate_input,
    _round_trip_locked_bt709_video_range_nv12,
)


SHA256_LENGTH = 64
ROUTES = ("direct-2x", "direct-3over2")
DOMAINS = ("engine_raw", "container_decoded")
FIXED_DESCRIPTOR_IDS = tuple(range(16))
CONVENTIONAL_ALGORITHM_IDS = (
    "bilinear-separable-v1",
    "keys-cubic-a-minus-0.5-separable-v1",
    "lanczos3-separable-v1",
)
NON_ASH_SELECTOR_ID = "continuous-linear-bank-selector-q15-v1"
NON_ASH_SELECTOR_ID_V2 = "continuous-linear-bank-selector-q15-v2"
CONTROL_MEASUREMENT_FRAME_ENCODING_V2 = (
    "mirmir-control-measurement-f64be-v2"
)
_CONTROL_MEASUREMENT_FRAME_MAGIC_V2 = (
    b"MIRMIR-CONTROL-MEASUREMENT-F64BE-V2\0"
)
NON_ASH_VALUES = (-384, -256, -128, 0, 128, 256, 384)
FULL_ASH_MAXIMUM_CANDIDATE_EVALUATION_BUDGET = 1345
NON_ASH_COORDINATES = tuple(
    [f"bias_descriptor_{index:02d}_q8_8" for index in range(16)]
    + [
        "weight_magnitude_q8_8",
        "weight_coherence_q8_8",
        "weight_texture_q8_8",
        "weight_risk_q8_8",
        "weight_chroma_alignment_q8_8",
        "weight_orientation_cos_q8_8",
        "weight_orientation_sin_q8_8",
        "weight_noise_q8_8",
        "weight_horizontal_phase_q8_8",
        "weight_vertical_phase_q8_8",
        "weight_route_q8_8",
    ]
)
SELECTION_METRICS = (
    "y_psnr_db",
    "y_ms_ssim",
    "y_ssim",
    "cb_psnr_db",
    "cr_psnr_db",
)
SELECTION_TUPLE_DESCRIPTION = (
    "lexicographically maximize validation engine_raw corpus means: "
    "Y PSNR, Y MS-SSIM, Y SSIM, Cb PSNR, Cr PSNR; then ascending stable ID"
)
P00_COMMIT = "20dc1a9e8057d25b0430bfcd4c09e7806dc22d0a"
P00_BACKEND_SHA256 = (
    "3c3a0652441fe6f1848e096358d6631c64611827f5fdfd03f5e8045b365d3343"
)
SCHEMAS_ROOT = Path(__file__).resolve().parent / "schemas"
SELECTION_OBJECTIVE = {
    "comparison_domain": "engine_raw",
    "row_scope": "natural corpus asset rows only",
    "per_source_aggregation": (
        "unweighted arithmetic mean across that source's locked "
        "degradation-profile rows"
    ),
    "across_source_aggregation": (
        "unweighted arithmetic mean across source assets"
    ),
    "direction": "lexicographically maximize",
    "metric_order": list(SELECTION_METRICS),
}
COMMON_CONTROL_BOUNDARY_CONTRACT = {
    "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
    "chroma_conversion": (
        "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once"
    ),
    "quantization": "common_420v_round_to_nearest_even",
    "output_reopen_verification": True,
}


class ProductionEvaluatorError(ValueError):
    """A quality input, control, metric, or evidence invariant failed."""


class SplitView(Protocol):
    split: str
    cases: Tuple[Mapping[str, object], ...]

    def load_case(self, opaque_case_token: str) -> PlanarFrame:
        ...


class DegradationCache(Protocol):
    degradation_policy_sha256: str

    def get_or_create(
        self,
        *,
        source_asset_id: str,
        target_frame: PlanarFrame,
        target_frame_sha256: str,
        profile_id: str,
        builder: Callable[[PlanarFrame], PlanarFrame],
    ) -> PlanarFrame:
        ...


@dataclass(frozen=True)
class WriterRoundTrip:
    """One isolated writer result with no filesystem path exposure."""

    decoded_frame: PlanarFrame
    input_frame_sha256: str
    decoded_frame_sha256: str
    settings_sha256: str
    encoded_sha256: str
    report_sha256: str
    evidence_sha256: str
    reopened_and_verified: bool


@dataclass(frozen=True)
class ControlExecutionProducerIdentityV2:
    """Authenticated producer identity supplied outside artifact evidence."""

    physical_candidate_items_bytes: bytes
    candidate_vector_sha256: str
    adapter_configuration_sha256: str
    authenticated_adapter_identity_bytes: bytes

    def __post_init__(self) -> None:
        if (
            type(self.physical_candidate_items_bytes) is not bytes
            or not self.physical_candidate_items_bytes
            or type(self.authenticated_adapter_identity_bytes) is not bytes
            or not self.authenticated_adapter_identity_bytes
        ):
            raise ProductionEvaluatorError(
                "control execution producer identity bytes are invalid"
            )
        _require_sha256(
            self.candidate_vector_sha256,
            "control producer candidate-vector hash",
        )
        _require_sha256(
            self.adapter_configuration_sha256,
            "control producer adapter-configuration hash",
        )
        try:
            physical_items = json.loads(self.physical_candidate_items_bytes)
            adapter_identity = json.loads(
                self.authenticated_adapter_identity_bytes
            )
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProductionEvaluatorError(
                "control execution producer identity JSON is invalid"
            ) from exc
        if (
            canonical_json_bytes(physical_items)
            != self.physical_candidate_items_bytes
            or not isinstance(physical_items, list)
            or len(physical_items) != 48
            or any(
                not isinstance(item, list)
                or len(item) != 2
                or not isinstance(item[0], str)
                or not item[0]
                for item in physical_items
            )
            or len({item[0] for item in physical_items}) != 48
            or canonical_sha256([item[1] for item in physical_items])
            != self.candidate_vector_sha256
            or canonical_json_bytes(adapter_identity)
            != self.authenticated_adapter_identity_bytes
            or not isinstance(adapter_identity, dict)
            or adapter_identity.get("adapter_configuration_sha256")
            != self.adapter_configuration_sha256
        ):
            raise ProductionEvaluatorError(
                "control execution producer identity is inconsistent"
            )


@dataclass(frozen=True)
class ControlWriterProducerIdentityV2:
    """Authenticated writer identity supplied outside artifact evidence."""

    writer_settings_bytes: bytes
    writer_settings_sha256: str
    authenticated_writer_identity_bytes: bytes

    def __post_init__(self) -> None:
        if (
            type(self.writer_settings_bytes) is not bytes
            or not self.writer_settings_bytes
            or type(self.authenticated_writer_identity_bytes) is not bytes
            or not self.authenticated_writer_identity_bytes
        ):
            raise ProductionEvaluatorError(
                "control writer producer identity bytes are invalid"
            )
        _require_sha256(
            self.writer_settings_sha256,
            "control producer writer-settings hash",
        )
        try:
            writer_settings = json.loads(self.writer_settings_bytes)
            writer_identity = json.loads(
                self.authenticated_writer_identity_bytes
            )
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProductionEvaluatorError(
                "control writer producer identity JSON is invalid"
            ) from exc
        if (
            canonical_json_bytes(writer_settings) != self.writer_settings_bytes
            or not isinstance(writer_settings, dict)
            or not writer_settings
            or canonical_sha256(writer_settings) != self.writer_settings_sha256
            or canonical_json_bytes(writer_identity)
            != self.authenticated_writer_identity_bytes
            or not isinstance(writer_identity, dict)
        ):
            raise ProductionEvaluatorError(
                "control writer producer identity is inconsistent"
            )


@dataclass(frozen=True)
class ControlExecutionSemanticContextV2:
    """Immutable snapshot bytes required for restart-safe control replay."""

    expected_scope_bytes: bytes
    expected_control_request_bytes: bytes
    source_profile_identity_bytes: bytes
    source_target_provenance_bytes: bytes
    source_target_frame_bytes: bytes
    degradation_profile_bytes: bytes
    low_resolution_input_frame_bytes: bytes
    raw_output_frame_bytes: bytes
    physical_candidate_items_bytes: bytes
    candidate_vector_sha256: str
    adapter_configuration_sha256: str
    authenticated_adapter_identity_bytes: bytes

    def __post_init__(self) -> None:
        byte_fields = (
            self.expected_scope_bytes,
            self.expected_control_request_bytes,
            self.source_profile_identity_bytes,
            self.source_target_provenance_bytes,
            self.source_target_frame_bytes,
            self.degradation_profile_bytes,
            self.low_resolution_input_frame_bytes,
            self.raw_output_frame_bytes,
            self.physical_candidate_items_bytes,
            self.authenticated_adapter_identity_bytes,
        )
        if any(type(value) is not bytes or not value for value in byte_fields):
            raise ProductionEvaluatorError(
                "control execution semantic context bytes are invalid"
            )
        _require_sha256(
            self.candidate_vector_sha256,
            "control semantic candidate-vector hash",
        )
        _require_sha256(
            self.adapter_configuration_sha256,
            "control semantic adapter-configuration hash",
        )


@dataclass(frozen=True)
class ControlWriterSemanticContextV2:
    """Immutable snapshot bytes required for restart-safe writer replay."""

    expected_scope_bytes: bytes
    expected_control_request_bytes: bytes
    source_profile_identity_bytes: bytes
    degradation_profile_bytes: bytes
    raw_output_frame_bytes: bytes
    decoded_output_frame_bytes: bytes
    decoded_payload_bytes: bytes
    encoded_container_bytes: bytes
    writer_report_bytes: bytes
    writer_provenance_bytes: bytes
    writer_settings_bytes: bytes
    writer_settings_sha256: str
    authenticated_writer_identity_bytes: bytes

    def __post_init__(self) -> None:
        byte_fields = (
            self.expected_scope_bytes,
            self.expected_control_request_bytes,
            self.source_profile_identity_bytes,
            self.degradation_profile_bytes,
            self.raw_output_frame_bytes,
            self.decoded_output_frame_bytes,
            self.decoded_payload_bytes,
            self.encoded_container_bytes,
            self.writer_report_bytes,
            self.writer_provenance_bytes,
            self.writer_settings_bytes,
            self.authenticated_writer_identity_bytes,
        )
        if any(type(value) is not bytes or not value for value in byte_fields):
            raise ProductionEvaluatorError(
                "control writer semantic context bytes are invalid"
            )
        _require_sha256(
            self.writer_settings_sha256,
            "control semantic writer-settings hash",
        )


class WriterCapability(Protocol):
    settings_sha256: str

    def round_trip(
        self,
        *,
        control_key: str,
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> WriterRoundTrip:
        ...

    def reopen_evidence(self, evidence_sha256: str) -> Mapping[str, object]:
        ...


@dataclass(frozen=True)
class RawControlMeasurementPublicationV2:
    """Exact producer inputs for one raw V2 control measurement row."""

    metadata: Mapping[str, object]
    profile: Mapping[str, object]
    target: PlanarFrame
    low_resolution: PlanarFrame
    raw_output: PlanarFrame
    native_execution_record: Mapping[str, object]


class ControlAuthorizationArtifactPublisherV2(Protocol):
    run_id: str

    def publish_raw_control_aggregate_v2(
        self,
        *,
        adapter: CandidateAdapter,
        run_id: str,
        split: str,
        control_family: str,
        stable_id: object,
        shared_bank_configuration_sha256: str,
        degradation_policy_sha256: str,
        control_request: Mapping[str, object],
        rows: Sequence[RawControlMeasurementPublicationV2],
    ) -> Mapping[str, object]:
        ...


class AnalyticFixtureCapability(Protocol):
    manifest_sha256: str

    def evaluate(
        self,
        *,
        adapter: CandidateAdapter,
        selection_bundle: "ControlSelectionBundle",
        comparison_identities: Mapping[str, object],
    ) -> Mapping[str, object]:
        ...


class EvidenceStore(Protocol):
    def publish(self, document: Mapping[str, object]) -> Mapping[str, object]:
        ...

    def publish_control_aggregate_document(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        ...

    def reopen(self, sha256: str) -> Mapping[str, object]:
        ...

    def preserve_failure(self, document: Mapping[str, object]) -> Mapping[str, object]:
        ...

    def publish_control_aggregate_origin(
        self,
        *,
        identity: Mapping[str, object],
        origin: Mapping[str, object],
    ) -> Mapping[str, object]:
        ...

    def reopen_control_aggregate_origin(
        self,
        identity: Mapping[str, object],
    ) -> Optional[Mapping[str, object]]:
        ...

    def flush_control_aggregate_dependencies(
        self,
        ordered_document_sha256_values: Sequence[str],
    ) -> Mapping[str, object]:
        ...

    def publish_control_aggregate_origins_batch(
        self,
        entries: Sequence[Mapping[str, Mapping[str, object]]],
    ) -> Mapping[str, object]:
        ...


class DevelopmentControlSelectionCache(Protocol):
    """Development-only durable origin store for bank-level selections."""

    implementation_identity: Mapping[str, object]

    def reopen(
        self,
        identity: Mapping[str, object],
    ) -> Optional[Mapping[str, object]]:
        ...

    def publish(
        self,
        *,
        identity: Mapping[str, object],
        origin: Mapping[str, object],
    ) -> Mapping[str, object]:
        ...


class EvaluationEvidenceProvider(Protocol):
    """Formula-derived checks, performance, and dispatch evidence boundary."""

    def evaluation_evidence(
        self,
        *,
        adapter: CandidateAdapter,
        vector: Mapping[str, object],
        split: str,
        prepared_cases: Sequence["_PreparedControlCase"],
        corpus_asset_results: Sequence[Mapping[str, object]],
        analytic_fixture_results: Sequence[Mapping[str, object]],
        selection_bundle: "ControlSelectionBundle",
        comparison_identities: Mapping[str, object],
        candidate_evidence_policy: Mapping[str, object],
        candidate_evidence_policy_sha256: str,
        candidate_evidence_source_sha256_bindings: Sequence[Tuple[str, str]],
        native_runtime_records: Sequence[Mapping[str, object]],
        native_control_records: Sequence[Mapping[str, object]],
    ) -> Mapping[str, object]:
        ...


_CONTROL_AGGREGATE_ORIGIN_FIELDS = {
    "schema_version",
    "artifact_kind",
    "identity",
    "identity_sha256",
    "aggregate",
    "ordered_output_proofs",
    "native_dependency_commit_sha256",
    "native_dependency_evidence_sha256",
    "evidence_dependency_commit_sha256",
    "evidence_dependency_evidence_sha256",
    "origin_manifest_sha256",
}
_CONTROL_AGGREGATE_BINDING_FIELDS = {
    "split",
    "stable_id",
    "shared_bank_configuration_sha256",
    "degradation_policy_sha256",
    "objective_means",
    "objective_summary_sha256",
    "output_manifest_sha256",
}
_CONTROL_AGGREGATE_OUTPUT_PROOF_FIELDS = {
    "ordinal",
    "cache_token",
    "output_frame_sha256",
    "native_record_sha256",
}
_PENDING_CONTROL_AGGREGATE_ORIGIN_FIELDS = {
    "identity",
    "aggregate",
    "ordered_output_proofs",
}
_EVIDENCE_DEPENDENCY_COMMIT_FIELDS = {
    "schema_version",
    "artifact_kind",
    "ordered_document_sha256_values",
    "document_count",
    "documents_directory_identity_sha256",
    "committed",
    "record_sha256",
}
_EVIDENCE_DEPENDENCY_COMMIT_RESULT_FIELDS = {
    "record",
    "document_sha256",
    "size_bytes",
}
_NATIVE_DEPENDENCY_COMMIT_FIELDS = {
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
}
_ORIGIN_BATCH_COMMIT_FIELDS = {
    "schema_version",
    "artifact_kind",
    "published_count",
    "ordered_identity_sha256_values",
    "ordered_origin_manifest_sha256_values",
    "record_sha256",
}
_NON_ASH_AGGREGATE_CONTEXT_FIELDS = {
    "degradation_policy_file_sha256",
    "metric_policy_file_sha256",
    "metric_policy_sha256",
    "baseline_ablation_contract_file_sha256",
    "baseline_selector_contract",
    "baseline_selector_contract_sha256",
    "sample_lock_file_sha256",
    "corpus_manifest_sha256",
    "corpus_lock_bundle_sha256",
    "common_boundary_contract",
    "common_boundary_contract_sha256",
    "native_implementation_closure",
    "quality_implementation_closure",
}
_NON_ASH_AGGREGATE_IDENTITY_FIELDS = {
    "schema_version",
    "artifact_kind",
    "split",
    "rule_configuration",
    "rule_sha256",
    "control_configuration_sha256",
    "shared_bank_configuration_sha256",
    "degradation_policy_file_sha256",
    "degradation_policy_sha256",
    "metric_policy_file_sha256",
    "metric_policy_sha256",
    "baseline_ablation_contract_file_sha256",
    "baseline_selector_contract",
    "baseline_selector_contract_sha256",
    "sample_lock_file_sha256",
    "corpus_manifest_sha256",
    "corpus_lock_bundle_sha256",
    "ordered_input_bindings",
    "common_boundary_contract",
    "common_boundary_contract_sha256",
    "native_implementation_closure",
    "quality_implementation_closure",
}
_NON_ASH_AGGREGATE_INPUT_FIELDS = {
    "ordinal",
    "source_asset_id",
    "source_family_id",
    "categories",
    "target_route",
    "degradation_profile_id",
    "degradation_profile_sha256",
    "target_frame_sha256",
    "input_frame_sha256",
    "cache_token",
    "cache_identity_sha256",
    "cache_origin_manifest_sha256",
}
_DEVELOPMENT_SELECTION_CACHE_SCHEMA = (
    "development-control-selection-cache-v1.schema.json"
)
_DEVELOPMENT_SELECTION_CACHE_IDENTITY_FIELDS = {
    "schema_version",
    "artifact_kind",
    "split",
    "selection_stage",
    "shared_bank_configuration_sha256",
    "degradation_policy_sha256",
    "aggregate_identity_context",
    "ordered_input_bindings",
    "selection_search_contract",
    "implementation_closure",
    "reuse_scope",
}
_DEVELOPMENT_SELECTION_CACHE_IMPLEMENTATION_FIELDS = {
    "production_evaluator_source_sha256",
    "storage_implementation_sha256",
    "cache_schema_sha256",
}
_DEVELOPMENT_SELECTION_CACHE_CAPABILITY_IMPLEMENTATION_FIELDS = {
    "storage_implementation_sha256",
    "cache_schema_sha256",
}


def _validate_control_aggregate_origin_envelope(
    origin: Mapping[str, object],
    *,
    identity: Mapping[str, object],
) -> Mapping[str, object]:
    """Validate the store-level immutable origin envelope and self-hash."""

    if (
        not isinstance(origin, dict)
        or set(origin) != _CONTROL_AGGREGATE_ORIGIN_FIELDS
    ):
        raise ProductionEvaluatorError("control-aggregate origin field set differs")
    canonical_identity = json.loads(canonical_json_bytes(identity))
    identity_sha256 = canonical_sha256(canonical_identity)
    aggregate = origin.get("aggregate")
    proofs = origin.get("ordered_output_proofs")
    unhashed = dict(origin)
    declared = unhashed.pop("origin_manifest_sha256", None)
    if (
        origin.get("schema_version") != "1.0.0"
        or origin.get("artifact_kind")
        != "p06_persisted_non_ash_control_aggregate_origin"
        or origin.get("identity") != canonical_identity
        or origin.get("identity_sha256") != identity_sha256
        or not isinstance(aggregate, dict)
        or set(aggregate) != _CONTROL_AGGREGATE_BINDING_FIELDS
        or aggregate.get("split") not in {"development", "validation"}
        or not isinstance(aggregate.get("objective_means"), list)
        or len(aggregate["objective_means"]) != len(SELECTION_METRICS)
        or any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            for value in aggregate["objective_means"]
        )
        or any(
            not _is_sha256(aggregate.get(field))
            for field in (
                "shared_bank_configuration_sha256",
                "degradation_policy_sha256",
                "objective_summary_sha256",
                "output_manifest_sha256",
            )
        )
        or any(
            not _is_sha256(origin.get(field))
            for field in (
                "native_dependency_commit_sha256",
                "native_dependency_evidence_sha256",
                "evidence_dependency_commit_sha256",
                "evidence_dependency_evidence_sha256",
            )
        )
        or not isinstance(proofs, list)
        or not proofs
        or any(
            not isinstance(proof, dict)
            or set(proof) != _CONTROL_AGGREGATE_OUTPUT_PROOF_FIELDS
            or proof.get("ordinal") != ordinal
            or any(
                not _is_sha256(proof.get(field))
                for field in (
                    "cache_token",
                    "output_frame_sha256",
                    "native_record_sha256",
                )
            )
            for ordinal, proof in enumerate(proofs)
        )
        or not _is_sha256(declared)
        or declared != canonical_sha256(unhashed)
    ):
        raise ProductionEvaluatorError("control-aggregate origin is invalid")
    return json.loads(canonical_json_bytes(origin))


def _validate_pending_control_aggregate_origin(
    pending: Mapping[str, object],
) -> Mapping[str, object]:
    if (
        not isinstance(pending, dict)
        or set(pending) != _PENDING_CONTROL_AGGREGATE_ORIGIN_FIELDS
        or not isinstance(pending.get("identity"), dict)
    ):
        raise ProductionEvaluatorError(
            "pending control-aggregate origin field set differs"
        )
    candidate: Dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_persisted_non_ash_control_aggregate_origin",
        "identity": pending["identity"],
        "identity_sha256": canonical_sha256(pending["identity"]),
        "aggregate": pending["aggregate"],
        "ordered_output_proofs": pending["ordered_output_proofs"],
        "native_dependency_commit_sha256": "0" * SHA256_LENGTH,
        "native_dependency_evidence_sha256": "0" * SHA256_LENGTH,
        "evidence_dependency_commit_sha256": "0" * SHA256_LENGTH,
        "evidence_dependency_evidence_sha256": "0" * SHA256_LENGTH,
    }
    candidate["origin_manifest_sha256"] = canonical_sha256(candidate)
    _validate_control_aggregate_origin_envelope(
        candidate,
        identity=pending["identity"],
    )
    return json.loads(canonical_json_bytes(pending))


def _validate_evidence_dependency_commit_result(
    result: Mapping[str, object],
    *,
    ordered_document_sha256_values: Sequence[str],
) -> Mapping[str, object]:
    if not isinstance(result, dict) or set(result) != (
        _EVIDENCE_DEPENDENCY_COMMIT_RESULT_FIELDS
    ):
        raise ProductionEvaluatorError(
            "aggregate evidence dependency commit result field set differs"
        )
    record = result.get("record")
    expected_documents = list(ordered_document_sha256_values)
    if (
        not isinstance(record, dict)
        or set(record) != _EVIDENCE_DEPENDENCY_COMMIT_FIELDS
    ):
        raise ProductionEvaluatorError(
            "aggregate evidence dependency commit field set differs"
        )
    unhashed = dict(record)
    declared = unhashed.pop("record_sha256", None)
    payload = canonical_json_bytes(record)
    if (
        record.get("schema_version") != "1.0.0"
        or record.get("artifact_kind")
        != "p06_control_aggregate_evidence_dependency_commit"
        or record.get("ordered_document_sha256_values")
        != expected_documents
        or len(expected_documents) != len(set(expected_documents))
        or any(not _is_sha256(value) for value in expected_documents)
        or record.get("document_count") != len(expected_documents)
        or not _is_sha256(record.get("documents_directory_identity_sha256"))
        or record.get("committed") is not True
        or not _is_sha256(declared)
        or declared != canonical_sha256(unhashed)
        or result.get("document_sha256")
        != hashlib.sha256(payload).hexdigest()
        or not isinstance(result.get("size_bytes"), int)
        or isinstance(result.get("size_bytes"), bool)
        or result.get("size_bytes") != len(payload)
    ):
        raise ProductionEvaluatorError(
            "aggregate evidence dependency commit is invalid"
        )
    return json.loads(canonical_json_bytes(result))


def _validate_native_dependency_commit(
    record: Mapping[str, object],
    *,
    adapter: CandidateAdapter,
    split: str,
    shared_bank_configuration_sha256: str,
    require_current_requester: bool = True,
) -> Mapping[str, object]:
    configuration = adapter.configuration
    swift_cli = configuration.get("swift_cli")
    if (
        not isinstance(record, dict)
        or set(record) != _NATIVE_DEPENDENCY_COMMIT_FIELDS
        or not isinstance(swift_cli, dict)
        or set(swift_cli)
        != {"executable_sha256", "source_manifest_sha256"}
    ):
        raise ProductionEvaluatorError(
            "native control-cache durability commit field set differs"
        )
    unhashed = dict(record)
    declared = unhashed.pop("record_sha256", None)
    requester = record.get("requesting_configuration_id")
    counts = (
        record.get("pending_file_count"),
        record.get("pending_directory_count"),
    )
    if (
        record.get("schema_version") != "1.0.0"
        or record.get("artifact_kind")
        != "p06_control_cache_durability_commit"
        or record.get("split") != split
        or not isinstance(requester, str)
        or not requester
        or (
            require_current_requester
            and requester != configuration.get("configuration_id")
        )
        or record.get("shared_bank_configuration_sha256")
        != shared_bank_configuration_sha256
        or record.get("native_executable_sha256")
        != swift_cli.get("executable_sha256")
        or record.get("native_source_manifest_sha256")
        != swift_cli.get("source_manifest_sha256")
        or any(
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < 0
            for value in counts
        )
        or not _is_sha256(record.get("ordered_file_bindings_sha256"))
        or not _is_sha256(record.get("ordered_directory_identities_sha256"))
        or record.get("committed") is not True
        or not _is_sha256(declared)
        or declared != canonical_sha256(unhashed)
    ):
        raise ProductionEvaluatorError(
            "native control-cache durability commit is invalid"
        )
    return json.loads(canonical_json_bytes(record))


class MemoryEvidenceStore:
    """Content-addressed evidence store used by focused tests and adapters."""

    def __init__(self) -> None:
        self._payloads: Dict[str, bytes] = {}
        self._failures: list[str] = []
        self._control_aggregate_origins: Dict[str, bytes] = {}

    def publish(self, document: Mapping[str, object]) -> Mapping[str, object]:
        payload = canonical_json_bytes(document)
        digest = hashlib.sha256(payload).hexdigest()
        existing = self._payloads.get(digest)
        if existing is not None and existing != payload:
            raise ProductionEvaluatorError("content-address collision")
        self._payloads[digest] = payload
        reopened = self.reopen(digest)
        if reopened != dict(document):
            raise ProductionEvaluatorError("content-addressed evidence reopen mismatch")
        return {"sha256": digest, "size_bytes": len(payload)}

    def publish_control_aggregate_document(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        return self.publish(document)

    def reopen(self, sha256: str) -> Mapping[str, object]:
        _require_sha256(sha256, "evidence hash")
        payload = self._payloads.get(sha256)
        if payload is None:
            raise ProductionEvaluatorError("content-addressed evidence is absent")
        if hashlib.sha256(payload).hexdigest() != sha256:
            raise ProductionEvaluatorError("content-addressed evidence hash changed")
        value = json.loads(payload)
        if not isinstance(value, dict):
            raise ProductionEvaluatorError("content-addressed evidence is not an object")
        return value

    def preserve_failure(self, document: Mapping[str, object]) -> Mapping[str, object]:
        binding = self.publish(document)
        self._failures.append(str(binding["sha256"]))
        return binding

    def publish_control_aggregate_origin(
        self,
        *,
        identity: Mapping[str, object],
        origin: Mapping[str, object],
    ) -> Mapping[str, object]:
        result = self.publish_control_aggregate_origins_batch(
            ({"identity": identity, "origin": origin},)
        )
        identity_sha256 = canonical_sha256(identity)
        reopened = self.reopen_control_aggregate_origin(identity)
        if reopened is None:
            raise ProductionEvaluatorError(
                "control-aggregate origin failed reopen verification"
            )
        return {
            "identity_sha256": identity_sha256,
            "origin_manifest_sha256": reopened["origin_manifest_sha256"],
            "size_bytes": len(canonical_json_bytes(reopened)),
            "batch_record_sha256": result["record_sha256"],
        }

    def publish_control_aggregate_origins_batch(
        self,
        entries: Sequence[Mapping[str, Mapping[str, object]]],
    ) -> Mapping[str, object]:
        if not isinstance(entries, (list, tuple)) or not entries:
            raise ProductionEvaluatorError("control-aggregate origin batch is empty")
        validated_entries = []
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"identity", "origin"}:
                raise ProductionEvaluatorError(
                    "control-aggregate origin batch entry field set differs"
                )
            identity = entry["identity"]
            origin = _validate_control_aggregate_origin_envelope(
                entry["origin"],
                identity=identity,
            )
            identity_sha256 = canonical_sha256(identity)
            payload = canonical_json_bytes(origin)
            existing = self._control_aggregate_origins.get(identity_sha256)
            if existing is not None and existing != payload:
                raise ProductionEvaluatorError("control-aggregate origin changed")
            validated_entries.append(
                (identity, origin, identity_sha256, payload)
            )
        identity_values = [entry[2] for entry in validated_entries]
        if len(identity_values) != len(set(identity_values)):
            raise ProductionEvaluatorError(
                "control-aggregate origin batch identity is duplicated"
            )
        for _, _, identity_sha256, payload in validated_entries:
            self._control_aggregate_origins[identity_sha256] = payload
        for identity, origin, _, _ in validated_entries:
            if self.reopen_control_aggregate_origin(identity) != origin:
                raise ProductionEvaluatorError(
                    "control-aggregate origin batch failed reopen"
                )
        record: Dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_control_aggregate_origin_batch_commit",
            "published_count": len(validated_entries),
            "ordered_identity_sha256_values": identity_values,
            "ordered_origin_manifest_sha256_values": [
                entry[1]["origin_manifest_sha256"]
                for entry in validated_entries
            ],
        }
        record["record_sha256"] = canonical_sha256(record)
        return record

    def flush_control_aggregate_dependencies(
        self,
        ordered_document_sha256_values: Sequence[str],
    ) -> Mapping[str, object]:
        values = list(ordered_document_sha256_values)
        if (
            not values
            or len(values) != len(set(values))
            or any(not _is_sha256(value) for value in values)
        ):
            raise ProductionEvaluatorError(
                "aggregate evidence dependency document order is invalid"
            )
        for value in values:
            self.reopen(value)
        record: Dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": (
                "p06_control_aggregate_evidence_dependency_commit"
            ),
            "ordered_document_sha256_values": values,
            "document_count": len(values),
            "documents_directory_identity_sha256": canonical_sha256(
                {"store_kind": "memory_evidence_store"}
            ),
            "committed": True,
        }
        record["record_sha256"] = canonical_sha256(record)
        binding = self.publish(record)
        return _validate_evidence_dependency_commit_result(
            {
                "record": record,
                "document_sha256": binding["sha256"],
                "size_bytes": binding["size_bytes"],
            },
            ordered_document_sha256_values=values,
        )

    def reopen_control_aggregate_origin(
        self,
        identity: Mapping[str, object],
    ) -> Optional[Mapping[str, object]]:
        identity_sha256 = canonical_sha256(identity)
        payload = self._control_aggregate_origins.get(identity_sha256)
        if payload is None:
            return None
        try:
            value = json.loads(payload)
        except (TypeError, ValueError) as error:
            raise ProductionEvaluatorError(
                "control-aggregate origin is not canonical JSON"
            ) from error
        if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
            raise ProductionEvaluatorError(
                "control-aggregate origin bytes are not canonical"
            )
        return _validate_control_aggregate_origin_envelope(
            value,
            identity=identity,
        )

    @property
    def failure_hashes(self) -> Tuple[str, ...]:
        return tuple(self._failures)


@dataclass(frozen=True)
class ControlAggregateEvidence:
    """All ordered rows for one uniform control and one split."""

    split: str
    stable_id: object
    shared_bank_configuration_sha256: str
    degradation_policy_sha256: str
    rows: Tuple[Mapping[str, object], ...]
    objective_means: Tuple[float, float, float, float, float]
    objective_summary_sha256: str
    output_manifest_sha256: str
    authorization_v2: Optional[Mapping[str, object]] = None


@dataclass(frozen=True)
class ControlSelectionBundle:
    """Frozen stage-scoped controls for exactly one shared bank."""

    selection_stage: str
    shared_bank_configuration_sha256: str
    degradation_policy_sha256: str
    candidate_vector_sha256: str
    adapter_configuration_sha256: str
    fixed_selection: Mapping[str, object]
    conventional_selection: Mapping[str, object]
    non_ash_selection: Mapping[str, object]
    requests: Mapping[str, Mapping[str, object]]
    bundle_sha256: str

    def request(self, key: str) -> Mapping[str, object]:
        value = self.requests.get(key)
        if not isinstance(value, dict):
            raise ProductionEvaluatorError(f"selected control request is absent: {key}")
        if value.get("shared_bank_configuration_sha256") != (
            self.shared_bank_configuration_sha256
        ):
            raise ProductionEvaluatorError(f"selected control uses a stale bank: {key}")
        return value


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == SHA256_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )


def _require_sha256(value: object, label: str) -> str:
    if not _is_sha256(value):
        raise ProductionEvaluatorError(f"{label} is not a lowercase SHA-256")
    return str(value)


def _require_finite(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProductionEvaluatorError(f"{label} is not numeric")
    result = float(value)
    if not math.isfinite(result):
        raise ProductionEvaluatorError(f"{label} is not finite")
    return result


def _freeze_frame(frame: PlanarFrame) -> PlanarFrame:
    planes = []
    for source in (frame.y, frame.cb, frame.cr):
        target = np.array(source, dtype=np.float64, copy=True, order="C")
        target.setflags(write=False)
        planes.append(target)
    return PlanarFrame(y=planes[0], cb=planes[1], cr=planes[2])


def _validate_frame(frame: object, context: CandidateContext, label: str) -> PlanarFrame:
    if not isinstance(frame, PlanarFrame):
        raise ProductionEvaluatorError(f"{label} is not a PlanarFrame")
    if (
        frame.y.shape != context.y_shape
        or frame.cb.shape != context.cb_shape
        or frame.cr.shape != context.cr_shape
    ):
        raise ProductionEvaluatorError(f"{label} has the wrong geometry")
    if not all(np.all(np.isfinite(plane)) for plane in (frame.y, frame.cb, frame.cr)):
        raise ProductionEvaluatorError(f"{label} contains nonfinite pixels")
    if (
        np.any(frame.y < 0.0)
        or np.any(frame.y > 1.0)
        or np.any(frame.cb < -0.5)
        or np.any(frame.cb > 0.5)
        or np.any(frame.cr < -0.5)
        or np.any(frame.cr > 0.5)
    ):
        raise ProductionEvaluatorError(f"{label} is outside normalized legal ranges")
    return frame


def _psnr_value(result: Mapping[str, object], label: str) -> float:
    if result.get("exact_match") is True:
        raise ProductionEvaluatorError(
            f"{label} is exact but the candidate schema has no infinite-PSNR representation"
        )
    return _require_finite(result.get("value"), label)


def corpus_metric_bundle(
    target: PlanarFrame,
    candidate: PlanarFrame,
    *,
    writer_y_psnr_contribution_db: object = None,
) -> Mapping[str, object]:
    """Compute annotation-free corpus metrics with validated helpers."""

    channels = channel_psnr(target, candidate)
    y_ssim = ms_ssim_detail(target.y, candidate.y)
    cb_ssim = ms_ssim_detail(target.cb, candidate.cb)
    cr_ssim = ms_ssim_detail(target.cr, candidate.cr)
    contribution = (
        None
        if writer_y_psnr_contribution_db is None
        else _require_finite(
            writer_y_psnr_contribution_db,
            "writer Y PSNR contribution",
        )
    )
    return {
        "y_psnr_db": _psnr_value(channels["Y"], "Y PSNR"),
        "cb_psnr_db": _psnr_value(channels["Cb"], "Cb PSNR"),
        "cr_psnr_db": _psnr_value(channels["Cr"], "Cr PSNR"),
        "y_ssim": _require_finite(
            y_ssim["scale_ssim_means"][0],
            "Y SSIM",
        ),
        "cb_ssim": _require_finite(
            cb_ssim["scale_ssim_means"][0],
            "Cb SSIM",
        ),
        "cr_ssim": _require_finite(
            cr_ssim["scale_ssim_means"][0],
            "Cr SSIM",
        ),
        "y_ms_ssim": _require_finite(y_ssim["value"], "Y MS-SSIM"),
        "cb_ms_ssim": _require_finite(
            cb_ssim["value"],
            "Cb MS-SSIM",
        ),
        "cr_ms_ssim": _require_finite(
            cr_ssim["value"],
            "Cr MS-SSIM",
        ),
        "writer_y_psnr_contribution_db": contribution,
    }


def _validated_control_measurement_frame_v2(
    frame: object,
    *,
    label: str,
) -> PlanarFrame:
    if not isinstance(frame, PlanarFrame):
        raise ProductionEvaluatorError(f"{label} is not a PlanarFrame")
    if not all(
        np.all(np.isfinite(plane))
        for plane in (frame.y, frame.cb, frame.cr)
    ):
        raise ProductionEvaluatorError(f"{label} contains nonfinite pixels")
    if (
        np.any(frame.y < 0.0)
        or np.any(frame.y > 1.0)
        or np.any(frame.cb < -0.5)
        or np.any(frame.cb > 0.5)
        or np.any(frame.cr < -0.5)
        or np.any(frame.cr > 0.5)
    ):
        raise ProductionEvaluatorError(
            f"{label} is outside normalized legal ranges"
        )
    return frame


def canonical_control_measurement_frame_bytes_v2(
    frame: PlanarFrame,
) -> bytes:
    """Serialize one exact metric frame as canonical big-endian float64 bytes."""

    validated = _validated_control_measurement_frame_v2(
        frame,
        label="control measurement frame",
    )
    payload = bytearray(_CONTROL_MEASUREMENT_FRAME_MAGIC_V2)
    for tag, plane in (
        (b"Y\0", validated.y),
        (b"CB", validated.cb),
        (b"CR", validated.cr),
    ):
        values = np.array(plane, dtype=np.float64, order="C", copy=True)
        values[values == 0.0] = 0.0
        payload.extend(tag)
        payload.extend(struct.pack(">II", values.shape[0], values.shape[1]))
        payload.extend(values.astype(">f8", copy=False).tobytes(order="C"))
    return bytes(payload)


def decode_control_measurement_frame_bytes_v2(payload: bytes) -> PlanarFrame:
    """Decode and canonicality-check exact control metric frame bytes."""

    if type(payload) is not bytes or not payload.startswith(
        _CONTROL_MEASUREMENT_FRAME_MAGIC_V2
    ):
        raise ProductionEvaluatorError(
            "control measurement frame bytes have the wrong encoding"
        )
    offset = len(_CONTROL_MEASUREMENT_FRAME_MAGIC_V2)
    planes = []
    try:
        for expected_tag in (b"Y\0", b"CB", b"CR"):
            if payload[offset : offset + 2] != expected_tag:
                raise ProductionEvaluatorError(
                    "control measurement frame plane order differs"
                )
            offset += 2
            height, width = struct.unpack_from(">II", payload, offset)
            offset += 8
            if height == 0 or width == 0:
                raise ProductionEvaluatorError(
                    "control measurement frame contains an empty plane"
                )
            value_count = height * width
            byte_count = value_count * 8
            if byte_count > len(payload) - offset:
                raise ProductionEvaluatorError(
                    "control measurement frame payload is truncated"
                )
            plane = np.frombuffer(
                payload,
                dtype=">f8",
                count=value_count,
                offset=offset,
            ).astype(np.float64)
            planes.append(plane.reshape((height, width)))
            offset += byte_count
    except (struct.error, ValueError) as exc:
        raise ProductionEvaluatorError(
            "control measurement frame bytes are malformed"
        ) from exc
    if offset != len(payload):
        raise ProductionEvaluatorError(
            "control measurement frame bytes contain trailing data"
        )
    try:
        frame = PlanarFrame(y=planes[0], cb=planes[1], cr=planes[2])
    except (IndexError, ValueError) as exc:
        raise ProductionEvaluatorError(
            "control measurement frame geometry is invalid"
        ) from exc
    _validated_control_measurement_frame_v2(
        frame,
        label="decoded control measurement frame",
    )
    if canonical_control_measurement_frame_bytes_v2(frame) != payload:
        raise ProductionEvaluatorError(
            "control measurement frame bytes are not canonical"
        )
    return frame


def hierarchical_control_objective_v2(
    raw_rows: Sequence[Mapping[str, object]],
    source_order: Sequence[str],
) -> Tuple[Tuple[Mapping[str, object], ...], Tuple[float, ...]]:
    """Compute the locked two-level control objective with one algorithm."""

    per_source = []
    values_by_source: Dict[str, Tuple[float, ...]] = {}
    for source_id in source_order:
        source_rows = [
            row for row in raw_rows if row.get("source_asset_id") == source_id
        ]
        if not source_rows:
            raise ProductionEvaluatorError(
                "control objective source has no degradation rows"
            )
        means = []
        for metric in SELECTION_METRICS:
            values = []
            for row in source_rows:
                metrics = row.get("metrics")
                if not isinstance(metrics, Mapping):
                    raise ProductionEvaluatorError(
                        "control objective row metrics are not an object"
                    )
                values.append(
                    _require_finite(
                        metrics.get(metric),
                        f"control objective {source_id}/{metric}",
                    )
                )
            means.append(math.fsum(values) / len(values))
        source_means = tuple(means)
        values_by_source[source_id] = source_means
        per_source.append(
            {
                "source_asset_id": source_id,
                "engine_raw_profile_mean_tuple": list(source_means),
            }
        )
    if not per_source:
        raise ProductionEvaluatorError("control objective source order is empty")
    objective = tuple(
        math.fsum(
            values_by_source[source_id][metric_index]
            for source_id in source_order
        )
        / len(source_order)
        for metric_index in range(len(SELECTION_METRICS))
    )
    return tuple(per_source), objective


def degradation_native_input(
    target: PlanarFrame,
    profile: Mapping[str, object],
) -> PlanarFrame:
    """Apply one locked spatial profile and cache the exact common-boundary bytes."""

    degraded = apply_degradation(target, profile)
    _, native_input = _round_trip_locked_bt709_video_range_nv12(degraded)
    return _freeze_frame(native_input)


def _control_request(
    *,
    control_key: str,
    control_mode: str,
    configuration_sha256: str,
    shared_bank_configuration_sha256: str,
    parameters: Mapping[str, object],
) -> Mapping[str, object]:
    _require_sha256(configuration_sha256, "control configuration hash")
    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    request = {
        "schema_version": "1.0.0",
        "operation": "reconstruct_control",
        "control_key": control_key,
        "control_mode": control_mode,
        "configuration_sha256": configuration_sha256,
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "parameters": dict(parameters),
    }
    request["request_sha256"] = canonical_sha256(request)
    return request


def fixed_control_configuration_sha256_v2(
    descriptor_id: int,
    shared_bank_configuration_sha256: str,
) -> str:
    """Derive the exact fixed-control configuration identity."""

    if type(descriptor_id) is not int or descriptor_id not in FIXED_DESCRIPTOR_IDS:
        raise ProductionEvaluatorError("fixed descriptor ID is outside 0...15")
    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    return canonical_sha256(
        {
            "control_id": "fixed-descriptor-uniform-v1",
            "descriptor_id": descriptor_id,
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256
            ),
        }
    )


def conventional_control_configuration_sha256_v2(
    algorithm_id: str,
    shared_bank_configuration_sha256: str,
) -> str:
    """Derive the exact conventional-control configuration identity."""

    if type(algorithm_id) is not str or algorithm_id not in CONVENTIONAL_ALGORITHM_IDS:
        raise ProductionEvaluatorError(
            "conventional algorithm ID is not preregistered"
        )
    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    return canonical_sha256(
        {
            "control_id": "uniform-conventional-selection-v1",
            "algorithm_id": algorithm_id,
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256
            ),
        }
    )


def non_ash_control_configuration_sha256_v2(
    *,
    selector_id: str,
    rule_sha256: str,
    shared_bank_configuration_sha256: str,
) -> str:
    """Derive a non-ASH configuration identity from selector, rule, and bank."""

    if selector_id not in {NON_ASH_SELECTOR_ID, NON_ASH_SELECTOR_ID_V2}:
        raise ProductionEvaluatorError("non-ASH selector ID is not preregistered")
    _require_sha256(rule_sha256, "non-ASH rule hash")
    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    return canonical_sha256(
        {
            "selector_id": selector_id,
            "rule_sha256": rule_sha256,
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256
            ),
        }
    )


def fixed_control_request(
    descriptor_id: int,
    shared_bank_configuration_sha256: str,
) -> Mapping[str, object]:
    configuration_sha256 = fixed_control_configuration_sha256_v2(
        descriptor_id,
        shared_bank_configuration_sha256,
    )
    return _control_request(
        control_key=f"fixed_descriptor_{descriptor_id:02d}",
        control_mode="fixed_descriptor_uniform",
        configuration_sha256=configuration_sha256,
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        parameters={"descriptor_id": descriptor_id},
    )


def conventional_control_request(
    algorithm_id: str,
    shared_bank_configuration_sha256: str,
) -> Mapping[str, object]:
    configuration_sha256 = conventional_control_configuration_sha256_v2(
        algorithm_id,
        shared_bank_configuration_sha256,
    )
    return _control_request(
        control_key=f"conventional_{CONVENTIONAL_ALGORITHM_IDS.index(algorithm_id)}",
        control_mode="conventional_uniform",
        configuration_sha256=configuration_sha256,
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        parameters={"algorithm_id": algorithm_id},
    )


def non_ash_control_request_for_selector_v2(
    rule: Mapping[str, object],
    shared_bank_configuration_sha256: str,
    *,
    selector_id: str,
) -> Mapping[str, object]:
    if set(rule) != set(NON_ASH_COORDINATES) or any(
        not isinstance(rule[name], int) or rule[name] not in NON_ASH_VALUES
        for name in NON_ASH_COORDINATES
    ):
        raise ProductionEvaluatorError("non-ASH rule is outside its preregistered domain")
    ordered_rule = {name: int(rule[name]) for name in NON_ASH_COORDINATES}
    rule_sha256 = canonical_sha256(ordered_rule)
    configuration_sha256 = non_ash_control_configuration_sha256_v2(
        selector_id=selector_id,
        rule_sha256=rule_sha256,
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
    )
    return _control_request(
        control_key="non_ash_selector",
        control_mode="non_ash_selector_q15",
        configuration_sha256=configuration_sha256,
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        parameters={
            "selector_id": selector_id,
            "selected_rule_sha256": rule_sha256,
            "selected_rule_configuration": ordered_rule,
        },
    )


def non_ash_control_request(
    rule: Mapping[str, object],
    shared_bank_configuration_sha256: str,
) -> Mapping[str, object]:
    return non_ash_control_request_for_selector_v2(
        rule,
        shared_bank_configuration_sha256,
        selector_id=NON_ASH_SELECTOR_ID,
    )


def _reject_path_or_sealed_split_fields(value: object) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).lower()
            if (
                normalized.endswith("_path")
                or normalized.endswith("_root")
                or normalized in {"path", "root", "holdout_id", "holdout_asset_id"}
            ):
                raise ProductionEvaluatorError(
                    "quality evidence exposes a path, root, or sealed-split identity"
                )
            _reject_path_or_sealed_split_fields(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            _reject_path_or_sealed_split_fields(child)


def build_expected_source_profile_matrix(
    *,
    cases: Sequence[Mapping[str, object]],
    degradation_policy: Mapping[str, object],
) -> Tuple[Mapping[str, object], ...]:
    """Derive the exact ordered three-profile matrix from split metadata."""

    if (
        degradation_policy.get("status") != "locked"
        or degradation_policy.get("policy_sha256")
        != manifest_sha256(degradation_policy, "policy_sha256")
    ):
        raise ProductionEvaluatorError("degradation policy is not locked or self-hashed")
    profiles = degradation_policy.get("profiles")
    if not isinstance(profiles, list):
        raise ProductionEvaluatorError("degradation policy profiles are absent")
    required_kinds = (
        "lowpass_decimate",
        "camera_blur_decimate",
        "codec_quantized_proxy",
    )
    route_profiles: Dict[str, Tuple[Mapping[str, object], ...]] = {}
    for route in ROUTES:
        matches = tuple(
            profile
            for profile in profiles
            if isinstance(profile, dict)
            and profile.get("target_route") == route
            and profile.get("kind") != "synthetic_motion"
        )
        if (
            len(matches) != 3
            or tuple(profile.get("kind") for profile in matches) != required_kinds
            or any(
                not isinstance(profile.get("id"), str) or not profile["id"]
                for profile in matches
            )
        ):
            raise ProductionEvaluatorError(
                f"locked three-profile spatial coverage differs for {route}"
            )
        route_profiles[route] = matches
    matrix: list[Mapping[str, object]] = []
    for case in cases:
        required = {
            "source_asset_id",
            "source_family_id",
            "categories",
            "target_route",
        }
        if not isinstance(case, dict) or not required.issubset(case):
            raise ProductionEvaluatorError("split case metadata is incomplete")
        _reject_path_or_sealed_split_fields(case)
        route = case["target_route"]
        categories = case["categories"]
        if (
            not isinstance(case["source_asset_id"], str)
            or not case["source_asset_id"]
            or not isinstance(case["source_family_id"], str)
            or not case["source_family_id"]
            or route not in ROUTES
            or not isinstance(categories, list)
            or not categories
            or len(categories) != len(set(categories))
        ):
            raise ProductionEvaluatorError("split case identity is invalid")
        for profile in route_profiles[str(route)]:
            matrix.append(
                {
                    "source_asset_id": case["source_asset_id"],
                    "source_family_id": case["source_family_id"],
                    "categories": list(categories),
                    "target_route": route,
                    "degradation_profile_id": profile["id"],
                    "degradation_profile_sha256": canonical_sha256(profile),
                }
            )
    if len(matrix) != len(cases) * 3:
        raise ProductionEvaluatorError("source/profile matrix cardinality differs")
    return tuple(matrix)


def _validate_metric_bundle(metrics: Mapping[str, object]) -> None:
    required = {
        "y_psnr_db",
        "cb_psnr_db",
        "cr_psnr_db",
        "y_ssim",
        "cb_ssim",
        "cr_ssim",
        "y_ms_ssim",
        "cb_ms_ssim",
        "cr_ms_ssim",
        "writer_y_psnr_contribution_db",
    }
    if set(metrics) != required:
        raise ProductionEvaluatorError("corpus metric bundle field set differs")
    for name in required - {"writer_y_psnr_contribution_db"}:
        _require_finite(metrics[name], f"metric {name}")
    contribution = metrics["writer_y_psnr_contribution_db"]
    if contribution is not None:
        _require_finite(contribution, "writer Y PSNR contribution")


def make_control_aggregate(
    *,
    split: str,
    stable_id: object,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
    control_configuration_sha256: str,
    expected_source_profile_matrix: Sequence[Mapping[str, object]],
    rows: Sequence[Mapping[str, object]],
    evidence_store: EvidenceStore,
    require_decoded_evidence: bool = True,
    aggregate_document_publisher: Optional[
        Callable[[Mapping[str, object]], Mapping[str, object]]
    ] = None,
) -> ControlAggregateEvidence:
    """Validate and content-address all rows for one uniformly applied control."""

    if split not in {"development", "validation"}:
        raise ProductionEvaluatorError("control aggregate split is not open in P06")
    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    _require_sha256(degradation_policy_sha256, "degradation policy hash")
    _require_sha256(control_configuration_sha256, "control configuration hash")
    if not rows:
        raise ProductionEvaluatorError("control aggregate has no rows")
    identity_fields = (
        "source_asset_id",
        "source_family_id",
        "categories",
        "target_route",
        "degradation_profile_id",
        "degradation_profile_sha256",
    )
    expected_identities: list[Mapping[str, object]] = []
    for identity in expected_source_profile_matrix:
        if not isinstance(identity, dict) or set(identity) != set(identity_fields):
            raise ProductionEvaluatorError(
                "expected source/profile matrix identity field set differs"
            )
        _reject_path_or_sealed_split_fields(identity)
        if (
            not isinstance(identity["source_asset_id"], str)
            or not identity["source_asset_id"]
            or not isinstance(identity["source_family_id"], str)
            or not identity["source_family_id"]
            or identity["target_route"] not in ROUTES
            or not isinstance(identity["categories"], list)
            or not identity["categories"]
            or len(identity["categories"]) != len(set(identity["categories"]))
            or not isinstance(identity["degradation_profile_id"], str)
            or not identity["degradation_profile_id"]
        ):
            raise ProductionEvaluatorError(
                "expected source/profile matrix identity is invalid"
            )
        _require_sha256(
            identity["degradation_profile_sha256"],
            "expected degradation profile hash",
        )
        expected_identities.append(json.loads(canonical_json_bytes(identity)))
    expected_pairs = [
        (
            str(identity["source_asset_id"]),
            str(identity["degradation_profile_id"]),
        )
        for identity in expected_identities
    ]
    if (
        not expected_pairs
        or len(expected_pairs) != len(set(expected_pairs))
        or {str(identity["target_route"]) for identity in expected_identities}
        != set(ROUTES)
    ):
        raise ProductionEvaluatorError(
            "expected source/profile matrix is empty, duplicated, or route-incomplete"
        )
    profiles_per_source: Dict[str, int] = {}
    for source_id, _ in expected_pairs:
        profiles_per_source[source_id] = profiles_per_source.get(source_id, 0) + 1
    if any(count != 3 for count in profiles_per_source.values()):
        raise ProductionEvaluatorError(
            "expected source/profile matrix does not contain exactly three profiles per source"
        )
    required_row_fields = {
        "source_asset_id",
        "source_family_id",
        "categories",
        "target_route",
        "degradation_profile_id",
        "degradation_profile_sha256",
        "degradation_policy_sha256",
        "comparison_domain",
        "output_sha256",
        "metrics",
        "writer_evidence_sha256",
        "control_configuration_sha256",
        "shared_bank_configuration_sha256",
    }
    normalized_rows: list[Mapping[str, object]] = []
    by_domain: Dict[str, list[Mapping[str, object]]] = {domain: [] for domain in DOMAINS}
    for row in rows:
        if not isinstance(row, dict) or set(row) != required_row_fields:
            raise ProductionEvaluatorError("control row field set differs")
        _reject_path_or_sealed_split_fields(row)
        domain = row["comparison_domain"]
        if domain not in DOMAINS:
            raise ProductionEvaluatorError("control row comparison domain is invalid")
        if row["target_route"] not in ROUTES:
            raise ProductionEvaluatorError("control row target route is invalid")
        if (
            not isinstance(row["degradation_profile_id"], str)
            or not row["degradation_profile_id"]
            or row["degradation_policy_sha256"] != degradation_policy_sha256
        ):
            raise ProductionEvaluatorError("control row degradation identity is invalid")
        _require_sha256(
            row["degradation_profile_sha256"],
            "degradation profile hash",
        )
        if (
            not isinstance(row["source_asset_id"], str)
            or not row["source_asset_id"]
            or not isinstance(row["source_family_id"], str)
            or not row["source_family_id"]
            or not isinstance(row["categories"], list)
            or not row["categories"]
            or len(row["categories"]) != len(set(row["categories"]))
        ):
            raise ProductionEvaluatorError("control row source metadata is invalid")
        if (
            row["control_configuration_sha256"] != control_configuration_sha256
            or row["shared_bank_configuration_sha256"]
            != shared_bank_configuration_sha256
        ):
            raise ProductionEvaluatorError("control row is stale for its bank")
        _require_sha256(row["output_sha256"], "control output hash")
        writer_binding = row["writer_evidence_sha256"]
        if (domain == "engine_raw") != (writer_binding is None):
            raise ProductionEvaluatorError(
                "writer evidence is assigned to the wrong comparison domain"
            )
        if writer_binding is not None:
            _require_sha256(writer_binding, "writer evidence hash")
        metrics = row["metrics"]
        if not isinstance(metrics, dict):
            raise ProductionEvaluatorError("control row metrics are not an object")
        _validate_metric_bundle(metrics)
        if (domain == "engine_raw") != (
            metrics["writer_y_psnr_contribution_db"] is None
        ):
            raise ProductionEvaluatorError(
                "writer contribution is assigned to the wrong domain"
            )
        frozen = json.loads(canonical_json_bytes(row))
        normalized_rows.append(frozen)
        by_domain[str(domain)].append(frozen)

    raw_pairs = [
        (str(row["source_asset_id"]), str(row["degradation_profile_id"]))
        for row in by_domain["engine_raw"]
    ]
    decoded_pairs = [
        (str(row["source_asset_id"]), str(row["degradation_profile_id"]))
        for row in by_domain["container_decoded"]
    ]
    expected_decoded_pairs = expected_pairs if require_decoded_evidence else []
    if raw_pairs != expected_pairs or decoded_pairs != expected_decoded_pairs:
        raise ProductionEvaluatorError(
            "control rows do not exactly cover the locked source/profile matrix"
        )
    required_domains = DOMAINS if require_decoded_evidence else ("engine_raw",)
    for domain in required_domains:
        for row, expected in zip(by_domain[domain], expected_identities):
            observed = {field: row[field] for field in identity_fields}
            if observed != expected:
                raise ProductionEvaluatorError(
                    "control row substitutes locked source/profile metadata"
                )
    source_order = list(dict.fromkeys(pair[0] for pair in raw_pairs))
    source_profile_matrix_sha256 = canonical_sha256(expected_identities)
    _, objective_means = hierarchical_control_objective_v2(
        by_domain["engine_raw"],
        source_order,
    )
    objective_summary = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_control_objective_summary",
        "split": split,
        "stable_id": stable_id,
        "comparison_domain": "engine_raw",
        "metric_order": list(SELECTION_METRICS),
        "means": list(objective_means),
        "selection_tuple": SELECTION_TUPLE_DESCRIPTION,
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "degradation_policy_sha256": degradation_policy_sha256,
        "control_configuration_sha256": control_configuration_sha256,
        "source_profile_matrix_sha256": source_profile_matrix_sha256,
    }
    publish_document = (
        evidence_store.publish
        if aggregate_document_publisher is None
        else aggregate_document_publisher
    )
    objective_binding = publish_document(objective_summary)
    output_manifest = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_control_output_manifest",
        "split": split,
        "stable_id": stable_id,
        "uniform_application": True,
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "degradation_policy_sha256": degradation_policy_sha256,
        "control_configuration_sha256": control_configuration_sha256,
        "source_profile_matrix_sha256": source_profile_matrix_sha256,
        "source_order": source_order,
        "source_profile_order": [list(pair) for pair in raw_pairs],
        "comparison_domains": list(required_domains),
        "rows": normalized_rows,
    }
    output_binding = publish_document(output_manifest)
    if (
        evidence_store.reopen(str(objective_binding["sha256"]))
        != objective_summary
        or evidence_store.reopen(str(output_binding["sha256"]))
        != output_manifest
    ):
        raise ProductionEvaluatorError("control evidence failed reopen verification")
    return ControlAggregateEvidence(
        split=split,
        stable_id=stable_id,
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        degradation_policy_sha256=degradation_policy_sha256,
        rows=tuple(normalized_rows),
        objective_means=objective_means,
        objective_summary_sha256=str(objective_binding["sha256"]),
        output_manifest_sha256=str(output_binding["sha256"]),
    )


def _validate_exhaustive_evidence(
    values: Mapping[object, ControlAggregateEvidence],
    expected_ids: Sequence[object],
    *,
    split: str,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
) -> None:
    if list(values) != list(expected_ids):
        raise ProductionEvaluatorError("control evidence ID coverage or order is incomplete")
    for identifier in expected_ids:
        evidence = values[identifier]
        if (
            evidence.stable_id != identifier
            or evidence.split != split
            or evidence.shared_bank_configuration_sha256
            != shared_bank_configuration_sha256
            or evidence.degradation_policy_sha256 != degradation_policy_sha256
        ):
            raise ProductionEvaluatorError("control evidence is mixed or stale")


def _selection_key(
    evidence: ControlAggregateEvidence,
    stable_order: Mapping[object, int],
) -> Tuple[object, ...]:
    return tuple(-value for value in evidence.objective_means) + (
        stable_order[evidence.stable_id],
    )


def _selection_result_rows(
    values: Mapping[object, ControlAggregateEvidence],
    id_field: str,
) -> list[Mapping[str, object]]:
    return [
        {
            id_field: identifier,
            "engine_raw_corpus_mean_tuple": list(evidence.objective_means),
            "objective_summary_sha256": evidence.objective_summary_sha256,
            "output_manifest_sha256": evidence.output_manifest_sha256,
        }
        for identifier, evidence in values.items()
    ]


def _embedded_selection(
    document: Mapping[str, object],
    evidence_store: EvidenceStore,
    schema_name: str,
) -> Mapping[str, object]:
    try:
        validate_schema(document, SCHEMAS_ROOT / schema_name)
    except ValueError as error:
        raise ProductionEvaluatorError(
            f"selection artifact violates {schema_name}: {error}"
        ) from error
    binding = evidence_store.publish(document)
    digest = str(binding["sha256"])
    if digest != canonical_sha256(document) or evidence_store.reopen(digest) != document:
        raise ProductionEvaluatorError("selection artifact failed content-address reopen")
    return {"sha256": digest, "document": dict(document)}


def select_development_provisional_controls(
    *,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
    development_fixed: Mapping[int, ControlAggregateEvidence],
    development_conventional: Mapping[str, ControlAggregateEvidence],
    evidence_store: EvidenceStore,
) -> Mapping[str, Mapping[str, object]]:
    """Choose dev-only provisional controls without touching validation evidence."""

    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    _require_sha256(degradation_policy_sha256, "degradation policy hash")
    _validate_exhaustive_evidence(
        development_fixed,
        FIXED_DESCRIPTOR_IDS,
        split="development",
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        degradation_policy_sha256=degradation_policy_sha256,
    )
    _validate_exhaustive_evidence(
        development_conventional,
        CONVENTIONAL_ALGORITHM_IDS,
        split="development",
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        degradation_policy_sha256=degradation_policy_sha256,
    )
    fixed_order = {identifier: index for index, identifier in enumerate(FIXED_DESCRIPTOR_IDS)}
    conventional_order = {
        identifier: index
        for index, identifier in enumerate(CONVENTIONAL_ALGORITHM_IDS)
    }
    selected_fixed = min(
        FIXED_DESCRIPTOR_IDS,
        key=lambda identifier: _selection_key(
            development_fixed[identifier],
            fixed_order,
        ),
    )
    selected_conventional = min(
        CONVENTIONAL_ALGORITHM_IDS,
        key=lambda identifier: _selection_key(
            development_conventional[identifier],
            conventional_order,
        ),
    )
    fixed_document = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_fixed_control_selection",
        "selection_stage": "development_provisional",
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "uniform_application": True,
        "candidate_ids": list(FIXED_DESCRIPTOR_IDS),
        "selection_objective": SELECTION_OBJECTIVE,
        "development_results": _selection_result_rows(
            development_fixed,
            "descriptor_id",
        ),
        "provisional_descriptor_id": selected_fixed,
        "tie_break": (
            "lexicographically maximize the development engine_raw corpus-mean "
            "tuple, then choose the numerically smallest descriptor ID"
        ),
    }
    conventional_document = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_conventional_control_selection",
        "selection_stage": "development_provisional",
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "uniform_application": True,
        "candidate_ids": list(CONVENTIONAL_ALGORITHM_IDS),
        "selection_objective": SELECTION_OBJECTIVE,
        "development_results": _selection_result_rows(
            development_conventional,
            "algorithm_id",
        ),
        "provisional_algorithm_id": selected_conventional,
        "tie_break": (
            "lexicographically maximize the development engine_raw corpus-mean "
            "tuple, then choose the lexicographically ascending stable "
            "algorithm ID"
        ),
    }
    return {
        "best_fixed": _embedded_selection(
            fixed_document,
            evidence_store,
            "fixed-control-selection-v1.schema.json",
        ),
        "conventional": _embedded_selection(
            conventional_document,
            evidence_store,
            "conventional-control-selection-v1.schema.json",
        ),
    }


def finalize_fixed_and_conventional_controls(
    *,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
    development_provisional: Mapping[str, Mapping[str, object]],
    validation_fixed: Mapping[int, ControlAggregateEvidence],
    validation_conventional: Mapping[str, ControlAggregateEvidence],
    full_ash_development_candidates_frozen_sha256: str,
    evidence_store: EvidenceStore,
) -> Mapping[str, Mapping[str, object]]:
    """Finalize controls on validation only after development candidates freeze."""

    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    _require_sha256(degradation_policy_sha256, "degradation policy hash")
    _require_sha256(
        full_ash_development_candidates_frozen_sha256,
        "frozen development-candidate manifest hash",
    )
    if set(development_provisional) != {"best_fixed", "conventional"}:
        raise ProductionEvaluatorError("development provisional controls are incomplete")
    fixed_provisional = _selection_document(
        development_provisional["best_fixed"],
        "development fixed provisional",
    )
    conventional_provisional = _selection_document(
        development_provisional["conventional"],
        "development conventional provisional",
    )
    for document, schema_name in (
        (fixed_provisional, "fixed-control-selection-v1.schema.json"),
        (
            conventional_provisional,
            "conventional-control-selection-v1.schema.json",
        ),
    ):
        try:
            validate_schema(document, SCHEMAS_ROOT / schema_name)
        except ValueError as error:
            raise ProductionEvaluatorError(
                "development provisional control violates its schema"
            ) from error
        if (
            document.get("selection_stage") != "development_provisional"
            or document.get("shared_bank_configuration_sha256")
            != shared_bank_configuration_sha256
        ):
            raise ProductionEvaluatorError("development provisional control is stale")
    _validate_exhaustive_evidence(
        validation_fixed,
        FIXED_DESCRIPTOR_IDS,
        split="validation",
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        degradation_policy_sha256=degradation_policy_sha256,
    )
    _validate_exhaustive_evidence(
        validation_conventional,
        CONVENTIONAL_ALGORITHM_IDS,
        split="validation",
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
        degradation_policy_sha256=degradation_policy_sha256,
    )
    fixed_order = {
        identifier: index for index, identifier in enumerate(FIXED_DESCRIPTOR_IDS)
    }
    conventional_order = {
        identifier: index
        for index, identifier in enumerate(CONVENTIONAL_ALGORITHM_IDS)
    }
    selected_fixed = min(
        FIXED_DESCRIPTOR_IDS,
        key=lambda identifier: _selection_key(
            validation_fixed[identifier],
            fixed_order,
        ),
    )
    selected_conventional = min(
        CONVENTIONAL_ALGORITHM_IDS,
        key=lambda identifier: _selection_key(
            validation_conventional[identifier],
            conventional_order,
        ),
    )
    fixed_document = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_fixed_control_selection",
        "selection_stage": "validation_final",
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "uniform_application": True,
        "candidate_ids": list(FIXED_DESCRIPTOR_IDS),
        "selection_objective": SELECTION_OBJECTIVE,
        "development_selection_sha256": development_provisional[
            "best_fixed"
        ]["sha256"],
        "validation_results": _selection_result_rows(
            validation_fixed,
            "descriptor_id",
        ),
        "chosen_descriptor_id": selected_fixed,
        "tie_break": (
            "lexicographically maximize the validation engine_raw corpus-mean "
            "tuple, then choose the numerically smallest descriptor ID"
        ),
    }
    conventional_document = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_conventional_control_selection",
        "selection_stage": "validation_final",
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "uniform_application": True,
        "candidate_ids": list(CONVENTIONAL_ALGORITHM_IDS),
        "selection_objective": SELECTION_OBJECTIVE,
        "development_selection_sha256": development_provisional[
            "conventional"
        ]["sha256"],
        "validation_results": _selection_result_rows(
            validation_conventional,
            "algorithm_id",
        ),
        "chosen_algorithm_id": selected_conventional,
        "tie_break": (
            "lexicographically maximize the validation engine_raw corpus-mean "
            "tuple, then choose the lexicographically ascending stable "
            "algorithm ID"
        ),
    }
    return {
        "best_fixed": _embedded_selection(
            fixed_document,
            evidence_store,
            "fixed-control-selection-v1.schema.json",
        ),
        "conventional": _embedded_selection(
            conventional_document,
            evidence_store,
            "conventional-control-selection-v1.schema.json",
        ),
    }


def _validate_non_ash_contract(contract: Mapping[str, object]) -> None:
    coordinates = contract.get("coordinates")
    if (
        contract.get("selector_id") != NON_ASH_SELECTOR_ID
        or contract.get("bank_descriptor_ids") != list(FIXED_DESCRIPTOR_IDS)
        or contract.get("candidate_evaluation_budget") != 1513
        or contract.get("full_ash_maximum_candidate_evaluation_budget")
        != FULL_ASH_MAXIMUM_CANDIDATE_EVALUATION_BUDGET
        or not isinstance(coordinates, dict)
        or coordinates.get("order") != list(NON_ASH_COORDINATES)
        or coordinates.get("values") != list(NON_ASH_VALUES)
        or coordinates.get("initial_value") != 0
        or coordinates.get("maximum_sweeps") != 8
    ):
        raise ProductionEvaluatorError("non-ASH selector contract differs from preregistration")


def _rule_serialization(rule: Mapping[str, object]) -> Tuple[int, ...]:
    if set(rule) != set(NON_ASH_COORDINATES):
        raise ProductionEvaluatorError("non-ASH rule field set differs")
    return tuple(int(rule[name]) for name in NON_ASH_COORDINATES)


def _rule_selection_key(evidence: ControlAggregateEvidence) -> Tuple[object, ...]:
    if not isinstance(evidence.stable_id, str):
        raise ProductionEvaluatorError("non-ASH evidence stable ID is not its rule hash")
    return tuple(-value for value in evidence.objective_means)


def _rule_stable_candidate_id(rule: Mapping[str, object]) -> str:
    ordered = {name: int(rule[name]) for name in NON_ASH_COORDINATES}
    return canonical_json_bytes(ordered).decode("utf-8")


def _validate_non_ash_evidence(
    *,
    evidence: ControlAggregateEvidence,
    split: str,
    rule_sha256: str,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
) -> None:
    if (
        evidence.split != split
        or evidence.stable_id != rule_sha256
        or evidence.shared_bank_configuration_sha256
        != shared_bank_configuration_sha256
        or evidence.degradation_policy_sha256 != degradation_policy_sha256
    ):
        raise ProductionEvaluatorError(
            "non-ASH evaluator returned mixed or stale evidence"
        )


def _non_ash_attempt_record(
    *,
    ordinal: int,
    split: str,
    rule: Mapping[str, object],
    evidence: ControlAggregateEvidence,
) -> Mapping[str, object]:
    return {
        "ordinal": ordinal,
        "split": split,
        "rule_sha256": evidence.stable_id,
        "rule_serialization": list(_rule_serialization(rule)),
        "objective_summary_sha256": evidence.objective_summary_sha256,
        "output_manifest_sha256": evidence.output_manifest_sha256,
    }


def _preserve_non_ash_failure(
    *,
    evidence_store: EvidenceStore,
    split: str,
    rule_sha256: str,
    attempt_ordinal: int,
    error: BaseException,
) -> None:
    evidence_store.preserve_failure(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_non_ash_selector_attempt_failure",
            "split": split,
            "rule_sha256": rule_sha256,
            "attempt_ordinal": attempt_ordinal,
            "failure_type": type(error).__name__,
        }
    )


def search_non_ash_development(
    *,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
    selector_contract: Mapping[str, object],
    development_evaluator: Callable[
        [Mapping[str, object]], ControlAggregateEvidence
    ],
    cached_16_operator_output_manifest_sha256: str,
    evidence_store: EvidenceStore,
) -> Mapping[str, object]:
    """Run preregistered development search without a validation capability."""

    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    _require_sha256(degradation_policy_sha256, "degradation policy hash")
    _require_sha256(
        cached_16_operator_output_manifest_sha256,
        "cached 16-operator output manifest hash",
    )
    _validate_non_ash_contract(selector_contract)
    initial = {name: 0 for name in NON_ASH_COORDINATES}
    development_cache: Dict[str, ControlAggregateEvidence] = {}
    attempts: list[Mapping[str, object]] = []

    def evaluate(rule: Mapping[str, object]) -> ControlAggregateEvidence:
        request = non_ash_control_request(rule, shared_bank_configuration_sha256)
        rule_sha256 = str(request["parameters"]["selected_rule_sha256"])
        if rule_sha256 in development_cache:
            evidence = development_cache[rule_sha256]
        else:
            try:
                evidence = development_evaluator(dict(rule))
            except BaseException as error:
                _preserve_non_ash_failure(
                    evidence_store=evidence_store,
                    split="development",
                    rule_sha256=rule_sha256,
                    attempt_ordinal=len(attempts),
                    error=error,
                )
                raise
            _validate_non_ash_evidence(
                evidence=evidence,
                split="development",
                rule_sha256=rule_sha256,
                shared_bank_configuration_sha256=(
                    shared_bank_configuration_sha256
                ),
                degradation_policy_sha256=degradation_policy_sha256,
            )
            development_cache[rule_sha256] = evidence
        attempts.append(
            _non_ash_attempt_record(
                ordinal=len(attempts),
                split="development",
                rule=rule,
                evidence=evidence,
            )
        )
        return evidence

    current = dict(initial)
    current_evidence = evaluate(current)
    for _ in range(8):
        changed = False
        for coordinate in NON_ASH_COORDINATES:
            candidates: list[tuple[Mapping[str, object], ControlAggregateEvidence]] = []
            for value in NON_ASH_VALUES:
                candidate = dict(current)
                candidate[coordinate] = value
                candidates.append((candidate, evaluate(candidate)))
            selected_rule, selected_evidence = min(
                candidates,
                key=lambda item: (
                    _rule_selection_key(item[1]),
                    _rule_stable_candidate_id(item[0]),
                ),
            )
            if selected_rule != current:
                current = dict(selected_rule)
                current_evidence = selected_evidence
                changed = True
        if not changed:
            break
    if len(attempts) > 1513:
        raise ProductionEvaluatorError("non-ASH development budget was exceeded")
    terminal = dict(current)
    terminal_request = non_ash_control_request(
        terminal,
        shared_bank_configuration_sha256,
    )
    terminal_sha256 = str(
        terminal_request["parameters"]["selected_rule_sha256"]
    )
    attempt_ledger = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_non_ash_selector_attempt_ledger",
        "selection_stage": "development_provisional",
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "degradation_policy_sha256": degradation_policy_sha256,
        "records": attempts,
    }
    attempt_binding = evidence_store.publish(attempt_ledger)
    document = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_non_ash_selector_selection",
        "selection_stage": "development_provisional",
        "selector_id": NON_ASH_SELECTOR_ID,
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "uniform_application": True,
        "candidate_evaluation_budget": 1513,
        "full_ash_maximum_candidate_evaluation_budget": (
            FULL_ASH_MAXIMUM_CANDIDATE_EVALUATION_BUDGET
        ),
        "selection_objective": SELECTION_OBJECTIVE,
        "development_attempt_count": len(attempts),
        "development_attempt_ledger_sha256": attempt_binding["sha256"],
        "development_terminal_rule_sha256": terminal_sha256,
        "development_terminal_rule_configuration": terminal,
        "cached_16_operator_output_manifest_sha256": (
            cached_16_operator_output_manifest_sha256
        ),
        "development_objective_summary_sha256": (
            current_evidence.objective_summary_sha256
        ),
        "development_engine_raw_corpus_mean_tuple": list(
            current_evidence.objective_means
        ),
        "tie_break": (
            "lexicographically maximize the development engine_raw corpus-mean "
            "tuple, then choose the lexicographically ascending canonical "
            "serialized complete rule vector"
        ),
    }
    embedded = _embedded_selection(
        document,
        evidence_store,
        "non-ash-selector-selection-v1.schema.json",
    )
    if evidence_store.reopen(str(attempt_binding["sha256"])) != attempt_ledger:
        raise ProductionEvaluatorError("non-ASH attempt ledger failed reopen")
    return embedded


def finalize_non_ash_validation(
    *,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
    development_provisional: Mapping[str, object],
    validation_evaluator: Callable[
        [Mapping[str, object]], ControlAggregateEvidence
    ],
    full_ash_development_candidates_frozen_sha256: str,
    evidence_store: EvidenceStore,
) -> Mapping[str, object]:
    """Evaluate only the frozen dev terminal and its one-coordinate neighbors."""

    _require_sha256(shared_bank_configuration_sha256, "shared-bank hash")
    _require_sha256(degradation_policy_sha256, "degradation policy hash")
    _require_sha256(
        full_ash_development_candidates_frozen_sha256,
        "frozen development-candidate manifest hash",
    )
    provisional = _selection_document(
        development_provisional,
        "development non-ASH provisional",
    )
    try:
        validate_schema(
            provisional,
            SCHEMAS_ROOT / "non-ash-selector-selection-v1.schema.json",
        )
    except ValueError as error:
        raise ProductionEvaluatorError(
            "development non-ASH provisional violates its schema"
        ) from error
    if (
        provisional.get("artifact_kind") != "p06_non_ash_selector_selection"
        or provisional.get("selection_stage") != "development_provisional"
        or provisional.get("shared_bank_configuration_sha256")
        != shared_bank_configuration_sha256
        or provisional.get("selector_id") != NON_ASH_SELECTOR_ID
    ):
        raise ProductionEvaluatorError("development non-ASH provisional is stale")
    terminal = provisional.get("development_terminal_rule_configuration")
    if not isinstance(terminal, dict):
        raise ProductionEvaluatorError("development terminal non-ASH rule is absent")
    terminal_request = non_ash_control_request(
        terminal,
        shared_bank_configuration_sha256,
    )
    terminal_sha256 = str(
        terminal_request["parameters"]["selected_rule_sha256"]
    )
    if (
        terminal_sha256 != provisional.get("development_terminal_rule_sha256")
    ):
        raise ProductionEvaluatorError("development terminal non-ASH hash differs")

    unique_neighbors: Dict[str, Mapping[str, object]] = {terminal_sha256: terminal}
    for coordinate in NON_ASH_COORDINATES:
        for value in NON_ASH_VALUES:
            candidate = dict(terminal)
            candidate[coordinate] = value
            request = non_ash_control_request(
                candidate,
                shared_bank_configuration_sha256,
            )
            unique_neighbors[
                str(request["parameters"]["selected_rule_sha256"])
            ] = candidate
    if len(unique_neighbors) != 1 + len(NON_ASH_COORDINATES) * (
        len(NON_ASH_VALUES) - 1
    ):
        raise ProductionEvaluatorError("non-ASH validation neighborhood is incomplete")

    attempts: list[Mapping[str, object]] = []
    validation_results: list[
        tuple[Mapping[str, object], ControlAggregateEvidence]
    ] = []
    for digest in sorted(unique_neighbors):
        rule = unique_neighbors[digest]
        try:
            evidence = validation_evaluator(dict(rule))
        except BaseException as error:
            _preserve_non_ash_failure(
                evidence_store=evidence_store,
                split="validation",
                rule_sha256=digest,
                attempt_ordinal=len(attempts),
                error=error,
            )
            raise
        _validate_non_ash_evidence(
            evidence=evidence,
            split="validation",
            rule_sha256=digest,
            shared_bank_configuration_sha256=shared_bank_configuration_sha256,
            degradation_policy_sha256=degradation_policy_sha256,
        )
        attempts.append(
            _non_ash_attempt_record(
                ordinal=len(attempts),
                split="validation",
                rule=rule,
                evidence=evidence,
            )
        )
        validation_results.append((rule, evidence))
    selected_rule, selected_validation = min(
        validation_results,
        key=lambda item: (
            _rule_selection_key(item[1]),
            _rule_stable_candidate_id(item[0]),
        ),
    )
    selected_request = non_ash_control_request(
        selected_rule,
        shared_bank_configuration_sha256,
    )
    selected_rule_sha256 = str(
        selected_request["parameters"]["selected_rule_sha256"]
    )
    neighbor_manifest = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_non_ash_validation_neighbor_manifest",
        "selection_stage": "validation_final",
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "degradation_policy_sha256": degradation_policy_sha256,
        "development_terminal_rule_sha256": terminal_sha256,
        "candidate_rule_sha256_values": sorted(unique_neighbors),
        "records": attempts,
    }
    neighbor_binding = evidence_store.publish(neighbor_manifest)
    validation_result_rows = [
        {
            "stable_candidate_id": _rule_stable_candidate_id(rule),
            "rule_sha256": evidence.stable_id,
            "rule_configuration": dict(rule),
            "engine_raw_corpus_mean_tuple": list(evidence.objective_means),
            "objective_summary_sha256": evidence.objective_summary_sha256,
            "output_manifest_sha256": evidence.output_manifest_sha256,
        }
        for rule, evidence in validation_results
    ]
    document = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_non_ash_selector_selection",
        "selection_stage": "validation_final",
        "selector_id": NON_ASH_SELECTOR_ID,
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "uniform_application": True,
        "selection_objective": SELECTION_OBJECTIVE,
        "development_selection_sha256": development_provisional["sha256"],
        "candidate_evaluation_budget": provisional[
            "candidate_evaluation_budget"
        ],
        "full_ash_maximum_candidate_evaluation_budget": provisional[
            "full_ash_maximum_candidate_evaluation_budget"
        ],
        "development_terminal_rule_sha256": terminal_sha256,
        "validation_neighbor_manifest_sha256": neighbor_binding["sha256"],
        "validation_candidate_count": len(validation_results),
        "validation_results": validation_result_rows,
        "selected_rule_sha256": selected_rule_sha256,
        "selected_rule_configuration": dict(selected_rule),
        "cached_16_operator_output_manifest_sha256": provisional[
            "cached_16_operator_output_manifest_sha256"
        ],
        "validation_objective_summary_sha256": (
            selected_validation.objective_summary_sha256
        ),
        "tie_break": (
            "lexicographically maximize the validation engine_raw corpus-mean "
            "tuple, then choose the lexicographically ascending canonical "
            "serialized complete rule vector"
        ),
    }
    embedded = _embedded_selection(
        document,
        evidence_store,
        "non-ash-selector-selection-v1.schema.json",
    )
    if evidence_store.reopen(str(neighbor_binding["sha256"])) != neighbor_manifest:
        raise ProductionEvaluatorError("non-ASH neighbor manifest failed reopen")
    return embedded


def _selection_document(embedded: Mapping[str, object], label: str) -> Mapping[str, object]:
    if set(embedded) != {"sha256", "document"}:
        raise ProductionEvaluatorError(f"{label} embedded selection field set differs")
    document = embedded.get("document")
    if (
        not isinstance(document, dict)
        or embedded.get("sha256") != canonical_sha256(document)
    ):
        raise ProductionEvaluatorError(f"{label} embedded selection hash is invalid")
    return document


def _development_selection_search_contract(
    selector_contract: Mapping[str, object],
) -> Mapping[str, object]:
    _validate_non_ash_contract(selector_contract)
    return {
        "fixed_descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
        "conventional_algorithm_ids": list(CONVENTIONAL_ALGORITHM_IDS),
        "non_ash_selector_contract": json.loads(
            canonical_json_bytes(selector_contract)
        ),
        "selection_objective": dict(SELECTION_OBJECTIVE),
        "fixed_tie_break": (
            "lexicographically maximize the development engine_raw "
            "corpus-mean tuple, then choose the numerically smallest "
            "descriptor ID"
        ),
        "conventional_tie_break": (
            "lexicographically maximize the development engine_raw "
            "corpus-mean tuple, then choose the lexicographically "
            "ascending stable algorithm ID"
        ),
        "non_ash_tie_break": (
            "lexicographically maximize the development engine_raw "
            "corpus-mean tuple, then choose the lexicographically ascending "
            "canonical serialized complete rule vector"
        ),
    }


def _selection_cache_file_sha256(path: Path, label: str) -> str:
    try:
        if path.is_symlink() or not path.is_file():
            raise OSError(f"{label} is not a regular file")
        payload = path.read_bytes()
    except OSError as error:
        raise ProductionEvaluatorError(f"{label} cannot be hash-bound") from error
    return hashlib.sha256(payload).hexdigest()


def _validate_development_selection_cache_identity(
    identity: Mapping[str, object],
) -> Mapping[str, object]:
    if (
        not isinstance(identity, dict)
        or set(identity) != _DEVELOPMENT_SELECTION_CACHE_IDENTITY_FIELDS
    ):
        raise ProductionEvaluatorError(
            "development control-selection cache identity field set differs"
        )
    context = identity.get("aggregate_identity_context")
    ordered = identity.get("ordered_input_bindings")
    search = identity.get("selection_search_contract")
    implementation = identity.get("implementation_closure")
    if (
        identity.get("schema_version") != "1.0.0"
        or identity.get("artifact_kind")
        != "p06_development_control_selection_cache_identity"
        or identity.get("split") != "development"
        or identity.get("selection_stage") != "development_provisional"
        or identity.get("reuse_scope")
        != "exact_bank_aggregate_input_search_implementation_identity"
        or not _is_sha256(
            identity.get("shared_bank_configuration_sha256")
        )
        or not _is_sha256(identity.get("degradation_policy_sha256"))
        or not isinstance(context, dict)
        or not isinstance(search, dict)
        or not isinstance(implementation, dict)
        or set(implementation)
        != _DEVELOPMENT_SELECTION_CACHE_IMPLEMENTATION_FIELDS
        or any(not _is_sha256(value) for value in implementation.values())
    ):
        raise ProductionEvaluatorError(
            "development control-selection cache identity is invalid"
        )
    validated_context = _validate_non_ash_aggregate_context(context)
    validated_ordered = _validate_non_ash_ordered_input_bindings(ordered)
    selector = validated_context["baseline_selector_contract"]
    if search != _development_selection_search_contract(selector):
        raise ProductionEvaluatorError(
            "development control-selection search identity differs"
        )
    _reject_path_or_sealed_split_fields(identity)
    normalized = json.loads(canonical_json_bytes(identity))
    normalized["aggregate_identity_context"] = validated_context
    normalized["ordered_input_bindings"] = validated_ordered
    return normalized


def _development_selection_cache_identity(
    *,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
    aggregate_identity_context: Mapping[str, object],
    ordered_input_bindings: Sequence[Mapping[str, object]],
    cache_implementation_identity: Mapping[str, object],
) -> Mapping[str, object]:
    cache_implementation = dict(cache_implementation_identity)
    if (
        set(cache_implementation)
        != _DEVELOPMENT_SELECTION_CACHE_CAPABILITY_IMPLEMENTATION_FIELDS
        or any(not _is_sha256(value) for value in cache_implementation.values())
    ):
        raise ProductionEvaluatorError(
            "development control-selection cache implementation identity is invalid"
        )
    schema_sha256 = _selection_cache_file_sha256(
        SCHEMAS_ROOT / _DEVELOPMENT_SELECTION_CACHE_SCHEMA,
        "development control-selection cache schema",
    )
    if cache_implementation["cache_schema_sha256"] != schema_sha256:
        raise ProductionEvaluatorError(
            "development control-selection cache schema identity differs"
        )
    context = _validate_non_ash_aggregate_context(
        aggregate_identity_context
    )
    identity = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_development_control_selection_cache_identity",
        "split": "development",
        "selection_stage": "development_provisional",
        "shared_bank_configuration_sha256": _require_sha256(
            shared_bank_configuration_sha256,
            "development control-selection cache shared-bank hash",
        ),
        "degradation_policy_sha256": _require_sha256(
            degradation_policy_sha256,
            "development control-selection cache degradation-policy hash",
        ),
        "aggregate_identity_context": context,
        "ordered_input_bindings": _validate_non_ash_ordered_input_bindings(
            list(ordered_input_bindings)
        ),
        "selection_search_contract": _development_selection_search_contract(
            context["baseline_selector_contract"]
        ),
        "implementation_closure": {
            "production_evaluator_source_sha256": (
                _selection_cache_file_sha256(
                    Path(__file__).resolve(strict=True),
                    "production evaluator source",
                )
            ),
            **cache_implementation,
        },
        "reuse_scope": (
            "exact_bank_aggregate_input_search_implementation_identity"
        ),
    }
    return _validate_development_selection_cache_identity(identity)


def _validate_development_selection_cache_origin(
    origin: Mapping[str, object],
    *,
    identity: Mapping[str, object],
) -> Mapping[str, object]:
    expected_identity = _validate_development_selection_cache_identity(identity)
    if not isinstance(origin, dict):
        raise ProductionEvaluatorError(
            "development control-selection cache origin is not an object"
        )
    try:
        validate_schema(
            origin,
            SCHEMAS_ROOT / _DEVELOPMENT_SELECTION_CACHE_SCHEMA,
        )
    except ValueError as error:
        raise ProductionEvaluatorError(
            "development control-selection cache origin violates its schema"
        ) from error
    unhashed = dict(origin)
    declared = unhashed.pop("origin_manifest_sha256", None)
    artifacts = origin.get("artifacts")
    if (
        origin.get("identity") != expected_identity
        or origin.get("identity_sha256") != canonical_sha256(expected_identity)
        or origin.get("shared_bank_configuration_sha256")
        != expected_identity["shared_bank_configuration_sha256"]
        or origin.get("validation_evidence_imported") is not False
        or origin.get("holdout_evidence_imported") is not False
        or origin.get("candidate_bound_outputs_cached") is not False
        or declared != canonical_sha256(unhashed)
        or not isinstance(artifacts, dict)
        or set(artifacts)
        != {"best_fixed", "conventional", "non_ash_selector"}
    ):
        raise ProductionEvaluatorError(
            "development control-selection cache origin is invalid"
        )
    for name, schema_name in (
        ("best_fixed", "fixed-control-selection-v1.schema.json"),
        ("conventional", "conventional-control-selection-v1.schema.json"),
        ("non_ash_selector", "non-ash-selector-selection-v1.schema.json"),
    ):
        document = _selection_document(artifacts[name], name)
        try:
            validate_schema(document, SCHEMAS_ROOT / schema_name)
        except ValueError as error:
            raise ProductionEvaluatorError(
                "cached development control selection violates its staged schema"
            ) from error
        if (
            document.get("selection_stage") != "development_provisional"
            or document.get("shared_bank_configuration_sha256")
            != expected_identity["shared_bank_configuration_sha256"]
        ):
            raise ProductionEvaluatorError(
                "cached development control selection is stale"
            )
    _reject_path_or_sealed_split_fields(origin)
    return json.loads(canonical_json_bytes(origin))


def _development_selection_cache_origin(
    *,
    identity: Mapping[str, object],
    artifacts: Mapping[str, Mapping[str, object]],
) -> Mapping[str, object]:
    validated_identity = _validate_development_selection_cache_identity(identity)
    origin: Dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_development_control_selection_cache_origin",
        "selection_stage": "development_provisional",
        "split": "development",
        "shared_bank_configuration_sha256": validated_identity[
            "shared_bank_configuration_sha256"
        ],
        "identity_sha256": canonical_sha256(validated_identity),
        "identity": validated_identity,
        "artifacts": json.loads(canonical_json_bytes(artifacts)),
        "validation_evidence_imported": False,
        "holdout_evidence_imported": False,
        "candidate_bound_outputs_cached": False,
    }
    origin["origin_manifest_sha256"] = canonical_sha256(origin)
    return _validate_development_selection_cache_origin(
        origin,
        identity=validated_identity,
    )


def _development_selection_cache_provenance(
    *,
    status: str,
    disabled_reason: Optional[str],
    identity_sha256: Optional[str],
    origin_manifest_sha256: Optional[str],
    selector_counts: Mapping[str, object],
) -> Mapping[str, object]:
    count_fields = {
        "selector_search_invocation_count",
        "selector_rule_aggregate_evaluation_count",
        "selector_search_native_recombination_count",
    }
    if (
        not isinstance(selector_counts, dict)
        or set(selector_counts) != count_fields
        or any(
            not isinstance(selector_counts[field], int)
            or isinstance(selector_counts[field], bool)
            or selector_counts[field] < 0
            for field in count_fields
        )
    ):
        raise ProductionEvaluatorError(
            "development control-selection cache counters are invalid"
        )
    search_count = int(selector_counts["selector_search_invocation_count"])
    aggregate_count = int(
        selector_counts["selector_rule_aggregate_evaluation_count"]
    )
    recombination_count = int(
        selector_counts["selector_search_native_recombination_count"]
    )
    hashes_present = _is_sha256(identity_sha256) and _is_sha256(
        origin_manifest_sha256
    )
    if status == "hit":
        valid = (
            disabled_reason is None
            and hashes_present
            and search_count == 0
            and aggregate_count == 0
            and recombination_count == 0
        )
    elif status == "miss":
        valid = (
            disabled_reason is None
            and hashes_present
            and search_count == 1
            and aggregate_count > 0
        )
    elif status == "disabled" and disabled_reason == "capability_absent":
        valid = (
            identity_sha256 is None
            and origin_manifest_sha256 is None
            and search_count == 1
            and aggregate_count > 0
        )
    elif status == "disabled" and disabled_reason in {
        "runner_selection_supplied",
        "split_not_development",
    }:
        valid = (
            identity_sha256 is None
            and origin_manifest_sha256 is None
            and search_count == 0
            and aggregate_count == 0
            and recombination_count == 0
        )
    else:
        valid = False
    if not valid:
        raise ProductionEvaluatorError(
            "development control-selection cache provenance is inconsistent"
        )
    return {
        "status": status,
        "disabled_reason": disabled_reason,
        "identity_sha256": identity_sha256,
        "origin_manifest_sha256": origin_manifest_sha256,
        "selector_search_invocation_count": search_count,
        "selector_rule_aggregate_evaluation_count": aggregate_count,
        "selector_search_native_recombination_count": recombination_count,
    }


@dataclass(frozen=True)
class _CachedDevelopmentControlSelection:
    selection_stage: str
    shared_bank_configuration_sha256: str
    artifacts: Mapping[str, Mapping[str, object]]
    full_ash_development_candidates_frozen_sha256: None = None


def _validate_p00_identity(identity: Mapping[str, object]) -> str:
    required = {
        "commit",
        "backend_source_sha256",
        "source_manifest_sha256",
        "executable_sha256",
        "configuration_sha256",
        "tile_size",
        "top_k",
        "luma_input_normalization",
        "luma_output_quantization",
        "chroma_reconstruction",
        "direct_3_over_2_postprocess",
        "compatibility_boundary_normalization",
    }
    if set(identity) != required:
        raise ProductionEvaluatorError("P00 identity field set differs")
    for field in (
        "backend_source_sha256",
        "source_manifest_sha256",
        "executable_sha256",
        "configuration_sha256",
    ):
        _require_sha256(identity[field], f"P00 {field}")
    if (
        identity["commit"] != P00_COMMIT
        or identity["backend_source_sha256"] != P00_BACKEND_SHA256
        or identity["tile_size"] != 32
        or identity["top_k"] != 1
        or identity["luma_input_normalization"] != "raw_byte_divided_by_255"
        or identity["luma_output_quantization"] != "rounded_times_255"
        or identity["chroma_reconstruction"] != "nearest"
        or identity["direct_3_over_2_postprocess"]
        != "baseline_MPSImageLanczosScale_after_exact_2x"
        or identity["compatibility_boundary_normalization"]
        != {
            "scope": (
                "reopened P00 helper NV12 output before PlanarFrame "
                "conversion, control-output caching, engine-raw metrics, "
                "and container encoding"
            ),
            "method": "p00_compatibility_nominal_video_range_clip_v1",
            "nominal_y_code_range": [16, 235],
            "nominal_chroma_code_range": [16, 240],
            "evidence": (
                "bind raw and normalized payload SHA-256 values and sizes, "
                "raw and normalized per-plane code ranges, and exact "
                "six-direction clip counts in every P00 native control "
                "record"
            ),
            "already_legal_payload_no_op_required": True,
            "direct_2x_postprocess_behavior": (
                "unchanged exact 2x; compatibility normalization only "
                "clips nominal-range excursions"
            ),
            "uniform_application": (
                "apply identically to every P00 control invocation before "
                "any comparison domain is derived"
            ),
        }
    ):
        raise ProductionEvaluatorError("P00 identity does not match baseline evidence")
    configuration = {
        key: identity[key]
        for key in (
            "tile_size",
            "top_k",
            "luma_input_normalization",
            "luma_output_quantization",
            "chroma_reconstruction",
            "direct_3_over_2_postprocess",
        )
    }
    if canonical_sha256(configuration) != identity["configuration_sha256"]:
        raise ProductionEvaluatorError("P00 configuration hash is invalid")
    return canonical_sha256(identity)


def make_control_selection_bundle(
    *,
    shared_bank_configuration_sha256: str,
    degradation_policy_sha256: str,
    candidate_vector_sha256: str,
    adapter_configuration_sha256: str,
    fixed_selection: Mapping[str, object],
    conventional_selection: Mapping[str, object],
    non_ash_selection: Mapping[str, object],
    p00_identity: Mapping[str, object],
    full_ash_development_candidates_frozen_sha256: object = None,
) -> ControlSelectionBundle:
    """Cross-bind selected controls and their native request bytes to one bank."""

    bank = _require_sha256(
        shared_bank_configuration_sha256,
        "shared-bank hash",
    )
    degradation_policy_hash = _require_sha256(
        degradation_policy_sha256,
        "degradation policy hash",
    )
    _require_sha256(candidate_vector_sha256, "candidate vector hash")
    _require_sha256(adapter_configuration_sha256, "adapter configuration hash")
    fixed = _selection_document(fixed_selection, "fixed")
    conventional = _selection_document(conventional_selection, "conventional")
    non_ash = _selection_document(non_ash_selection, "non-ASH")
    is_v2 = (
        fixed.get("schema_version") == "2.0.0"
        and conventional.get("schema_version") == "2.0.0"
        and non_ash.get("schema_version") == "2.0.2"
    )
    schema_names = (
        (
            "fixed-control-selection-v2.schema.json",
            "conventional-control-selection-v2.schema.json",
            "non-ash-selector-selection-v2.schema.json",
        )
        if is_v2
        else (
            "fixed-control-selection-v1.schema.json",
            "conventional-control-selection-v1.schema.json",
            "non-ash-selector-selection-v1.schema.json",
        )
    )
    for document, schema_name in zip(
        (fixed, conventional, non_ash),
        schema_names,
    ):
        try:
            validate_schema(document, SCHEMAS_ROOT / schema_name)
        except ValueError as error:
            raise ProductionEvaluatorError(
                "selected control violates its staged schema"
            ) from error
    stages = {
        fixed.get("selection_stage"),
        conventional.get("selection_stage"),
        non_ash.get("selection_stage"),
    }
    if len(stages) != 1:
        raise ProductionEvaluatorError("selected controls mix lifecycle stages")
    selection_stage = stages.pop()
    if selection_stage not in {"development_provisional", "validation_final"}:
        raise ProductionEvaluatorError("selected control lifecycle stage is invalid")
    expected_kinds = (
        (
            "p06_fixed_control_selection_v2",
            "p06_conventional_control_selection_v2",
            "p06_non_ash_selector_selection_v2",
        )
        if is_v2
        else (
            "p06_fixed_control_selection",
            "p06_conventional_control_selection",
            "p06_non_ash_selector_selection",
        )
    )
    if (
        fixed.get("artifact_kind") != expected_kinds[0]
        or conventional.get("artifact_kind") != expected_kinds[1]
        or non_ash.get("artifact_kind") != expected_kinds[2]
        or fixed.get("shared_bank_configuration_sha256") != bank
        or conventional.get("shared_bank_configuration_sha256") != bank
        or non_ash.get("shared_bank_configuration_sha256") != bank
        or fixed.get("candidate_ids") != list(FIXED_DESCRIPTOR_IDS)
        or conventional.get("candidate_ids") != list(CONVENTIONAL_ALGORITHM_IDS)
        or fixed.get("uniform_application") is not True
        or conventional.get("uniform_application") is not True
        or non_ash.get("uniform_application") is not True
    ):
        raise ProductionEvaluatorError("selected control artifacts are stale or nonuniform")
    frozen_development_sha256: object = None
    if selection_stage == "development_provisional":
        if full_ash_development_candidates_frozen_sha256 is not None:
            raise ProductionEvaluatorError(
                "development provisional bundle cannot bind a frozen terminal"
            )
    else:
        frozen_development_sha256 = _require_sha256(
            full_ash_development_candidates_frozen_sha256,
            "frozen development-candidate manifest hash",
        )
    selected_descriptor = fixed.get(
        "provisional_descriptor_id"
        if selection_stage == "development_provisional"
        else "chosen_descriptor_id"
    )
    selected_algorithm = conventional.get(
        "provisional_algorithm_id"
        if selection_stage == "development_provisional"
        else "chosen_algorithm_id"
    )
    if is_v2:
        rule_values = non_ash.get(
            "development_terminal_rule_values"
            if selection_stage == "development_provisional"
            else "selected_control_rule_values"
        )
        serialization = non_ash.get("canonical_rule_serialization")
        coordinate_order = (
            serialization.get("coordinate_order")
            if isinstance(serialization, dict)
            else None
        )
        selected_rule = (
            dict(zip(coordinate_order, rule_values))
            if isinstance(coordinate_order, list)
            and isinstance(rule_values, list)
            and len(coordinate_order) == len(rule_values)
            else None
        )
        selected_rule_sha256 = non_ash.get(
            "development_terminal_rule_sha256"
            if selection_stage == "development_provisional"
            else "selected_control_rule_sha256"
        )
    else:
        selected_rule = non_ash.get(
            "development_terminal_rule_configuration"
            if selection_stage == "development_provisional"
            else "selected_rule_configuration"
        )
        selected_rule_sha256 = non_ash.get(
            "development_terminal_rule_sha256"
            if selection_stage == "development_provisional"
            else "selected_rule_sha256"
        )
    if not isinstance(selected_descriptor, int) or not isinstance(selected_algorithm, str):
        raise ProductionEvaluatorError("selected fixed or conventional ID is invalid")
    if not isinstance(selected_rule, dict):
        raise ProductionEvaluatorError("selected non-ASH rule is absent")
    fixed_request = fixed_control_request(selected_descriptor, bank)
    conventional_request = conventional_control_request(selected_algorithm, bank)
    non_ash_request = non_ash_control_request_for_selector_v2(
        selected_rule,
        bank,
        selector_id=(
            NON_ASH_SELECTOR_ID_V2 if is_v2 else NON_ASH_SELECTOR_ID
        ),
    )
    if (
        non_ash_request["parameters"]["selected_rule_sha256"]
        != selected_rule_sha256
    ):
        raise ProductionEvaluatorError("selected non-ASH rule hash differs")
    state_only_configuration = canonical_sha256(
        {
            "control_id": "ash-state-only-base-descriptor-v1",
            "candidate_vector_sha256": candidate_vector_sha256,
        }
    )
    full_request = _control_request(
        control_key="full_ash",
        control_mode="full_ash",
        configuration_sha256=adapter_configuration_sha256,
        shared_bank_configuration_sha256=bank,
        parameters={
            "control_id": "ash-state-plus-branch-compiler-v1",
            "candidate_vector_sha256": candidate_vector_sha256,
        },
    )
    state_only_request = _control_request(
        control_key="state_only",
        control_mode="state_only",
        configuration_sha256=state_only_configuration,
        shared_bank_configuration_sha256=bank,
        parameters={
            "control_id": "ash-state-only-base-descriptor-v1",
            "candidate_vector_sha256": candidate_vector_sha256,
        },
    )
    h07_configuration = canonical_sha256(
        {
            "control_id": "direct2x-then-lanczos3-control-v1",
            "candidate_adapter_configuration_sha256": adapter_configuration_sha256,
        }
    )
    h07_request = _control_request(
        control_key="h07_direct_3_over_2",
        control_mode="h07_direct2x_then_lanczos3",
        configuration_sha256=h07_configuration,
        shared_bank_configuration_sha256=bank,
        parameters={
            "experiment_id": "H07",
            "direct_id": "direct3over2-locked-route-v1",
            "control_id": "direct2x-then-lanczos3-control-v1",
            "candidate_adapter_configuration_sha256": adapter_configuration_sha256,
        },
    )
    nearest_configuration = canonical_sha256(
        {
            "control_id": "nearest-same-writer-420v-v1",
            "shared_bank_configuration_sha256": bank,
        }
    )
    nearest_request = _control_request(
        control_key="nearest_same_writer",
        control_mode="nearest_uniform",
        configuration_sha256=nearest_configuration,
        shared_bank_configuration_sha256=bank,
        parameters={"control_id": "nearest-same-writer-420v-v1"},
    )
    p00_configuration = _validate_p00_identity(p00_identity)
    current_request = _control_request(
        control_key="current_production_ash",
        control_mode="p00_current_production_ash",
        configuration_sha256=p00_configuration,
        shared_bank_configuration_sha256=bank,
        parameters={
            "control_id": "p00-current-production-ash-baseline-v1",
            **dict(p00_identity),
            "p00_backend_reset_before_frame": True,
            "p00_prior_frame_count": 0,
        },
    )
    requests = {
        "full_ash": full_request,
        "best_fixed": fixed_request,
        "conventional": conventional_request,
        "non_ash_selector": non_ash_request,
        "state_only": state_only_request,
        "h07_direct_3_over_2": h07_request,
        "nearest_same_writer": nearest_request,
        "current_production_ash": current_request,
    }
    bundle_document = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_control_selection_bundle",
        "selection_stage": selection_stage,
        "shared_bank_configuration_sha256": bank,
        "degradation_policy_sha256": degradation_policy_hash,
        "full_ash_development_candidates_frozen_sha256": (
            frozen_development_sha256
        ),
        "candidate_vector_sha256": candidate_vector_sha256,
        "adapter_configuration_sha256": adapter_configuration_sha256,
        "fixed_selection_sha256": fixed_selection["sha256"],
        "conventional_selection_sha256": conventional_selection["sha256"],
        "non_ash_selection_sha256": non_ash_selection["sha256"],
        "uniform_application": True,
        "selection_tuple": SELECTION_TUPLE_DESCRIPTION,
        "request_sha256_values": {
            key: request["request_sha256"] for key, request in requests.items()
        },
    }
    bundle_sha256 = canonical_sha256(bundle_document)
    return ControlSelectionBundle(
        selection_stage=str(selection_stage),
        shared_bank_configuration_sha256=bank,
        degradation_policy_sha256=degradation_policy_hash,
        candidate_vector_sha256=candidate_vector_sha256,
        adapter_configuration_sha256=adapter_configuration_sha256,
        fixed_selection=dict(fixed_selection),
        conventional_selection=dict(conventional_selection),
        non_ash_selection=dict(non_ash_selection),
        requests=requests,
        bundle_sha256=bundle_sha256,
    )


def _control_runtime_record(
    adapter: CandidateAdapter,
    before_count: int,
) -> Mapping[str, object]:
    provider = getattr(adapter.callable, "control_runtime_records", None)
    if not callable(provider):
        raise ProductionEvaluatorError(
            "native control capability has no runtime-record provider"
        )
    records = provider()
    if (
        not isinstance(records, (list, tuple))
        or len(records) != before_count + 1
        or not isinstance(records[-1], dict)
    ):
        raise ProductionEvaluatorError(
            "native control capability did not append exactly one runtime record"
        )
    return records[-1]


def _control_record_count(adapter: CandidateAdapter) -> int:
    provider = getattr(adapter.callable, "control_runtime_records", None)
    if not callable(provider):
        raise ProductionEvaluatorError(
            "tracked candidate callable has no native control record capability"
        )
    records = provider()
    if not isinstance(records, (list, tuple)) or any(
        not isinstance(record, dict) for record in records
    ):
        raise ProductionEvaluatorError("native control runtime records are invalid")
    return len(records)


def _invoke_native_control(
    *,
    adapter: CandidateAdapter,
    request: Mapping[str, object],
    low_resolution: PlanarFrame,
    context: CandidateContext,
) -> tuple[PlanarFrame, Mapping[str, object]]:
    reconstruct = getattr(adapter.callable, "reconstruct_control", None)
    if not callable(reconstruct):
        raise ProductionEvaluatorError(
            f"native control mode is unavailable: {request.get('control_key')}"
        )
    if (
        request.get("operation") != "reconstruct_control"
        or request.get("request_sha256")
        != canonical_sha256(
            {key: value for key, value in request.items() if key != "request_sha256"}
        )
        or request.get("shared_bank_configuration_sha256")
        != adapter.configuration.get("shared_bank_configuration_sha256")
    ):
        raise ProductionEvaluatorError("native control request is invalid or stale")
    before_count = _control_record_count(adapter)
    input_hash = frame_sha256(low_resolution)
    output = reconstruct(
        dict(request),
        _isolated_candidate_input(low_resolution),
        context,
    )
    if frame_sha256(low_resolution) != input_hash:
        raise ProductionEvaluatorError("native control mutated its immutable input")
    output = _validate_frame(output, context, "native control output")
    output_hash = frame_sha256(output)
    record = _control_runtime_record(adapter, before_count)
    _reject_path_or_sealed_split_fields(record)
    required = {
        "control_key": request["control_key"],
        "control_mode": request["control_mode"],
        "request_sha256": request["request_sha256"],
        "configuration_sha256": request["configuration_sha256"],
        "shared_bank_configuration_sha256": request[
            "shared_bank_configuration_sha256"
        ],
        "input_frame_sha256": input_hash,
        "output_frame_sha256": output_hash,
        "target_route": context.target_route,
    }
    if any(record.get(key) != value for key, value in required.items()):
        raise ProductionEvaluatorError("native control runtime record is not cross-bound")
    if (
        record.get("parameters") != request.get("parameters")
        or record.get("parameters_sha256")
        != canonical_sha256(request.get("parameters"))
    ):
        raise ProductionEvaluatorError("native control mode proof differs from request")
    declared_record_sha256 = record.get("record_sha256")
    if declared_record_sha256 != canonical_sha256(
        {key: value for key, value in record.items() if key != "record_sha256"}
    ):
        raise ProductionEvaluatorError("native control runtime record self-hash is invalid")
    if request["control_mode"] == "p00_current_production_ash":
        parameters = request["parameters"]
        p00_expected = {
            "p00_commit": parameters["commit"],
            "p00_backend_source_sha256": parameters["backend_source_sha256"],
            "p00_source_manifest_sha256": parameters["source_manifest_sha256"],
            "p00_executable_sha256": parameters["executable_sha256"],
            "p00_configuration_sha256": parameters["configuration_sha256"],
            "p00_backend_reset_before_frame": True,
            "p00_prior_frame_count": 0,
        }
        if any(record.get(key) != value for key, value in p00_expected.items()):
            raise ProductionEvaluatorError("P00 native control identity differs")
    return _freeze_frame(output), dict(record)


def _validate_writer_round_trip(
    *,
    writer: WriterCapability,
    result: WriterRoundTrip,
    control_key: str,
    raw_frame: PlanarFrame,
    context: CandidateContext,
) -> PlanarFrame:
    _require_sha256(writer.settings_sha256, "writer settings hash")
    for value, label in (
        (result.input_frame_sha256, "writer input hash"),
        (result.decoded_frame_sha256, "writer decoded hash"),
        (result.settings_sha256, "writer result settings hash"),
        (result.encoded_sha256, "writer encoded hash"),
        (result.report_sha256, "writer report hash"),
        (result.evidence_sha256, "writer evidence hash"),
    ):
        _require_sha256(value, label)
    decoded = _validate_frame(result.decoded_frame, context, "writer decoded output")
    if (
        result.input_frame_sha256 != frame_sha256(raw_frame)
        or result.decoded_frame_sha256 != frame_sha256(decoded)
        or result.settings_sha256 != writer.settings_sha256
        or result.reopened_and_verified is not True
    ):
        raise ProductionEvaluatorError("writer result is not bound to reopened pixels")
    evidence = writer.reopen_evidence(result.evidence_sha256)
    _reject_path_or_sealed_split_fields(evidence)
    expected = {
        "control_key": control_key,
        "input_frame_sha256": result.input_frame_sha256,
        "decoded_frame_sha256": result.decoded_frame_sha256,
        "settings_sha256": result.settings_sha256,
        "encoded_sha256": result.encoded_sha256,
        "report_sha256": result.report_sha256,
        "reopened_and_verified": True,
    }
    if any(evidence.get(key) != value for key, value in expected.items()):
        raise ProductionEvaluatorError("writer evidence differs from its result")
    if result.evidence_sha256 != canonical_sha256(evidence):
        raise ProductionEvaluatorError("writer evidence content hash is invalid")
    return _freeze_frame(decoded)


class ProductionCalibrationEvaluator:
    """Evaluate one candidate split with native controls and isolated writers."""

    def __init__(
        self,
        *,
        degradation_policy: Mapping[str, object],
        metric_policy: Mapping[str, object],
        selection_bundle: ControlSelectionBundle,
        comparison_identities: Mapping[str, object],
        writer: WriterCapability,
        analytic_fixtures: AnalyticFixtureCapability,
        evidence_store: EvidenceStore,
    ) -> None:
        if (
            degradation_policy.get("status") != "locked"
            or degradation_policy.get("policy_sha256")
            != manifest_sha256(degradation_policy, "policy_sha256")
        ):
            raise ProductionEvaluatorError("degradation policy is not locked or self-hashed")
        if metric_policy.get("policy_sha256") != manifest_sha256(
            metric_policy,
            "policy_sha256",
        ):
            raise ProductionEvaluatorError("metric policy self-hash is invalid")
        analytic_binding = metric_policy.get("analytic_fixture_manifest")
        if (
            not isinstance(analytic_binding, dict)
            or analytic_binding.get("manifest_sha256")
            != analytic_fixtures.manifest_sha256
        ):
            raise ProductionEvaluatorError("analytic fixture capability is stale or absent")
        _require_sha256(writer.settings_sha256, "writer settings hash")
        self.degradation_policy = dict(degradation_policy)
        self.metric_policy = dict(metric_policy)
        self.selection_bundle = selection_bundle
        self.comparison_identities = json.loads(
            canonical_json_bytes(comparison_identities)
        )
        self.writer = writer
        self.analytic_fixtures = analytic_fixtures
        self.evidence_store = evidence_store
        self.profiles = self._route_profiles()

    def _route_profiles(
        self,
    ) -> Mapping[str, Tuple[Mapping[str, object], ...]]:
        profiles = self.degradation_policy.get("profiles")
        if not isinstance(profiles, list):
            raise ProductionEvaluatorError("degradation policy profiles are absent")
        result: Dict[str, Tuple[Mapping[str, object], ...]] = {}
        required_kinds = (
            "lowpass_decimate",
            "camera_blur_decimate",
            "codec_quantized_proxy",
        )
        for route in ROUTES:
            matches = [
                profile
                for profile in profiles
                if isinstance(profile, dict)
                and profile.get("target_route") == route
                and profile.get("kind") != "synthetic_motion"
            ]
            if (
                len(matches) != len(required_kinds)
                or tuple(profile.get("kind") for profile in matches)
                != required_kinds
                or any(
                    not isinstance(profile.get("id"), str)
                    or not profile["id"]
                    for profile in matches
                )
                or len({str(profile["id"]) for profile in matches})
                != len(matches)
            ):
                raise ProductionEvaluatorError(
                    f"locked three-profile spatial coverage differs for {route}"
                )
            result[route] = tuple(dict(profile) for profile in matches)
        return result

    def _validate_adapter(self, adapter: CandidateAdapter) -> None:
        adapter.validate_configuration()
        if (
            adapter.configuration_sha256
            != self.selection_bundle.adapter_configuration_sha256
            or adapter.configuration.get("implementation_role") != "production_swift"
            or adapter.configuration.get("shared_bank_configuration_sha256")
            != self.selection_bundle.shared_bank_configuration_sha256
            or adapter.configuration.get("serialized_candidate_vector_sha256")
            != self.selection_bundle.candidate_vector_sha256
        ):
            raise ProductionEvaluatorError("candidate adapter is stale for control selection")

    def __call__(
        self,
        adapter: CandidateAdapter,
        vector: Mapping[str, object],
        view: SplitView,
        degradation_cache: DegradationCache,
    ) -> Mapping[str, object]:
        self._validate_adapter(adapter)
        if view.split not in {"development", "validation"}:
            raise ProductionEvaluatorError("quality evaluator received a sealed split")
        expected_selection_stage = {
            "development": "development_provisional",
            "validation": "validation_final",
        }[view.split]
        if self.selection_bundle.selection_stage != expected_selection_stage:
            raise ProductionEvaluatorError(
                "control selection lifecycle stage differs from evaluation split"
            )
        if (
            degradation_cache.degradation_policy_sha256
            != self.degradation_policy["policy_sha256"]
            or self.selection_bundle.degradation_policy_sha256
            != self.degradation_policy["policy_sha256"]
        ):
            raise ProductionEvaluatorError("degradation cache uses a stale policy")
        if not view.cases:
            raise ProductionEvaluatorError("quality evaluator has no split cases")
        rows: list[Mapping[str, object]] = []
        control_records: list[Mapping[str, object]] = []
        expected_source_order: list[str] = []
        expected_source_profile_order: list[tuple[str, str]] = []
        observed_routes: set[str] = set()
        for case in view.cases:
            required = {
                "source_asset_id",
                "source_family_id",
                "target_route",
                "categories",
                "target_frame_sha256",
                "opaque_case_token",
            }
            if not required.issubset(case):
                raise ProductionEvaluatorError("split case metadata is incomplete")
            _reject_path_or_sealed_split_fields(case)
            source_id = case["source_asset_id"]
            route = case["target_route"]
            categories = case["categories"]
            if (
                not isinstance(source_id, str)
                or not source_id
                or not isinstance(case["source_family_id"], str)
                or not case["source_family_id"]
                or route not in ROUTES
                or not isinstance(categories, list)
                or not categories
                or len(categories) != len(set(categories))
            ):
                raise ProductionEvaluatorError("split case identity is invalid")
            expected_source_order.append(source_id)
            observed_routes.add(str(route))
            target = view.load_case(str(case["opaque_case_token"]))
            if not isinstance(target, PlanarFrame):
                raise ProductionEvaluatorError("one-use target is not a PlanarFrame")
            if frame_sha256(target) != case["target_frame_sha256"]:
                raise ProductionEvaluatorError("one-use target differs from its lock")
            context = CandidateContext(
                y_shape=target.y.shape,
                cb_shape=target.cb.shape,
                cr_shape=target.cr.shape,
                target_route=str(route),
            )
            for profile in self.profiles[str(route)]:
                profile_id = str(profile["id"])
                profile_sha256 = canonical_sha256(profile)
                expected_source_profile_order.append((source_id, profile_id))
                low_resolution = degradation_cache.get_or_create(
                    source_asset_id=source_id,
                    target_frame=target,
                    target_frame_sha256=str(case["target_frame_sha256"]),
                    profile_id=profile_id,
                    builder=lambda frame, profile=profile: degradation_native_input(
                        frame,
                        profile,
                    ),
                )
                low_resolution = _freeze_frame(low_resolution)
                degraded_input_frame_sha256 = frame_sha256(low_resolution)
                full = adapter.reconstruct(
                    _isolated_candidate_input(low_resolution),
                    context,
                )
                full = _validate_frame(full, context, "full ASH output")
                full_native_sha256 = frame_sha256(full)
                _, full = _round_trip_locked_bt709_video_range_nv12(full)
                if frame_sha256(full) != full_native_sha256:
                    raise ProductionEvaluatorError(
                        "full ASH output is not on the common 420v boundary"
                    )
                raw_outputs: Dict[str, PlanarFrame] = {
                    "full_ash": _freeze_frame(full),
                    "state_plus_branch": _freeze_frame(full),
                }
                for key in (
                    "best_fixed",
                    "conventional",
                    "non_ash_selector",
                    "state_only",
                    "nearest_same_writer",
                    "current_production_ash",
                ):
                    output, record = _invoke_native_control(
                        adapter=adapter,
                        request=self.selection_bundle.request(key),
                        low_resolution=low_resolution,
                        context=context,
                    )
                    _, output = _round_trip_locked_bt709_video_range_nv12(output)
                    if frame_sha256(output) != record["output_frame_sha256"]:
                        raise ProductionEvaluatorError(
                            "native control output is not on the common 420v boundary"
                        )
                    raw_outputs[key] = _freeze_frame(output)
                    control_records.append(record)
                if route == "direct-3over2":
                    output, record = _invoke_native_control(
                        adapter=adapter,
                        request=self.selection_bundle.request(
                            "h07_direct_3_over_2"
                        ),
                        low_resolution=low_resolution,
                        context=context,
                    )
                    _, output = _round_trip_locked_bt709_video_range_nv12(output)
                    if frame_sha256(output) != record["output_frame_sha256"]:
                        raise ProductionEvaluatorError(
                            "H07 output is not on the common 420v boundary"
                        )
                    raw_outputs["h07_direct_3_over_2"] = _freeze_frame(output)
                    control_records.append(record)

                decoded_outputs: Dict[str, PlanarFrame] = {}
                writer_evidence: Dict[str, str] = {}
                for key, raw in raw_outputs.items():
                    result = self.writer.round_trip(
                        control_key=key,
                        frame=raw,
                        context=context,
                    )
                    decoded_outputs[key] = _validate_writer_round_trip(
                        writer=self.writer,
                        result=result,
                        control_key=key,
                        raw_frame=raw,
                        context=context,
                    )
                    writer_evidence[key] = result.evidence_sha256

                raw_metrics = {
                    key: corpus_metric_bundle(target, output)
                    for key, output in raw_outputs.items()
                }
                decoded_metrics: Dict[str, Mapping[str, object]] = {}
                for key, output in decoded_outputs.items():
                    decoded = dict(corpus_metric_bundle(target, output))
                    decoded["writer_y_psnr_contribution_db"] = (
                        float(decoded["y_psnr_db"])
                        - float(raw_metrics[key]["y_psnr_db"])
                    )
                    decoded_metrics[key] = decoded
                for domain, outputs, metrics in (
                    ("engine_raw", raw_outputs, raw_metrics),
                    ("container_decoded", decoded_outputs, decoded_metrics),
                ):
                    row = {
                        "source_asset_id": source_id,
                        "source_family_id": case["source_family_id"],
                        "categories": list(categories),
                        "target_route": route,
                        "degradation_profile_id": profile_id,
                        "degradation_profile_sha256": profile_sha256,
                        "degraded_input_frame_sha256": (
                            degraded_input_frame_sha256
                        ),
                        "comparison_domain": domain,
                        "comparison_identities": self.comparison_identities,
                        "control_output_sha256_values": {
                            key: frame_sha256(output)
                            for key, output in outputs.items()
                        },
                        "metrics_by_control": metrics,
                        "writer_evidence_sha256_values": (
                            {key: None for key in outputs}
                            if domain == "engine_raw"
                            else writer_evidence
                        ),
                    }
                    if "h07_direct_3_over_2" not in outputs:
                        row["control_output_sha256_values"][
                            "h07_direct_3_over_2"
                        ] = None
                        row["metrics_by_control"]["h07_direct_3_over_2"] = None
                        row["writer_evidence_sha256_values"][
                            "h07_direct_3_over_2"
                        ] = None
                    binding = self.evidence_store.publish(row)
                    if self.evidence_store.reopen(str(binding["sha256"])) != row:
                        raise ProductionEvaluatorError(
                            "corpus row failed evidence reopen"
                        )
                    rows.append(row)
        if observed_routes != set(ROUTES):
            raise ProductionEvaluatorError("split cases do not cover both target routes")
        for domain in DOMAINS:
            domain_order = [
                (
                    str(row["source_asset_id"]),
                    str(row["degradation_profile_id"]),
                )
                for row in rows
                if row["comparison_domain"] == domain
            ]
            if domain_order != expected_source_profile_order:
                raise ProductionEvaluatorError(
                    f"{domain} evidence changed locked source/profile order"
                )
        analytic = self.analytic_fixtures.evaluate(
            adapter=adapter,
            selection_bundle=self.selection_bundle,
            comparison_identities=self.comparison_identities,
        )
        _reject_path_or_sealed_split_fields(analytic)
        if (
            analytic.get("artifact_kind") != "p06_analytic_fixture_results"
            or analytic.get("manifest_sha256")
            != self.analytic_fixtures.manifest_sha256
            or analytic.get("shared_bank_configuration_sha256")
            != self.selection_bundle.shared_bank_configuration_sha256
            or analytic.get("status") != "pass"
            or analytic.get("ordinary_candidate_reconstruct_invocations") != 0
            or not isinstance(analytic.get("results"), list)
            or len(analytic["results"]) != 28
            or analytic.get("result_sha256")
            != canonical_sha256(
                {key: value for key, value in analytic.items() if key != "result_sha256"}
            )
        ):
            raise ProductionEvaluatorError("analytic fixture evidence is invalid or stale")
        analytic_binding = self.evidence_store.publish(analytic)
        document: Dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_production_quality_evaluation",
            "split": view.split,
            "candidate_id": adapter.candidate_id,
            "candidate_configuration_sha256": adapter.configuration_sha256,
            "candidate_vector": dict(vector),
            "shared_bank_configuration_sha256": (
                self.selection_bundle.shared_bank_configuration_sha256
            ),
            "control_selection_bundle_sha256": self.selection_bundle.bundle_sha256,
            "degradation_policy_sha256": self.degradation_policy["policy_sha256"],
            "metric_policy_sha256": self.metric_policy["policy_sha256"],
            "writer_settings_sha256": self.writer.settings_sha256,
            "source_order": expected_source_order,
            "source_profile_order": [
                list(value) for value in expected_source_profile_order
            ],
            "comparison_domains": list(DOMAINS),
            "domain_aggregation_performed": False,
            "corpus_results": rows,
            "analytic_fixture_results_sha256": analytic_binding["sha256"],
            "analytic_fixture_results": analytic,
            "control_runtime_records": control_records,
        }
        document["evaluation_sha256"] = canonical_sha256(document)
        _reject_path_or_sealed_split_fields(document)
        return document


@dataclass(frozen=True)
class _PreparedControlCase:
    metadata: Mapping[str, object]
    profile: Mapping[str, object]
    target: PlanarFrame
    low_resolution: PlanarFrame
    context: CandidateContext

    def public_evidence(self) -> Mapping[str, object]:
        return {
            "source_asset_id": self.metadata["source_asset_id"],
            "source_family_id": self.metadata["source_family_id"],
            "categories": list(self.metadata["categories"]),
            "target_route": self.metadata["target_route"],
            "degradation_profile_id": self.profile["id"],
            "degradation_profile_sha256": canonical_sha256(self.profile),
            "target_frame_sha256": frame_sha256(self.target),
            "input_frame_sha256": frame_sha256(self.low_resolution),
            "target_y_shape": list(self.context.y_shape),
            "target_cb_shape": list(self.context.cb_shape),
            "target_cr_shape": list(self.context.cr_shape),
            "low_resolution_y_shape": list(self.low_resolution.y.shape),
        }


@dataclass(frozen=True)
class _NativeOutputCacheEntry:
    item: _PreparedControlCase
    cache_token: str
    manifest: Mapping[str, object]
    preparation_evidence: Mapping[str, object]


def _prepare_native_output_cache(
    *,
    adapter: CandidateAdapter,
    frame: PlanarFrame,
    context: CandidateContext,
    source_asset_id: str,
    degradation_profile_id: Optional[str],
    degradation_profile_sha256: Optional[str],
    shared_bank_configuration_sha256: str,
) -> tuple[str, Mapping[str, object], Mapping[str, object]]:
    provider = getattr(adapter.callable, "prepare_non_ash_cache", None)
    preparation_count_provider = getattr(
        adapter.callable,
        "non_ash_cache_preparation_records_count",
        None,
    )
    preparation_record_provider = getattr(
        adapter.callable,
        "non_ash_cache_preparation_records_record",
        None,
    )
    if not callable(provider):
        raise ProductionEvaluatorError(
            "native non-ASH output-cache preparation capability is absent"
        )
    if not callable(preparation_count_provider) or not callable(
        preparation_record_provider
    ):
        raise ProductionEvaluatorError(
            "native non-ASH cache preparation cursor evidence is absent"
        )
    before_count = preparation_count_provider()
    if (
        not isinstance(before_count, int)
        or isinstance(before_count, bool)
        or before_count < 0
    ):
        raise ProductionEvaluatorError(
            "native non-ASH preparation record count is invalid"
        )
    result = provider(
        frame,
        context,
        source_asset_id=source_asset_id,
        degradation_profile_id=degradation_profile_id,
        degradation_profile_sha256=degradation_profile_sha256,
    )
    after_count = preparation_count_provider()
    if (
        not isinstance(after_count, int)
        or isinstance(after_count, bool)
        or after_count != before_count + 1
    ):
        raise ProductionEvaluatorError(
            "native cache prepare did not append exactly one evidence record"
        )
    appended_record = preparation_record_provider(before_count)
    if not isinstance(appended_record, dict):
        raise ProductionEvaluatorError(
            "native non-ASH preparation cursor record is invalid"
        )
    preparation_record = dict(appended_record)
    result_fields = {
        "cache_token",
        "cache_manifest",
        "cache_reused",
        "preparation_analysis_grid_invocation_count",
        "preparation_spatial_operator_evaluation_count",
        "cache_reopen_evidence_sha256",
        "cache_origin_manifest_sha256",
    }
    if not isinstance(result, dict) or set(result) != result_fields:
        raise ProductionEvaluatorError("native output-cache result field set differs")
    token = result.get("cache_token")
    manifest = result.get("cache_manifest")
    if not _is_sha256(token) or not isinstance(manifest, dict):
        raise ProductionEvaluatorError("native output-cache result is invalid")
    expected_fields = {
        "schema_version",
        "artifact_kind",
        "bank_id",
        "route",
        "source_asset_id",
        "degradation_profile_id",
        "degradation_profile_sha256",
        "input_frame_sha256",
        "dimensions",
        "analysis_grid_invocation_count",
        "feature_tensor_q15_sha256",
        "descriptor_outputs",
        "cache_manifest_sha256",
    }
    unhashed = dict(manifest)
    declared = unhashed.pop("cache_manifest_sha256", None)
    dimensions = manifest.get("dimensions")
    descriptor_outputs = manifest.get("descriptor_outputs")
    expected_dimensions = {
        "input_luma": list(frame.y.shape),
        "input_chroma": list(frame.cb.shape),
        "output_luma": list(context.y_shape),
        "output_chroma": list(context.cb_shape),
    }
    if (
        set(manifest) != expected_fields
        or manifest.get("schema_version") != "1.0.0"
        or manifest.get("artifact_kind") != "p06_native_non_ash_output_cache"
        or manifest.get("bank_id") != shared_bank_configuration_sha256
        or manifest.get("route") != context.target_route
        or manifest.get("source_asset_id") != source_asset_id
        or manifest.get("degradation_profile_id") != degradation_profile_id
        or manifest.get("degradation_profile_sha256")
        != degradation_profile_sha256
        or manifest.get("input_frame_sha256") != frame_sha256(frame)
        or dimensions != expected_dimensions
        or manifest.get("analysis_grid_invocation_count") != 1
        or not _is_sha256(manifest.get("feature_tensor_q15_sha256"))
        or not isinstance(descriptor_outputs, list)
        or [record.get("descriptor_id") for record in descriptor_outputs]
        != list(FIXED_DESCRIPTOR_IDS)
        or any(
            not isinstance(record, dict)
            or set(record) != {"descriptor_id", "output_frame_sha256"}
            or not _is_sha256(record.get("output_frame_sha256"))
            for record in descriptor_outputs
        )
        or declared != canonical_sha256(unhashed)
        or token != declared
    ):
        raise ProductionEvaluatorError(
            "native output-cache manifest is incomplete or stale"
        )
    reused = result.get("cache_reused")
    expected_analysis_count = 0 if reused is True else 1
    expected_operator_count = 0 if reused is True else 16
    if (
        not isinstance(reused, bool)
        or result.get("preparation_analysis_grid_invocation_count")
        != expected_analysis_count
        or result.get("preparation_spatial_operator_evaluation_count")
        != expected_operator_count
        or not _is_sha256(result.get("cache_reopen_evidence_sha256"))
        or not _is_sha256(result.get("cache_origin_manifest_sha256"))
    ):
        raise ProductionEvaluatorError(
            "native output-cache reuse evidence is incomplete"
        )
    preparation_fields = {
        "schema_version",
        "artifact_kind",
        "identity_sha256",
        "cache_token",
        "cache_origin_manifest_sha256",
        "requesting_configuration_id",
        "shared_bank_configuration_sha256",
        "cache_reused",
        "preparation_analysis_grid_invocation_count",
        "preparation_spatial_operator_evaluation_count",
        "cache_artifact_sha256",
        "cache_artifact_size_bytes",
        "feature_tensor_q15_sha256",
        "descriptor_output_frame_sha256_values",
        "record_sha256",
    }
    unhashed_preparation = dict(preparation_record)
    declared_preparation = unhashed_preparation.pop("record_sha256", None)
    if (
        set(preparation_record) != preparation_fields
        or preparation_record.get("schema_version") != "1.0.0"
        or preparation_record.get("artifact_kind")
        != "p06_non_ash_cache_preparation_evidence"
        or not _is_sha256(preparation_record.get("identity_sha256"))
        or preparation_record.get("cache_token") != token
        or preparation_record.get("cache_origin_manifest_sha256")
        != result.get("cache_origin_manifest_sha256")
        or preparation_record.get("requesting_configuration_id")
        != adapter.configuration.get("configuration_id")
        or preparation_record.get("shared_bank_configuration_sha256")
        != shared_bank_configuration_sha256
        or preparation_record.get("cache_reused") is not reused
        or preparation_record.get("preparation_analysis_grid_invocation_count")
        != expected_analysis_count
        or preparation_record.get(
            "preparation_spatial_operator_evaluation_count"
        )
        != expected_operator_count
        or not _is_sha256(preparation_record.get("cache_artifact_sha256"))
        or not isinstance(preparation_record.get("cache_artifact_size_bytes"), int)
        or isinstance(preparation_record.get("cache_artifact_size_bytes"), bool)
        or int(preparation_record["cache_artifact_size_bytes"]) <= 0
        or preparation_record.get("feature_tensor_q15_sha256")
        != manifest.get("feature_tensor_q15_sha256")
        or preparation_record.get("descriptor_output_frame_sha256_values")
        != [
            record["output_frame_sha256"] for record in descriptor_outputs
        ]
        or declared_preparation != canonical_sha256(unhashed_preparation)
        or result.get("cache_reopen_evidence_sha256")
        != declared_preparation
    ):
        raise ProductionEvaluatorError(
            "native cache preparation record is incomplete or stale"
        )
    _reject_path_or_sealed_split_fields(result)
    preparation_evidence = dict(preparation_record)
    return str(token), dict(manifest), preparation_evidence


def _cache_record_delta(
    *,
    adapter: CandidateAdapter,
    provider_name: str,
    invoke: Callable[[], PlanarFrame],
) -> tuple[PlanarFrame, Mapping[str, object]]:
    count_provider = getattr(
        adapter.callable,
        f"{provider_name}_count",
        None,
    )
    record_provider = getattr(
        adapter.callable,
        f"{provider_name}_record",
        None,
    )
    if not callable(count_provider) or not callable(record_provider):
        raise ProductionEvaluatorError(
            f"native cache record cursor is absent: {provider_name}"
        )
    before_count = count_provider()
    if (
        not isinstance(before_count, int)
        or isinstance(before_count, bool)
        or before_count < 0
    ):
        raise ProductionEvaluatorError("native cache record count is invalid")
    output = invoke()
    after_count = count_provider()
    if (
        not isinstance(after_count, int)
        or isinstance(after_count, bool)
        or after_count != before_count + 1
    ):
        raise ProductionEvaluatorError(
            "native cache call did not append exactly one proof record"
        )
    record = record_provider(before_count)
    if not isinstance(record, dict):
        raise ProductionEvaluatorError("native cache cursor record is invalid")
    return output, dict(record)


def _invoke_cached_fixed(
    *,
    adapter: CandidateAdapter,
    cache_token: str,
    cache_manifest: Mapping[str, object],
    descriptor_id: int,
    context: CandidateContext,
    shared_bank_configuration_sha256: str,
) -> tuple[PlanarFrame, Mapping[str, object]]:
    provider = getattr(adapter.callable, "reconstruct_fixed_cached", None)
    if not callable(provider):
        raise ProductionEvaluatorError(
            "native cached fixed reconstruction capability is absent"
        )
    output, record = _cache_record_delta(
        adapter=adapter,
        provider_name="fixed_cache_records",
        invoke=lambda: provider(cache_token, descriptor_id),
    )
    expected_fields = {
        "schema_version",
        "artifact_kind",
        "cache_token",
        "cache_manifest_sha256",
        "descriptor_id",
        "shared_bank_configuration_sha256",
        "input_frame_sha256",
        "output_frame_sha256",
        "target_route",
        "control_request",
        "stateful_lut_lookup_count",
        "spatial_operator_recompute_count",
        "analysis_grid_invocation_count",
        "record_sha256",
    }
    unhashed = dict(record)
    declared = unhashed.pop("record_sha256", None)
    descriptor_outputs = cache_manifest["descriptor_outputs"]
    expected_output = descriptor_outputs[descriptor_id]["output_frame_sha256"]
    request = fixed_control_request(
        descriptor_id,
        shared_bank_configuration_sha256,
    )
    output = _validate_frame(output, context, "cached fixed output")
    _, reopened = _round_trip_locked_bt709_video_range_nv12(output)
    if (
        set(record) != expected_fields
        or record.get("schema_version") != "1.0.0"
        or record.get("artifact_kind")
        != "p06_native_fixed_cached_reconstruction"
        or record.get("cache_token") != cache_token
        or record.get("cache_manifest_sha256") != cache_token
        or record.get("descriptor_id") != descriptor_id
        or record.get("shared_bank_configuration_sha256")
        != shared_bank_configuration_sha256
        or record.get("input_frame_sha256")
        != cache_manifest["input_frame_sha256"]
        or record.get("output_frame_sha256") != expected_output
        or record.get("target_route") != context.target_route
        or record.get("control_request") != request
        or record.get("stateful_lut_lookup_count") != 0
        or record.get("spatial_operator_recompute_count") != 0
        or record.get("analysis_grid_invocation_count") != 0
        or declared != canonical_sha256(unhashed)
        or frame_sha256(output) != expected_output
        or frame_sha256(reopened) != expected_output
    ):
        raise ProductionEvaluatorError(
            "cached fixed reconstruction proof is incomplete or stale"
        )
    return _freeze_frame(output), record


def _invoke_cached_non_ash_with_capability(
    *,
    adapter: CandidateAdapter,
    cache_token: str,
    cache_manifest: Mapping[str, object],
    rule: Mapping[str, object],
    context: CandidateContext,
    capability_name: str,
) -> tuple[PlanarFrame, Mapping[str, object]]:
    provider = getattr(adapter.callable, capability_name, None)
    if not callable(provider):
        raise ProductionEvaluatorError(
            f"native cached non-ASH capability is absent: {capability_name}"
        )
    output, record = _cache_record_delta(
        adapter=adapter,
        provider_name="non_ash_cache_records",
        invoke=lambda: provider(cache_token, rule),
    )
    expected_fields = {
        "schema_version",
        "artifact_kind",
        "cache_token",
        "cache_manifest_sha256",
        "rule_configuration",
        "rule_sha256",
        "output_frame_sha256",
        "target_route",
        "stateful_lut_lookup_count",
        "spatial_operator_recompute_count",
        "analysis_grid_invocation_count",
        "record_sha256",
    }
    canonical_rule = {coordinate: rule[coordinate] for coordinate in NON_ASH_COORDINATES}
    rule_sha256 = canonical_sha256(canonical_rule)
    unhashed = dict(record)
    declared = unhashed.pop("record_sha256", None)
    output = _validate_frame(output, context, "cached non-ASH output")
    _, reopened = _round_trip_locked_bt709_video_range_nv12(output)
    if (
        set(record) != expected_fields
        or record.get("schema_version") != "1.0.0"
        or record.get("artifact_kind")
        != "p06_native_non_ash_cached_reconstruction"
        or record.get("cache_token") != cache_token
        or record.get("cache_manifest_sha256") != cache_token
        or record.get("rule_configuration") != canonical_rule
        or record.get("rule_sha256") != rule_sha256
        or record.get("target_route") != context.target_route
        or record.get("stateful_lut_lookup_count") != 0
        or record.get("spatial_operator_recompute_count") != 0
        or record.get("analysis_grid_invocation_count") != 0
        or declared != canonical_sha256(unhashed)
        or record.get("output_frame_sha256") != frame_sha256(output)
        or frame_sha256(reopened) != frame_sha256(output)
    ):
        raise ProductionEvaluatorError(
            "cached non-ASH reconstruction proof is incomplete or stale"
        )
    return _freeze_frame(output), record


def _invoke_cached_non_ash(
    *,
    adapter: CandidateAdapter,
    cache_token: str,
    cache_manifest: Mapping[str, object],
    rule: Mapping[str, object],
    context: CandidateContext,
) -> tuple[PlanarFrame, Mapping[str, object]]:
    return _invoke_cached_non_ash_with_capability(
        adapter=adapter,
        cache_token=cache_token,
        cache_manifest=cache_manifest,
        rule=rule,
        context=context,
        capability_name="reconstruct_non_ash_cached",
    )


def _reopen_cached_non_ash(
    *,
    adapter: CandidateAdapter,
    cache_token: str,
    cache_manifest: Mapping[str, object],
    rule: Mapping[str, object],
    context: CandidateContext,
) -> tuple[PlanarFrame, Mapping[str, object]]:
    """Validate persisted proof and obtain the current native recombination."""

    return _invoke_cached_non_ash_with_capability(
        adapter=adapter,
        cache_token=cache_token,
        cache_manifest=cache_manifest,
        rule=rule,
        context=context,
        capability_name="reopen_non_ash_cached",
    )


def _validate_non_ash_aggregate_context(
    context: Mapping[str, object],
) -> Mapping[str, object]:
    if (
        not isinstance(context, dict)
        or set(context) != _NON_ASH_AGGREGATE_CONTEXT_FIELDS
    ):
        raise ProductionEvaluatorError(
            "non-ASH aggregate context field set differs"
        )
    selector = context.get("baseline_selector_contract")
    native = context.get("native_implementation_closure")
    quality = context.get("quality_implementation_closure")
    if (
        any(
            not _is_sha256(context.get(field))
            for field in (
                "degradation_policy_file_sha256",
                "metric_policy_file_sha256",
                "metric_policy_sha256",
                "baseline_ablation_contract_file_sha256",
                "baseline_selector_contract_sha256",
                "sample_lock_file_sha256",
                "corpus_manifest_sha256",
                "corpus_lock_bundle_sha256",
                "common_boundary_contract_sha256",
            )
        )
        or not isinstance(selector, dict)
        or canonical_sha256(selector)
        != context.get("baseline_selector_contract_sha256")
        or context.get("common_boundary_contract")
        != COMMON_CONTROL_BOUNDARY_CONTRACT
        or context.get("common_boundary_contract_sha256")
        != canonical_sha256(COMMON_CONTROL_BOUNDARY_CONTRACT)
        or not isinstance(native, dict)
        or set(native) != {
            "executable_sha256",
            "source_manifest_sha256",
        }
        or any(not _is_sha256(value) for value in native.values())
        or not isinstance(quality, dict)
        or set(quality)
        != {
            "implementation_manifest_file_sha256",
            "implementation_manifest_sha256",
        }
        or any(not _is_sha256(value) for value in quality.values())
    ):
        raise ProductionEvaluatorError("non-ASH aggregate context is invalid")
    _validate_non_ash_contract(selector)
    return json.loads(canonical_json_bytes(context))


def _validate_non_ash_ordered_input_bindings(
    ordered: object,
) -> list[Mapping[str, object]]:
    if (
        not isinstance(ordered, list)
        or not ordered
        or any(
            not isinstance(binding, dict)
            or set(binding) != _NON_ASH_AGGREGATE_INPUT_FIELDS
            or binding.get("ordinal") != ordinal
            or not isinstance(binding.get("source_asset_id"), str)
            or not binding["source_asset_id"]
            or not isinstance(binding.get("source_family_id"), str)
            or not binding["source_family_id"]
            or not isinstance(binding.get("categories"), list)
            or not binding["categories"]
            or len(binding["categories"]) != len(set(binding["categories"]))
            or binding.get("target_route") not in ROUTES
            or not isinstance(binding.get("degradation_profile_id"), str)
            or not binding["degradation_profile_id"]
            or any(
                not _is_sha256(binding.get(field))
                for field in (
                    "degradation_profile_sha256",
                    "target_frame_sha256",
                    "input_frame_sha256",
                    "cache_token",
                    "cache_identity_sha256",
                    "cache_origin_manifest_sha256",
                )
            )
            for ordinal, binding in enumerate(ordered)
        )
    ):
        raise ProductionEvaluatorError("non-ASH aggregate identity is invalid")
    return json.loads(canonical_json_bytes(ordered))


def _validate_non_ash_aggregate_identity(
    identity: Mapping[str, object],
) -> Mapping[str, object]:
    if (
        not isinstance(identity, dict)
        or set(identity) != _NON_ASH_AGGREGATE_IDENTITY_FIELDS
    ):
        raise ProductionEvaluatorError(
            "non-ASH aggregate identity field set differs"
        )
    rule = identity.get("rule_configuration")
    ordered = identity.get("ordered_input_bindings")
    context = {
        field: identity[field]
        for field in _NON_ASH_AGGREGATE_CONTEXT_FIELDS
    }
    if (
        identity.get("schema_version") != "1.0.0"
        or identity.get("artifact_kind")
        != "p06_non_ash_control_aggregate_identity"
        or identity.get("split") not in {"development", "validation"}
        or not isinstance(rule, dict)
        or set(rule) != set(NON_ASH_COORDINATES)
        or any(
            not isinstance(rule[name], int)
            or isinstance(rule[name], bool)
            or rule[name] not in NON_ASH_VALUES
            for name in NON_ASH_COORDINATES
        )
        or identity.get("rule_sha256")
        != canonical_sha256(
            {name: rule[name] for name in NON_ASH_COORDINATES}
        )
        or any(
            not _is_sha256(identity.get(field))
            for field in (
                "rule_sha256",
                "control_configuration_sha256",
                "shared_bank_configuration_sha256",
                "degradation_policy_sha256",
            )
        )
        or not isinstance(ordered, list)
    ):
        raise ProductionEvaluatorError("non-ASH aggregate identity is invalid")
    _validate_non_ash_aggregate_context(context)
    _validate_non_ash_ordered_input_bindings(ordered)
    _reject_path_or_sealed_split_fields(identity)
    return json.loads(canonical_json_bytes(identity))


def _ordered_unique_aggregate_dependency_sha256_values(
    native_dependency_sha256: str,
    pending: Sequence[Mapping[str, object]],
) -> list[str]:
    if not _is_sha256(native_dependency_sha256):
        raise ProductionEvaluatorError(
            "native aggregate dependency evidence SHA-256 is invalid"
        )
    ordered = [native_dependency_sha256]
    seen = {native_dependency_sha256}
    for value in pending:
        aggregate = value.get("aggregate")
        if not isinstance(aggregate, dict):
            raise ProductionEvaluatorError(
                "pending non-ASH aggregate document binding is absent"
            )
        for field in (
            "objective_summary_sha256",
            "output_manifest_sha256",
        ):
            document_sha256 = aggregate.get(field)
            if not _is_sha256(document_sha256):
                raise ProductionEvaluatorError(
                    "pending non-ASH aggregate document SHA-256 is invalid"
                )
            assert isinstance(document_sha256, str)
            if document_sha256 in seen:
                continue
            seen.add(document_sha256)
            ordered.append(document_sha256)
    return ordered


class _NativeSelectionOutputCache:
    """One analysis/operator preparation per natural bank/input/route."""

    def __init__(
        self,
        *,
        adapter: CandidateAdapter,
        prepared: Sequence[_PreparedControlCase],
        split: str,
        shared_bank_configuration_sha256: str,
        degradation_policy_sha256: str,
        evidence_store: EvidenceStore,
        aggregate_identity_context: Mapping[str, object],
    ) -> None:
        self.adapter = adapter
        self.split = split
        self.bank = shared_bank_configuration_sha256
        self.degradation_policy_sha256 = degradation_policy_sha256
        self.evidence_store = evidence_store
        self.aggregate_identity_context = _validate_non_ash_aggregate_context(
            aggregate_identity_context
        )
        if (
            adapter.configuration.get("swift_cli")
            != self.aggregate_identity_context[
                "native_implementation_closure"
            ]
            or adapter.configuration.get("raw_output_contract_sha256")
            != self.aggregate_identity_context[
                "common_boundary_contract_sha256"
            ]
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate native implementation closure differs"
            )
        entries = []
        for item in prepared:
            token, manifest, preparation = _prepare_native_output_cache(
                adapter=adapter,
                frame=item.low_resolution,
                context=item.context,
                source_asset_id=str(item.metadata["source_asset_id"]),
                degradation_profile_id=str(item.profile["id"]),
                degradation_profile_sha256=canonical_sha256(item.profile),
                shared_bank_configuration_sha256=self.bank,
            )
            entries.append(
                _NativeOutputCacheEntry(
                    item=item,
                    cache_token=token,
                    manifest=manifest,
                    preparation_evidence=preparation,
                )
            )
        self.entries = tuple(entries)
        self.preparation_evidence_sha256 = canonical_sha256(
            [dict(entry.preparation_evidence) for entry in self.entries]
        )
        manifest = {
            "schema_version": "1.1.0",
            "artifact_kind": "p06_cached_16_operator_output_manifest",
            "split": split,
            "shared_bank_configuration_sha256": self.bank,
            "degradation_policy_sha256": degradation_policy_sha256,
            "descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
            "input_cache_manifest_sha256_values": [
                entry.cache_token for entry in self.entries
            ],
            "input_cache_manifests": [
                dict(entry.manifest) for entry in self.entries
            ],
        }
        binding = evidence_store.publish(manifest)
        if evidence_store.reopen(str(binding["sha256"])) != manifest:
            raise ProductionEvaluatorError(
                "native output-cache set failed reopen verification"
            )
        self.manifest_sha256 = str(binding["sha256"])
        self._fixed: Dict[int, ControlAggregateEvidence] = {}
        self._pending_aggregate_origins: Dict[str, Mapping[str, object]] = {}
        self._pending_native_dependency_record: Optional[
            Mapping[str, object]
        ] = None
        self._pending_native_dependency: Optional[Mapping[str, object]] = None
        self._pending_evidence_dependency: Optional[Mapping[str, object]] = None
        self._development_selector_search_active = False
        self._development_selector_search_invocation_count = 0
        self._development_selector_rule_aggregate_evaluation_count = 0
        self._development_selector_native_recombination_count = 0

    @staticmethod
    def _identity(
        entry: _NativeOutputCacheEntry,
        *,
        configuration_sha256: str,
        degradation_policy_sha256: str,
        bank: str,
    ) -> Mapping[str, object]:
        item = entry.item
        return {
            "source_asset_id": item.metadata["source_asset_id"],
            "source_family_id": item.metadata["source_family_id"],
            "categories": list(item.metadata["categories"]),
            "target_route": item.context.target_route,
            "degradation_profile_id": item.profile["id"],
            "degradation_profile_sha256": canonical_sha256(item.profile),
            "degradation_policy_sha256": degradation_policy_sha256,
            "control_configuration_sha256": configuration_sha256,
            "shared_bank_configuration_sha256": bank,
        }

    def _ordered_input_bindings(self) -> list[Mapping[str, object]]:
        return [
            {
                "ordinal": ordinal,
                "source_asset_id": entry.item.metadata["source_asset_id"],
                "source_family_id": entry.item.metadata["source_family_id"],
                "categories": list(entry.item.metadata["categories"]),
                "target_route": entry.item.context.target_route,
                "degradation_profile_id": entry.item.profile["id"],
                "degradation_profile_sha256": canonical_sha256(
                    entry.item.profile
                ),
                "target_frame_sha256": frame_sha256(entry.item.target),
                "input_frame_sha256": frame_sha256(entry.item.low_resolution),
                "cache_token": entry.cache_token,
                "cache_identity_sha256": entry.preparation_evidence[
                    "identity_sha256"
                ],
                "cache_origin_manifest_sha256": entry.preparation_evidence[
                    "cache_origin_manifest_sha256"
                ],
            }
            for ordinal, entry in enumerate(self.entries)
        ]

    def begin_development_selector_search(self) -> None:
        if self._development_selector_search_active:
            raise ProductionEvaluatorError(
                "development selector search scope is already active"
            )
        self._development_selector_search_active = True
        self._development_selector_search_invocation_count += 1

    def end_development_selector_search(self) -> None:
        if not self._development_selector_search_active:
            raise ProductionEvaluatorError(
                "development selector search scope is not active"
            )
        self._development_selector_search_active = False

    def development_selector_search_counts(self) -> Mapping[str, int]:
        if self._development_selector_search_active:
            raise ProductionEvaluatorError(
                "development selector search counts are not final"
            )
        return {
            "selector_search_invocation_count": (
                self._development_selector_search_invocation_count
            ),
            "selector_rule_aggregate_evaluation_count": (
                self._development_selector_rule_aggregate_evaluation_count
            ),
            "selector_search_native_recombination_count": (
                self._development_selector_native_recombination_count
            ),
        }

    def _non_ash_aggregate_identity(
        self,
        *,
        rule: Mapping[str, object],
        request: Mapping[str, object],
    ) -> Mapping[str, object]:
        canonical_rule = {
            name: int(rule[name]) for name in NON_ASH_COORDINATES
        }
        identity = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_non_ash_control_aggregate_identity",
            "split": self.split,
            "rule_configuration": canonical_rule,
            "rule_sha256": request["parameters"]["selected_rule_sha256"],
            "control_configuration_sha256": request["configuration_sha256"],
            "shared_bank_configuration_sha256": self.bank,
            "degradation_policy_sha256": self.degradation_policy_sha256,
            **self.aggregate_identity_context,
            "ordered_input_bindings": self._ordered_input_bindings(),
        }
        return _validate_non_ash_aggregate_identity(identity)

    def _expected_matrix(self) -> Tuple[Mapping[str, object], ...]:
        return tuple(
            {
                "source_asset_id": entry.item.metadata["source_asset_id"],
                "source_family_id": entry.item.metadata["source_family_id"],
                "categories": list(entry.item.metadata["categories"]),
                "target_route": entry.item.context.target_route,
                "degradation_profile_id": entry.item.profile["id"],
                "degradation_profile_sha256": canonical_sha256(
                    entry.item.profile
                ),
            }
            for entry in self.entries
        )

    @staticmethod
    def _aggregate_binding(
        evidence: ControlAggregateEvidence,
    ) -> Mapping[str, object]:
        return {
            "split": evidence.split,
            "stable_id": evidence.stable_id,
            "shared_bank_configuration_sha256": (
                evidence.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": evidence.degradation_policy_sha256,
            "objective_means": list(evidence.objective_means),
            "objective_summary_sha256": evidence.objective_summary_sha256,
            "output_manifest_sha256": evidence.output_manifest_sha256,
        }

    def _aggregate(
        self,
        *,
        stable_id: object,
        configuration_sha256: str,
        outputs: Sequence[PlanarFrame],
        defer_document_durability: bool,
    ) -> ControlAggregateEvidence:
        rows = []
        for entry, output in zip(self.entries, outputs):
            rows.append(
                {
                    **self._identity(
                        entry,
                        configuration_sha256=configuration_sha256,
                        degradation_policy_sha256=self.degradation_policy_sha256,
                        bank=self.bank,
                    ),
                    "comparison_domain": "engine_raw",
                    "output_sha256": frame_sha256(output),
                    "metrics": corpus_metric_bundle(entry.item.target, output),
                    "writer_evidence_sha256": None,
                }
            )
        aggregate_document_publisher = None
        if defer_document_durability:
            aggregate_document_publisher = getattr(
                self.evidence_store,
                "publish_control_aggregate_document",
                None,
            )
            if not callable(aggregate_document_publisher):
                raise ProductionEvaluatorError(
                    "deferred aggregate-document publisher is absent"
                )
        return make_control_aggregate(
            split=self.split,
            stable_id=stable_id,
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=self.degradation_policy_sha256,
            control_configuration_sha256=configuration_sha256,
            expected_source_profile_matrix=self._expected_matrix(),
            rows=rows,
            evidence_store=self.evidence_store,
            require_decoded_evidence=False,
            aggregate_document_publisher=aggregate_document_publisher,
        )

    def _queue_non_ash_aggregate_origin(
        self,
        *,
        identity: Mapping[str, object],
        evidence: ControlAggregateEvidence,
        records: Sequence[Mapping[str, object]],
    ) -> None:
        if len(records) != len(self.entries) or len(evidence.rows) != len(
            self.entries
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate origin output cardinality differs"
            )
        proofs = []
        for ordinal, (entry, row, record) in enumerate(
            zip(self.entries, evidence.rows, records)
        ):
            if (
                row.get("output_sha256") != record.get("output_frame_sha256")
                or record.get("cache_token") != entry.cache_token
                or not _is_sha256(record.get("record_sha256"))
            ):
                raise ProductionEvaluatorError(
                    "non-ASH aggregate native output proof differs"
                )
            proofs.append(
                {
                    "ordinal": ordinal,
                    "cache_token": entry.cache_token,
                    "output_frame_sha256": row["output_sha256"],
                    "native_record_sha256": record["record_sha256"],
                }
            )
        pending: Dict[str, object] = {
            "identity": dict(identity),
            "aggregate": self._aggregate_binding(evidence),
            "ordered_output_proofs": proofs,
        }
        validated = _validate_pending_control_aggregate_origin(pending)
        identity_sha256 = canonical_sha256(identity)
        if (
            self._pending_native_dependency_record is not None
            or self._pending_native_dependency is not None
            or self._pending_evidence_dependency is not None
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate origin was queued after durability began"
            )
        existing = self._pending_aggregate_origins.get(identity_sha256)
        if existing is not None and existing != validated:
            raise ProductionEvaluatorError(
                "pending non-ASH aggregate origin changed"
            )
        self._pending_aggregate_origins[identity_sha256] = validated

    @property
    def pending_aggregate_origin_count(self) -> int:
        return len(self._pending_aggregate_origins)

    def commit_pending_aggregate_origins(self) -> Mapping[str, object]:
        """Durably order native bytes, evidence documents, then origins."""

        if not self._pending_aggregate_origins:
            record: Dict[str, object] = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_control_aggregate_origin_batch_commit",
                "published_count": 0,
                "ordered_identity_sha256_values": [],
                "ordered_origin_manifest_sha256_values": [],
            }
            record["record_sha256"] = canonical_sha256(record)
            return record

        pending = tuple(self._pending_aggregate_origins.values())
        if self._pending_native_dependency is None:
            if self._pending_native_dependency_record is None:
                flush_provider = getattr(
                    self.adapter.callable,
                    "flush_control_cache_durability",
                    None,
                )
                if not callable(flush_provider):
                    raise ProductionEvaluatorError(
                        "native control-cache durability capability is absent"
                    )
                self._pending_native_dependency_record = (
                    _validate_native_dependency_commit(
                        flush_provider(),
                        adapter=self.adapter,
                        split=self.split,
                        shared_bank_configuration_sha256=self.bank,
                    )
                )
            native_record = self._pending_native_dependency_record
            assert native_record is not None
            native_binding = self.evidence_store.publish(native_record)
            if (
                native_binding.get("sha256")
                != hashlib.sha256(canonical_json_bytes(native_record)).hexdigest()
                or self.evidence_store.reopen(str(native_binding["sha256"]))
                != native_record
            ):
                raise ProductionEvaluatorError(
                    "native durability commit failed evidence publication"
                )
            self._pending_native_dependency = {
                "record": native_record,
                "document_sha256": native_binding["sha256"],
            }

        native_dependency = self._pending_native_dependency
        assert native_dependency is not None
        if self._pending_evidence_dependency is None:
            ordered_documents = (
                _ordered_unique_aggregate_dependency_sha256_values(
                    str(native_dependency["document_sha256"]),
                    pending,
                )
            )
            dependency_result = _validate_evidence_dependency_commit_result(
                self.evidence_store.flush_control_aggregate_dependencies(
                    ordered_documents
                ),
                ordered_document_sha256_values=ordered_documents,
            )
            if (
                self.evidence_store.reopen(
                    str(dependency_result["document_sha256"])
                )
                != dependency_result["record"]
            ):
                raise ProductionEvaluatorError(
                    "aggregate evidence dependency commit failed reopen"
                )
            self._pending_evidence_dependency = dependency_result

        evidence_dependency = self._pending_evidence_dependency
        assert evidence_dependency is not None
        native_record = native_dependency["record"]
        evidence_record = evidence_dependency["record"]
        assert isinstance(native_record, dict)
        assert isinstance(evidence_record, dict)
        entries = []
        origins = []
        for value in pending:
            identity = value["identity"]
            assert isinstance(identity, dict)
            origin: Dict[str, object] = {
                "schema_version": "1.0.0",
                "artifact_kind": (
                    "p06_persisted_non_ash_control_aggregate_origin"
                ),
                "identity": identity,
                "identity_sha256": canonical_sha256(identity),
                "aggregate": value["aggregate"],
                "ordered_output_proofs": value["ordered_output_proofs"],
                "native_dependency_commit_sha256": native_record[
                    "record_sha256"
                ],
                "native_dependency_evidence_sha256": native_dependency[
                    "document_sha256"
                ],
                "evidence_dependency_commit_sha256": evidence_record[
                    "record_sha256"
                ],
                "evidence_dependency_evidence_sha256": evidence_dependency[
                    "document_sha256"
                ],
            }
            origin["origin_manifest_sha256"] = canonical_sha256(origin)
            validated_origin = _validate_control_aggregate_origin_envelope(
                origin,
                identity=identity,
            )
            entries.append(
                {"identity": identity, "origin": validated_origin}
            )
            origins.append(validated_origin)
        batch = self.evidence_store.publish_control_aggregate_origins_batch(
            entries
        )
        unhashed_batch = dict(batch) if isinstance(batch, dict) else {}
        declared_batch = unhashed_batch.pop("record_sha256", None)
        expected_identities = [
            str(origin["identity_sha256"]) for origin in origins
        ]
        expected_origins = [
            str(origin["origin_manifest_sha256"]) for origin in origins
        ]
        if (
            not isinstance(batch, dict)
            or set(batch) != _ORIGIN_BATCH_COMMIT_FIELDS
            or batch.get("schema_version") != "1.0.0"
            or batch.get("artifact_kind")
            != "p06_control_aggregate_origin_batch_commit"
            or batch.get("published_count") != len(origins)
            or batch.get("ordered_identity_sha256_values")
            != expected_identities
            or batch.get("ordered_origin_manifest_sha256_values")
            != expected_origins
            or not _is_sha256(declared_batch)
            or declared_batch != canonical_sha256(unhashed_batch)
        ):
            raise ProductionEvaluatorError(
                "control-aggregate origin batch commit is invalid"
            )
        for entry, origin in zip(entries, origins):
            if (
                self.evidence_store.reopen_control_aggregate_origin(
                    entry["identity"]
                )
                != origin
            ):
                raise ProductionEvaluatorError(
                    "committed control-aggregate origin failed reopen"
                )
        self._pending_aggregate_origins.clear()
        self._pending_native_dependency_record = None
        self._pending_native_dependency = None
        self._pending_evidence_dependency = None
        return batch

    def _reopen_non_ash_aggregate(
        self,
        *,
        identity: Mapping[str, object],
        origin: Mapping[str, object],
        rule: Mapping[str, object],
        request: Mapping[str, object],
    ) -> ControlAggregateEvidence:
        validated_origin = _validate_control_aggregate_origin_envelope(
            origin,
            identity=identity,
        )
        if (
            _validate_non_ash_aggregate_identity(
                validated_origin["identity"]
            )
            != identity
            or identity["ordered_input_bindings"]
            != self._ordered_input_bindings()
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate origin identity changed"
            )
        aggregate = validated_origin["aggregate"]
        native_evidence_sha256 = str(
            validated_origin["native_dependency_evidence_sha256"]
        )
        native_dependency_record = _validate_native_dependency_commit(
            self.evidence_store.reopen(native_evidence_sha256),
            adapter=self.adapter,
            split=self.split,
            shared_bank_configuration_sha256=self.bank,
            require_current_requester=False,
        )
        if (
            native_dependency_record["record_sha256"]
            != validated_origin["native_dependency_commit_sha256"]
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate native dependency commit changed"
            )
        evidence_evidence_sha256 = str(
            validated_origin["evidence_dependency_evidence_sha256"]
        )
        evidence_dependency_record = self.evidence_store.reopen(
            evidence_evidence_sha256
        )
        ordered_dependencies = evidence_dependency_record.get(
            "ordered_document_sha256_values"
        )
        if not isinstance(ordered_dependencies, list):
            raise ProductionEvaluatorError(
                "non-ASH aggregate evidence dependency order is absent"
            )
        evidence_dependency = _validate_evidence_dependency_commit_result(
            {
                "record": evidence_dependency_record,
                "document_sha256": evidence_evidence_sha256,
                "size_bytes": len(
                    canonical_json_bytes(evidence_dependency_record)
                ),
            },
            ordered_document_sha256_values=ordered_dependencies,
        )
        required_dependencies = {
            native_evidence_sha256,
            str(aggregate["objective_summary_sha256"]),
            str(aggregate["output_manifest_sha256"]),
        }
        if (
            evidence_dependency["record"]["record_sha256"]
            != validated_origin["evidence_dependency_commit_sha256"]
            or not required_dependencies.issubset(set(ordered_dependencies))
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate evidence dependency commit changed"
            )
        objective_sha256 = str(aggregate["objective_summary_sha256"])
        output_sha256 = str(aggregate["output_manifest_sha256"])
        objective_document = self.evidence_store.reopen(objective_sha256)
        output_document = self.evidence_store.reopen(output_sha256)
        rows = output_document.get("rows")
        if not isinstance(rows, list):
            raise ProductionEvaluatorError(
                "non-ASH aggregate output manifest rows are absent"
            )
        reproduced = make_control_aggregate(
            split=self.split,
            stable_id=request["parameters"]["selected_rule_sha256"],
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=self.degradation_policy_sha256,
            control_configuration_sha256=str(request["configuration_sha256"]),
            expected_source_profile_matrix=self._expected_matrix(),
            rows=rows,
            evidence_store=self.evidence_store,
            require_decoded_evidence=False,
            aggregate_document_publisher=(
                self.evidence_store.publish_control_aggregate_document
            ),
        )
        if (
            self._aggregate_binding(reproduced) != aggregate
            or self.evidence_store.reopen(reproduced.objective_summary_sha256)
            != objective_document
            or self.evidence_store.reopen(reproduced.output_manifest_sha256)
            != output_document
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate documents changed during reopen"
            )
        proofs = validated_origin["ordered_output_proofs"]
        if len(proofs) != len(self.entries) or len(reproduced.rows) != len(
            self.entries
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate reopen cardinality differs"
            )
        for ordinal, (entry, row, proof) in enumerate(
            zip(self.entries, reproduced.rows, proofs)
        ):
            if (
                proof["ordinal"] != ordinal
                or proof["cache_token"] != entry.cache_token
                or proof["output_frame_sha256"] != row["output_sha256"]
            ):
                raise ProductionEvaluatorError(
                    "non-ASH aggregate output order or hash changed"
                )
            output, record = _reopen_cached_non_ash(
                adapter=self.adapter,
                cache_token=entry.cache_token,
                cache_manifest=entry.manifest,
                rule=rule,
                context=entry.item.context,
            )
            if self._development_selector_search_active:
                self._development_selector_native_recombination_count += 1
            if (
                frame_sha256(output) != proof["output_frame_sha256"]
                or record.get("record_sha256")
                != proof["native_record_sha256"]
                or record.get("rule_sha256") != identity["rule_sha256"]
            ):
                raise ProductionEvaluatorError(
                    "non-ASH aggregate reopened native proof changed"
                )
        return reproduced

    def fixed(self, descriptor_id: int) -> ControlAggregateEvidence:
        existing = self._fixed.get(descriptor_id)
        if existing is not None:
            return existing
        request = fixed_control_request(descriptor_id, self.bank)
        outputs = []
        for entry in self.entries:
            output, _ = _invoke_cached_fixed(
                adapter=self.adapter,
                cache_token=entry.cache_token,
                cache_manifest=entry.manifest,
                descriptor_id=descriptor_id,
                context=entry.item.context,
                shared_bank_configuration_sha256=self.bank,
            )
            outputs.append(output)
        evidence = self._aggregate(
            stable_id=descriptor_id,
            configuration_sha256=str(request["configuration_sha256"]),
            outputs=outputs,
            defer_document_durability=False,
        )
        self._fixed[descriptor_id] = evidence
        return evidence

    def non_ash(self, rule: Mapping[str, object]) -> ControlAggregateEvidence:
        if self._development_selector_search_active:
            self._development_selector_rule_aggregate_evaluation_count += 1
        request = non_ash_control_request(rule, self.bank)
        identity = self._non_ash_aggregate_identity(
            rule=rule,
            request=request,
        )
        origin = self.evidence_store.reopen_control_aggregate_origin(identity)
        if origin is not None:
            return self._reopen_non_ash_aggregate(
                identity=identity,
                origin=origin,
                rule=rule,
                request=request,
            )
        outputs = []
        records = []
        for entry in self.entries:
            output, record = _invoke_cached_non_ash(
                adapter=self.adapter,
                cache_token=entry.cache_token,
                cache_manifest=entry.manifest,
                rule=rule,
                context=entry.item.context,
            )
            if self._development_selector_search_active:
                self._development_selector_native_recombination_count += 1
            if record["rule_sha256"] != request["parameters"][
                "selected_rule_sha256"
            ]:
                raise ProductionEvaluatorError(
                    "cached non-ASH rule identity differs from control request"
                )
            outputs.append(output)
            records.append(record)
        evidence = self._aggregate(
            stable_id=request["parameters"]["selected_rule_sha256"],
            configuration_sha256=str(request["configuration_sha256"]),
            outputs=outputs,
            defer_document_durability=True,
        )
        self._queue_non_ash_aggregate_origin(
            identity=identity,
            evidence=evidence,
            records=records,
        )
        return evidence


class _CapturedSplitView:
    def __init__(
        self,
        *,
        source: SplitView,
        frames: Mapping[str, PlanarFrame],
    ) -> None:
        self.split = source.split
        self.cases = source.cases
        self.input_sha256_bindings = getattr(source, "input_sha256_bindings", ())
        self.corpus_manifest_sha256 = getattr(
            source,
            "corpus_manifest_sha256",
            None,
        )
        self.corpus_lock_bundle_sha256 = getattr(
            source,
            "corpus_lock_bundle_sha256",
            None,
        )
        self.quality_harness_implementation_manifest_sha256 = getattr(
            source,
            "quality_harness_implementation_manifest_sha256",
            None,
        )
        self.candidate_evidence_policy = getattr(
            source,
            "candidate_evidence_policy",
            None,
        )
        self.candidate_evidence_source_sha256_bindings = getattr(
            source,
            "candidate_evidence_source_sha256_bindings",
            (),
        )
        self._frames = dict(frames)

    def load_case(self, opaque_case_token: str) -> PlanarFrame:
        frame = self._frames.pop(opaque_case_token, None)
        if frame is None:
            raise ProductionEvaluatorError(
                "captured split frame is absent or already consumed"
            )
        return frame


class ProductionCandidateEvaluator:
    """Five-argument runner evaluator with staged selection orchestration."""

    def __init__(
        self,
        *,
        degradation_policy: Mapping[str, object],
        metric_policy: Mapping[str, object],
        baseline_ablation_contract: Mapping[str, object],
        baseline_ablation_contract_sha256: str,
        writer: WriterCapability,
        analytic_fixtures: AnalyticFixtureCapability,
        evidence_store: EvidenceStore,
        evaluation_evidence_provider: EvaluationEvidenceProvider,
    ) -> None:
        _require_sha256(
            baseline_ablation_contract_sha256,
            "baseline ablation contract hash",
        )
        if (
            degradation_policy.get("status") != "locked"
            or degradation_policy.get("policy_sha256")
            != manifest_sha256(degradation_policy, "policy_sha256")
        ):
            raise ProductionEvaluatorError("degradation policy is not locked")
        if metric_policy.get("policy_sha256") != manifest_sha256(
            metric_policy,
            "policy_sha256",
        ):
            raise ProductionEvaluatorError("metric policy self-hash is invalid")
        self.degradation_policy = dict(degradation_policy)
        self.metric_policy = dict(metric_policy)
        selector = baseline_ablation_contract.get("non_ash_selector")
        if not isinstance(selector, dict):
            raise ProductionEvaluatorError(
                "baseline contract lacks non-ASH selector"
            )
        _validate_non_ash_contract(selector)
        self.baseline_ablation_contract = dict(baseline_ablation_contract)
        self.baseline_ablation_contract_sha256 = (
            baseline_ablation_contract_sha256
        )
        self.writer = writer
        self.analytic_fixtures = analytic_fixtures
        self.evidence_store = evidence_store
        self.evaluation_evidence_provider = evaluation_evidence_provider
        self._control_authorization_artifact_publisher_v2: Optional[
            ControlAuthorizationArtifactPublisherV2
        ] = None
        self._development_control_selection_cache: Optional[
            DevelopmentControlSelectionCache
        ] = None

    def configure_control_authorization_artifact_publisher_v2(
        self,
        publisher: ControlAuthorizationArtifactPublisherV2,
    ) -> None:
        """Install one producer-owned V2 control artifact publisher."""

        if (
            self._control_authorization_artifact_publisher_v2 is not None
            or not callable(
                getattr(publisher, "publish_raw_control_aggregate_v2", None)
            )
        ):
            raise ProductionEvaluatorError(
                "control authorization artifact publisher is invalid"
            )
        self._control_authorization_artifact_publisher_v2 = publisher

    def configure_development_control_selection_cache(
        self,
        cache: DevelopmentControlSelectionCache,
    ) -> None:
        """Install one runner-owned development-only persistent capability."""

        implementation = getattr(cache, "implementation_identity", None)
        if (
            self._development_control_selection_cache is not None
            or not callable(getattr(cache, "reopen", None))
            or not callable(getattr(cache, "publish", None))
            or not isinstance(implementation, dict)
            or set(implementation)
            != _DEVELOPMENT_SELECTION_CACHE_CAPABILITY_IMPLEMENTATION_FIELDS
            or any(not _is_sha256(value) for value in implementation.values())
        ):
            raise ProductionEvaluatorError(
                "development control-selection cache capability is invalid"
            )
        expected_schema_sha256 = _selection_cache_file_sha256(
            SCHEMAS_ROOT / _DEVELOPMENT_SELECTION_CACHE_SCHEMA,
            "development control-selection cache schema",
        )
        if implementation["cache_schema_sha256"] != expected_schema_sha256:
            raise ProductionEvaluatorError(
                "development control-selection cache capability schema differs"
            )
        self._development_control_selection_cache = cache

    @staticmethod
    def _capture(view: SplitView) -> _CapturedSplitView:
        frames: Dict[str, PlanarFrame] = {}
        for case in view.cases:
            token = case.get("opaque_case_token")
            expected = case.get("target_frame_sha256")
            if not isinstance(token, str) or not _is_sha256(expected):
                raise ProductionEvaluatorError("split case capability is invalid")
            frame = view.load_case(token)
            if not isinstance(frame, PlanarFrame) or frame_sha256(frame) != expected:
                raise ProductionEvaluatorError("captured target differs from its lock")
            frames[token] = _freeze_frame(frame)
        return _CapturedSplitView(source=view, frames=frames)

    def _route_profiles(self, route: str) -> Tuple[Mapping[str, object], ...]:
        profiles = self.degradation_policy.get("profiles")
        if not isinstance(profiles, list):
            raise ProductionEvaluatorError("degradation profiles are absent")
        matches = tuple(
            profile
            for profile in profiles
            if isinstance(profile, dict)
            and profile.get("target_route") == route
            and profile.get("kind") != "synthetic_motion"
        )
        if (
            len(matches) != 3
            or tuple(profile.get("kind") for profile in matches)
            != (
                "lowpass_decimate",
                "camera_blur_decimate",
                "codec_quantized_proxy",
            )
        ):
            raise ProductionEvaluatorError(
                f"three-profile coverage differs for {route}"
            )
        return matches

    def _prepare_cases(
        self,
        captured: _CapturedSplitView,
        degradation_cache: DegradationCache,
    ) -> Tuple[_PreparedControlCase, ...]:
        prepared: list[_PreparedControlCase] = []
        for case in captured.cases:
            token = str(case["opaque_case_token"])
            target = captured._frames.get(token)
            if target is None:
                raise ProductionEvaluatorError("captured target is absent")
            route = str(case["target_route"])
            context = CandidateContext(
                y_shape=target.y.shape,
                cb_shape=target.cb.shape,
                cr_shape=target.cr.shape,
                target_route=route,
            )
            for profile in self._route_profiles(route):
                low_resolution = degradation_cache.get_or_create(
                    source_asset_id=str(case["source_asset_id"]),
                    target_frame=target,
                    target_frame_sha256=str(case["target_frame_sha256"]),
                    profile_id=str(profile["id"]),
                    builder=lambda frame, profile=profile: degradation_native_input(
                        frame,
                        profile,
                    ),
                )
                prepared.append(
                    _PreparedControlCase(
                        metadata=dict(case),
                        profile=dict(profile),
                        target=target,
                        low_resolution=_freeze_frame(low_resolution),
                        context=context,
                    )
                )
        if len(prepared) != len(captured.cases) * 3:
            raise ProductionEvaluatorError("prepared source/profile matrix differs")
        return tuple(prepared)

    @staticmethod
    def _native_p00_identity(adapter: CandidateAdapter) -> Mapping[str, object]:
        provider = getattr(adapter.callable, "p00_identity", None)
        if not callable(provider):
            raise ProductionEvaluatorError("native P00 identity provider is absent")
        identity = provider()
        if not isinstance(identity, dict):
            raise ProductionEvaluatorError("native P00 identity is invalid")
        _validate_p00_identity(identity)
        return dict(identity)

    def _aggregate_identity_context(
        self,
        *,
        adapter: CandidateAdapter,
        captured: _CapturedSplitView,
    ) -> Mapping[str, object]:
        bindings = dict(captured.input_sha256_bindings)
        sample_lock_key = f"{captured.split}_sample_lock"
        swift_cli = adapter.configuration.get("swift_cli")
        selector = self.baseline_ablation_contract.get("non_ash_selector")
        required_binding_keys = {
            "degradation_policy",
            "metric_policy_seed",
            "baseline_ablation_contract",
            sample_lock_key,
            "quality_harness_implementation_manifest",
        }
        if (
            not required_binding_keys.issubset(bindings)
            or any(
                not _is_sha256(bindings[key])
                for key in required_binding_keys
            )
            or not _is_sha256(captured.corpus_manifest_sha256)
            or not _is_sha256(captured.corpus_lock_bundle_sha256)
            or not _is_sha256(
                captured.quality_harness_implementation_manifest_sha256
            )
            or not isinstance(swift_cli, dict)
            or set(swift_cli) != {
                "executable_sha256",
                "source_manifest_sha256",
            }
            or any(not _is_sha256(value) for value in swift_cli.values())
            or not isinstance(selector, dict)
            or adapter.configuration.get("raw_output_contract_sha256")
            != canonical_sha256(COMMON_CONTROL_BOUNDARY_CONTRACT)
        ):
            raise ProductionEvaluatorError(
                "non-ASH aggregate implementation or input closure is absent"
            )
        context = {
            "degradation_policy_file_sha256": bindings[
                "degradation_policy"
            ],
            "metric_policy_file_sha256": bindings["metric_policy_seed"],
            "metric_policy_sha256": self.metric_policy["policy_sha256"],
            "baseline_ablation_contract_file_sha256": bindings[
                "baseline_ablation_contract"
            ],
            "baseline_selector_contract": dict(selector),
            "baseline_selector_contract_sha256": canonical_sha256(selector),
            "sample_lock_file_sha256": bindings[sample_lock_key],
            "corpus_manifest_sha256": captured.corpus_manifest_sha256,
            "corpus_lock_bundle_sha256": captured.corpus_lock_bundle_sha256,
            "common_boundary_contract": COMMON_CONTROL_BOUNDARY_CONTRACT,
            "common_boundary_contract_sha256": canonical_sha256(
                COMMON_CONTROL_BOUNDARY_CONTRACT
            ),
            "native_implementation_closure": dict(swift_cli),
            "quality_implementation_closure": {
                "implementation_manifest_file_sha256": bindings[
                    "quality_harness_implementation_manifest"
                ],
                "implementation_manifest_sha256": (
                    captured.quality_harness_implementation_manifest_sha256
                ),
            },
        }
        return _validate_non_ash_aggregate_context(context)

    def _uniform_control_evidence(
        self,
        *,
        adapter: CandidateAdapter,
        prepared: Sequence[_PreparedControlCase],
        request: Mapping[str, object],
        split: str,
        stable_id: object,
    ) -> ControlAggregateEvidence:
        raw_rows: list[Mapping[str, object]] = []
        publication_rows: list[RawControlMeasurementPublicationV2] = []
        for item in prepared:
            output, record = _invoke_native_control(
                adapter=adapter,
                request=request,
                low_resolution=item.low_resolution,
                context=item.context,
            )
            _, reopened = _round_trip_locked_bt709_video_range_nv12(output)
            if frame_sha256(output) != frame_sha256(reopened):
                raise ProductionEvaluatorError(
                    "selection control output is not on the common boundary"
                )
            output = _freeze_frame(output)
            raw_metrics = corpus_metric_bundle(item.target, output)
            identity = {
                "source_asset_id": item.metadata["source_asset_id"],
                "source_family_id": item.metadata["source_family_id"],
                "categories": list(item.metadata["categories"]),
                "target_route": item.context.target_route,
                "degradation_profile_id": item.profile["id"],
                "degradation_profile_sha256": canonical_sha256(item.profile),
                "degradation_policy_sha256": self.degradation_policy[
                    "policy_sha256"
                ],
                "control_configuration_sha256": request[
                    "configuration_sha256"
                ],
                "shared_bank_configuration_sha256": request[
                    "shared_bank_configuration_sha256"
                ],
            }
            raw_rows.append(
                {
                    **identity,
                    "comparison_domain": "engine_raw",
                    "output_sha256": frame_sha256(output),
                    "metrics": raw_metrics,
                    "writer_evidence_sha256": None,
                }
            )
            if record["configuration_sha256"] != request["configuration_sha256"]:
                raise ProductionEvaluatorError(
                    "selection control runtime configuration differs"
                )
            publication_rows.append(
                RawControlMeasurementPublicationV2(
                    metadata=dict(item.metadata),
                    profile=dict(item.profile),
                    target=item.target,
                    low_resolution=item.low_resolution,
                    raw_output=output,
                    native_execution_record=dict(record),
                )
            )
        expected_matrix = tuple(
            {
                "source_asset_id": item.metadata["source_asset_id"],
                "source_family_id": item.metadata["source_family_id"],
                "categories": list(item.metadata["categories"]),
                "target_route": item.context.target_route,
                "degradation_profile_id": item.profile["id"],
                "degradation_profile_sha256": canonical_sha256(item.profile),
            }
            for item in prepared
        )
        aggregate = make_control_aggregate(
            split=split,
            stable_id=stable_id,
            shared_bank_configuration_sha256=str(
                request["shared_bank_configuration_sha256"]
            ),
            degradation_policy_sha256=str(
                self.degradation_policy["policy_sha256"]
            ),
            control_configuration_sha256=str(request["configuration_sha256"]),
            expected_source_profile_matrix=expected_matrix,
            rows=raw_rows,
            evidence_store=self.evidence_store,
            require_decoded_evidence=False,
        )
        publisher = self._control_authorization_artifact_publisher_v2
        if publisher is None:
            return aggregate
        run_id = getattr(publisher, "run_id", None)
        if type(run_id) is not str or not run_id:
            raise ProductionEvaluatorError(
                "control authorization artifact publisher run ID is absent"
            )
        authorization_v2 = publisher.publish_raw_control_aggregate_v2(
            adapter=adapter,
            run_id=run_id,
            split=split,
            control_family=(
                "best_fixed"
                if type(stable_id) is int
                else (
                    "conventional"
                    if stable_id in CONVENTIONAL_ALGORITHM_IDS
                    else "non_ash_selector"
                )
            ),
            stable_id=stable_id,
            shared_bank_configuration_sha256=str(
                request["shared_bank_configuration_sha256"]
            ),
            degradation_policy_sha256=str(
                self.degradation_policy["policy_sha256"]
            ),
            control_request=request,
            rows=tuple(publication_rows),
        )
        if not isinstance(authorization_v2, dict):
            raise ProductionEvaluatorError(
                "control authorization artifact publication is invalid"
            )
        return ControlAggregateEvidence(
            split=aggregate.split,
            stable_id=aggregate.stable_id,
            shared_bank_configuration_sha256=(
                aggregate.shared_bank_configuration_sha256
            ),
            degradation_policy_sha256=aggregate.degradation_policy_sha256,
            rows=aggregate.rows,
            objective_means=aggregate.objective_means,
            objective_summary_sha256=aggregate.objective_summary_sha256,
            output_manifest_sha256=aggregate.output_manifest_sha256,
            authorization_v2=json.loads(canonical_json_bytes(authorization_v2)),
        )

    @staticmethod
    def _external_selection(
        control_selection: object,
    ) -> tuple[str, str, Mapping[str, Mapping[str, object]], Optional[str]]:
        stage = getattr(control_selection, "selection_stage", None)
        bank = getattr(
            control_selection,
            "shared_bank_configuration_sha256",
            None,
        )
        artifacts = getattr(control_selection, "artifacts", None)
        frozen = getattr(
            control_selection,
            "full_ash_development_candidates_frozen_sha256",
            None,
        )
        if (
            stage not in {"development_provisional", "validation_final"}
            or not _is_sha256(bank)
            or not isinstance(artifacts, dict)
            or set(artifacts) != {"best_fixed", "conventional", "non_ash_selector"}
        ):
            raise ProductionEvaluatorError("runner control selection is invalid")
        return str(stage), str(bank), artifacts, frozen

    def _make_bundle(
        self,
        *,
        adapter: CandidateAdapter,
        artifacts: Mapping[str, Mapping[str, object]],
        frozen_development_sha256: object = None,
    ) -> ControlSelectionBundle:
        return make_control_selection_bundle(
            shared_bank_configuration_sha256=str(
                adapter.configuration["shared_bank_configuration_sha256"]
            ),
            degradation_policy_sha256=str(
                self.degradation_policy["policy_sha256"]
            ),
            candidate_vector_sha256=str(
                adapter.configuration["serialized_candidate_vector_sha256"]
            ),
            adapter_configuration_sha256=adapter.configuration_sha256,
            fixed_selection=artifacts["best_fixed"],
            conventional_selection=artifacts["conventional"],
            non_ash_selection=artifacts["non_ash_selector"],
            p00_identity=self._native_p00_identity(adapter),
            full_ash_development_candidates_frozen_sha256=(
                frozen_development_sha256
            ),
        )

    def _exhaustive_fixed_and_conventional(
        self,
        *,
        adapter: CandidateAdapter,
        prepared: Sequence[_PreparedControlCase],
        split: str,
        bank: str,
        operator_cache: _NativeSelectionOutputCache,
    ) -> tuple[
        Mapping[int, ControlAggregateEvidence],
        Mapping[str, ControlAggregateEvidence],
        str,
    ]:
        fixed = {
            identifier: operator_cache.fixed(identifier)
            for identifier in FIXED_DESCRIPTOR_IDS
        }
        conventional = {
            identifier: self._uniform_control_evidence(
                adapter=adapter,
                prepared=prepared,
                request=conventional_control_request(identifier, bank),
                split=split,
                stable_id=identifier,
            )
            for identifier in CONVENTIONAL_ALGORITHM_IDS
        }
        return fixed, conventional, operator_cache.manifest_sha256

    def _validate_cached_development_selection_dependencies(
        self,
        *,
        artifacts: Mapping[str, Mapping[str, object]],
        operator_cache: _NativeSelectionOutputCache,
    ) -> None:
        """Reopen the complete selected-search evidence closure without pixels."""

        documents = {
            name: _selection_document(embedded, name)
            for name, embedded in artifacts.items()
        }
        for name, embedded in artifacts.items():
            if self.evidence_store.reopen(str(embedded["sha256"])) != documents[name]:
                raise ProductionEvaluatorError(
                    "cached development selection document changed"
                )

        non_ash = documents["non_ash_selector"]
        cached_manifest_sha256 = non_ash.get(
            "cached_16_operator_output_manifest_sha256"
        )
        if cached_manifest_sha256 != operator_cache.manifest_sha256:
            raise ProductionEvaluatorError(
                "cached development selection input manifest changed"
            )
        manifest = self.evidence_store.reopen(operator_cache.manifest_sha256)
        if (
            manifest.get("artifact_kind")
            != "p06_cached_16_operator_output_manifest"
            or manifest.get("split") != "development"
            or manifest.get("shared_bank_configuration_sha256")
            != operator_cache.bank
            or manifest.get("degradation_policy_sha256")
            != operator_cache.degradation_policy_sha256
            or manifest.get("descriptor_ids") != list(FIXED_DESCRIPTOR_IDS)
            or manifest.get("input_cache_manifest_sha256_values")
            != [
                binding["cache_token"]
                for binding in operator_cache._ordered_input_bindings()
            ]
        ):
            raise ProductionEvaluatorError(
                "cached development selection input manifest is invalid"
            )

        dependency_sha256_values = []
        for name in ("best_fixed", "conventional"):
            results = documents[name].get("development_results")
            if not isinstance(results, list):
                raise ProductionEvaluatorError(
                    "cached development selection results are absent"
                )
            for result in results:
                if not isinstance(result, dict):
                    raise ProductionEvaluatorError(
                        "cached development selection result is invalid"
                    )
                dependency_sha256_values.extend(
                    (
                        result.get("objective_summary_sha256"),
                        result.get("output_manifest_sha256"),
                    )
                )

        attempt_ledger_sha256 = non_ash.get(
            "development_attempt_ledger_sha256"
        )
        terminal_objective_sha256 = non_ash.get(
            "development_objective_summary_sha256"
        )
        if not _is_sha256(attempt_ledger_sha256) or not _is_sha256(
            terminal_objective_sha256
        ):
            raise ProductionEvaluatorError(
                "cached development non-ASH dependencies are absent"
            )
        attempt_ledger = self.evidence_store.reopen(
            str(attempt_ledger_sha256)
        )
        records = attempt_ledger.get("records")
        if (
            attempt_ledger.get("schema_version") != "1.0.0"
            or attempt_ledger.get("artifact_kind")
            != "p06_non_ash_selector_attempt_ledger"
            or attempt_ledger.get("selection_stage")
            != "development_provisional"
            or attempt_ledger.get("shared_bank_configuration_sha256")
            != operator_cache.bank
            or attempt_ledger.get("degradation_policy_sha256")
            != operator_cache.degradation_policy_sha256
            or not isinstance(records, list)
            or len(records) != non_ash.get("development_attempt_count")
        ):
            raise ProductionEvaluatorError(
                "cached development non-ASH attempt ledger is invalid"
            )
        terminal_rule_sha256 = non_ash.get(
            "development_terminal_rule_sha256"
        )
        terminal_record_found = False
        required_record_fields = {
            "ordinal",
            "split",
            "rule_sha256",
            "rule_serialization",
            "objective_summary_sha256",
            "output_manifest_sha256",
        }
        for ordinal, record in enumerate(records):
            if (
                not isinstance(record, dict)
                or set(record) != required_record_fields
                or record.get("ordinal") != ordinal
                or record.get("split") != "development"
                or not _is_sha256(record.get("rule_sha256"))
                or not isinstance(record.get("rule_serialization"), list)
                or len(record["rule_serialization"]) != len(NON_ASH_COORDINATES)
                or any(
                    not isinstance(value, int)
                    or isinstance(value, bool)
                    or value not in NON_ASH_VALUES
                    for value in record["rule_serialization"]
                )
                or not _is_sha256(record.get("objective_summary_sha256"))
                or not _is_sha256(record.get("output_manifest_sha256"))
            ):
                raise ProductionEvaluatorError(
                    "cached development non-ASH attempt record is invalid"
                )
            dependency_sha256_values.extend(
                (
                    record["objective_summary_sha256"],
                    record["output_manifest_sha256"],
                )
            )
            if (
                record["rule_sha256"] == terminal_rule_sha256
                and record["objective_summary_sha256"]
                == terminal_objective_sha256
            ):
                terminal_record_found = True
        if not terminal_record_found:
            raise ProductionEvaluatorError(
                "cached development terminal non-ASH evidence is absent"
            )
        for dependency_sha256 in dict.fromkeys(dependency_sha256_values):
            if not _is_sha256(dependency_sha256):
                raise ProductionEvaluatorError(
                    "cached development selection dependency hash is invalid"
                )
            self.evidence_store.reopen(str(dependency_sha256))

    def _resolve_selection(
        self,
        *,
        adapter: CandidateAdapter,
        prepared: Sequence[_PreparedControlCase],
        split: str,
        control_selection: object,
        operator_cache: _NativeSelectionOutputCache,
    ) -> tuple[ControlSelectionBundle, Mapping[str, Mapping[str, object]]]:
        bank = str(adapter.configuration["shared_bank_configuration_sha256"])
        if split == "development":
            if control_selection is not None:
                stage, supplied_bank, artifacts, frozen = self._external_selection(
                    control_selection
                )
                if (
                    stage != "development_provisional"
                    or supplied_bank != bank
                    or frozen is not None
                ):
                    raise ProductionEvaluatorError(
                        "development received stale or validation-bound controls"
                    )
                return self._make_bundle(adapter=adapter, artifacts=artifacts), artifacts
            fixed, conventional, cached_manifest_sha256 = (
                self._exhaustive_fixed_and_conventional(
                    adapter=adapter,
                    prepared=prepared,
                    split="development",
                    bank=bank,
                    operator_cache=operator_cache,
                )
            )
            fixed_artifacts = select_development_provisional_controls(
                shared_bank_configuration_sha256=bank,
                degradation_policy_sha256=str(
                    self.degradation_policy["policy_sha256"]
                ),
                development_fixed=fixed,
                development_conventional=conventional,
                evidence_store=self.evidence_store,
            )

            def development_rule(
                rule: Mapping[str, object],
            ) -> ControlAggregateEvidence:
                return operator_cache.non_ash(rule)

            operator_cache.begin_development_selector_search()
            try:
                non_ash = search_non_ash_development(
                    shared_bank_configuration_sha256=bank,
                    degradation_policy_sha256=str(
                        self.degradation_policy["policy_sha256"]
                    ),
                    selector_contract=self.baseline_ablation_contract[
                        "non_ash_selector"
                    ],
                    development_evaluator=development_rule,
                    cached_16_operator_output_manifest_sha256=(
                        cached_manifest_sha256
                    ),
                    evidence_store=self.evidence_store,
                )
            finally:
                operator_cache.end_development_selector_search()
            operator_cache.commit_pending_aggregate_origins()
            artifacts = {
                **fixed_artifacts,
                "non_ash_selector": non_ash,
            }
            return self._make_bundle(adapter=adapter, artifacts=artifacts), artifacts

        if split != "validation" or control_selection is None:
            raise ProductionEvaluatorError(
                "validation requires runner-authorized development controls"
            )
        stage, supplied_bank, artifacts, frozen = self._external_selection(
            control_selection
        )
        if supplied_bank != bank or not _is_sha256(frozen):
            raise ProductionEvaluatorError(
                "validation control context lacks the verified development freeze"
            )
        if stage == "validation_final":
            return (
                self._make_bundle(
                    adapter=adapter,
                    artifacts=artifacts,
                    frozen_development_sha256=frozen,
                ),
                artifacts,
            )
        if stage != "development_provisional":
            raise ProductionEvaluatorError("validation selection stage is invalid")
        fixed, conventional, _ = self._exhaustive_fixed_and_conventional(
            adapter=adapter,
            prepared=prepared,
            split="validation",
            bank=bank,
            operator_cache=operator_cache,
        )
        fixed_artifacts = finalize_fixed_and_conventional_controls(
            shared_bank_configuration_sha256=bank,
            degradation_policy_sha256=str(
                self.degradation_policy["policy_sha256"]
            ),
            development_provisional={
                "best_fixed": artifacts["best_fixed"],
                "conventional": artifacts["conventional"],
            },
            validation_fixed=fixed,
            validation_conventional=conventional,
            full_ash_development_candidates_frozen_sha256=str(frozen),
            evidence_store=self.evidence_store,
        )

        def validation_rule(
            rule: Mapping[str, object],
        ) -> ControlAggregateEvidence:
            return operator_cache.non_ash(rule)

        non_ash = finalize_non_ash_validation(
            shared_bank_configuration_sha256=bank,
            degradation_policy_sha256=str(
                self.degradation_policy["policy_sha256"]
            ),
            development_provisional=artifacts["non_ash_selector"],
            validation_evaluator=validation_rule,
            full_ash_development_candidates_frozen_sha256=str(frozen),
            evidence_store=self.evidence_store,
        )
        operator_cache.commit_pending_aggregate_origins()
        final_artifacts = {
            **fixed_artifacts,
            "non_ash_selector": non_ash,
        }
        return (
            self._make_bundle(
                adapter=adapter,
                artifacts=final_artifacts,
                frozen_development_sha256=frozen,
            ),
            final_artifacts,
        )

    def _ensure_natural_check_controls(
        self,
        *,
        adapter: CandidateAdapter,
        prepared: Sequence[_PreparedControlCase],
        selection_bundle: ControlSelectionBundle,
        operator_cache: _NativeSelectionOutputCache,
    ) -> None:
        """Materialize the complete natural-case check scope exactly once."""

        existing = self._native_records(adapter, "control_runtime_records")
        full_keys = {
            (
                str(record.get("input_frame_sha256")),
                str(record.get("target_route")),
            )
            for record in existing
            if record.get("control_mode") == "full_ash"
        }
        for item in prepared:
            input_sha256 = frame_sha256(item.low_resolution)
            full_key = (input_sha256, item.context.target_route)
            if full_key not in full_keys:
                output, record = _invoke_native_control(
                    adapter=adapter,
                    request=selection_bundle.request("full_ash"),
                    low_resolution=item.low_resolution,
                    context=item.context,
                )
                _, reopened = _round_trip_locked_bt709_video_range_nv12(output)
                if (
                    frame_sha256(output) != frame_sha256(reopened)
                    or record.get("control_mode") != "full_ash"
                    or not isinstance(record.get("locked_runtime_summary"), dict)
                ):
                    raise ProductionEvaluatorError(
                        "natural full-ASH check control is not on the locked boundary"
                    )
                full_keys.add(full_key)
        for descriptor_id in FIXED_DESCRIPTOR_IDS:
            operator_cache.fixed(descriptor_id)

    def _comparison_identities(
        self,
        *,
        adapter: CandidateAdapter,
        captured: _CapturedSplitView,
        bundle: ControlSelectionBundle,
        artifacts: Mapping[str, Mapping[str, object]],
    ) -> Mapping[str, object]:
        bindings = dict(captured.input_sha256_bindings)
        quality_policy_sha256 = bindings.get("quality_gate_policy_seed")
        baseline_sha256 = bindings.get("baseline_ablation_contract")
        if (
            not _is_sha256(quality_policy_sha256)
            or baseline_sha256 != self.baseline_ablation_contract_sha256
        ):
            raise ProductionEvaluatorError(
                "comparison policy bindings are absent or stale"
            )
        fixed_document = _selection_document(artifacts["best_fixed"], "fixed")
        conventional_document = _selection_document(
            artifacts["conventional"],
            "conventional",
        )
        non_ash_document = _selection_document(
            artifacts["non_ash_selector"],
            "non-ASH",
        )
        development = bundle.selection_stage == "development_provisional"
        descriptor_id = fixed_document[
            "provisional_descriptor_id" if development else "chosen_descriptor_id"
        ]
        algorithm_id = conventional_document[
            "provisional_algorithm_id" if development else "chosen_algorithm_id"
        ]
        rule_sha256 = non_ash_document[
            "development_terminal_rule_sha256"
            if development
            else (
                "selected_control_rule_sha256"
                if non_ash_document.get("schema_version") == "2.0.2"
                else "selected_rule_sha256"
            )
        ]
        bank = bundle.shared_bank_configuration_sha256
        baseline_selection = self.baseline_ablation_contract_sha256
        requests = bundle.requests
        return {
            "shared_bank_configuration_sha256": bank,
            "quality_policy_seed_sha256": quality_policy_sha256,
            "baseline_ablation_contract_sha256": baseline_sha256,
            "best_fixed": {
                "control_id": "fixed-descriptor-uniform-v1",
                "descriptor_id": descriptor_id,
                "configuration_sha256": requests["best_fixed"][
                    "configuration_sha256"
                ],
                "selection_sha256": artifacts["best_fixed"]["sha256"],
                "shared_bank_configuration_sha256": bank,
            },
            "conventional": {
                "control_id": "uniform-conventional-selection-v1",
                "algorithm_id": algorithm_id,
                "configuration_sha256": requests["conventional"][
                    "configuration_sha256"
                ],
                "selection_sha256": artifacts["conventional"]["sha256"],
                "shared_bank_configuration_sha256": bank,
            },
            "non_ash_selector": {
                "selector_id": non_ash_document["selector_id"],
                "configuration_sha256": requests["non_ash_selector"][
                    "configuration_sha256"
                ],
                "selection_sha256": artifacts["non_ash_selector"]["sha256"],
                "rule_sha256": rule_sha256,
                "candidate_evaluation_budget": non_ash_document[
                    "candidate_evaluation_budget"
                ],
                "shared_bank_configuration_sha256": bank,
            },
            "state_only": {
                "control_id": "ash-state-only-base-descriptor-v1",
                "configuration_sha256": requests["state_only"][
                    "configuration_sha256"
                ],
                "selection_sha256": baseline_selection,
                "shared_bank_configuration_sha256": bank,
            },
            "state_plus_branch": {
                "control_id": "ash-state-plus-branch-compiler-v1",
                "configuration_sha256": adapter.configuration_sha256,
                "selection_sha256": baseline_selection,
                "shared_bank_configuration_sha256": bank,
            },
            "h07_direct_3_over_2": {
                "experiment_id": "H07",
                "direct_id": "direct3over2-locked-route-v1",
                "control_id": "direct2x-then-lanczos3-control-v1",
                "configuration_sha256": requests["h07_direct_3_over_2"][
                    "configuration_sha256"
                ],
                "selection_sha256": baseline_selection,
                "shared_bank_configuration_sha256": bank,
                "evidence_sha256": baseline_selection,
            },
            "nearest_same_writer": {
                "control_id": "nearest-same-writer-420v-v1",
                "configuration_sha256": requests["nearest_same_writer"][
                    "configuration_sha256"
                ],
                "selection_sha256": baseline_selection,
                "shared_bank_configuration_sha256": bank,
            },
            "current_production_ash": {
                "control_id": "p00-current-production-ash-baseline-v1",
                "configuration_sha256": requests["current_production_ash"][
                    "configuration_sha256"
                ],
                "selection_sha256": baseline_selection,
                "shared_bank_configuration_sha256": bank,
            },
        }

    @staticmethod
    def _native_records(adapter: CandidateAdapter, provider_name: str) -> Tuple[Mapping[str, object], ...]:
        provider = getattr(adapter.callable, provider_name, None)
        if not callable(provider):
            raise ProductionEvaluatorError(
                f"native evidence provider is absent: {provider_name}"
            )
        records = provider()
        if not isinstance(records, (list, tuple)) or any(
            not isinstance(record, dict) for record in records
        ):
            raise ProductionEvaluatorError(
                f"native evidence records are invalid: {provider_name}"
            )
        return tuple(dict(record) for record in records)

    @staticmethod
    def _runtime_invocations(
        *,
        adapter: CandidateAdapter,
        prepared: Sequence[_PreparedControlCase],
        records: Sequence[Mapping[str, object]],
    ) -> list[Mapping[str, object]]:
        if len(records) != len(prepared):
            raise ProductionEvaluatorError(
                "native full-runtime record count differs from corpus matrix"
            )
        invocations = []
        for item, record in zip(prepared, records):
            expected = {
                "input_frame_sha256": frame_sha256(item.low_resolution),
                "target_route": item.context.target_route,
            }
            if any(record.get(key) != value for key, value in expected.items()):
                raise ProductionEvaluatorError(
                    "native full-runtime record differs from prepared input"
                )
            invocations.append(
                {
                    "source_asset_id": item.metadata["source_asset_id"],
                    "degradation_profile_id": item.profile["id"],
                    "degradation_profile_sha256": canonical_sha256(item.profile),
                    "target_route": item.context.target_route,
                    "input_frame_sha256": record["input_frame_sha256"],
                    "output_frame_sha256": record["output_frame_sha256"],
                    "adapter_configuration_sha256": adapter.configuration_sha256,
                    "native_summary_sha256": canonical_sha256(record),
                }
            )
        return invocations

    @staticmethod
    def _control_runtime_invocations(
        records: Sequence[Mapping[str, object]],
    ) -> list[Mapping[str, object]]:
        invocations = []
        for record in records:
            parameters = record.get("parameters")
            if not isinstance(parameters, dict):
                raise ProductionEvaluatorError(
                    "native control record lacks exact parameters"
                )
            request = {
                "schema_version": "1.0.0",
                "operation": "reconstruct_control",
                "control_key": record.get("control_key"),
                "control_mode": record.get("control_mode"),
                "configuration_sha256": record.get("configuration_sha256"),
                "shared_bank_configuration_sha256": record.get(
                    "shared_bank_configuration_sha256"
                ),
                "parameters": parameters,
            }
            request["request_sha256"] = canonical_sha256(request)
            if (
                request["request_sha256"] != record.get("request_sha256")
                or record.get("record_sha256")
                != canonical_sha256(
                    {
                        key: value
                        for key, value in record.items()
                        if key != "record_sha256"
                    }
                )
            ):
                raise ProductionEvaluatorError(
                    "native control record request or self-hash differs"
                )
            invocations.append(
                {
                    "request": request,
                    "request_sha256": request["request_sha256"],
                    "request_document_sha256": canonical_sha256(request),
                    "input_frame_sha256": record["input_frame_sha256"],
                    "output_frame_sha256": record["output_frame_sha256"],
                    "target_route": record["target_route"],
                    "native_summary_sha256": canonical_sha256(record),
                }
            )
        return invocations

    @staticmethod
    def _runtime_summary(
        adapter: CandidateAdapter,
        records: Sequence[Mapping[str, object]],
    ) -> Mapping[str, object]:
        if not records:
            raise ProductionEvaluatorError("native full-runtime evidence is empty")
        fields = {
            "measured_cpu_reference_analysis_traversals": (
                "cpu_reference_analysis_traversals"
            ),
            "measured_cpu_reference_full_frame_reconstruction_loops": (
                "cpu_reference_full_frame_loop_count"
            ),
            "production_metal_constraint_satisfied": (
                "production_metal_constraint_satisfied"
            ),
            "loaded_lut_instance_count": "loaded_lut_instance_count",
            "per_frame_lut_load_count": "per_frame_lut_load_count",
            "runtime_leaf_tree_generations": "runtime_leaf_tree_generations",
            "runtime_path_generations": "runtime_path_generations",
            "configuration_id": "configuration_id",
            "chroma_convention": "chroma_convention",
        }
        summary = {
            output_name: records[0].get(record_name)
            for output_name, record_name in fields.items()
        }
        if any(
            record.get(record_name) != summary[output_name]
            for record in records
            for output_name, record_name in fields.items()
        ):
            raise ProductionEvaluatorError(
                "native full-runtime summaries are inconsistent"
            )
        if summary["configuration_id"] != adapter.configuration.get(
            "configuration_id"
        ):
            raise ProductionEvaluatorError(
                "runtime summary configuration identity differs"
            )
        return summary

    def __call__(
        self,
        adapter: CandidateAdapter,
        vector: Mapping[str, object],
        view: SplitView,
        degradation_cache: DegradationCache,
        control_selection: object,
    ) -> Mapping[str, object]:
        if view.split not in {"development", "validation"}:
            raise ProductionEvaluatorError("candidate evaluator received sealed split")
        captured = self._capture(view)
        prepared = self._prepare_cases(captured, degradation_cache)
        aggregate_identity_context = self._aggregate_identity_context(
            adapter=adapter,
            captured=captured,
        )
        operator_cache = _NativeSelectionOutputCache(
            adapter=adapter,
            prepared=prepared,
            split=view.split,
            shared_bank_configuration_sha256=str(
                adapter.configuration["shared_bank_configuration_sha256"]
            ),
            degradation_policy_sha256=str(
                self.degradation_policy["policy_sha256"]
            ),
            evidence_store=self.evidence_store,
            aggregate_identity_context=aggregate_identity_context,
        )
        effective_control_selection = control_selection
        cache_identity: Optional[Mapping[str, object]] = None
        cache_missed = False
        selection_cache = self._development_control_selection_cache
        cache_status = "disabled"
        cache_disabled_reason: Optional[str]
        if view.split != "development":
            cache_disabled_reason = "split_not_development"
        elif control_selection is not None:
            cache_disabled_reason = "runner_selection_supplied"
        elif selection_cache is None:
            cache_disabled_reason = "capability_absent"
        else:
            cache_disabled_reason = None
        cache_identity_sha256: Optional[str] = None
        cache_origin_manifest_sha256: Optional[str] = None
        if (
            view.split == "development"
            and control_selection is None
            and selection_cache is not None
        ):
            cache_identity = _development_selection_cache_identity(
                shared_bank_configuration_sha256=str(
                    adapter.configuration[
                        "shared_bank_configuration_sha256"
                    ]
                ),
                degradation_policy_sha256=str(
                    self.degradation_policy["policy_sha256"]
                ),
                aggregate_identity_context=aggregate_identity_context,
                ordered_input_bindings=(
                    operator_cache._ordered_input_bindings()
                ),
                cache_implementation_identity=(
                    selection_cache.implementation_identity
                ),
            )
            cache_identity_sha256 = canonical_sha256(cache_identity)
            cached_origin = selection_cache.reopen(cache_identity)
            if cached_origin is None:
                cache_missed = True
                cache_status = "miss"
            else:
                validated_origin = _validate_development_selection_cache_origin(
                    cached_origin,
                    identity=cache_identity,
                )
                cache_status = "hit"
                cache_origin_manifest_sha256 = str(
                    validated_origin["origin_manifest_sha256"]
                )
                cached_artifacts = validated_origin["artifacts"]
                if not isinstance(cached_artifacts, dict):
                    raise ProductionEvaluatorError(
                        "cached development selection artifacts are invalid"
                    )
                self._validate_cached_development_selection_dependencies(
                    artifacts=cached_artifacts,
                    operator_cache=operator_cache,
                )
                effective_control_selection = (
                    _CachedDevelopmentControlSelection(
                        selection_stage="development_provisional",
                        shared_bank_configuration_sha256=str(
                            cache_identity[
                                "shared_bank_configuration_sha256"
                            ]
                        ),
                        artifacts=cached_artifacts,
                    )
                )
        bundle, artifacts = self._resolve_selection(
            adapter=adapter,
            prepared=prepared,
            split=view.split,
            control_selection=effective_control_selection,
            operator_cache=operator_cache,
        )
        if cache_missed:
            assert cache_identity is not None
            assert selection_cache is not None
            origin = _development_selection_cache_origin(
                identity=cache_identity,
                artifacts=artifacts,
            )
            cache_origin_manifest_sha256 = str(
                origin["origin_manifest_sha256"]
            )
            published = selection_cache.publish(
                identity=cache_identity,
                origin=origin,
            )
            if (
                _validate_development_selection_cache_origin(
                    published,
                    identity=cache_identity,
                )
                != origin
            ):
                raise ProductionEvaluatorError(
                    "development control-selection cache publication changed"
                )
        cache_provenance = _development_selection_cache_provenance(
            status=cache_status,
            disabled_reason=cache_disabled_reason,
            identity_sha256=cache_identity_sha256,
            origin_manifest_sha256=cache_origin_manifest_sha256,
            selector_counts=operator_cache.development_selector_search_counts(),
        )
        comparison_identities = self._comparison_identities(
            adapter=adapter,
            captured=captured,
            bundle=bundle,
            artifacts=artifacts,
        )
        self._ensure_natural_check_controls(
            adapter=adapter,
            prepared=prepared,
            selection_bundle=bundle,
            operator_cache=operator_cache,
        )
        selected_evaluator = ProductionCalibrationEvaluator(
            degradation_policy=self.degradation_policy,
            metric_policy=self.metric_policy,
            selection_bundle=bundle,
            comparison_identities=comparison_identities,
            writer=self.writer,
            analytic_fixtures=self.analytic_fixtures,
            evidence_store=self.evidence_store,
        )
        selected = selected_evaluator(
            adapter,
            vector,
            captured,
            degradation_cache,
        )
        native_runtime_records = self._native_records(adapter, "runtime_records")
        native_control_records = self._native_records(
            adapter,
            "control_runtime_records",
        )
        runtime_invocations = self._runtime_invocations(
            adapter=adapter,
            prepared=prepared,
            records=native_runtime_records,
        )
        control_runtime_invocations = self._control_runtime_invocations(
            native_control_records
        )
        analytic_document = selected.get("analytic_fixture_results")
        if not isinstance(analytic_document, dict) or not isinstance(
            analytic_document.get("results"),
            list,
        ):
            raise ProductionEvaluatorError("analytic fixture result document is absent")
        corpus_rows = selected.get("corpus_results")
        if not isinstance(corpus_rows, list):
            raise ProductionEvaluatorError("corpus result rows are absent")
        policy = captured.candidate_evidence_policy
        source_bindings = captured.candidate_evidence_source_sha256_bindings
        if not isinstance(policy, dict) or not isinstance(
            source_bindings,
            (list, tuple),
        ):
            raise ProductionEvaluatorError(
                "candidate evidence policy capability is absent"
            )
        provider_result = self.evaluation_evidence_provider.evaluation_evidence(
            adapter=adapter,
            vector=vector,
            split=view.split,
            prepared_cases=prepared,
            corpus_asset_results=corpus_rows,
            analytic_fixture_results=analytic_document["results"],
            selection_bundle=bundle,
            comparison_identities=comparison_identities,
            candidate_evidence_policy=policy,
            candidate_evidence_policy_sha256=_require_sha256(
                dict(captured.input_sha256_bindings).get(
                    "candidate_evidence_policy"
                ),
                "candidate evidence policy hash",
            ),
            candidate_evidence_source_sha256_bindings=source_bindings,
            native_runtime_records=native_runtime_records,
            native_control_records=native_control_records,
        )
        if not isinstance(provider_result, dict) or set(provider_result) != {
            "checks",
            "performance",
            "dispatch_measurement",
        }:
            raise ProductionEvaluatorError(
                "evaluation evidence provider field set differs"
            )
        document: Dict[str, object] = {
            "schema_version": "1.1.0",
            "artifact_kind": "p06_candidate_evaluation",
            "candidate_id": adapter.candidate_id,
            "candidate_vector_sha256": adapter.configuration[
                "serialized_candidate_vector_sha256"
            ],
            "adapter_configuration_sha256": adapter.configuration_sha256,
            "split": view.split,
            "runtime_evidence": dict(adapter.configuration),
            "runtime_invocations": runtime_invocations,
            "control_runtime_invocations": control_runtime_invocations,
            "runtime_summary": self._runtime_summary(
                adapter,
                native_runtime_records,
            ),
            "comparison_identities": comparison_identities,
            "control_selection_artifacts": dict(artifacts),
            "development_control_selection_cache": cache_provenance,
            "corpus_asset_results": corpus_rows,
            "analytic_fixture_results": analytic_document["results"],
            **provider_result,
        }
        if view.split == "validation":
            frozen = getattr(
                control_selection,
                "full_ash_development_candidates_frozen_sha256",
                None,
            )
            document["full_ash_development_candidates_frozen_sha256"] = (
                _require_sha256(frozen, "frozen development-candidate manifest hash")
            )
        try:
            validate_schema(
                document,
                SCHEMAS_ROOT / "candidate-evaluation-v1.schema.json",
            )
        except ValueError as error:
            raise ProductionEvaluatorError(
                f"candidate evaluation violates its schema: {error}"
            ) from error
        _reject_path_or_sealed_split_fields(document)
        return document


def production_candidate_evaluator(
    *,
    degradation_policy: Mapping[str, object],
    metric_policy: Mapping[str, object],
    baseline_ablation_contract: Mapping[str, object],
    baseline_ablation_contract_sha256: str,
    writer: WriterCapability,
    analytic_fixtures: AnalyticFixtureCapability,
    evidence_store: EvidenceStore,
    evaluation_evidence_provider: EvaluationEvidenceProvider,
) -> ProductionCandidateEvaluator:
    """Assemble the concrete five-argument evaluator used by CalibrationExecutor."""

    return ProductionCandidateEvaluator(
        degradation_policy=degradation_policy,
        metric_policy=metric_policy,
        baseline_ablation_contract=baseline_ablation_contract,
        baseline_ablation_contract_sha256=(
            baseline_ablation_contract_sha256
        ),
        writer=writer,
        analytic_fixtures=analytic_fixtures,
        evidence_store=evidence_store,
        evaluation_evidence_provider=evaluation_evidence_provider,
    )
