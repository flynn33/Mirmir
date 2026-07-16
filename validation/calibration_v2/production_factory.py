"""Concrete normal-mode assembly for one P06 calibration transaction."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from validation.calibration_v2.native_adapter.factory import (
    NativeCandidateAdapterFactory,
    make_native_candidate_adapter_factory,
)
from validation.calibration_v2.production_evaluator import (
    ProductionEvaluatorError,
    production_candidate_evaluator,
)
from validation.calibration_v2.production_evidence import (
    PolicyEvaluationEvidenceProvider,
    policy_evaluation_evidence_provider,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
    LockedAnalyticFixtureCapability,
    NativeProductionWriterCapability,
    content_addressed_evidence_store,
    locked_analytic_fixture_capability,
    production_writer_capability,
)
from validation.calibration_v2.runner import (
    CalibrationCandidate,
    LiveHoldoutPreopenBinding,
)


@dataclass(frozen=True)
class ProductionCalibrationAssembly:
    """Concrete dependencies consumed by a normal-mode CalibrationExecutor."""

    candidate: CalibrationCandidate
    dispatch_measurement_root: Path
    p00_identity: Mapping[str, object]
    adapter_factory: NativeCandidateAdapterFactory
    evidence_store: ContentAddressedEvidenceStore
    writer: NativeProductionWriterCapability
    analytic_fixtures: LockedAnalyticFixtureCapability
    evaluation_evidence_provider: PolicyEvaluationEvidenceProvider


def _verify_bound(bound_inputs: object) -> None:
    verify = getattr(bound_inputs, "verify_unchanged", None)
    documents = getattr(bound_inputs, "documents", None)
    record = getattr(bound_inputs, "record", None)
    if (
        not callable(verify)
        or not isinstance(documents, Mapping)
        or not callable(record)
    ):
        raise ProductionEvaluatorError(
            "production assembly requires prevalidated immutable bound inputs"
        )
    verify()


def _assemble(
    *,
    native_factory: NativeCandidateAdapterFactory,
    evidence_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
) -> ProductionCalibrationAssembly:
    bound = native_factory.bound
    _verify_bound(bound)
    required_documents = {
        "degradation_policy",
        "metric_policy_seed",
        "baseline_ablation_contract",
        "metric_performance_tolerances",
    }
    if not required_documents.issubset(bound.documents):
        raise ProductionEvaluatorError(
            "production assembly bound inputs are incomplete"
        )
    degradation_policy = bound.documents["degradation_policy"]
    metric_policy = bound.documents["metric_policy_seed"]
    baseline_contract = bound.documents["baseline_ablation_contract"]
    tolerances = bound.documents["metric_performance_tolerances"]
    for label, document in (
        ("degradation policy", degradation_policy),
        ("metric policy", metric_policy),
        ("baseline contract", baseline_contract),
        ("metric tolerances", tolerances),
    ):
        if not isinstance(document, dict):
            raise ProductionEvaluatorError(f"{label} is not an object")

    evidence_store = content_addressed_evidence_store(evidence_root)
    writer = production_writer_capability(writer_root)
    analytic_fixtures = locked_analytic_fixture_capability(
        metric_policy_sha256=str(metric_policy["policy_sha256"]),
        degradation_policy=degradation_policy,
        writer=writer,
    )
    evidence_provider = policy_evaluation_evidence_provider(
        metric_performance_tolerances=tolerances,
        measurement_evidence_root=dispatch_measurement_root,
        evidence_store=evidence_store,
    )
    evaluator = production_candidate_evaluator(
        degradation_policy=degradation_policy,
        metric_policy=metric_policy,
        baseline_ablation_contract=baseline_contract,
        baseline_ablation_contract_sha256=str(
            bound.record("baseline_ablation_contract")["sha256"]
        ),
        writer=writer,
        analytic_fixtures=analytic_fixtures,
        evidence_store=evidence_store,
        evaluation_evidence_provider=evidence_provider,
    )
    candidate = CalibrationCandidate(
        adapter_factory=native_factory,
        evaluator=evaluator,
        analytic_fixture=False,
    )
    p00_identity = json.loads(
        json.dumps(native_factory.p00_builder.executable.identity)
    )
    _verify_bound(bound)
    return ProductionCalibrationAssembly(
        candidate=candidate,
        dispatch_measurement_root=dispatch_measurement_root.resolve(strict=True),
        p00_identity=p00_identity,
        adapter_factory=native_factory,
        evidence_store=evidence_store,
        writer=writer,
        analytic_fixtures=analytic_fixtures,
        evaluation_evidence_provider=evidence_provider,
    )


def make_production_calibration_candidate(
    *,
    repository_root: Path,
    bound_inputs: object,
    evidence_root: Path,
    native_cache_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    timeout_seconds: float = 900.0,
) -> CalibrationCandidate:
    """Build a concrete candidate when the orchestrator owns bound inputs."""

    return make_production_calibration_assembly_from_bound_inputs(
        repository_root=repository_root,
        bound_inputs=bound_inputs,
        evidence_root=evidence_root,
        native_cache_root=native_cache_root,
        writer_root=writer_root,
        dispatch_measurement_root=dispatch_measurement_root,
        timeout_seconds=timeout_seconds,
    ).candidate


def make_production_calibration_assembly_from_bound_inputs(
    *,
    repository_root: Path,
    bound_inputs: object,
    evidence_root: Path,
    native_cache_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    timeout_seconds: float = 900.0,
) -> ProductionCalibrationAssembly:
    """Build the concrete assembly inside an existing binding transaction."""

    _verify_bound(bound_inputs)
    native_factory = make_native_candidate_adapter_factory(
        repository_root,
        cache_root=native_cache_root,
        timeout_seconds=timeout_seconds,
        bound_inputs=bound_inputs,
        verify_bound_inputs=True,
    )
    assembly = _assemble(
        native_factory=native_factory,
        evidence_root=evidence_root,
        writer_root=writer_root,
        dispatch_measurement_root=dispatch_measurement_root,
    )
    _verify_bound(bound_inputs)
    return assembly


def make_production_calibration_assembly(
    *,
    repository_root: Path,
    evidence_root: Path,
    native_cache_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    live_holdout_preopen_binding: LiveHoldoutPreopenBinding,
    timeout_seconds: float = 900.0,
) -> ProductionCalibrationAssembly:
    """Build every real dependency for one normal calibration transaction."""

    native_factory = make_native_candidate_adapter_factory(
        repository_root,
        cache_root=native_cache_root,
        timeout_seconds=timeout_seconds,
        live_holdout_preopen_binding=live_holdout_preopen_binding,
        verify_bound_inputs=True,
    )
    return _assemble(
        native_factory=native_factory,
        evidence_root=evidence_root,
        writer_root=writer_root,
        dispatch_measurement_root=dispatch_measurement_root,
    )
