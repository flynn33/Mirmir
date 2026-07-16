from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shutil
import stat
import time
from typing import Mapping

import numpy as np
import pytest

import validation.calibration_v2.production_evaluator as evaluator_module
import validation.calibration_v2.production_providers as providers_module
from validation.calibration_v2.production_evaluator import (
    COMMON_CONTROL_BOUNDARY_CONTRACT,
    FIXED_DESCRIPTOR_IDS,
    NON_ASH_COORDINATES,
    NON_ASH_SELECTOR_ID,
    NON_ASH_VALUES,
    MemoryEvidenceStore,
    ProductionEvaluatorError,
    _NativeSelectionOutputCache,
    _PreparedControlCase,
    _prepare_native_output_cache,
    canonical_json_bytes,
    canonical_sha256,
    frame_sha256,
    non_ash_control_request,
    search_non_ash_development,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
)
from validation.calibration_v2.runner import _TrackedCandidateCallable
from validation.quality.src.mirmir_quality.arrays import PlanarFrame
from validation.quality.src.mirmir_quality.metrics import ms_ssim, ssim
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _round_trip_locked_bt709_video_range_nv12,
)


BANK = "1" * 64
DEGRADATION_POLICY = "2" * 64


def _selector_contract() -> Mapping[str, object]:
    return {
        "selector_id": NON_ASH_SELECTOR_ID,
        "bank_descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
        "candidate_evaluation_budget": 1513,
        "full_ash_maximum_candidate_evaluation_budget": 1345,
        "coordinates": {
            "order": list(NON_ASH_COORDINATES),
            "values": list(NON_ASH_VALUES),
            "initial_value": 0,
            "maximum_sweeps": 8,
        },
    }


def _aggregate_context() -> Mapping[str, object]:
    selector = _selector_contract()
    return {
        "degradation_policy_file_sha256": "3" * 64,
        "metric_policy_file_sha256": "4" * 64,
        "metric_policy_sha256": "5" * 64,
        "baseline_ablation_contract_file_sha256": "6" * 64,
        "baseline_selector_contract": selector,
        "baseline_selector_contract_sha256": canonical_sha256(selector),
        "sample_lock_file_sha256": "7" * 64,
        "corpus_manifest_sha256": "8" * 64,
        "corpus_lock_bundle_sha256": "9" * 64,
        "common_boundary_contract": COMMON_CONTROL_BOUNDARY_CONTRACT,
        "common_boundary_contract_sha256": canonical_sha256(
            COMMON_CONTROL_BOUNDARY_CONTRACT
        ),
        "native_implementation_closure": {
            "executable_sha256": "a" * 64,
            "source_manifest_sha256": "b" * 64,
        },
        "quality_implementation_closure": {
            "implementation_manifest_file_sha256": "c" * 64,
            "implementation_manifest_sha256": "d" * 64,
        },
    }


def _legal_frame(height: int, width: int, y_code: int) -> PlanarFrame:
    frame = PlanarFrame(
        y=np.full((height, width), (float(y_code) - 16.0) / 219.0),
        cb=np.zeros((height // 2, width // 2), dtype=np.float64),
        cr=np.zeros((height // 2, width // 2), dtype=np.float64),
    )
    _, reopened = _round_trip_locked_bt709_video_range_nv12(frame)
    return reopened


def test_corpus_metric_bundle_reuses_scale_zero_without_numeric_drift(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    rng = np.random.default_rng(20_260_712)

    def frame(seed_offset: int) -> PlanarFrame:
        local = np.random.default_rng(20_260_712 + seed_offset)
        return PlanarFrame(
            y=(
                local.integers(16, 236, size=(192, 324)).astype(np.float64)
                - 16.0
            )
            / 219.0,
            cb=(
                local.integers(16, 241, size=(96, 162)).astype(np.float64)
                - 16.0
            )
            / 224.0
            - 0.5,
            cr=(
                local.integers(16, 241, size=(96, 162)).astype(np.float64)
                - 16.0
            )
            / 224.0
            - 0.5,
        )

    target = frame(0)
    candidate = frame(int(rng.integers(1, 1_000_000)))
    expected = {
        "y_ssim": ssim(target.y, candidate.y),
        "cb_ssim": ssim(target.cb, candidate.cb),
        "cr_ssim": ssim(target.cr, candidate.cr),
        "y_ms_ssim": ms_ssim(target.y, candidate.y),
        "cb_ms_ssim": ms_ssim(target.cb, candidate.cb),
        "cr_ms_ssim": ms_ssim(target.cr, candidate.cr),
    }
    detail_calls = []
    original_detail = evaluator_module.ms_ssim_detail

    def counted_detail(
        reference: np.ndarray,
        output: np.ndarray,
    ) -> Mapping[str, object]:
        detail_calls.append(reference.shape)
        return original_detail(reference, output)

    monkeypatch.setattr(evaluator_module, "ms_ssim_detail", counted_detail)
    observed = evaluator_module.corpus_metric_bundle(target, candidate)

    assert {name: observed[name] for name in expected} == expected
    assert detail_calls == [(192, 324), (96, 162), (96, 162)]


def _prepared_cases(
    source_count: int = 2,
) -> tuple[_PreparedControlCase, ...]:
    values = []
    for source_ordinal in range(source_count):
        route = ("direct-2x", "direct-3over2")[source_ordinal % 2]
        target = _legal_frame(2, 2, 100 + source_ordinal)
        low_resolution = _legal_frame(2, 2, 80 + source_ordinal)
        context = CandidateContext(
            y_shape=(2, 2),
            cb_shape=(1, 1),
            cr_shape=(1, 1),
            target_route=route,
        )
        for profile_ordinal in range(3):
            values.append(
                _PreparedControlCase(
                    metadata={
                        "source_asset_id": f"asset-{source_ordinal}",
                        "source_family_id": f"family-{source_ordinal}",
                        "categories": ["focused-cache"],
                        "target_route": route,
                    },
                    profile={
                        "id": f"{route}-profile-{profile_ordinal}",
                        "kind": "focused-cache-profile",
                        "target_route": route,
                    },
                    target=target,
                    low_resolution=low_resolution,
                    context=context,
                )
            )
    return tuple(values)


class _FakeCachedCallable:
    def __init__(self, *, configuration_id: str = "focused-cache") -> None:
        self.configuration_id = configuration_id
        self.preparation_records: list[Mapping[str, object]] = []
        self.cache_records: list[Mapping[str, object]] = []
        self.control_records: list[Mapping[str, object]] = []
        self.caches: dict[str, tuple[Mapping[str, object], PlanarFrame]] = {}
        self.cache_tokens_by_identity: dict[str, str] = {}
        self.reconstruction_calls = 0
        self.reopen_calls = 0
        self.durability_flush_calls = 0
        self.pending_file_count = 0
        self.pending_directory_count = 0
        self.preparation_record_count_calls = 0
        self.preparation_record_lookup_calls = 0
        self.cache_record_count_calls = 0
        self.cache_record_lookup_calls = 0

    def __call__(
        self,
        _frame: PlanarFrame,
        _context: CandidateContext,
    ) -> PlanarFrame:
        raise AssertionError("ordinary candidate reconstruction is out of scope")

    def prepare_non_ash_cache(
        self,
        frame: PlanarFrame,
        context: CandidateContext,
        *,
        source_asset_id: str,
        degradation_profile_id: str,
        degradation_profile_sha256: str,
    ) -> Mapping[str, object]:
        identity_sha256 = canonical_sha256(
            {
                "source_asset_id": source_asset_id,
                "degradation_profile_id": degradation_profile_id,
                "degradation_profile_sha256": degradation_profile_sha256,
                "input_frame_sha256": frame_sha256(frame),
                "route": context.target_route,
                "bank": BANK,
            }
        )
        existing_token = self.cache_tokens_by_identity.get(identity_sha256)
        reused = existing_token is not None
        if existing_token is None:
            output = _legal_frame(
                context.y_shape[0],
                context.y_shape[1],
                96 + len(self.caches),
            )
            descriptor_outputs = [
                {
                    "descriptor_id": descriptor_id,
                    "output_frame_sha256": frame_sha256(output),
                }
                for descriptor_id in FIXED_DESCRIPTOR_IDS
            ]
            manifest_without_hash = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_native_non_ash_output_cache",
                "bank_id": BANK,
                "route": context.target_route,
                "source_asset_id": source_asset_id,
                "degradation_profile_id": degradation_profile_id,
                "degradation_profile_sha256": degradation_profile_sha256,
                "input_frame_sha256": frame_sha256(frame),
                "dimensions": {
                    "input_luma": list(frame.y.shape),
                    "input_chroma": list(frame.cb.shape),
                    "output_luma": list(context.y_shape),
                    "output_chroma": list(context.cb_shape),
                },
                "analysis_grid_invocation_count": 1,
                "feature_tensor_q15_sha256": canonical_sha256(
                    {
                        "source_asset_id": source_asset_id,
                        "degradation_profile_id": degradation_profile_id,
                        "kind": "features",
                    }
                ),
                "descriptor_outputs": descriptor_outputs,
            }
            token = canonical_sha256(manifest_without_hash)
            manifest = {
                **manifest_without_hash,
                "cache_manifest_sha256": token,
            }
            self.caches[token] = (copy.deepcopy(manifest), output)
            self.cache_tokens_by_identity[identity_sha256] = token
        else:
            token = existing_token
            cached_manifest, _ = self.caches[token]
            manifest = copy.deepcopy(cached_manifest)
            descriptor_outputs = manifest["descriptor_outputs"]
        origin_sha256 = canonical_sha256(
            {"identity_sha256": identity_sha256, "cache_token": token}
        )
        artifact_sha256 = canonical_sha256(
            {"cache_token": token, "kind": "cache-artifact"}
        )
        preparation = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_non_ash_cache_preparation_evidence",
            "identity_sha256": identity_sha256,
            "cache_token": token,
            "cache_origin_manifest_sha256": origin_sha256,
            "requesting_configuration_id": self.configuration_id,
            "shared_bank_configuration_sha256": BANK,
            "cache_reused": reused,
            "preparation_analysis_grid_invocation_count": 0 if reused else 1,
            "preparation_spatial_operator_evaluation_count": 0 if reused else 16,
            "cache_artifact_sha256": artifact_sha256,
            "cache_artifact_size_bytes": 1,
            "feature_tensor_q15_sha256": manifest[
                "feature_tensor_q15_sha256"
            ],
            "descriptor_output_frame_sha256_values": [
                value["output_frame_sha256"] for value in descriptor_outputs
            ],
        }
        preparation["record_sha256"] = canonical_sha256(preparation)
        self.preparation_records.append(copy.deepcopy(preparation))
        return {
            "cache_token": token,
            "cache_manifest": copy.deepcopy(manifest),
            "cache_reused": reused,
            "preparation_analysis_grid_invocation_count": 0 if reused else 1,
            "preparation_spatial_operator_evaluation_count": 0 if reused else 16,
            "cache_reopen_evidence_sha256": preparation["record_sha256"],
            "cache_origin_manifest_sha256": origin_sha256,
        }

    def non_ash_cache_preparation_records(
        self,
    ) -> tuple[Mapping[str, object], ...]:
        return tuple(copy.deepcopy(self.preparation_records))

    def non_ash_cache_preparation_records_count(self) -> int:
        self.preparation_record_count_calls += 1
        return len(self.preparation_records)

    def non_ash_cache_preparation_records_record(
        self,
        index: int,
    ) -> Mapping[str, object]:
        self.preparation_record_lookup_calls += 1
        return copy.deepcopy(self.preparation_records[index])

    def non_ash_cache_records(self) -> tuple[Mapping[str, object], ...]:
        return tuple(copy.deepcopy(self.cache_records))

    def non_ash_cache_records_count(self) -> int:
        self.cache_record_count_calls += 1
        return len(self.cache_records)

    def non_ash_cache_records_record(
        self,
        index: int,
    ) -> Mapping[str, object]:
        self.cache_record_lookup_calls += 1
        return copy.deepcopy(self.cache_records[index])

    def control_runtime_records(self) -> tuple[Mapping[str, object], ...]:
        return tuple(copy.deepcopy(self.control_records))

    def control_runtime_records_count(self) -> int:
        return len(self.control_records)

    def control_runtime_records_record(
        self,
        index: int,
    ) -> Mapping[str, object]:
        return copy.deepcopy(self.control_records[index])

    def _cached_output(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> PlanarFrame:
        manifest, output = self.caches[cache_token]
        canonical_rule = {
            coordinate: int(rule[coordinate])
            for coordinate in NON_ASH_COORDINATES
        }
        record = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_native_non_ash_cached_reconstruction",
            "cache_token": cache_token,
            "cache_manifest_sha256": cache_token,
            "rule_configuration": canonical_rule,
            "rule_sha256": canonical_sha256(canonical_rule),
            "output_frame_sha256": frame_sha256(output),
            "target_route": manifest["route"],
            "stateful_lut_lookup_count": 0,
            "spatial_operator_recompute_count": 0,
            "analysis_grid_invocation_count": 0,
        }
        record["record_sha256"] = canonical_sha256(record)
        self.cache_records.append(record)
        request = non_ash_control_request(canonical_rule, BANK)
        parameters = request["parameters"]
        control_record = {
            "control_key": request["control_key"],
            "control_mode": request["control_mode"],
            "request_sha256": request["request_sha256"],
            "configuration_sha256": request["configuration_sha256"],
            "shared_bank_configuration_sha256": BANK,
            "input_frame_sha256": manifest["input_frame_sha256"],
            "output_frame_sha256": record["output_frame_sha256"],
            "target_route": manifest["route"],
            "parameters": copy.deepcopy(parameters),
            "parameters_sha256": canonical_sha256(parameters),
            "non_ash_cache_record_sha256": record["record_sha256"],
        }
        control_record["record_sha256"] = canonical_sha256(control_record)
        self.control_records.append(control_record)
        return output

    def reconstruct_non_ash_cached(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> PlanarFrame:
        self.reconstruction_calls += 1
        self.pending_file_count += 2
        self.pending_directory_count += 1
        return self._cached_output(cache_token, rule)

    def reopen_non_ash_cached(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> PlanarFrame:
        self.reopen_calls += 1
        return self._cached_output(cache_token, rule)

    def flush_control_cache_durability(self) -> Mapping[str, object]:
        self.durability_flush_calls += 1
        record = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_control_cache_durability_commit",
            "split": "development",
            "requesting_configuration_id": self.configuration_id,
            "shared_bank_configuration_sha256": BANK,
            "native_executable_sha256": "a" * 64,
            "native_source_manifest_sha256": "b" * 64,
            "pending_file_count": self.pending_file_count,
            "pending_directory_count": self.pending_directory_count,
            "ordered_file_bindings_sha256": canonical_sha256(
                {
                    "pending_file_count": self.pending_file_count,
                    "flush_ordinal": self.durability_flush_calls,
                }
            ),
            "ordered_directory_identities_sha256": canonical_sha256(
                {
                    "pending_directory_count": self.pending_directory_count,
                    "flush_ordinal": self.durability_flush_calls,
                }
            ),
            "committed": True,
        }
        record["record_sha256"] = canonical_sha256(record)
        self.pending_file_count = 0
        self.pending_directory_count = 0
        return record


def _adapter(
    context: Mapping[str, object],
    *,
    configuration_id: str = "focused-cache",
) -> tuple[CandidateAdapter, _FakeCachedCallable]:
    callable_value = _FakeCachedCallable(configuration_id=configuration_id)
    configuration = {
        "configuration_id": configuration_id,
        "shared_bank_configuration_sha256": BANK,
        "swift_cli": copy.deepcopy(context["native_implementation_closure"]),
        "raw_output_contract_sha256": context[
            "common_boundary_contract_sha256"
        ],
    }
    return (
        CandidateAdapter(
            candidate_id="focused-cache",
            configuration=configuration,
            configuration_sha256=canonical_sha256(configuration),
            callable=callable_value,
        ),
        callable_value,
    )


def _operator_cache(
    *,
    evidence_store: MemoryEvidenceStore | ContentAddressedEvidenceStore,
    context: Mapping[str, object] | None = None,
    prepared: tuple[_PreparedControlCase, ...] | None = None,
    configuration_id: str = "focused-cache",
) -> tuple[_NativeSelectionOutputCache, _FakeCachedCallable]:
    aggregate_context = context or _aggregate_context()
    adapter, callable_value = _adapter(
        aggregate_context,
        configuration_id=configuration_id,
    )
    return (
        _NativeSelectionOutputCache(
            adapter=adapter,
            prepared=prepared or _prepared_cases(),
            split="development",
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=DEGRADATION_POLICY,
            evidence_store=evidence_store,
            aggregate_identity_context=aggregate_context,
        ),
        callable_value,
    )


def _tracked_operator_cache(
    *,
    evidence_store: ContentAddressedEvidenceStore,
    prepared: tuple[_PreparedControlCase, ...],
) -> tuple[
    _NativeSelectionOutputCache,
    _FakeCachedCallable,
    _TrackedCandidateCallable,
]:
    aggregate_context = _aggregate_context()
    source_adapter, callable_value = _adapter(aggregate_context)
    tracked = _TrackedCandidateCallable(source_adapter, [], [])
    adapter = CandidateAdapter(
        candidate_id=source_adapter.candidate_id,
        configuration=source_adapter.configuration,
        configuration_sha256=source_adapter.configuration_sha256,
        callable=tracked,
    )
    return (
        _NativeSelectionOutputCache(
            adapter=adapter,
            prepared=prepared,
            split="development",
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=DEGRADATION_POLICY,
            evidence_store=evidence_store,
            aggregate_identity_context=aggregate_context,
        ),
        callable_value,
        tracked,
    )


def _zero_rule() -> Mapping[str, object]:
    return {coordinate: 0 for coordinate in NON_ASH_COORDINATES}


def _metric_bundle() -> Mapping[str, object]:
    return {
        "y_psnr_db": 30.0,
        "cb_psnr_db": 29.0,
        "cr_psnr_db": 28.0,
        "y_ssim": 0.90,
        "cb_ssim": 0.80,
        "cr_ssim": 0.70,
        "y_ms_ssim": 0.95,
        "cb_ms_ssim": 0.85,
        "cr_ms_ssim": 0.75,
        "writer_y_psnr_contribution_db": None,
    }


def _install_counted_metrics(monkeypatch: pytest.MonkeyPatch) -> list[int]:
    calls: list[int] = []

    def metric(
        _target: PlanarFrame,
        _output: PlanarFrame,
        *,
        writer_y_psnr_contribution_db: object = None,
    ) -> Mapping[str, object]:
        assert writer_y_psnr_contribution_db is None
        calls.append(1)
        return _metric_bundle()

    monkeypatch.setattr(evaluator_module, "corpus_metric_bundle", metric)
    return calls


def test_cold_and_warm_aggregate_are_equal_and_warm_calls_no_metrics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    metric_calls = _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cache, callable_value = _operator_cache(evidence_store=store)

    cold = cache.non_ash(_zero_rule())
    cold_metric_count = len(metric_calls)
    assert cache.pending_aggregate_origin_count == 1
    assert store._control_aggregate_origins == {}
    cache.commit_pending_aggregate_origins()
    assert len(store._control_aggregate_origins) == 1
    warm = cache.non_ash(_zero_rule())

    assert cold == warm
    assert cold_metric_count == len(_prepared_cases())
    assert len(metric_calls) == cold_metric_count
    assert callable_value.reconstruction_calls == len(_prepared_cases())
    assert callable_value.reopen_calls == len(_prepared_cases())


def test_cold_build_and_warm_reopen_share_content_manifest_not_lifecycle_hash(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    aggregate_context = _aggregate_context()
    adapter, callable_value = _adapter(aggregate_context)
    prepared = _prepared_cases(source_count=2)

    cold_cache = _NativeSelectionOutputCache(
        adapter=adapter,
        prepared=prepared,
        split="development",
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=DEGRADATION_POLICY,
        evidence_store=store,
        aggregate_identity_context=aggregate_context,
    )
    cold_preparation_records = tuple(callable_value.preparation_records)
    cold_output = cold_cache.non_ash(_zero_rule())
    cold_selection = search_non_ash_development(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=DEGRADATION_POLICY,
        selector_contract=_selector_contract(),
        development_evaluator=cold_cache.non_ash,
        cached_16_operator_output_manifest_sha256=(
            cold_cache.manifest_sha256
        ),
        evidence_store=store,
    )
    cold_cache.commit_pending_aggregate_origins()

    warm_record_start = len(callable_value.preparation_records)
    warm_cache = _NativeSelectionOutputCache(
        adapter=adapter,
        prepared=prepared,
        split="development",
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=DEGRADATION_POLICY,
        evidence_store=store,
        aggregate_identity_context=aggregate_context,
    )
    warm_preparation_records = tuple(
        callable_value.preparation_records[warm_record_start:]
    )
    warm_output = warm_cache.non_ash(_zero_rule())
    warm_selection = search_non_ash_development(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=DEGRADATION_POLICY,
        selector_contract=_selector_contract(),
        development_evaluator=warm_cache.non_ash,
        cached_16_operator_output_manifest_sha256=(
            warm_cache.manifest_sha256
        ),
        evidence_store=store,
    )
    warm_cache.commit_pending_aggregate_origins()

    assert cold_output == warm_output
    assert cold_selection == warm_selection
    assert (
        cold_selection["document"]["development_attempt_ledger_sha256"]
        == warm_selection["document"]["development_attempt_ledger_sha256"]
    )
    assert cold_cache.manifest_sha256 == warm_cache.manifest_sha256
    assert cold_cache.preparation_evidence_sha256 == canonical_sha256(
        cold_preparation_records
    )
    assert warm_cache.preparation_evidence_sha256 == canonical_sha256(
        warm_preparation_records
    )
    assert (
        cold_cache.preparation_evidence_sha256
        != warm_cache.preparation_evidence_sha256
    )
    assert all(
        record["cache_reused"] is False
        and record["preparation_analysis_grid_invocation_count"] == 1
        and record["preparation_spatial_operator_evaluation_count"] == 16
        for record in cold_preparation_records
    )
    assert all(
        record["cache_reused"] is True
        and record["preparation_analysis_grid_invocation_count"] == 0
        and record["preparation_spatial_operator_evaluation_count"] == 0
        for record in warm_preparation_records
    )
    content_manifest = store.reopen(cold_cache.manifest_sha256)
    assert content_manifest["schema_version"] == "1.1.0"
    assert "preparation_evidence" not in content_manifest
    assert len(content_manifest["input_cache_manifests"]) == len(prepared)
    assert [
        manifest["cache_manifest_sha256"]
        for manifest in content_manifest["input_cache_manifests"]
    ] == content_manifest["input_cache_manifest_sha256_values"]


def test_cache_proof_capture_uses_only_constant_time_cursors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    cache, callable_value = _operator_cache(evidence_store=MemoryEvidenceStore())
    callable_value.cache_records.extend(
        {"historical": index} for index in range(50_000)
    )

    def forbidden_stream() -> tuple[Mapping[str, object], ...]:
        raise AssertionError("full cache-record stream must not be materialized")

    callable_value.non_ash_cache_records = forbidden_stream
    cache.non_ash(_zero_rule())

    assert callable_value.cache_record_count_calls == 2 * len(_prepared_cases())
    assert callable_value.cache_record_lookup_calls == len(_prepared_cases())


def test_cache_preparation_capture_uses_only_constant_time_cursors() -> None:
    aggregate_context = _aggregate_context()
    adapter, callable_value = _adapter(aggregate_context)
    callable_value.preparation_records.extend(
        {"historical": index} for index in range(50_000)
    )

    def forbidden_stream() -> tuple[Mapping[str, object], ...]:
        raise AssertionError(
            "full preparation-record stream must not be materialized"
        )

    callable_value.non_ash_cache_preparation_records = forbidden_stream
    item = _prepared_cases()[0]

    _prepare_native_output_cache(
        adapter=adapter,
        frame=item.low_resolution,
        context=item.context,
        source_asset_id=str(item.metadata["source_asset_id"]),
        degradation_profile_id=str(item.profile["id"]),
        degradation_profile_sha256=canonical_sha256(item.profile),
        shared_bank_configuration_sha256=BANK,
    )

    assert callable_value.preparation_record_count_calls == 2
    assert callable_value.preparation_record_lookup_calls == 1


def test_origin_commit_orders_native_evidence_then_origin_batch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    events: list[str] = []
    store = MemoryEvidenceStore()
    cache, callable_value = _operator_cache(evidence_store=store)
    native_flush = callable_value.flush_control_cache_durability
    evidence_flush = store.flush_control_aggregate_dependencies
    origin_batch = store.publish_control_aggregate_origins_batch

    def tracked_native_flush() -> Mapping[str, object]:
        events.append("native")
        return native_flush()

    def tracked_evidence_flush(values: list[str]) -> Mapping[str, object]:
        events.append("evidence")
        return evidence_flush(values)

    def tracked_origin_batch(
        entries: list[Mapping[str, Mapping[str, object]]],
    ) -> Mapping[str, object]:
        events.append("origins")
        return origin_batch(entries)

    callable_value.flush_control_cache_durability = tracked_native_flush
    store.flush_control_aggregate_dependencies = tracked_evidence_flush
    store.publish_control_aggregate_origins_batch = tracked_origin_batch
    cache.non_ash(_zero_rule())

    cache.commit_pending_aggregate_origins()

    assert events == ["native", "evidence", "origins"]
    origin = json.loads(next(iter(store._control_aggregate_origins.values())))
    native_commit = store.reopen(origin["native_dependency_evidence_sha256"])
    evidence_commit = store.reopen(
        origin["evidence_dependency_evidence_sha256"]
    )
    assert origin["native_dependency_commit_sha256"] == native_commit[
        "record_sha256"
    ]
    assert origin["evidence_dependency_commit_sha256"] == evidence_commit[
        "record_sha256"
    ]


def test_aggregate_dependency_order_preserves_first_occurrence_with_duplicates() -> None:
    native = "0" * 64
    first = "1" * 64
    second = "2" * 64
    third = "3" * 64
    pending = [
        {
            "aggregate": {
                "objective_summary_sha256": first,
                "output_manifest_sha256": second,
            }
        },
        {
            "aggregate": {
                "objective_summary_sha256": first,
                "output_manifest_sha256": third,
            }
        },
        {
            "aggregate": {
                "objective_summary_sha256": second,
                "output_manifest_sha256": native,
            }
        },
    ]

    observed = (
        evaluator_module._ordered_unique_aggregate_dependency_sha256_values(
            native,
            pending,
        )
    )

    assert observed == [native, first, second, third]


def test_aggregate_dependency_order_handles_maximum_1297_rule_closure() -> None:
    native = f"{0:064x}"
    pending = [
        {
            "aggregate": {
                "objective_summary_sha256": f"{2 * ordinal + 1:064x}",
                "output_manifest_sha256": f"{2 * ordinal + 2:064x}",
            }
        }
        for ordinal in range(1297)
    ]

    observed = (
        evaluator_module._ordered_unique_aggregate_dependency_sha256_values(
            native,
            pending,
        )
    )

    assert len(observed) == 1 + 2 * 1297
    assert len(set(observed)) == len(observed)
    assert observed[:3] == [native, f"{1:064x}", f"{2:064x}"]
    assert observed[-1] == f"{2 * 1297:064x}"


def test_native_flush_failure_leaves_no_aggregate_origin(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cache, callable_value = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())

    def fail_native_flush() -> Mapping[str, object]:
        raise ProductionEvaluatorError("injected native flush failure")

    callable_value.flush_control_cache_durability = fail_native_flush
    with pytest.raises(ProductionEvaluatorError, match="native flush failure"):
        cache.commit_pending_aggregate_origins()

    assert store._control_aggregate_origins == {}
    assert cache.pending_aggregate_origin_count == 1


def test_native_commit_publication_failure_retries_exact_record_without_reflush(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cache, callable_value = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    publish = store.publish
    captured_records: list[Mapping[str, object]] = []

    def fail_native_commit_publication(
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        if (
            document.get("artifact_kind")
            == "p06_control_cache_durability_commit"
        ):
            captured_records.append(copy.deepcopy(document))
            raise ProductionEvaluatorError(
                "injected native commit publication failure"
            )
        return publish(document)

    store.publish = fail_native_commit_publication
    with pytest.raises(ProductionEvaluatorError, match="publication failure"):
        cache.commit_pending_aggregate_origins()

    assert callable_value.durability_flush_calls == 1
    assert len(captured_records) == 1
    assert cache._pending_native_dependency_record == captured_records[0]
    assert cache._pending_native_dependency is None
    assert store._control_aggregate_origins == {}

    store.publish = publish
    cache.commit_pending_aggregate_origins()

    assert callable_value.durability_flush_calls == 1
    origin = json.loads(next(iter(store._control_aggregate_origins.values())))
    assert origin["native_dependency_commit_sha256"] == captured_records[0][
        "record_sha256"
    ]
    assert store.reopen(origin["native_dependency_evidence_sha256"]) == (
        captured_records[0]
    )


def test_evidence_flush_failure_is_retryable_without_second_native_flush(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cache, callable_value = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    evidence_flush = store.flush_control_aggregate_dependencies

    def fail_evidence_flush(_values: list[str]) -> Mapping[str, object]:
        raise ProductionEvaluatorError("injected evidence flush failure")

    store.flush_control_aggregate_dependencies = fail_evidence_flush
    with pytest.raises(ProductionEvaluatorError, match="evidence flush failure"):
        cache.commit_pending_aggregate_origins()
    assert store._control_aggregate_origins == {}
    assert callable_value.durability_flush_calls == 1

    store.flush_control_aggregate_dependencies = evidence_flush
    cache.commit_pending_aggregate_origins()

    assert callable_value.durability_flush_calls == 1
    assert len(store._control_aggregate_origins) == 1


@pytest.mark.parametrize(
    ("field", "replacement"),
    (
        ("metric_policy_file_sha256", "d" * 64),
        ("sample_lock_file_sha256", "e" * 64),
        ("corpus_lock_bundle_sha256", "f" * 64),
    ),
)
def test_bound_identity_change_is_a_cache_miss(
    monkeypatch: pytest.MonkeyPatch,
    field: str,
    replacement: str,
) -> None:
    metric_calls = _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cold, _ = _operator_cache(evidence_store=store)
    cold.non_ash(_zero_rule())
    cold.commit_pending_aggregate_origins()
    count_after_cold = len(metric_calls)
    changed_context = copy.deepcopy(_aggregate_context())
    changed_context[field] = replacement
    changed, callable_value = _operator_cache(
        evidence_store=store,
        context=changed_context,
    )

    changed.non_ash(_zero_rule())

    assert len(metric_calls) == count_after_cold + len(_prepared_cases())
    assert callable_value.reconstruction_calls == len(_prepared_cases())
    assert callable_value.reopen_calls == 0


@pytest.mark.parametrize(
    ("closure", "field", "replacement"),
    (
        ("native_implementation_closure", "source_manifest_sha256", "d" * 64),
        (
            "quality_implementation_closure",
            "implementation_manifest_file_sha256",
            "e" * 64,
        ),
        (
            "quality_implementation_closure",
            "implementation_manifest_sha256",
            "f" * 64,
        ),
    ),
)
def test_implementation_closure_change_is_a_cache_miss(
    monkeypatch: pytest.MonkeyPatch,
    closure: str,
    field: str,
    replacement: str,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cold, _ = _operator_cache(evidence_store=store)
    cold.non_ash(_zero_rule())
    cold.commit_pending_aggregate_origins()
    changed_context = copy.deepcopy(_aggregate_context())
    changed_context[closure][field] = replacement
    changed, callable_value = _operator_cache(
        evidence_store=store,
        context=changed_context,
    )

    changed.non_ash(_zero_rule())

    assert callable_value.reconstruction_calls == len(_prepared_cases())
    assert callable_value.reopen_calls == 0


def test_order_change_is_a_cache_miss(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cold, _ = _operator_cache(evidence_store=store)
    cold.non_ash(_zero_rule())
    cold.commit_pending_aggregate_origins()
    reordered, callable_value = _operator_cache(
        evidence_store=store,
        prepared=tuple(reversed(_prepared_cases())),
    )

    reordered.non_ash(_zero_rule())

    assert callable_value.reconstruction_calls == len(_prepared_cases())
    assert callable_value.reopen_calls == 0


def test_existing_tampered_aggregate_origin_hard_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cache, _ = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    cache.commit_pending_aggregate_origins()
    identity_sha256, payload = next(iter(store._control_aggregate_origins.items()))
    origin = json.loads(payload)
    origin["aggregate"]["objective_means"][0] += 1.0
    unhashed = dict(origin)
    unhashed.pop("origin_manifest_sha256")
    origin["origin_manifest_sha256"] = canonical_sha256(unhashed)
    store._control_aggregate_origins[identity_sha256] = canonical_json_bytes(origin)

    with pytest.raises(
        ProductionEvaluatorError,
        match="documents changed during reopen",
    ):
        cache.non_ash(_zero_rule())


def test_existing_reordered_output_proofs_hard_fail(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cache, _ = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    cache.commit_pending_aggregate_origins()
    identity_sha256, payload = next(iter(store._control_aggregate_origins.items()))
    origin = json.loads(payload)
    proofs = list(reversed(origin["ordered_output_proofs"]))
    for ordinal, proof in enumerate(proofs):
        proof["ordinal"] = ordinal
    origin["ordered_output_proofs"] = proofs
    unhashed = dict(origin)
    unhashed.pop("origin_manifest_sha256")
    origin["origin_manifest_sha256"] = canonical_sha256(unhashed)
    store._control_aggregate_origins[identity_sha256] = canonical_json_bytes(origin)

    with pytest.raises(
        ProductionEvaluatorError,
        match="output order or hash changed",
    ):
        cache.non_ash(_zero_rule())


def test_persistent_origin_parent_symlink_replacement_hard_fails(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, _ = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    cache.commit_pending_aggregate_origins()
    origins = store._control_aggregate_origins
    preserved = origins.with_name("preserved-origins")
    origins.rename(preserved)
    external = tmp_path / "external"
    external.mkdir()
    origins.symlink_to(external, target_is_directory=True)

    with pytest.raises(
        ProductionEvaluatorError,
        match="origin directory cannot be opened",
    ):
        cache.non_ash(_zero_rule())


def test_persistent_cold_and_warm_aggregate_are_equal(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    metric_calls = _install_counted_metrics(monkeypatch)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, callable_value = _operator_cache(evidence_store=store)

    cold = cache.non_ash(_zero_rule())
    cold_metric_count = len(metric_calls)
    cache.commit_pending_aggregate_origins()
    warm = cache.non_ash(_zero_rule())

    assert warm == cold
    assert len(metric_calls) == cold_metric_count
    assert callable_value.reconstruction_calls == len(_prepared_cases())
    assert callable_value.reopen_calls == len(_prepared_cases())


def test_persistent_restart_reopens_aggregate_with_new_store_adapter_and_cache(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    metric_calls = _install_counted_metrics(monkeypatch)
    evidence_root = tmp_path / "evidence"
    cold_store = ContentAddressedEvidenceStore(evidence_root)
    cold_cache, cold_callable = _operator_cache(evidence_store=cold_store)
    cold = cold_cache.non_ash(_zero_rule())
    cold_cache.commit_pending_aggregate_origins()
    cold_metric_count = len(metric_calls)

    warm_store = ContentAddressedEvidenceStore(evidence_root)
    warm_cache, warm_callable = _operator_cache(evidence_store=warm_store)
    warm = warm_cache.non_ash(_zero_rule())
    warm_cache.commit_pending_aggregate_origins()

    assert warm == cold
    assert len(metric_calls) == cold_metric_count
    assert cold_callable.reconstruction_calls == len(_prepared_cases())
    assert warm_callable.reconstruction_calls == 0
    assert warm_callable.reopen_calls == len(_prepared_cases())
    assert warm_cache.pending_aggregate_origin_count == 0


def test_persistent_restart_accepts_historical_requester_for_same_bank(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    metric_calls = _install_counted_metrics(monkeypatch)
    evidence_root = tmp_path / "evidence"
    cold_store = ContentAddressedEvidenceStore(evidence_root)
    cold_cache, cold_callable = _operator_cache(
        evidence_store=cold_store,
        configuration_id="cold-candidate",
    )
    cold = cold_cache.non_ash(_zero_rule())
    cold_cache.commit_pending_aggregate_origins()
    cold_metric_count = len(metric_calls)

    warm_store = ContentAddressedEvidenceStore(evidence_root)
    warm_cache, warm_callable = _operator_cache(
        evidence_store=warm_store,
        configuration_id="same-bank-neighbor",
    )
    warm = warm_cache.non_ash(_zero_rule())

    assert warm == cold
    assert len(metric_calls) == cold_metric_count
    assert cold_callable.durability_flush_calls == 1
    assert warm_callable.durability_flush_calls == 0
    assert warm_cache.pending_aggregate_origin_count == 0


def test_new_native_durability_commit_rejects_wrong_requester(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = MemoryEvidenceStore()
    cache, callable_value = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    callable_value.configuration_id = "wrong-requester"

    with pytest.raises(
        ProductionEvaluatorError,
        match="native control-cache durability commit is invalid",
    ):
        cache.commit_pending_aggregate_origins()

    assert store._control_aggregate_origins == {}


def test_partial_origin_batch_contains_only_safe_complete_origins(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, callable_value = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    second_rule = dict(_zero_rule())
    second_rule[NON_ASH_COORDINATES[0]] = 128
    cache.non_ash(second_rule)
    pending_identities = [
        value["identity"] for value in cache._pending_aggregate_origins.values()
    ]
    original_write = ContentAddressedEvidenceStore._write_at
    origin_write_count = 0

    def partial_write(
        directory_descriptor: int,
        filename: str,
        payload: bytes,
        *,
        label: str,
        fsync_file: bool = True,
    ) -> None:
        nonlocal origin_write_count
        if label == "control-aggregate origin":
            origin_write_count += 1
            if origin_write_count == 2:
                raise ProductionEvaluatorError("injected origin batch interruption")
        original_write(
            directory_descriptor,
            filename,
            payload,
            label=label,
            fsync_file=fsync_file,
        )

    monkeypatch.setattr(
        ContentAddressedEvidenceStore,
        "_write_at",
        staticmethod(partial_write),
    )
    with pytest.raises(ProductionEvaluatorError, match="batch interruption"):
        cache.commit_pending_aggregate_origins()

    first_origin = store.reopen_control_aggregate_origin(pending_identities[0])
    assert first_origin is not None
    assert store.reopen(first_origin["native_dependency_evidence_sha256"])[
        "record_sha256"
    ] == first_origin["native_dependency_commit_sha256"]
    assert store.reopen(first_origin["evidence_dependency_evidence_sha256"])[
        "record_sha256"
    ] == first_origin["evidence_dependency_commit_sha256"]
    assert callable_value.durability_flush_calls == 1

    monkeypatch.setattr(
        ContentAddressedEvidenceStore,
        "_write_at",
        staticmethod(original_write),
    )
    cache.commit_pending_aggregate_origins()

    assert callable_value.durability_flush_calls == 1
    assert all(
        store.reopen_control_aggregate_origin(identity) is not None
        for identity in pending_identities
    )


def test_persistent_origin_real_directory_replacement_hard_fails(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, _ = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    cache.commit_pending_aggregate_origins()
    origins = store._control_aggregate_origins
    origins.rename(origins.with_name("preserved-origins"))
    origins.mkdir()

    with pytest.raises(
        ProductionEvaluatorError,
        match="origin directory identity changed",
    ):
        cache.non_ash(_zero_rule())


def test_document_directory_real_replacement_blocks_origin_commit(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, _ = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    documents = store._documents
    documents.rename(documents.with_name("preserved-documents"))
    documents.mkdir()

    with pytest.raises(
        ProductionEvaluatorError,
        match="document directory identity changed",
    ):
        cache.commit_pending_aggregate_origins()

    assert not any(store._control_aggregate_origins.iterdir())


def test_new_persistent_origin_fsyncs_containing_directory(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    fsync_modes: list[int] = []
    fsync_identities: list[tuple[int, int]] = []
    original_fsync = providers_module.os.fsync

    def tracked_fsync(descriptor: int) -> None:
        status = providers_module.os.fstat(descriptor)
        fsync_modes.append(status.st_mode)
        if stat.S_ISDIR(status.st_mode):
            fsync_identities.append((status.st_dev, status.st_ino))
        original_fsync(descriptor)

    monkeypatch.setattr(providers_module.os, "fsync", tracked_fsync)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, _ = _operator_cache(evidence_store=store)

    cache.non_ash(_zero_rule())
    cache.commit_pending_aggregate_origins()

    assert any(stat.S_ISDIR(mode) for mode in fsync_modes)
    documents_identity = store._directory_identities[store._documents]
    origins_identity = store._directory_identities[
        store._control_aggregate_origins
    ]
    assert documents_identity in fsync_identities
    assert origins_identity in fsync_identities
    assert fsync_identities.index(documents_identity) < fsync_identities.index(
        origins_identity
    )


def test_generic_and_failure_publication_fsync_their_pinned_directories(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    fsync_identities: list[tuple[int, int]] = []
    original_fsync = providers_module.os.fsync

    def tracked_fsync(descriptor: int) -> None:
        status = providers_module.os.fstat(descriptor)
        if stat.S_ISDIR(status.st_mode):
            fsync_identities.append((status.st_dev, status.st_ino))
        original_fsync(descriptor)

    monkeypatch.setattr(providers_module.os, "fsync", tracked_fsync)
    store.publish({"artifact_kind": "generic-directory-durability"})
    store.preserve_failure(
        {"artifact_kind": "failure-directory-durability"}
    )

    assert store._directory_identities[store._documents] in fsync_identities
    assert store._directory_identities[store._failures] in fsync_identities


def test_non_ash_aggregate_documents_are_staged_until_commit(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    fsync_modes: list[int] = []
    original_fsync = providers_module.os.fsync

    def tracked_fsync(descriptor: int) -> None:
        fsync_modes.append(providers_module.os.fstat(descriptor).st_mode)
        original_fsync(descriptor)

    monkeypatch.setattr(providers_module.os, "fsync", tracked_fsync)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, _ = _operator_cache(evidence_store=store)
    fsync_count_before_aggregate = len(fsync_modes)

    aggregate = cache.non_ash(_zero_rule())

    aggregate_documents = {
        aggregate.objective_summary_sha256,
        aggregate.output_manifest_sha256,
    }
    assert len(fsync_modes) == fsync_count_before_aggregate
    assert set(store._pending_control_aggregate_documents) == (
        aggregate_documents
    )
    assert all(
        not (store._documents / f"{sha256}.json").exists()
        for sha256 in aggregate_documents
    )
    assert all(store.reopen(sha256) for sha256 in aggregate_documents)

    cache.commit_pending_aggregate_origins()

    assert store._pending_control_aggregate_documents == {}
    assert all(
        (store._documents / f"{sha256}.json").is_file()
        for sha256 in aggregate_documents
    )
    assert not any(
        store._is_temporary_filename(path.name)
        for path in store._documents.iterdir()
    )
    assert len(fsync_modes) > fsync_count_before_aggregate

    generic_fsync_count = len(fsync_modes)
    store.publish({"artifact_kind": "generic-immediate-durability"})
    assert len(fsync_modes) > generic_fsync_count


def test_partial_aggregate_document_promotion_is_retryable(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, callable_value = _operator_cache(evidence_store=store)
    aggregate = cache.non_ash(_zero_rule())
    aggregate_documents = {
        aggregate.objective_summary_sha256,
        aggregate.output_manifest_sha256,
    }
    original_promote = ContentAddressedEvidenceStore._promote_staged_at
    promotion_count = 0

    def interrupt_second_promotion(
        directory_descriptor: int,
        temporary_filename: str,
        filename: str,
        payload: bytes,
        *,
        label: str,
    ) -> None:
        nonlocal promotion_count
        promotion_count += 1
        if promotion_count == 2:
            raise ProductionEvaluatorError(
                "injected aggregate document promotion interruption"
            )
        original_promote(
            directory_descriptor,
            temporary_filename,
            filename,
            payload,
            label=label,
        )

    monkeypatch.setattr(
        ContentAddressedEvidenceStore,
        "_promote_staged_at",
        staticmethod(interrupt_second_promotion),
    )
    with pytest.raises(ProductionEvaluatorError, match="promotion interruption"):
        cache.commit_pending_aggregate_origins()

    assert callable_value.durability_flush_calls == 1
    assert not any(store._control_aggregate_origins.iterdir())
    assert sum(
        (store._documents / f"{sha256}.json").is_file()
        for sha256 in aggregate_documents
    ) == 1
    assert len(store._pending_control_aggregate_documents) == 1

    monkeypatch.setattr(
        ContentAddressedEvidenceStore,
        "_promote_staged_at",
        staticmethod(original_promote),
    )
    cache.commit_pending_aggregate_origins()

    assert callable_value.durability_flush_calls == 1
    assert store._pending_control_aggregate_documents == {}
    assert len(tuple(store._control_aggregate_origins.glob("*.json"))) == 1


def test_interrupted_atomic_document_write_leaves_no_final_poison(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    document = {"artifact_kind": "atomic-document-interruption", "value": 1}
    digest = canonical_sha256(document)
    final_path = store._documents / f"{digest}.json"
    original_write = providers_module.os.write
    write_count = 0

    def interrupted_write(descriptor: int, payload: bytes) -> int:
        nonlocal write_count
        write_count += 1
        if write_count == 1:
            return original_write(
                descriptor,
                payload[: max(1, len(payload) // 2)],
            )
        raise OSError("injected mid-write interruption")

    monkeypatch.setattr(providers_module.os, "write", interrupted_write)
    with pytest.raises(OSError, match="mid-write interruption"):
        store.publish(document)

    assert not final_path.exists()
    assert not any(
        store._is_temporary_filename(path.name)
        for path in store._documents.iterdir()
    )

    monkeypatch.setattr(providers_module.os, "write", original_write)
    assert store.publish(document)["sha256"] == digest


def test_interrupted_atomic_origin_write_leaves_no_final_poison(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_counted_metrics(monkeypatch)
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    cache, callable_value = _operator_cache(evidence_store=store)
    cache.non_ash(_zero_rule())
    original_write_at = ContentAddressedEvidenceStore._write_at
    original_os_write = providers_module.os.write
    origin_write_active = False
    origin_chunk_count = 0

    def scoped_write_at(
        directory_descriptor: int,
        filename: str,
        payload: bytes,
        *,
        label: str,
        fsync_file: bool = True,
    ) -> None:
        nonlocal origin_write_active
        origin_write_active = label == "control-aggregate origin"
        try:
            original_write_at(
                directory_descriptor,
                filename,
                payload,
                label=label,
                fsync_file=fsync_file,
            )
        finally:
            origin_write_active = False

    def interrupted_origin_write(descriptor: int, payload: bytes) -> int:
        nonlocal origin_chunk_count
        if not origin_write_active:
            return original_os_write(descriptor, payload)
        origin_chunk_count += 1
        if origin_chunk_count == 1:
            return original_os_write(
                descriptor,
                payload[: max(1, len(payload) // 2)],
            )
        raise OSError("injected origin mid-write interruption")

    monkeypatch.setattr(
        ContentAddressedEvidenceStore,
        "_write_at",
        staticmethod(scoped_write_at),
    )
    monkeypatch.setattr(
        providers_module.os,
        "write",
        interrupted_origin_write,
    )
    with pytest.raises(OSError, match="origin mid-write interruption"):
        cache.commit_pending_aggregate_origins()

    assert not any(store._control_aggregate_origins.iterdir())
    assert callable_value.durability_flush_calls == 1

    monkeypatch.setattr(
        ContentAddressedEvidenceStore,
        "_write_at",
        staticmethod(original_write_at),
    )
    monkeypatch.setattr(providers_module.os, "write", original_os_write)
    cache.commit_pending_aggregate_origins()

    assert callable_value.durability_flush_calls == 1
    assert len(tuple(store._control_aggregate_origins.glob("*.json"))) == 1


def test_store_startup_removes_stale_same_directory_temporary_files(
    tmp_path: Path,
) -> None:
    root = tmp_path / "evidence"
    first = ContentAddressedEvidenceStore(root)
    stale_paths = []
    for directory in (
        first._documents,
        first._failures,
        first._control_aggregate_origins,
    ):
        path = directory / ".mirmir-write-crash.tmp"
        path.write_bytes(b"partial")
        stale_paths.append(path)

    ContentAddressedEvidenceStore(root)

    assert all(not path.exists() for path in stale_paths)


def test_store_initialization_fsyncs_each_new_directory_parent(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    existing_parent = tmp_path / "existing-parent"
    existing_parent.mkdir()
    fsync_identities: list[tuple[int, int]] = []
    original_fsync = providers_module.os.fsync

    def tracked_fsync(descriptor: int) -> None:
        status = providers_module.os.fstat(descriptor)
        if stat.S_ISDIR(status.st_mode):
            fsync_identities.append((status.st_dev, status.st_ino))
        original_fsync(descriptor)

    monkeypatch.setattr(providers_module.os, "fsync", tracked_fsync)
    store = ContentAddressedEvidenceStore(
        existing_parent / "new-parent" / "evidence"
    )
    existing_identity = (
        existing_parent.stat().st_dev,
        existing_parent.stat().st_ino,
    )
    new_parent = existing_parent / "new-parent"
    new_parent_identity = (
        new_parent.stat().st_dev,
        new_parent.stat().st_ino,
    )
    root_identity = (store._root.stat().st_dev, store._root.stat().st_ino)

    assert existing_identity in fsync_identities
    assert new_parent_identity in fsync_identities
    assert root_identity in fsync_identities
    assert fsync_identities.index(existing_identity) < (
        fsync_identities.index(new_parent_identity)
    )
    assert fsync_identities.index(new_parent_identity) < (
        fsync_identities.index(root_identity)
    )


def test_preexisting_partial_document_final_fails_closed(
    tmp_path: Path,
) -> None:
    store = ContentAddressedEvidenceStore(tmp_path / "evidence")
    document = {"artifact_kind": "preexisting-partial-final", "value": 2}
    digest = canonical_sha256(document)
    final_path = store._documents / f"{digest}.json"
    final_path.write_bytes(b'{"artifact_kind":')

    with pytest.raises(ProductionEvaluatorError, match="evidence changed"):
        store.publish(document)

    assert final_path.read_bytes() == b'{"artifact_kind":'


def test_persistent_store_rejects_root_symlink(tmp_path: Path) -> None:
    external = tmp_path / "external"
    external.mkdir()
    root = tmp_path / "evidence"
    root.symlink_to(external, target_is_directory=True)

    with pytest.raises(
        ProductionEvaluatorError,
        match="root path contains a symlink",
    ):
        ContentAddressedEvidenceStore(root)


def test_persistent_store_rejects_intermediate_parent_symlink(
    tmp_path: Path,
) -> None:
    external = tmp_path / "external"
    external.mkdir()
    linked_parent = tmp_path / "linked-parent"
    linked_parent.symlink_to(external, target_is_directory=True)

    with pytest.raises(
        ProductionEvaluatorError,
        match="root path contains a symlink",
    ):
        ContentAddressedEvidenceStore(linked_parent / "evidence")


def test_root_real_directory_replacement_hard_fails(tmp_path: Path) -> None:
    root = tmp_path / "evidence"
    store = ContentAddressedEvidenceStore(root)
    root.rename(tmp_path / "preserved-evidence")
    root.mkdir()

    with pytest.raises(
        ProductionEvaluatorError,
        match="root directory identity changed",
    ):
        store.publish({"artifact_kind": "replacement-probe"})


def test_intermediate_parent_real_directory_replacement_hard_fails(
    tmp_path: Path,
) -> None:
    parent = tmp_path / "parent"
    root = parent / "evidence"
    store = ContentAddressedEvidenceStore(root)
    parent.rename(tmp_path / "preserved-parent")
    parent.mkdir()

    with pytest.raises(
        ProductionEvaluatorError,
        match="root directory identity changed",
    ):
        store.publish({"artifact_kind": "parent-replacement-probe"})


def test_persistent_store_rejects_preexisting_origin_directory_symlink(
    tmp_path: Path,
) -> None:
    root = tmp_path / "evidence"
    root.mkdir()
    external = tmp_path / "external"
    external.mkdir()
    (root / "control-aggregate-origins").symlink_to(
        external,
        target_is_directory=True,
    )

    with pytest.raises(
        ProductionEvaluatorError,
        match="must not be a symlink",
    ):
        ContentAddressedEvidenceStore(root)


def test_persistent_store_rejects_preexisting_document_directory_symlink(
    tmp_path: Path,
) -> None:
    root = tmp_path / "evidence"
    root.mkdir()
    external = tmp_path / "external"
    external.mkdir()
    (root / "documents").symlink_to(external, target_is_directory=True)

    with pytest.raises(
        ProductionEvaluatorError,
        match="document directory must not be a symlink",
    ):
        ContentAddressedEvidenceStore(root)


def test_tracked_full_selector_cold_warm_benchmark_and_exact_ledger(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    metric_calls = _install_counted_metrics(monkeypatch)
    evidence_root = tmp_path / "evidence"
    store = ContentAddressedEvidenceStore(evidence_root)
    prepared = _prepared_cases(source_count=6)
    assert len(prepared) == 18
    cache, callable_value, tracked = _tracked_operator_cache(
        evidence_store=store,
        prepared=prepared,
    )
    free_disk_bytes_before = shutil.disk_usage(evidence_root).free

    cold_started = time.perf_counter()
    first = search_non_ash_development(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=DEGRADATION_POLICY,
        selector_contract=_selector_contract(),
        development_evaluator=cache.non_ash,
        cached_16_operator_output_manifest_sha256=cache.manifest_sha256,
        evidence_store=store,
    )
    cache.commit_pending_aggregate_origins()
    cold_seconds = time.perf_counter() - cold_started
    first_metric_count = len(metric_calls)
    first_reconstruction_count = callable_value.reconstruction_calls
    first_ledger_sha256 = first["document"][
        "development_attempt_ledger_sha256"
    ]
    first_ledger_bytes = canonical_json_bytes(
        store.reopen(first_ledger_sha256)
    )
    cold_files = tuple(
        path
        for path in evidence_root.rglob("*")
        if path.is_file() and not path.is_symlink()
    )
    cold_file_count = len(cold_files)
    cold_size_bytes = sum(path.stat().st_size for path in cold_files)

    warm_started = time.perf_counter()
    second = search_non_ash_development(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=DEGRADATION_POLICY,
        selector_contract=_selector_contract(),
        development_evaluator=cache.non_ash,
        cached_16_operator_output_manifest_sha256=cache.manifest_sha256,
        evidence_store=store,
    )
    cache.commit_pending_aggregate_origins()
    warm_seconds = time.perf_counter() - warm_started
    second_ledger_sha256 = second["document"][
        "development_attempt_ledger_sha256"
    ]
    warm_files = tuple(
        path
        for path in evidence_root.rglob("*")
        if path.is_file() and not path.is_symlink()
    )
    warm_file_count = len(warm_files)
    warm_size_bytes = sum(path.stat().st_size for path in warm_files)
    free_disk_bytes_after = shutil.disk_usage(evidence_root).free
    prepared_case_count = len(prepared)
    observed_unique_rules = first_reconstruction_count // prepared_case_count
    maximum_unique_rules_per_bank = 1297
    maximum_native_calls_per_bank = (
        maximum_unique_rules_per_bank * prepared_case_count
    )
    maximum_bank_count = 321
    maximum_native_calls_all_banks = (
        maximum_native_calls_per_bank * maximum_bank_count
    )
    benchmark = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_control_aggregate_cache_synthetic_benchmark",
        "scope": (
            "actual _TrackedCandidateCallable and _NativeSelectionOutputCache; "
            "real ContentAddressedEvidenceStore; synthetic in-process native stub"
        ),
        "native_performance_claim": False,
        "free_disk_bytes_before": free_disk_bytes_before,
        "free_disk_bytes_after": free_disk_bytes_after,
        "prepared_case_count": prepared_case_count,
        "route_case_counts": {
            route: sum(
                1 for item in prepared if item.context.target_route == route
            )
            for route in ("direct-2x", "direct-3over2")
        },
        "cold": {
            "seconds": cold_seconds,
            "metric_call_count": first_metric_count,
            "native_reconstruction_call_count": first_reconstruction_count,
            "persisted_file_count": cold_file_count,
            "persisted_size_bytes": cold_size_bytes,
        },
        "warm": {
            "seconds": warm_seconds,
            "metric_call_count": len(metric_calls) - first_metric_count,
            "native_reopen_recombination_call_count": callable_value.reopen_calls,
            "persisted_file_count": warm_file_count,
            "persisted_size_bytes": warm_size_bytes,
        },
        "observed": {
            "development_attempt_count": first["document"][
                "development_attempt_count"
            ],
            "unique_rule_count": observed_unique_rules,
            "origin_file_count": len(
                tuple(store._control_aggregate_origins.glob("*.json"))
            ),
            "tracked_control_call_count": len(tracked.control_calls),
        },
        "maximum_formulas": {
            "unique_rules_per_bank": maximum_unique_rules_per_bank,
            "prepared_cases_per_bank": prepared_case_count,
            "native_calls_per_bank": maximum_native_calls_per_bank,
            "bank_count": maximum_bank_count,
            "native_calls_all_banks": maximum_native_calls_all_banks,
            "native_calls_per_bank_formula": "1297 * 18 = 23346",
            "native_calls_all_banks_formula": "23346 * 321 = 7494066",
        },
    }
    benchmark["evidence_sha256"] = canonical_sha256(benchmark)
    benchmark_output = os.environ.get("MIRMIR_AGGREGATE_BENCHMARK_OUTPUT")
    if benchmark_output:
        Path(benchmark_output).write_bytes(canonical_json_bytes(benchmark) + b"\n")

    assert second == first
    assert second_ledger_sha256 == first_ledger_sha256
    assert canonical_json_bytes(store.reopen(second_ledger_sha256)) == (
        first_ledger_bytes
    )
    assert len(metric_calls) == first_metric_count
    assert callable_value.reconstruction_calls == first_reconstruction_count
    assert callable_value.reopen_calls > 0
    assert first_metric_count == first_reconstruction_count
    assert first_reconstruction_count % prepared_case_count == 0
    assert observed_unique_rules <= maximum_unique_rules_per_bank
    assert callable_value.reopen_calls == first_reconstruction_count
    assert maximum_native_calls_per_bank == 23_346
    assert maximum_native_calls_all_banks == 7_494_066
    assert warm_file_count == cold_file_count
    assert warm_size_bytes == cold_size_bytes
