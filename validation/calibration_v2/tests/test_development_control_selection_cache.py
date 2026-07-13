from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
from typing import Mapping

import pytest

import validation.calibration_v2.production_evaluator as evaluator_module
from validation.calibration_v2.production_evaluator import (
    COMMON_CONTROL_BOUNDARY_CONTRACT,
    CONVENTIONAL_ALGORITHM_IDS,
    FIXED_DESCRIPTOR_IDS,
    NON_ASH_COORDINATES,
    NON_ASH_SELECTOR_ID,
    NON_ASH_VALUES,
    P00_BACKEND_SHA256,
    P00_COMMIT,
    SELECTION_OBJECTIVE,
    ControlAggregateEvidence,
    ProductionCandidateEvaluator,
    ProductionEvaluatorError,
    _development_selection_cache_identity,
    _development_selection_cache_origin,
    _development_selection_cache_provenance,
    _validate_development_selection_cache_origin,
    canonical_json_bytes,
    canonical_sha256,
    non_ash_control_request,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
)
from validation.calibration_v2.runner import (
    CalibrationError,
    CalibrationBindingError,
    _DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY,
    _DevelopmentControlSelectionCache,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
)


BANK = "1" * 64
DEGRADATION_POLICY = "2" * 64


def _sha256(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


_CANDIDATE_EVALUATION_SCHEMA = json.loads(
    (
        evaluator_module.SCHEMAS_ROOT
        / "candidate-evaluation-v1.schema.json"
    ).read_text(encoding="utf-8")
)


def _candidate_schema_fixture(
    definition_name: str,
) -> Mapping[str, object]:
    definitions = _CANDIDATE_EVALUATION_SCHEMA["$defs"]

    def fixture(
        schema: Mapping[str, object],
        *,
        label: str,
        ordinal: int = 0,
    ) -> object:
        reference = schema.get("$ref")
        if isinstance(reference, str):
            prefix = "#/$defs/"
            if not reference.startswith(prefix):
                raise AssertionError(
                    f"unsupported candidate schema reference: {reference}"
                )
            target = definitions.get(reference[len(prefix) :])
            if not isinstance(target, dict):
                raise AssertionError(
                    f"missing candidate schema definition: {reference}"
                )
            return fixture(target, label=label, ordinal=ordinal)
        if "const" in schema:
            return copy.deepcopy(schema["const"])
        enum = schema.get("enum")
        if isinstance(enum, list) and enum:
            return copy.deepcopy(enum[ordinal % len(enum)])
        alternatives = schema.get("oneOf")
        if isinstance(alternatives, list) and alternatives:
            first = alternatives[0]
            if not isinstance(first, dict):
                raise AssertionError("candidate schema alternative is invalid")
            return fixture(first, label=label, ordinal=ordinal)
        schema_type = schema.get("type")
        if isinstance(schema_type, list):
            schema_type = next(
                (value for value in schema_type if value != "null"),
                "null",
            )
        if schema_type == "object" or "properties" in schema:
            properties = schema.get("properties", {})
            if not isinstance(properties, dict):
                raise AssertionError("candidate schema properties are invalid")
            value = {
                key: fixture(
                    properties.get(key, {}),
                    label=f"{label}.{key}",
                    ordinal=ordinal,
                )
                for key in schema.get("required", [])
            }
            minimum = int(schema.get("minProperties", 0))
            additional = schema.get("additionalProperties")
            while len(value) < minimum:
                key = f"fixture_{len(value):02d}"
                value[key] = fixture(
                    additional if isinstance(additional, dict) else {},
                    label=f"{label}.{key}",
                    ordinal=len(value),
                )
            return value
        if schema_type == "array":
            item_schema = schema.get("items", {})
            if not isinstance(item_schema, dict):
                raise AssertionError("candidate schema array item is invalid")
            return [
                fixture(
                    item_schema,
                    label=f"{label}[{index}]",
                    ordinal=index,
                )
                for index in range(int(schema.get("minItems", 0)))
            ]
        if schema_type == "string":
            if schema.get("pattern") == "^[0-9a-f]{64}$":
                return _sha256(label)
            return "x" * max(1, int(schema.get("minLength", 0)))
        if schema_type == "integer":
            return int(schema.get("minimum", 0))
        if schema_type == "number":
            return float(schema.get("minimum", 0))
        if schema_type == "boolean":
            return True
        if schema_type == "null":
            return None
        return {}

    definition = definitions.get(definition_name)
    if not isinstance(definition, dict):
        raise AssertionError(
            f"missing candidate schema definition: {definition_name}"
        )
    result = fixture(definition, label=definition_name)
    if not isinstance(result, dict):
        raise AssertionError(
            f"candidate schema fixture is not an object: {definition_name}"
        )
    return result


def _selector_contract() -> Mapping[str, object]:
    return {
        "selector_id": NON_ASH_SELECTOR_ID,
        "bank_descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
        "candidate_evaluation_budget": 1513,
        "full_ash_maximum_candidate_evaluation_budget": 1297,
        "coordinates": {
            "order": list(NON_ASH_COORDINATES),
            "values": list(NON_ASH_VALUES),
            "initial_value": 0,
            "maximum_sweeps": 8,
        },
    }


def _aggregate_context(*, sample_lock: str = "sample-lock") -> Mapping[str, object]:
    selector = _selector_contract()
    return {
        "degradation_policy_file_sha256": _sha256("degradation-file"),
        "metric_policy_file_sha256": _sha256("metric-file"),
        "metric_policy_sha256": _sha256("metric-policy"),
        "baseline_ablation_contract_file_sha256": _sha256("baseline-file"),
        "baseline_selector_contract": selector,
        "baseline_selector_contract_sha256": canonical_sha256(selector),
        "sample_lock_file_sha256": _sha256(sample_lock),
        "corpus_manifest_sha256": _sha256("corpus-manifest"),
        "corpus_lock_bundle_sha256": _sha256("corpus-bundle"),
        "common_boundary_contract": COMMON_CONTROL_BOUNDARY_CONTRACT,
        "common_boundary_contract_sha256": canonical_sha256(
            COMMON_CONTROL_BOUNDARY_CONTRACT
        ),
        "native_implementation_closure": {
            "executable_sha256": _sha256("native-executable"),
            "source_manifest_sha256": _sha256("native-source"),
        },
        "quality_implementation_closure": {
            "implementation_manifest_file_sha256": _sha256(
                "quality-manifest-file"
            ),
            "implementation_manifest_sha256": _sha256("quality-manifest"),
        },
    }


def _ordered_input_bindings(
    *,
    first_input: str = "input-0",
) -> list[Mapping[str, object]]:
    values = []
    for ordinal, route in enumerate(("direct-2x", "direct-3over2")):
        input_label = first_input if ordinal == 0 else f"input-{ordinal}"
        values.append(
            {
                "ordinal": ordinal,
                "source_asset_id": f"source-{ordinal}",
                "source_family_id": f"family-{ordinal}",
                "categories": ["focused-cache"],
                "target_route": route,
                "degradation_profile_id": f"profile-{ordinal}",
                "degradation_profile_sha256": _sha256(
                    f"profile-document-{ordinal}"
                ),
                "target_frame_sha256": _sha256(f"target-{ordinal}"),
                "input_frame_sha256": _sha256(input_label),
                "cache_token": _sha256(f"cache-token-{ordinal}"),
                "cache_identity_sha256": _sha256(
                    f"cache-identity-{ordinal}"
                ),
                "cache_origin_manifest_sha256": _sha256(
                    f"cache-origin-{ordinal}"
                ),
            }
        )
    return values


def _embedded(document: Mapping[str, object]) -> Mapping[str, object]:
    copied = json.loads(canonical_json_bytes(document))
    return {"sha256": canonical_sha256(copied), "document": copied}


def _selection_artifacts(bank: str = BANK) -> Mapping[str, Mapping[str, object]]:
    fixed_results = [
        {
            "descriptor_id": descriptor_id,
            "engine_raw_corpus_mean_tuple": [
                float(descriptor_id),
                0.9,
                0.8,
                40.0,
                39.0,
            ],
            "objective_summary_sha256": _sha256(
                f"fixed-objective-{descriptor_id}"
            ),
            "output_manifest_sha256": _sha256(
                f"fixed-output-{descriptor_id}"
            ),
        }
        for descriptor_id in FIXED_DESCRIPTOR_IDS
    ]
    fixed = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_fixed_control_selection",
        "selection_stage": "development_provisional",
        "shared_bank_configuration_sha256": bank,
        "uniform_application": True,
        "candidate_ids": list(FIXED_DESCRIPTOR_IDS),
        "selection_objective": SELECTION_OBJECTIVE,
        "development_results": fixed_results,
        "provisional_descriptor_id": 15,
        "tie_break": (
            "lexicographically maximize the development engine_raw "
            "corpus-mean tuple, then choose the numerically smallest "
            "descriptor ID"
        ),
    }
    conventional_results = [
        {
            "algorithm_id": algorithm_id,
            "engine_raw_corpus_mean_tuple": [float(ordinal), 0.9, 0.8, 40.0, 39.0],
            "objective_summary_sha256": _sha256(
                f"conventional-objective-{ordinal}"
            ),
            "output_manifest_sha256": _sha256(
                f"conventional-output-{ordinal}"
            ),
        }
        for ordinal, algorithm_id in enumerate(CONVENTIONAL_ALGORITHM_IDS)
    ]
    conventional = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_conventional_control_selection",
        "selection_stage": "development_provisional",
        "shared_bank_configuration_sha256": bank,
        "uniform_application": True,
        "candidate_ids": list(CONVENTIONAL_ALGORITHM_IDS),
        "selection_objective": SELECTION_OBJECTIVE,
        "development_results": conventional_results,
        "provisional_algorithm_id": CONVENTIONAL_ALGORITHM_IDS[-1],
        "tie_break": (
            "lexicographically maximize the development engine_raw "
            "corpus-mean tuple, then choose the lexicographically ascending "
            "stable algorithm ID"
        ),
    }
    terminal_rule = {coordinate: 0 for coordinate in NON_ASH_COORDINATES}
    non_ash = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_non_ash_selector_selection",
        "selection_stage": "development_provisional",
        "selector_id": NON_ASH_SELECTOR_ID,
        "shared_bank_configuration_sha256": bank,
        "uniform_application": True,
        "candidate_evaluation_budget": 1513,
        "full_ash_maximum_candidate_evaluation_budget": 1297,
        "selection_objective": SELECTION_OBJECTIVE,
        "development_attempt_count": 1,
        "development_attempt_ledger_sha256": _sha256("attempt-ledger"),
        "development_terminal_rule_sha256": canonical_sha256(terminal_rule),
        "development_terminal_rule_configuration": terminal_rule,
        "cached_16_operator_output_manifest_sha256": _sha256(
            "operator-output-manifest"
        ),
        "development_objective_summary_sha256": _sha256(
            "terminal-objective"
        ),
        "development_engine_raw_corpus_mean_tuple": [42.0, 0.9, 0.8, 40.0, 39.0],
        "tie_break": (
            "lexicographically maximize the development engine_raw "
            "corpus-mean tuple, then choose the lexicographically ascending "
            "canonical serialized complete rule vector"
        ),
    }
    return {
        "best_fixed": _embedded(fixed),
        "conventional": _embedded(conventional),
        "non_ash_selector": _embedded(non_ash),
    }


def _identity(
    cache: _DevelopmentControlSelectionCache,
    *,
    bank: str = BANK,
    sample_lock: str = "sample-lock",
    first_input: str = "input-0",
    storage_implementation_sha256: str | None = None,
) -> Mapping[str, object]:
    implementation = dict(cache.implementation_identity)
    if storage_implementation_sha256 is not None:
        implementation["storage_implementation_sha256"] = (
            storage_implementation_sha256
        )
    return _development_selection_cache_identity(
        shared_bank_configuration_sha256=bank,
        degradation_policy_sha256=DEGRADATION_POLICY,
        aggregate_identity_context=_aggregate_context(sample_lock=sample_lock),
        ordered_input_bindings=_ordered_input_bindings(first_input=first_input),
        cache_implementation_identity=implementation,
    )


def _cache(tmp_path: Path) -> _DevelopmentControlSelectionCache:
    return _DevelopmentControlSelectionCache(
        tmp_path / _DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY
    )


def _p00_identity() -> Mapping[str, object]:
    configuration = {
        "tile_size": 32,
        "top_k": 1,
        "luma_input_normalization": "raw_byte_divided_by_255",
        "luma_output_quantization": "rounded_times_255",
        "chroma_reconstruction": "nearest",
        "direct_3_over_2_postprocess": (
            "baseline_MPSImageLanczosScale_after_exact_2x"
        ),
    }
    return {
        "commit": P00_COMMIT,
        "backend_source_sha256": P00_BACKEND_SHA256,
        "source_manifest_sha256": _sha256("p00-source"),
        "executable_sha256": _sha256("p00-executable"),
        "configuration_sha256": canonical_sha256(configuration),
        "compatibility_boundary_normalization": {
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
        },
        **configuration,
    }


class _CountingSelectionCache:
    def __init__(self, delegate: _DevelopmentControlSelectionCache) -> None:
        self.delegate = delegate
        self.reopen_count = 0
        self.publish_count = 0

    @property
    def implementation_identity(self) -> Mapping[str, object]:
        return self.delegate.implementation_identity

    def reopen(
        self,
        identity: Mapping[str, object],
    ) -> Mapping[str, object] | None:
        self.reopen_count += 1
        return self.delegate.reopen(identity)

    def publish(
        self,
        *,
        identity: Mapping[str, object],
        origin: Mapping[str, object],
    ) -> Mapping[str, object]:
        self.publish_count += 1
        return self.delegate.publish(identity=identity, origin=origin)

    def close(self) -> None:
        self.delegate.close()


class _InstrumentedOperatorCache:
    def __init__(
        self,
        *,
        instrumentation: dict[str, object],
        adapter: CandidateAdapter,
        prepared: object,
        split: str,
        shared_bank_configuration_sha256: str,
        degradation_policy_sha256: str,
        evidence_store: ContentAddressedEvidenceStore,
        aggregate_identity_context: Mapping[str, object],
    ) -> None:
        del adapter, prepared, aggregate_identity_context
        self.split = split
        self.bank = shared_bank_configuration_sha256
        self.degradation_policy_sha256 = degradation_policy_sha256
        self.evidence_store = evidence_store
        self.instrumentation = instrumentation
        self.selector_native_recombinations = 0
        self.fixed_materializations = 0
        self._development_selector_search_active = False
        self._development_selector_search_invocation_count = 0
        self._development_selector_rule_aggregate_evaluation_count = 0
        self._development_selector_native_recombination_count = 0
        self._bindings = _ordered_input_bindings()
        manifest = {
            "schema_version": "1.1.0",
            "artifact_kind": "p06_cached_16_operator_output_manifest",
            "split": split,
            "shared_bank_configuration_sha256": self.bank,
            "degradation_policy_sha256": self.degradation_policy_sha256,
            "descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
            "input_cache_manifest_sha256_values": [
                binding["cache_token"] for binding in self._bindings
            ],
            "input_cache_manifests": [
                {
                    "cache_manifest_sha256": binding["cache_token"],
                    "input_frame_sha256": binding["input_frame_sha256"],
                    "target_route": binding["target_route"],
                }
                for binding in self._bindings
            ],
        }
        self.manifest_sha256 = str(
            evidence_store.publish(manifest)["sha256"]
        )
        instrumentation["operator_instances"].append(self)

    def begin_development_selector_search(self) -> None:
        assert self._development_selector_search_active is False
        self._development_selector_search_active = True
        self._development_selector_search_invocation_count += 1

    def end_development_selector_search(self) -> None:
        assert self._development_selector_search_active is True
        self._development_selector_search_active = False

    def development_selector_search_counts(self) -> Mapping[str, int]:
        assert self._development_selector_search_active is False
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

    def _ordered_input_bindings(self) -> list[Mapping[str, object]]:
        return json.loads(canonical_json_bytes(self._bindings))

    def _evidence(
        self,
        *,
        stable_id: object,
        score: float,
        label: str,
    ) -> ControlAggregateEvidence:
        objective = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_instrumented_control_objective",
            "split": self.split,
            "stable_id": stable_id,
            "score": score,
            "label": label,
            "shared_bank_configuration_sha256": self.bank,
            "degradation_policy_sha256": self.degradation_policy_sha256,
        }
        output = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_instrumented_control_output_manifest",
            "split": self.split,
            "stable_id": stable_id,
            "label": label,
            "shared_bank_configuration_sha256": self.bank,
            "degradation_policy_sha256": self.degradation_policy_sha256,
        }
        objective_binding = self.evidence_store.publish(objective)
        output_binding = self.evidence_store.publish(output)
        return ControlAggregateEvidence(
            split=self.split,
            stable_id=stable_id,
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=self.degradation_policy_sha256,
            rows=(),
            objective_means=(score, score, score, score, score),
            objective_summary_sha256=str(objective_binding["sha256"]),
            output_manifest_sha256=str(output_binding["sha256"]),
        )

    def fixed(self, descriptor_id: int) -> ControlAggregateEvidence:
        self.fixed_materializations += 1
        return self._evidence(
            stable_id=descriptor_id,
            score=float(descriptor_id),
            label=f"fixed-{descriptor_id}",
        )

    def conventional(self, algorithm_id: str) -> ControlAggregateEvidence:
        ordinal = CONVENTIONAL_ALGORITHM_IDS.index(algorithm_id)
        return self._evidence(
            stable_id=algorithm_id,
            score=float(ordinal),
            label=f"conventional-{ordinal}",
        )

    def non_ash(
        self,
        rule: Mapping[str, object],
    ) -> ControlAggregateEvidence:
        self.selector_native_recombinations += 1
        if self._development_selector_search_active:
            self._development_selector_rule_aggregate_evaluation_count += 1
            self._development_selector_native_recombination_count += 1
        request = non_ash_control_request(rule, self.bank)
        rule_sha256 = request["parameters"]["selected_rule_sha256"]
        score = -float(sum(abs(int(value)) for value in rule.values()))
        return self._evidence(
            stable_id=rule_sha256,
            score=score,
            label=f"non-ash-{rule_sha256}",
        )

    def commit_pending_aggregate_origins(self) -> Mapping[str, object]:
        self.instrumentation["aggregate_commits"] += 1
        return {"published_count": 0}


class _InstrumentedCaptured:
    def __init__(self, split: str) -> None:
        self.split = split
        self.input_sha256_bindings = (
            ("candidate_evidence_policy", _sha256("candidate-policy")),
        )
        self.candidate_evidence_policy = {"scope": "instrumented"}
        self.candidate_evidence_source_sha256_bindings = ()


def _integration_comparison_identities(
    bundle: object,
) -> Mapping[str, object]:
    identities = copy.deepcopy(
        _candidate_schema_fixture("comparisonIdentities")
    )
    identities["shared_bank_configuration_sha256"] = BANK
    identities["baseline_ablation_contract_sha256"] = _sha256(
        "baseline-contract"
    )
    for key in (
        "best_fixed",
        "conventional",
        "non_ash_selector",
        "state_only",
        "state_plus_branch",
        "h07_direct_3_over_2",
        "nearest_same_writer",
        "current_production_ash",
    ):
        identities[key]["shared_bank_configuration_sha256"] = BANK

    fixed = bundle.fixed_selection
    conventional = bundle.conventional_selection
    non_ash = bundle.non_ash_selection
    identities["best_fixed"].update(
        {
            "descriptor_id": fixed["document"][
                "provisional_descriptor_id"
            ],
            "configuration_sha256": bundle.request("best_fixed")[
                "configuration_sha256"
            ],
            "selection_sha256": fixed["sha256"],
        }
    )
    identities["conventional"].update(
        {
            "algorithm_id": conventional["document"][
                "provisional_algorithm_id"
            ],
            "configuration_sha256": bundle.request("conventional")[
                "configuration_sha256"
            ],
            "selection_sha256": conventional["sha256"],
        }
    )
    identities["non_ash_selector"].update(
        {
            "configuration_sha256": bundle.request("non_ash_selector")[
                "configuration_sha256"
            ],
            "selection_sha256": non_ash["sha256"],
            "rule_sha256": non_ash["document"][
                "development_terminal_rule_sha256"
            ],
        }
    )
    for identity_key, request_key in (
        ("state_only", "state_only"),
        ("state_plus_branch", "full_ash"),
        ("h07_direct_3_over_2", "h07_direct_3_over_2"),
        ("nearest_same_writer", "nearest_same_writer"),
        ("current_production_ash", "current_production_ash"),
    ):
        identities[identity_key].update(
            {
                "configuration_sha256": bundle.request(request_key)[
                    "configuration_sha256"
                ],
                "selection_sha256": bundle.bundle_sha256,
            }
        )
    return identities


def _integration_corpus_results(bundle: object) -> list[Mapping[str, object]]:
    comparison_identities = _integration_comparison_identities(bundle)
    rows = []
    for ordinal in range(6):
        row = copy.deepcopy(_candidate_schema_fixture("assetResult"))
        row.update(
            {
                "source_asset_id": f"integration-source-{ordinal}",
                "source_family_id": f"integration-family-{ordinal}",
                "categories": ["integration-cache"],
                "target_route": (
                    "direct-2x" if ordinal % 2 == 0 else "direct-3over2"
                ),
                "comparison_identities": comparison_identities,
            }
        )
        rows.append(row)
    return rows


def _integration_analytic_results(
    bundle: object,
) -> list[Mapping[str, object]]:
    comparison_identities = _integration_comparison_identities(bundle)
    rows = []
    for ordinal in range(28):
        row = copy.deepcopy(
            _candidate_schema_fixture("analyticFixtureResult")
        )
        row.update(
            {
                "fixture_id": f"integration-fixture-{ordinal}",
                "target_route": (
                    "direct-2x" if ordinal % 2 == 0 else "direct-3over2"
                ),
                "comparison_identities": comparison_identities,
            }
        )
        rows.append(row)
    return rows


class _InstrumentedEvidenceProvider:
    def __init__(self, instrumentation: dict[str, object]) -> None:
        self.instrumentation = instrumentation

    def evaluation_evidence(self, **kwargs: object) -> Mapping[str, object]:
        self.instrumentation["provider_calls"].append(
            {
                "split": kwargs["split"],
                "candidate_vector_sha256": kwargs[
                    "adapter"
                ].configuration["serialized_candidate_vector_sha256"],
            }
        )
        return {
            "checks": _candidate_schema_fixture("checks"),
            "performance": _candidate_schema_fixture("performance"),
            "dispatch_measurement": _candidate_schema_fixture(
                "developmentDispatchEstimate"
            ),
        }


class _InstrumentedProductionEvaluator(ProductionCandidateEvaluator):
    def __init__(
        self,
        *,
        evidence_store: ContentAddressedEvidenceStore,
        instrumentation: dict[str, object],
    ) -> None:
        self.degradation_policy = {"policy_sha256": DEGRADATION_POLICY}
        self.metric_policy = {}
        self.baseline_ablation_contract = {
            "non_ash_selector": _selector_contract()
        }
        self.baseline_ablation_contract_sha256 = _sha256("baseline-contract")
        self.writer = object()
        self.analytic_fixtures = object()
        self.evidence_store = evidence_store
        self.evaluation_evidence_provider = _InstrumentedEvidenceProvider(
            instrumentation
        )
        self._development_control_selection_cache = None
        self.instrumentation = instrumentation

    @staticmethod
    def _capture(view: object) -> _InstrumentedCaptured:
        return _InstrumentedCaptured(str(view.split))

    @staticmethod
    def _prepare_cases(
        captured: _InstrumentedCaptured,
        degradation_cache: object,
    ) -> tuple[Mapping[str, object], ...]:
        del captured, degradation_cache
        return ({"instrumented": True},)

    def _aggregate_identity_context(
        self,
        *,
        adapter: CandidateAdapter,
        captured: _InstrumentedCaptured,
    ) -> Mapping[str, object]:
        del adapter, captured
        return _aggregate_context()

    @staticmethod
    def _native_p00_identity(
        adapter: CandidateAdapter,
    ) -> Mapping[str, object]:
        del adapter
        return _p00_identity()

    def _exhaustive_fixed_and_conventional(
        self,
        *,
        adapter: CandidateAdapter,
        prepared: object,
        split: str,
        bank: str,
        operator_cache: _InstrumentedOperatorCache,
    ) -> tuple[
        Mapping[int, ControlAggregateEvidence],
        Mapping[str, ControlAggregateEvidence],
        str,
    ]:
        del adapter, prepared
        assert split == operator_cache.split
        assert bank == operator_cache.bank
        return (
            {
                descriptor_id: operator_cache.fixed(descriptor_id)
                for descriptor_id in FIXED_DESCRIPTOR_IDS
            },
            {
                algorithm_id: operator_cache.conventional(algorithm_id)
                for algorithm_id in CONVENTIONAL_ALGORITHM_IDS
            },
            operator_cache.manifest_sha256,
        )

    def _comparison_identities(
        self,
        *,
        adapter: CandidateAdapter,
        captured: _InstrumentedCaptured,
        bundle: object,
        artifacts: Mapping[str, Mapping[str, object]],
    ) -> Mapping[str, object]:
        del adapter, captured, artifacts
        return _integration_comparison_identities(bundle)

    def _ensure_natural_check_controls(
        self,
        *,
        adapter: CandidateAdapter,
        prepared: object,
        selection_bundle: object,
        operator_cache: _InstrumentedOperatorCache,
    ) -> None:
        del adapter, prepared
        for descriptor_id in FIXED_DESCRIPTOR_IDS:
            operator_cache.fixed(descriptor_id)
        self.instrumentation["natural_check_calls"].append(
            selection_bundle.candidate_vector_sha256
        )

    @staticmethod
    def _native_records(
        adapter: CandidateAdapter,
        provider_name: str,
    ) -> tuple[Mapping[str, object], ...]:
        del adapter, provider_name
        return ()

    @staticmethod
    def _runtime_invocations(**kwargs: object) -> list[Mapping[str, object]]:
        invocation = copy.deepcopy(
            _candidate_schema_fixture("runtimeInvocation")
        )
        invocation["adapter_configuration_sha256"] = kwargs[
            "adapter"
        ].configuration_sha256
        return [invocation]

    @staticmethod
    def _control_runtime_invocations(
        records: object,
    ) -> list[Mapping[str, object]]:
        del records
        return [
            _candidate_schema_fixture("controlRuntimeInvocation")
        ]

    @staticmethod
    def _runtime_summary(
        adapter: CandidateAdapter,
        records: object,
    ) -> Mapping[str, object]:
        del records
        summary = copy.deepcopy(
            _CANDIDATE_EVALUATION_SCHEMA["properties"]["runtime_summary"]
        )
        properties = summary["properties"]
        value = {}
        for field in summary["required"]:
            field_schema = properties[field]
            if "const" in field_schema:
                value[field] = field_schema["const"]
            elif "boolean" in field_schema.get("type", []):
                value[field] = True
            elif field_schema.get("type") == "boolean":
                value[field] = True
            elif field_schema.get("type") == "integer":
                value[field] = int(field_schema.get("minimum", 0))
            else:
                value[field] = "integration"
        value["configuration_id"] = adapter.configuration["configuration_id"]
        return value


class _SplitAttempt:
    def __init__(self, split: str) -> None:
        self.split = split


def _integration_adapter(vector: Mapping[str, object]) -> CandidateAdapter:
    vector_sha256 = canonical_sha256(vector)
    configuration = copy.deepcopy(
        _candidate_schema_fixture("productionRuntime")
    )
    configuration.update(
        {
            "configuration_id": f"integration-{vector_sha256[:12]}",
            "serialized_candidate_vector_sha256": vector_sha256,
            "candidate_vector": dict(vector),
            "shared_bank_configuration_sha256": BANK,
        }
    )
    return CandidateAdapter(
        candidate_id="development-selection-cache-integration",
        configuration=configuration,
        configuration_sha256=canonical_sha256(configuration),
        callable=lambda frame, context: (frame, context),
    )


def _selection_dependency_hashes(
    artifacts: Mapping[str, Mapping[str, object]],
    store: ContentAddressedEvidenceStore,
) -> tuple[str, ...]:
    values = []
    for name in ("best_fixed", "conventional"):
        for result in artifacts[name]["document"]["development_results"]:
            values.extend(
                (
                    result["objective_summary_sha256"],
                    result["output_manifest_sha256"],
                )
            )
    non_ash = artifacts["non_ash_selector"]["document"]
    ledger = store.reopen(non_ash["development_attempt_ledger_sha256"])
    for record in ledger["records"]:
        values.extend(
            (
                record["objective_summary_sha256"],
                record["output_manifest_sha256"],
            )
        )
    return tuple(values)


def test_cold_publication_equals_independent_reopen_and_is_not_candidate_bound(
    tmp_path: Path,
) -> None:
    cold = _cache(tmp_path)
    identity = _identity(cold)
    artifacts = _selection_artifacts()
    origin = _development_selection_cache_origin(
        identity=identity,
        artifacts=artifacts,
    )

    assert cold.reopen(identity) is None
    assert cold.publish(identity=identity, origin=origin) == origin
    cold.close()

    independent = _cache(tmp_path)
    try:
        reopened = independent.reopen(identity)
        assert reopened == origin
        assert reopened["artifacts"] == artifacts
        assert reopened["validation_evidence_imported"] is False
        assert reopened["holdout_evidence_imported"] is False
        assert reopened["candidate_bound_outputs_cached"] is False
        serialized = canonical_json_bytes(reopened)
        assert b"candidate_vector_sha256" not in serialized
        assert b"adapter_configuration_sha256" not in serialized
        assert b"corpus_asset_results" not in serialized
    finally:
        independent.close()


def test_threshold_neighbors_share_identity_but_bound_identity_changes_miss(
    tmp_path: Path,
) -> None:
    cache = _cache(tmp_path)
    try:
        first = _identity(cache)
        threshold_only_neighbor = _identity(cache)
        assert threshold_only_neighbor == first
        assert "selection_search_contract" in first
        assert set(first["implementation_closure"]) == {
            "production_evaluator_source_sha256",
            "storage_implementation_sha256",
            "cache_schema_sha256",
        }
        origin = _development_selection_cache_origin(
            identity=first,
            artifacts=_selection_artifacts(),
        )
        cache.publish(identity=first, origin=origin)

        changed_identities = (
            _identity(cache, bank="3" * 64),
            _identity(cache, sample_lock="changed-sample-lock"),
            _identity(cache, first_input="changed-input"),
            _identity(
                cache,
                storage_implementation_sha256=_sha256(
                    "changed-storage-implementation"
                ),
            ),
        )
        assert all(changed != first for changed in changed_identities)
        assert all(cache.reopen(changed) is None for changed in changed_identities)

        changed_search = copy.deepcopy(first)
        changed_search["selection_search_contract"]["fixed_tie_break"] = "changed"
        with pytest.raises(
            ProductionEvaluatorError,
            match="search identity differs",
        ):
            _validate_development_selection_cache_origin(
                origin,
                identity=changed_search,
            )
    finally:
        cache.close()


def test_atomic_publication_rejects_different_origin_for_existing_identity(
    tmp_path: Path,
) -> None:
    cache = _cache(tmp_path)
    try:
        identity = _identity(cache)
        origin = _development_selection_cache_origin(
            identity=identity,
            artifacts=_selection_artifacts(),
        )
        cache.publish(identity=identity, origin=origin)

        changed = copy.deepcopy(origin)
        fixed = changed["artifacts"]["best_fixed"]
        fixed["document"]["development_results"][0][
            "engine_raw_corpus_mean_tuple"
        ][0] = -1.0
        fixed["sha256"] = canonical_sha256(fixed["document"])
        unhashed = dict(changed)
        unhashed.pop("origin_manifest_sha256")
        changed["origin_manifest_sha256"] = canonical_sha256(unhashed)
        with pytest.raises(
            CalibrationError,
            match="cache origin changed",
        ):
            cache.publish(identity=identity, origin=changed)
        assert cache.reopen(identity) == origin
    finally:
        cache.close()


def test_expected_corrupt_origin_fails_closed(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    identity = _identity(cache)
    origin = _development_selection_cache_origin(
        identity=identity,
        artifacts=_selection_artifacts(),
    )
    cache.publish(identity=identity, origin=origin)
    cache.close()

    artifact = (
        tmp_path
        / _DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY
        / f"{canonical_sha256(identity)}.json"
    )
    artifact.write_bytes(b"{not-json")
    independent = _cache(tmp_path)
    try:
        with pytest.raises(
            CalibrationBindingError,
            match="expected development control-selection cache artifact is corrupt",
        ):
            independent.reopen(identity)
    finally:
        independent.close()


def test_cache_directory_substitution_fails_closed(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    identity = _identity(cache)
    root = tmp_path / _DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY
    root.rename(tmp_path / "moved-cache")
    root.mkdir()
    try:
        with pytest.raises(
            CalibrationBindingError,
            match="cache directory is invalid",
        ):
            cache.reopen(identity)
    finally:
        cache.close()


def test_origin_schema_forbids_validation_or_holdout_imports(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    try:
        identity = _identity(cache)
        origin = _development_selection_cache_origin(
            identity=identity,
            artifacts=_selection_artifacts(),
        )
        for field in ("validation_evidence_imported", "holdout_evidence_imported"):
            changed = copy.deepcopy(origin)
            changed[field] = True
            unhashed = dict(changed)
            unhashed.pop("origin_manifest_sha256")
            changed["origin_manifest_sha256"] = canonical_sha256(unhashed)
            with pytest.raises(
                ProductionEvaluatorError,
                match="violates its schema",
            ):
                _validate_development_selection_cache_origin(
                    changed,
                    identity=identity,
                )
    finally:
        cache.close()


def test_miss_provenance_accepts_reopened_native_evidence() -> None:
    provenance = _development_selection_cache_provenance(
        status="miss",
        disabled_reason=None,
        identity_sha256=_sha256("selection-cache-identity"),
        origin_manifest_sha256=_sha256("selection-cache-origin"),
        selector_counts={
            "selector_search_invocation_count": 1,
            "selector_rule_aggregate_evaluation_count": 57,
            "selector_search_native_recombination_count": 0,
        },
    )

    assert provenance[
        "selector_search_native_recombination_count"
    ] == 0


def test_production_evaluator_cold_then_fresh_threshold_neighbor_cache_hit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    instrumentation: dict[str, object] = {
        "operator_instances": [],
        "aggregate_commits": 0,
        "provider_calls": [],
        "natural_check_calls": [],
        "selected_bundles": [],
        "fresh_path_calls": [],
    }

    def operator_factory(**kwargs: object) -> _InstrumentedOperatorCache:
        return _InstrumentedOperatorCache(
            instrumentation=instrumentation,
            **kwargs,
        )

    real_search = evaluator_module.search_non_ash_development
    search_calls = []

    def counted_search(**kwargs: object) -> Mapping[str, object]:
        search_calls.append(kwargs["shared_bank_configuration_sha256"])
        return real_search(**kwargs)

    fresh_control_keys = (
        "full_ash",
        "state_only",
        "h07_direct_3_over_2",
        "current_production_ash",
    )

    def selected_evaluator_factory(**kwargs: object) -> object:
        selection_bundle = kwargs["selection_bundle"]

        class SelectedEvaluator:
            def __call__(
                self,
                adapter: CandidateAdapter,
                vector: Mapping[str, object],
                captured: object,
                degradation_cache: object,
            ) -> Mapping[str, object]:
                del vector, captured, degradation_cache
                instrumentation["selected_bundles"].append(selection_bundle)
                for domain in ("natural", "analytic"):
                    for key in fresh_control_keys:
                        request = selection_bundle.request(key)
                        instrumentation["fresh_path_calls"].append(
                            {
                                "domain": domain,
                                "control_key": key,
                                "candidate_vector_sha256": selection_bundle.candidate_vector_sha256,
                                "configuration_sha256": request[
                                    "configuration_sha256"
                                ],
                                "request_sha256": request["request_sha256"],
                            }
                        )
                return {
                    "corpus_results": _integration_corpus_results(
                        selection_bundle
                    ),
                    "analytic_fixture_results": {
                        "results": _integration_analytic_results(
                            selection_bundle
                        )
                    },
                }

        return SelectedEvaluator()

    monkeypatch.setattr(
        evaluator_module,
        "_NativeSelectionOutputCache",
        operator_factory,
    )
    monkeypatch.setattr(
        evaluator_module,
        "search_non_ash_development",
        counted_search,
    )
    monkeypatch.setattr(
        evaluator_module,
        "ProductionCalibrationEvaluator",
        selected_evaluator_factory,
    )

    cache_parent = tmp_path / "runs"
    cache_parent.mkdir()
    cache_root = cache_parent / _DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY
    evidence_root = tmp_path / "evidence"
    cold_vector = {
        **{f"integration_coordinate_{ordinal:02d}": 0 for ordinal in range(41)},
        "edge_present_low_unorm15": 4096,
    }
    threshold_neighbor = {
        **cold_vector,
        "edge_present_low_unorm15": 4097,
    }

    cold_store = ContentAddressedEvidenceStore(evidence_root)
    cold_cache = _CountingSelectionCache(
        _DevelopmentControlSelectionCache(cache_root)
    )
    cold_evaluator = _InstrumentedProductionEvaluator(
        evidence_store=cold_store,
        instrumentation=instrumentation,
    )
    cold_evaluator.configure_development_control_selection_cache(cold_cache)
    cold_result = cold_evaluator(
        _integration_adapter(cold_vector),
        cold_vector,
        _SplitAttempt("development"),
        object(),
        None,
    )
    cold_cache.close()

    assert cold_cache.reopen_count == 1
    assert cold_cache.publish_count == 1
    assert search_calls == [BANK]
    cold_operator = instrumentation["operator_instances"][0]
    assert cold_operator.selector_native_recombinations > 0
    cold_counts = cold_operator.development_selector_search_counts()
    cold_provenance = cold_result[
        "development_control_selection_cache"
    ]
    assert cold_result["schema_version"] == "1.1.0"
    assert cold_provenance == {
        "status": "miss",
        "disabled_reason": None,
        "identity_sha256": cold_provenance["identity_sha256"],
        "origin_manifest_sha256": cold_provenance[
            "origin_manifest_sha256"
        ],
        **cold_counts,
    }
    assert len(cold_provenance["identity_sha256"]) == 64
    assert len(cold_provenance["origin_manifest_sha256"]) == 64
    assert cold_counts["selector_search_invocation_count"] == 1
    assert cold_counts[
        "selector_rule_aggregate_evaluation_count"
    ] > 0
    assert cold_counts[
        "selector_search_native_recombination_count"
    ] == cold_operator.selector_native_recombinations

    reopened_store = ContentAddressedEvidenceStore(evidence_root)
    reopened_cache = _CountingSelectionCache(
        _DevelopmentControlSelectionCache(cache_root)
    )
    reopened_evaluator = _InstrumentedProductionEvaluator(
        evidence_store=reopened_store,
        instrumentation=instrumentation,
    )
    reopened_evaluator.configure_development_control_selection_cache(
        reopened_cache
    )
    reopened_result = reopened_evaluator(
        _integration_adapter(threshold_neighbor),
        threshold_neighbor,
        _SplitAttempt("development"),
        object(),
        None,
    )
    reopened_cache.close()

    assert reopened_cache.reopen_count == 1
    assert reopened_cache.publish_count == 0
    assert search_calls == [BANK]
    reopened_operator = instrumentation["operator_instances"][1]
    assert reopened_operator.selector_native_recombinations == 0
    reopened_counts = reopened_operator.development_selector_search_counts()
    reopened_provenance = reopened_result[
        "development_control_selection_cache"
    ]
    assert reopened_result["schema_version"] == "1.1.0"
    assert reopened_provenance == {
        "status": "hit",
        "disabled_reason": None,
        "identity_sha256": cold_provenance["identity_sha256"],
        "origin_manifest_sha256": cold_provenance[
            "origin_manifest_sha256"
        ],
        **reopened_counts,
    }
    assert reopened_counts == {
        "selector_search_invocation_count": 0,
        "selector_rule_aggregate_evaluation_count": 0,
        "selector_search_native_recombination_count": 0,
    }

    candidate_schema = (
        evaluator_module.SCHEMAS_ROOT
        / "candidate-evaluation-v1.schema.json"
    )
    miss_with_reopened_native_evidence = copy.deepcopy(cold_result)
    miss_with_reopened_native_evidence[
        "development_control_selection_cache"
    ]["selector_search_native_recombination_count"] = 0
    evaluator_module.validate_schema(
        miss_with_reopened_native_evidence,
        candidate_schema,
    )

    capability_absent = copy.deepcopy(cold_result)
    capability_absent_provenance = capability_absent[
        "development_control_selection_cache"
    ]
    capability_absent_provenance.update(
        {
            "status": "disabled",
            "disabled_reason": "capability_absent",
            "identity_sha256": None,
            "origin_manifest_sha256": None,
            "selector_search_native_recombination_count": 0,
        }
    )
    evaluator_module.validate_schema(capability_absent, candidate_schema)

    runner_selection_supplied = copy.deepcopy(reopened_result)
    runner_selection_provenance = runner_selection_supplied[
        "development_control_selection_cache"
    ]
    runner_selection_provenance.update(
        {
            "status": "disabled",
            "disabled_reason": "runner_selection_supplied",
            "identity_sha256": None,
            "origin_manifest_sha256": None,
        }
    )
    evaluator_module.validate_schema(
        runner_selection_supplied,
        candidate_schema,
    )

    invalid_miss = copy.deepcopy(cold_result)
    invalid_miss["development_control_selection_cache"][
        "selector_search_invocation_count"
    ] = 0
    with pytest.raises(ValueError):
        evaluator_module.validate_schema(invalid_miss, candidate_schema)

    invalid_hit = copy.deepcopy(reopened_result)
    invalid_hit["development_control_selection_cache"][
        "selector_rule_aggregate_evaluation_count"
    ] = 1
    with pytest.raises(ValueError):
        evaluator_module.validate_schema(invalid_hit, candidate_schema)

    invalid_development_reason = copy.deepcopy(reopened_result)
    invalid_development_reason["development_control_selection_cache"].update(
        {
            "status": "disabled",
            "disabled_reason": "split_not_development",
            "identity_sha256": None,
            "origin_manifest_sha256": None,
        }
    )
    with pytest.raises(ValueError):
        evaluator_module.validate_schema(
            invalid_development_reason,
            candidate_schema,
        )

    cold_artifacts = cold_result["control_selection_artifacts"]
    reopened_artifacts = reopened_result["control_selection_artifacts"]
    assert reopened_artifacts == cold_artifacts
    for embedded in cold_artifacts.values():
        assert cold_store.reopen(embedded["sha256"]) == embedded["document"]
    cold_non_ash = cold_artifacts["non_ash_selector"]["document"]
    reopened_non_ash = reopened_artifacts["non_ash_selector"]["document"]
    for field in (
        "development_terminal_rule_sha256",
        "development_terminal_rule_configuration",
        "development_attempt_ledger_sha256",
        "development_objective_summary_sha256",
        "cached_16_operator_output_manifest_sha256",
    ):
        assert reopened_non_ash[field] == cold_non_ash[field]
    cold_dependency_hashes = _selection_dependency_hashes(
        cold_artifacts,
        cold_store,
    )
    reopened_dependency_hashes = _selection_dependency_hashes(
        reopened_artifacts,
        reopened_store,
    )
    assert reopened_dependency_hashes == cold_dependency_hashes
    for dependency_sha256 in dict.fromkeys(cold_dependency_hashes):
        cold_store.reopen(dependency_sha256)
        reopened_store.reopen(dependency_sha256)

    cold_bundle, reopened_bundle = instrumentation["selected_bundles"]
    assert cold_bundle.candidate_vector_sha256 != (
        reopened_bundle.candidate_vector_sha256
    )
    assert cold_bundle.adapter_configuration_sha256 != (
        reopened_bundle.adapter_configuration_sha256
    )
    assert cold_bundle.bundle_sha256 != reopened_bundle.bundle_sha256
    for key in ("full_ash", "state_only", "h07_direct_3_over_2"):
        assert cold_bundle.request(key)["configuration_sha256"] != (
            reopened_bundle.request(key)["configuration_sha256"]
        )
    assert cold_bundle.request("current_production_ash")[
        "configuration_sha256"
    ] == reopened_bundle.request("current_production_ash")[
        "configuration_sha256"
    ]

    fresh_path_calls = instrumentation["fresh_path_calls"]
    for bundle in (cold_bundle, reopened_bundle):
        for domain in ("natural", "analytic"):
            assert {
                record["control_key"]
                for record in fresh_path_calls
                if record["domain"] == domain
                and record["candidate_vector_sha256"]
                == bundle.candidate_vector_sha256
            } == set(fresh_control_keys)
    assert instrumentation["natural_check_calls"] == [
        cold_bundle.candidate_vector_sha256,
        reopened_bundle.candidate_vector_sha256,
    ]
    assert len(instrumentation["provider_calls"]) == 2

    validation_cache = _CountingSelectionCache(
        _DevelopmentControlSelectionCache(cache_root)
    )
    validation_evaluator = _InstrumentedProductionEvaluator(
        evidence_store=ContentAddressedEvidenceStore(evidence_root),
        instrumentation=instrumentation,
    )
    validation_evaluator.configure_development_control_selection_cache(
        validation_cache
    )
    with pytest.raises(
        ProductionEvaluatorError,
        match="validation requires runner-authorized development controls",
    ):
        validation_evaluator(
            _integration_adapter(threshold_neighbor),
            threshold_neighbor,
            _SplitAttempt("validation"),
            object(),
            None,
        )
    validation_cache.close()
    assert validation_cache.reopen_count == 0
    assert validation_cache.publish_count == 0
    assert search_calls == [BANK]
