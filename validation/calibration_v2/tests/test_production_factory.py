from __future__ import annotations

import hashlib
import json
from pathlib import Path

from validation.calibration_v2.native_adapter.factory import (
    NativeCandidateAdapterFactory,
)
from validation.calibration_v2.production_evaluator import (
    ProductionCandidateEvaluator,
)
from validation.calibration_v2.production_evidence import (
    PolicyEvaluationEvidenceProvider,
)
from validation.calibration_v2.production_factory import (
    make_production_calibration_assembly_from_bound_inputs,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
    LockedAnalyticFixtureCapability,
    NativeProductionWriterCapability,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def _load(relative: str) -> dict[str, object]:
    return json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))


class _VerifiedBindings:
    def __init__(self) -> None:
        self.verify_count = 0
        self.documents = {
            "calibration_plan": _load(
                "validation/calibration_v2/contracts/calibration-plan-v1.json"
            ),
            "degradation_policy": _load(
                "validation/quality/policies/degradation-policy.json"
            ),
            "metric_policy_seed": _load(
                "validation/quality/policies/metric-policy.json"
            ),
            "baseline_ablation_contract": _load(
                "validation/calibration_v2/contracts/baseline-ablation-contract-v1.json"
            ),
            "metric_performance_tolerances": _load(
                "validation/calibration_v2/contracts/metric-performance-tolerances-v1.json"
            ),
        }

    def verify_unchanged(self) -> None:
        self.verify_count += 1

    def record(self, identifier: str) -> dict[str, object]:
        if identifier != "baseline_ablation_contract":
            raise AssertionError(f"unexpected assembly binding: {identifier}")
        path = (
            REPOSITORY_ROOT
            / "validation/calibration_v2/contracts/baseline-ablation-contract-v1.json"
        )
        return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def test_bound_transaction_assembles_only_concrete_normal_mode_dependencies(
    tmp_path: Path,
) -> None:
    bound = _VerifiedBindings()
    assembly = make_production_calibration_assembly_from_bound_inputs(
        repository_root=REPOSITORY_ROOT,
        bound_inputs=bound,
        evidence_root=tmp_path / "evidence",
        native_cache_root=tmp_path / "native",
        writer_root=tmp_path / "writer",
        dispatch_measurement_root=tmp_path / "dispatch",
        timeout_seconds=300.0,
    )

    assert type(assembly.adapter_factory) is NativeCandidateAdapterFactory
    assert type(assembly.evidence_store) is ContentAddressedEvidenceStore
    assert type(assembly.writer) is NativeProductionWriterCapability
    assert type(assembly.analytic_fixtures) is LockedAnalyticFixtureCapability
    assert (
        type(assembly.evaluation_evidence_provider)
        is PolicyEvaluationEvidenceProvider
    )
    assert type(assembly.candidate.evaluator) is ProductionCandidateEvaluator
    assert assembly.candidate.adapter_factory is assembly.adapter_factory
    assert assembly.candidate.analytic_fixture is False
    assert assembly.dispatch_measurement_root == (tmp_path / "dispatch").resolve()
    assert not hasattr(assembly, "analytic_case_provider")
    assert not hasattr(assembly, "analytic_measurement_resolver")
    assert bound.verify_count >= 3

