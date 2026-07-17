"""Native-measurement adapter for schema-2 P06 candidate evaluations.

This module owns no search or quality formula.  It sequences one split-scoped
native measurement session around the production V2 control-selection service,
then applies the existing production summary and feasibility functions to the
authenticated raw measurement envelope.  Historical candidate/control
artifacts are rejected rather than translated.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from types import MappingProxyType
from typing import Mapping, Optional, Sequence, Tuple, Union

from validation.calibration_v2.calibration_persistence_v2 import (
    CandidateControlProducerCapabilitiesV2,
    CandidateControlProducerRequestV2,
    FileBindingV2,
    _read_regular_file,
    authority_bindings_v2,
    candidate_evidence_sha256_v2,
    canonical_json_bytes_v2,
    evaluation_semantic_sha256_v2,
    finalize_artifact_sha256_v2,
)
from validation.calibration_v2.calibration_plan_codec import (
    ParsedCalibrationPlanV2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    DEVELOPMENT_SPLIT,
    VALIDATION_SPLIT,
)
from validation.calibration_v2.control_authorization_v2 import (
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    VALIDATION_ADMISSION_KIND,
    TypedArtifactBindingV2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.native_adapter.factory import (
    NativeCandidateAdapterFactory,
)
from validation.calibration_v2.production_control_selection_v2 import (
    ProductionControlSelectionRequestV2,
    ProductionControlSelectionResultV2,
    ProductionControlSelectionV2,
)
from validation.calibration_v2.production_coordinator_v2 import (
    CandidateEvaluationFailureV2,
    CandidateEvaluationRequestV2,
    CandidateEvaluationSuccessV2,
)
from validation.calibration_v2.production_providers import (
    NativeControlExecutionCapabilityProviderV2,
    native_control_execution_capability_provider_v2,
)
from validation.calibration_v2.runner import (
    evaluation_feasible,
    summarize_evaluation,
)
from validation.quality.src.mirmir_quality.json_tools import validate_schema


CALIBRATION_ROOT = Path(__file__).resolve().parent
METRIC_TOLERANCES_SCHEMA = (
    CALIBRATION_ROOT / "schemas/metric-performance-tolerances-v1.schema.json"
)
CANDIDATE_EVALUATION_SCHEMA = (
    CALIBRATION_ROOT / "schemas/candidate-evaluation-v2.schema.json"
)
REQUIRED_SOURCE_GATE_IDS = ("G04", "G05", "G06")
RAW_MEASUREMENT_KIND = "p06_native_candidate_measurements_v2"
RAW_MEASUREMENT_SCHEMA_VERSION = "2.0.0"
ZERO_SHA256 = "0" * 64


class ProductionCandidateProviderV2Error(ValueError):
    """A native session, control authorization, or measurement identity differs."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and value != ZERO_SHA256
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _canonical_object(payload: bytes, *, label: str) -> Mapping[str, object]:
    if type(payload) is not bytes or not payload:
        raise ProductionCandidateProviderV2Error(f"{label} bytes are absent")
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProductionCandidateProviderV2Error(
            f"{label} is not valid UTF-8 JSON"
        ) from error
    if type(document) is not dict or canonical_json_bytes_v2(document) != payload:
        raise ProductionCandidateProviderV2Error(
            f"{label} is not one canonical JSON object"
        )
    return MappingProxyType(document)


@dataclass(frozen=True)
class SourceGateEvidenceV2:
    gate_id: str
    binding: FileBindingV2

    def __post_init__(self) -> None:
        if (
            self.gate_id not in REQUIRED_SOURCE_GATE_IDS
            or type(self.binding) is not FileBindingV2
        ):
            raise ProductionCandidateProviderV2Error(
                "candidate source-gate evidence is invalid"
            )

    def document(self) -> Mapping[str, object]:
        return {
            "id": self.gate_id,
            "path": self.binding.path,
            "sha256": self.binding.sha256,
            "size_bytes": self.binding.size_bytes,
        }


@dataclass(frozen=True)
class NativeCandidateMeasurementV2:
    """Immutable native result produced only after V2 controls are authorized."""

    request: CandidateEvaluationRequestV2
    control_selection: ProductionControlSelectionResultV2
    candidate_id: str
    adapter_configuration_bytes: bytes
    raw_measurement_bytes: bytes

    def __post_init__(self) -> None:
        if (
            type(self.request) is not CandidateEvaluationRequestV2
            or type(self.control_selection) is not ProductionControlSelectionResultV2
            or type(self.candidate_id) is not str
            or not self.candidate_id
        ):
            raise ProductionCandidateProviderV2Error(
                "native candidate measurement identity is invalid"
            )
        _canonical_object(
            self.adapter_configuration_bytes,
            label="native adapter configuration",
        )
        _canonical_object(
            self.raw_measurement_bytes,
            label="native candidate measurement",
        )


class ProductionNativeCandidateMeasurementSessionV2(ABC):
    """One candidate/split session with control and full-measurement phases."""

    @abstractmethod
    def control_selection_request(self) -> ProductionControlSelectionRequestV2:
        """Measure raw controls and return their exact V2 selection request."""

    @abstractmethod
    def control_selection_service(self) -> ProductionControlSelectionV2:
        """Return the selector bound to this session's publisher and replay ID."""

    @abstractmethod
    def measure_authorized_candidate(
        self,
        control_selection: ProductionControlSelectionResultV2,
    ) -> Union[NativeCandidateMeasurementV2, CandidateEvaluationFailureV2]:
        """Measure the full candidate only under the supplied authorization."""

    @abstractmethod
    def close(self) -> None:
        """Close native resources idempotently."""


class ProductionNativeCandidateMeasurementSourceV2(ABC):
    """Factory for authenticated Apple-native candidate measurement sessions."""

    @abstractmethod
    def open_session(
        self,
        request: CandidateEvaluationRequestV2,
    ) -> ProductionNativeCandidateMeasurementSessionV2:
        """Open one development or validation session; holdout is not representable."""


def _typed_validation_admission(
    binding: Optional[FileBindingV2],
) -> Optional[TypedArtifactBindingV2]:
    if binding is None:
        return None
    return TypedArtifactBindingV2(
        artifact_kind=VALIDATION_ADMISSION_KIND,
        schema_sha256=schema_sha256_for_kind_v2(VALIDATION_ADMISSION_KIND),
        path=binding.path,
        sha256=binding.sha256,
        size_bytes=binding.size_bytes,
    )


def _require_control_request_scope(
    candidate_request: CandidateEvaluationRequestV2,
    control_request: ProductionControlSelectionRequestV2,
    *,
    shared_bank_sha256: str,
) -> None:
    if type(control_request) is not ProductionControlSelectionRequestV2:
        raise ProductionCandidateProviderV2Error(
            "native session returned a non-production control request"
        )
    expected_admission = _typed_validation_admission(
        candidate_request.validation_admission
    )
    if (
        control_request.run_id != candidate_request.run_id
        or control_request.split != candidate_request.split
        or control_request.shared_bank_configuration_sha256
        != shared_bank_sha256
        or control_request.non_ash_evaluation_scope.shared_bank_configuration_sha256
        != shared_bank_sha256
        or control_request.non_ash_evaluation_scope.calibration_plan_file_sha256
        != candidate_request.cache_identity.calibration_plan_file_sha256
        or control_request.validation_admission != expected_admission
    ):
        raise ProductionCandidateProviderV2Error(
            "native control-selection request scope differs from the candidate"
        )


def _require_adapter_configuration(
    measurement: NativeCandidateMeasurementV2,
    request: CandidateEvaluationRequestV2,
    *,
    shared_bank_sha256: str,
) -> Mapping[str, object]:
    configuration = _canonical_object(
        measurement.adapter_configuration_bytes,
        label="native adapter configuration",
    )
    physical = dict(request.physical_candidate_items)
    route_luts = configuration.get("route_luts")
    if (
        configuration.get("schema_version") != "2.0.0"
        or configuration.get("implementation_role")
        != "production_swift_format_1_2"
        or configuration.get("physical_candidate_vector") != physical
        or configuration.get("serialized_candidate_vector_sha256")
        != request.cache_identity.candidate_vector_sha256
        or configuration.get("shared_bank_configuration_sha256")
        != shared_bank_sha256
        or configuration.get("calibration_plan_sha256")
        != request.cache_identity.calibration_plan_file_sha256
        or not _is_sha256(configuration.get("compiler_input_file_sha256"))
        or not _is_sha256(configuration.get("compiler_inputs_sha256"))
        or not _is_sha256(
            configuration.get("candidate_lut_runtime_manifest_sha256")
        )
        or type(route_luts) is not dict
        or set(route_luts) != {"direct-2x", "direct-3over2"}
        or any(
            type(route_luts[route]) is not dict
            or not _is_sha256(route_luts[route].get("whole_file_sha256"))
            or not _is_sha256(route_luts[route].get("payload_sha256"))
            for route in ("direct-2x", "direct-3over2")
        )
    ):
        raise ProductionCandidateProviderV2Error(
            "native adapter is not the exact format-1.2 candidate"
        )
    return configuration


_RAW_MEASUREMENT_FIELDS = {
    "schema_version",
    "artifact_kind",
    "run_id",
    "split",
    "candidate_id",
    "candidate_vector_sha256",
    "adapter_configuration_sha256",
    "control_authorization_bundle_sha256",
    "source_profile_matrix_sha256",
    "corpus_asset_results",
    "analytic_fixture_results",
    "checks",
    "performance",
    "dispatch_measurement",
}


def _require_raw_measurement(
    measurement: NativeCandidateMeasurementV2,
    request: CandidateEvaluationRequestV2,
    control_request: ProductionControlSelectionRequestV2,
    configuration: Mapping[str, object],
) -> Mapping[str, object]:
    raw = _canonical_object(
        measurement.raw_measurement_bytes,
        label="native candidate measurement",
    )
    configuration_sha256 = _sha256(measurement.adapter_configuration_bytes)
    if (
        set(raw) != _RAW_MEASUREMENT_FIELDS
        or raw.get("schema_version") != RAW_MEASUREMENT_SCHEMA_VERSION
        or raw.get("artifact_kind") != RAW_MEASUREMENT_KIND
        or raw.get("run_id") != request.run_id
        or raw.get("split") != request.split
        or raw.get("candidate_id") != measurement.candidate_id
        or raw.get("candidate_vector_sha256")
        != request.cache_identity.candidate_vector_sha256
        or raw.get("adapter_configuration_sha256") != configuration_sha256
        or raw.get("control_authorization_bundle_sha256")
        != measurement.control_selection.bundle_binding.sha256
        or raw.get("source_profile_matrix_sha256")
        != control_request.source_profile_matrix_sha256
        or type(raw.get("corpus_asset_results")) is not list
        or type(raw.get("analytic_fixture_results")) is not list
        or type(raw.get("checks")) is not dict
        or type(raw.get("performance")) is not dict
        or type(raw.get("dispatch_measurement")) is not dict
        or configuration.get("configuration_id") not in measurement.candidate_id
    ):
        raise ProductionCandidateProviderV2Error(
            "native candidate measurement scope or field set differs"
        )
    return raw


def _evaluation_document(
    *,
    split: str,
    raw: Mapping[str, object],
    metric_tolerances: Mapping[str, object],
) -> Tuple[Mapping[str, object], Tuple[str, ...], Mapping[str, object]]:
    try:
        summary = summarize_evaluation(raw, metric_tolerances)
        feasible, reasons = evaluation_feasible(raw, summary, metric_tolerances)
    except Exception as error:
        raise ProductionCandidateProviderV2Error(
            "native measurements cannot be reduced by the production metric policy"
        ) from error
    if type(feasible) is not bool or type(reasons) is not tuple:
        raise ProductionCandidateProviderV2Error(
            "production feasibility reduction returned an invalid result"
        )
    if len(reasons) != len(set(reasons)) or any(
        type(reason) is not str or not reason for reason in reasons
    ):
        raise ProductionCandidateProviderV2Error(
            "production feasibility reasons are invalid"
        )
    engine = summary.get("engine_raw")
    if not isinstance(engine, Mapping):
        raise ProductionCandidateProviderV2Error(
            "engine-raw production summary is absent"
        )
    if split == DEVELOPMENT_SPLIT:
        objective_names = (
            "mean_y_psnr_delta_vs_fixed_db",
            "mean_y_psnr_delta_vs_non_ash_db",
            "mean_ms_ssim_delta_vs_conventional",
            "maximum_ringing_excursion",
            "maximum_alias_ratio",
            "estimated_dispatch_cost",
        )
        objective = {name: engine[name] for name in objective_names}
    elif split == VALIDATION_SPLIT:
        try:
            objective = {
                "y_vs_fixed_ci_low": engine["bootstraps"]["y_vs_fixed"][
                    "ci_low"
                ],
                "y_vs_non_ash_ci_low": engine["bootstraps"][
                    "y_vs_non_ash"
                ]["ci_low"],
                "y_vs_conventional_ci_low": engine["bootstraps"][
                    "y_vs_conventional"
                ]["ci_low"],
                "mean_ms_ssim_delta_vs_conventional": engine[
                    "mean_ms_ssim_delta_vs_conventional"
                ],
                "maximum_ringing_excursion": engine[
                    "maximum_ringing_excursion"
                ],
                "maximum_alias_ratio": engine["maximum_alias_ratio"],
                "estimated_dispatch_cost": engine["estimated_dispatch_cost"],
            }
        except (KeyError, TypeError) as error:
            raise ProductionCandidateProviderV2Error(
                "validation production summary ranking fields are absent"
            ) from error
    else:
        raise ProductionCandidateProviderV2Error(
            "candidate measurement split is sealed"
        )
    evaluation = {
        "feasible": feasible,
        "failure_reasons": list(reasons),
        "objective": objective,
    }
    return evaluation, reasons, summary


def build_production_candidate_evaluation_v2(
    *,
    request: CandidateEvaluationRequestV2,
    control_request: ProductionControlSelectionRequestV2,
    measurement: NativeCandidateMeasurementV2,
    metric_tolerances: Mapping[str, object],
    source_gates: Sequence[SourceGateEvidenceV2],
    plan: ParsedCalibrationPlanV2,
) -> Mapping[str, object]:
    """Build one schema-2 candidate solely from authenticated native evidence."""

    if (
        type(request) is not CandidateEvaluationRequestV2
        or type(measurement) is not NativeCandidateMeasurementV2
        or measurement.request is not request
        or type(measurement.control_selection) is not ProductionControlSelectionResultV2
        or type(plan) is not ParsedCalibrationPlanV2
        or plan.plan_file_sha256
        != request.cache_identity.calibration_plan_file_sha256
        or type(source_gates) not in {tuple, list}
        or tuple(gate.gate_id for gate in source_gates)
        != REQUIRED_SOURCE_GATE_IDS
    ):
        raise ProductionCandidateProviderV2Error(
            "candidate evaluation build inputs are invalid"
        )
    physical = dict(request.physical_candidate_items)
    shared_bank_sha256 = shared_bank_configuration_sha256_v2(
        physical,
        plan,
    )
    _require_control_request_scope(
        request,
        control_request,
        shared_bank_sha256=shared_bank_sha256,
    )
    configuration = _require_adapter_configuration(
        measurement,
        request,
        shared_bank_sha256=shared_bank_sha256,
    )
    raw = _require_raw_measurement(
        measurement,
        request,
        control_request,
        configuration,
    )
    evaluation, reasons, _ = _evaluation_document(
        split=request.split,
        raw=raw,
        metric_tolerances=metric_tolerances,
    )
    measurement_sha256 = _sha256(measurement.raw_measurement_bytes)
    checks = (
        [
            {
                "check_id": "candidate-policy-v2",
                "status": "pass",
                "evidence_sha256": measurement_sha256,
            }
        ]
        if not reasons
        else [
            {
                "check_id": reason,
                "status": "fail",
                "evidence_sha256": measurement_sha256,
            }
            for reason in reasons
        ]
    )
    route_luts = configuration["route_luts"]
    document = {
        "schema_version": "2.0.3",
        "artifact_kind": "p06_candidate_evaluation_v2",
        "authority_bindings": authority_bindings_v2(),
        "run_id": request.run_id,
        "candidate_id": measurement.candidate_id,
        "split": request.split,
        "candidate_vector_sha256": request.cache_identity.candidate_vector_sha256,
        "adapter_configuration_sha256": _sha256(
            measurement.adapter_configuration_bytes
        ),
        "physical_candidate_items": [
            [name, value] for name, value in request.physical_candidate_items
        ],
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "degradation_policy_sha256": control_request.degradation_policy_sha256,
        "source_profile_matrix_sha256": (
            control_request.source_profile_matrix_sha256
        ),
        "evaluation_cache_identity": {
            "split": request.split,
            "candidate_vector_sha256": (
                request.cache_identity.candidate_vector_sha256
            ),
            "calibration_plan_v2_file_sha256": (
                request.cache_identity.calibration_plan_file_sha256
            ),
        },
        "source_evidence_sha256_bindings": [
            dict(gate.document()) for gate in source_gates
        ],
        "compiler_input": {
            "file_sha256": configuration["compiler_input_file_sha256"],
            "payload_sha256": configuration["compiler_inputs_sha256"],
        },
        "route_lut_bindings": [
            {
                "route": route,
                "whole_file_sha256": route_luts[route]["whole_file_sha256"],
                "payload_sha256": route_luts[route]["payload_sha256"],
            }
            for route in ("direct-2x", "direct-3over2")
        ],
        "runtime_evidence_sha256": configuration[
            "candidate_lut_runtime_manifest_sha256"
        ],
        "control_authorization_bundle": (
            measurement.control_selection.bundle_binding.as_document()
        ),
        "evaluation": evaluation,
        "evaluation_semantic_sha256": evaluation_semantic_sha256_v2(evaluation),
        "checks": checks,
        "evaluation_status": "feasible" if evaluation["feasible"] else "infeasible",
        "evidence_sha256": ZERO_SHA256,
        "data_access": {
            "development_accessed": request.split == DEVELOPMENT_SPLIT,
            "validation_accessed": request.split == VALIDATION_SPLIT,
            "holdout_accessed": False,
            "release_locks_written": False,
        },
        "artifact_sha256": ZERO_SHA256,
    }
    document["evidence_sha256"] = candidate_evidence_sha256_v2(document)
    finalized = finalize_artifact_sha256_v2(document)
    try:
        validate_schema(finalized, CANDIDATE_EVALUATION_SCHEMA)
    except ValueError as error:
        raise ProductionCandidateProviderV2Error(
            "native candidate evaluation violates schema 2.0.3"
        ) from error
    return finalized


class ProductionCandidateEvaluationProviderV2:
    """Concrete CandidateEvaluationProviderV2 over native production sessions."""

    def __init__(
        self,
        *,
        measurement_source: ProductionNativeCandidateMeasurementSourceV2,
        control_capability_provider: NativeControlExecutionCapabilityProviderV2,
        metric_tolerances: Mapping[str, object],
        source_gates: Sequence[SourceGateEvidenceV2],
        artifact_root: Path,
        plan: ParsedCalibrationPlanV2,
    ) -> None:
        if (
            not isinstance(
                measurement_source,
                ProductionNativeCandidateMeasurementSourceV2,
            )
            or type(control_capability_provider)
            is not NativeControlExecutionCapabilityProviderV2
            or type(plan) is not ParsedCalibrationPlanV2
            or type(source_gates) not in {tuple, list}
            or tuple(gate.gate_id for gate in source_gates)
            != REQUIRED_SOURCE_GATE_IDS
        ):
            raise ProductionCandidateProviderV2Error(
                "production candidate provider capabilities are invalid"
            )
        tolerances = json.loads(canonical_json_bytes_v2(metric_tolerances))
        try:
            validate_schema(tolerances, METRIC_TOLERANCES_SCHEMA)
        except ValueError as error:
            raise ProductionCandidateProviderV2Error(
                "metric-performance tolerances are invalid"
            ) from error
        self.measurement_source = measurement_source
        self.control_capability_provider = control_capability_provider
        self.metric_tolerances = MappingProxyType(tolerances)
        self.source_gates = tuple(source_gates)
        self.artifact_root = Path(artifact_root)
        self.plan = plan
        for gate in self.source_gates:
            self._reopen_gate(gate)

    def _reopen_gate(self, gate: SourceGateEvidenceV2) -> None:
        payload = _read_regular_file(
            self.artifact_root / gate.binding.path,
            label=f"candidate source evidence {gate.gate_id}",
        )
        if (
            len(payload) != gate.binding.size_bytes
            or _sha256(payload) != gate.binding.sha256
        ):
            raise ProductionCandidateProviderV2Error(
                f"candidate source evidence {gate.gate_id} changed"
            )

    def control_producer_capabilities(
        self,
        request: CandidateControlProducerRequestV2,
    ) -> CandidateControlProducerCapabilitiesV2:
        return self.control_capability_provider(request)

    def __call__(
        self,
        request: CandidateEvaluationRequestV2,
    ) -> Union[CandidateEvaluationSuccessV2, CandidateEvaluationFailureV2]:
        if type(request) is not CandidateEvaluationRequestV2:
            raise ProductionCandidateProviderV2Error(
                "candidate provider request has the wrong type"
            )
        for gate in self.source_gates:
            self._reopen_gate(gate)
        session = self.measurement_source.open_session(request)
        if not isinstance(session, ProductionNativeCandidateMeasurementSessionV2):
            raise ProductionCandidateProviderV2Error(
                "native measurement source returned the wrong session type"
            )
        try:
            control_request = session.control_selection_request()
            shared_bank_sha256 = shared_bank_configuration_sha256_v2(
                dict(request.physical_candidate_items),
                self.plan,
            )
            _require_control_request_scope(
                request,
                control_request,
                shared_bank_sha256=shared_bank_sha256,
            )
            control_selection = session.control_selection_service()
            if type(control_selection) is not ProductionControlSelectionV2:
                raise ProductionCandidateProviderV2Error(
                    "native session returned a non-production control service"
                )
            control_result = control_selection.authorize(control_request)
            if type(control_result) is not ProductionControlSelectionResultV2:
                raise ProductionCandidateProviderV2Error(
                    "production control authorization returned the wrong type"
                )
            measurement = session.measure_authorized_candidate(control_result)
            if type(measurement) is CandidateEvaluationFailureV2:
                return measurement
            if (
                type(measurement) is not NativeCandidateMeasurementV2
                or measurement.request is not request
                or measurement.control_selection is not control_result
            ):
                raise ProductionCandidateProviderV2Error(
                    "native candidate measurement differs from its authorization"
                )
            document = build_production_candidate_evaluation_v2(
                request=request,
                control_request=control_request,
                measurement=measurement,
                metric_tolerances=self.metric_tolerances,
                source_gates=self.source_gates,
                plan=self.plan,
            )
            return CandidateEvaluationSuccessV2(document)
        finally:
            session.close()


def production_candidate_evaluation_provider_v2(
    *,
    measurement_source: ProductionNativeCandidateMeasurementSourceV2,
    native_factory: NativeCandidateAdapterFactory,
    metric_tolerances: Mapping[str, object],
    source_gates: Sequence[SourceGateEvidenceV2],
    artifact_root: Path,
    plan: ParsedCalibrationPlanV2,
) -> ProductionCandidateEvaluationProviderV2:
    """Construct the production provider; no analytic/fake option is exposed."""

    if type(native_factory) is not NativeCandidateAdapterFactory:
        raise ProductionCandidateProviderV2Error(
            "production candidate provider requires the native Swift factory"
        )
    return ProductionCandidateEvaluationProviderV2(
        measurement_source=measurement_source,
        control_capability_provider=(
            native_control_execution_capability_provider_v2(native_factory)
        ),
        metric_tolerances=metric_tolerances,
        source_gates=source_gates,
        artifact_root=artifact_root,
        plan=plan,
    )


__all__ = [
    "NativeCandidateMeasurementV2",
    "ProductionCandidateEvaluationProviderV2",
    "ProductionCandidateProviderV2Error",
    "ProductionNativeCandidateMeasurementSessionV2",
    "ProductionNativeCandidateMeasurementSourceV2",
    "SourceGateEvidenceV2",
    "build_production_candidate_evaluation_v2",
    "production_candidate_evaluation_provider_v2",
]
