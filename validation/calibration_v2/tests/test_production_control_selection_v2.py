from __future__ import annotations

from contextlib import ExitStack
from copy import deepcopy
from dataclasses import replace
import hashlib
import json
from pathlib import Path
from typing import Mapping
from unittest.mock import patch

import numpy as np
import pytest

import validation.calibration_v2.control_authorization_v2 as authorization
import validation.calibration_v2.control_evidence_publisher_v2 as publisher_module
import validation.calibration_v2.tests.test_non_ash_selector_artifacts_v2 as non_ash_fixture_module
from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
    ClosureFileBindingV2,
    ClosureFileSnapshotV2,
)
from validation.calibration_v2.baseline_ablation_budget_v2 import (
    COORDINATE_ORDER_V2,
    EXPECTED_OVERLAY_FILE_SHA256,
    EXPECTED_OVERLAY_SCHEMA_SHA256,
    EXPECTED_OVERLAY_SELF_SHA256,
    INITIAL_VALUE_V2,
    MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
    MAXIMUM_SWEEPS_V2,
    MAXIMUM_VALIDATION_CANDIDATES_V2,
    SELECTOR_ID_V2,
    VALUES_V2,
    NonAshSelectorAuthorityIdentityV2,
    NonAshSelectorExecutionProfileV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    ATTEMPT_LEDGER_KIND,
    CONVENTIONAL_ALGORITHM_IDS,
    CONVENTIONAL_SELECTION_KIND,
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    FIXED_DESCRIPTOR_IDS,
    FIXED_SELECTION_KIND,
    NEIGHBOR_MANIFEST_KIND,
    OBJECTIVE_SUMMARY_KIND,
    OUTPUT_MANIFEST_KIND,
    SELECTION_KIND,
    CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
    ControlAuthorizationVerifierV2,
    ControlAuthorizationV2Error,
    ControlExecutionSemanticContextV2,
    TypedArtifactBindingV2,
    canonical_json_bytes_v2,
    canonical_json_file_bytes_v2,
    conventional_control_configuration_sha256_v2,
    dependency_set_sha256_v2,
    fixed_control_configuration_sha256_v2,
    finalize_artifact_sha256_v2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.control_evidence_publisher_v2 import (
    RAW_CONTROL_AGGREGATE_PUBLICATION_KIND_V2,
    RawControlAuthorizationArtifactPublisherV2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    CALIBRATION_PLAN_V2_FILE_SHA256,
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorEvaluationV2,
    canonical_rule_values_v2,
    rule_mapping_v2,
    rule_sha256_v2,
    run_non_ash_development_search_v2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    EVALUATION_EVIDENCE_KIND,
    canonical_artifact_bytes_v2,
    canonical_evaluation_evidence_bytes_v2,
)
from validation.calibration_v2.production_control_selection_v2 import (
    NonAshControlSelectionInputV2,
    ProductionControlSelectionRequestV2,
    ProductionControlSelectionV2,
    ProductionControlSelectionV2Error,
)
from validation.calibration_v2.production_evaluator import (
    ControlExecutionProducerIdentityV2,
    RawControlMeasurementPublicationV2,
    canonical_control_measurement_frame_bytes_v2,
    conventional_control_request,
    decode_control_measurement_frame_bytes_v2,
    fixed_control_request,
    non_ash_control_request_for_selector_v2,
)
from validation.calibration_v2.tests.test_control_evidence_publisher_v2 import (
    DEGRADATION_POLICY,
    _prepared_cases,
)
from validation.quality.src.mirmir_quality.arrays import (
    PlanarFrame,
    frame_sha256,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
)


RUN_ID = "production-control-selection-v2-test"
BANK = "1" * 64
DEGRADATION = "2" * 64
DEVELOPMENT_MATRIX = "3" * 64
VALIDATION_MATRIX = "4" * 64
EXTRA_KIND = "test_extra_dependency_v2"


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _binding(
    *,
    kind: str,
    path: str,
    payload: bytes,
    schema_sha256: str | None = None,
) -> TypedArtifactBindingV2:
    return TypedArtifactBindingV2(
        artifact_kind=kind,
        schema_sha256=(
            schema_sha256
            if schema_sha256 is not None
            else schema_sha256_for_kind_v2(kind)
        ),
        path=path,
        sha256=hashlib.sha256(payload).hexdigest(),
        size_bytes=len(payload),
    )


def _snapshot(
    entries: tuple[tuple[TypedArtifactBindingV2, bytes], ...],
) -> AuthenticatedClosureSnapshotV2:
    return AuthenticatedClosureSnapshotV2(
        tuple(
            ClosureFileSnapshotV2(
                ClosureFileBindingV2(
                    binding.path,
                    binding.sha256,
                    binding.size_bytes,
                ),
                payload,
            )
            for binding, payload in entries
        )
    )


def _producer_identity(
    configuration_sha256: str | None = None,
) -> ControlExecutionProducerIdentityV2:
    physical_items = [[f"field_{index:02d}", index] for index in range(48)]
    physical_bytes = canonical_json_bytes_v2(physical_items)
    if configuration_sha256 is None:
        configuration_sha256 = _digest("adapter-configuration")
    adapter_identity = {
        "adapter_configuration_sha256": configuration_sha256,
        "native_source_manifest_sha256": _digest("native-source"),
        "native_executable_sha256": _digest("native-executable"),
        "native_implementation_source_sha256": _digest(
            "native-implementation"
        ),
    }
    return ControlExecutionProducerIdentityV2(
        physical_candidate_items_bytes=physical_bytes,
        candidate_vector_sha256=hashlib.sha256(
            canonical_json_bytes_v2([item[1] for item in physical_items])
        ).hexdigest(),
        adapter_configuration_sha256=configuration_sha256,
        authenticated_adapter_identity_bytes=canonical_json_bytes_v2(
            adapter_identity
        ),
    )


def _profile() -> NonAshSelectorExecutionProfileV2:
    return NonAshSelectorExecutionProfileV2(
        selector_id=SELECTOR_ID_V2,
        coordinate_order=COORDINATE_ORDER_V2,
        values=VALUES_V2,
        initial_value=INITIAL_VALUE_V2,
        maximum_sweeps=MAXIMUM_SWEEPS_V2,
        maximum_development_attempts=MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
        maximum_validation_candidates=MAXIMUM_VALIDATION_CANDIDATES_V2,
        authority_identity=NonAshSelectorAuthorityIdentityV2(
            overlay_file_sha256=EXPECTED_OVERLAY_FILE_SHA256,
            overlay_self_sha256=EXPECTED_OVERLAY_SELF_SHA256,
            overlay_schema_sha256=EXPECTED_OVERLAY_SCHEMA_SHA256,
        ),
    )


class _Fixture:
    def __init__(self) -> None:
        self.publisher = RawControlAuthorizationArtifactPublisherV2(
            run_id=RUN_ID,
            control_execution_producer_identity=_producer_identity(),
        )
        self.profile = _profile()
        self.evaluation_scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=DEGRADATION,
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256=_digest(
                "cached-16-manifest"
            ),
        )
        self.development_publications = self._publications(
            split="development",
            matrix_sha256=DEVELOPMENT_MATRIX,
        )
        self.validation_publications = self._publications(
            split="validation",
            matrix_sha256=VALIDATION_MATRIX,
        )

    @staticmethod
    def _configuration(family: str, stable_id: object) -> str:
        if family == "best_fixed":
            return fixed_control_configuration_sha256_v2(stable_id, BANK)
        if family == "conventional":
            return conventional_control_configuration_sha256_v2(
                stable_id,
                BANK,
            )
        return _digest(f"non-ash-configuration:{stable_id}")

    def _publication(
        self,
        *,
        split: str,
        family: str,
        stable_id: object,
        matrix_sha256: str,
        score: float,
    ) -> Mapping[str, object]:
        identity = f"{split}:{family}:{stable_id}"
        configuration = self._configuration(family, stable_id)
        summary = {
            "schema_version": "2.0.0",
            "artifact_kind": OBJECTIVE_SUMMARY_KIND,
            "run_id": RUN_ID,
            "split": split,
            "control_family": family,
            "stable_id": stable_id,
            "source_profile_matrix_sha256": matrix_sha256,
            "metric_order": [
                "y_psnr_db",
                "y_ms_ssim",
                "y_ssim",
                "cb_psnr_db",
                "cr_psnr_db",
            ],
            "comparison_domain": "engine_raw",
            "control_configuration_sha256": configuration,
            "means": [score, 4.0, 3.0, 2.0, 1.0],
        }
        summary_payload = canonical_json_file_bytes_v2(summary)
        summary_binding = _binding(
            kind=OBJECTIVE_SUMMARY_KIND,
            path=f"raw/{_digest(identity + ':summary')}.json",
            payload=summary_payload,
        )
        manifest = {
            "schema_version": "2.0.0",
            "artifact_kind": OUTPUT_MANIFEST_KIND,
            "run_id": RUN_ID,
            "split": split,
            "control_family": family,
            "stable_id": stable_id,
            "identity": identity,
        }
        manifest_payload = canonical_json_file_bytes_v2(manifest)
        manifest_binding = _binding(
            kind=OUTPUT_MANIFEST_KIND,
            path=f"raw/{_digest(identity + ':manifest')}.json",
            payload=manifest_payload,
        )
        dependencies = tuple(
            sorted(
                (summary_binding, manifest_binding),
                key=lambda binding: binding.path,
            )
        )
        snapshot = _snapshot(
            tuple(
                (binding, summary_payload if binding == summary_binding else manifest_payload)
                for binding in dependencies
            )
        )
        publication = {
            "schema_version": "2.0.0",
            "artifact_kind": RAW_CONTROL_AGGREGATE_PUBLICATION_KIND_V2,
            "run_id": RUN_ID,
            "split": split,
            "control_family": family,
            "stable_id": stable_id,
            "source_profile_matrix_sha256": matrix_sha256,
            "comparison_domains": ["engine_raw"],
            "objective_summary": summary_binding.as_document(),
            "output_manifest": manifest_binding.as_document(),
            "dependency_bindings": [
                binding.as_document() for binding in dependencies
            ],
            "dependency_set_sha256": dependency_set_sha256_v2(dependencies),
            "closure_sha256": snapshot.closure_sha256,
        }
        exact = json.loads(canonical_json_bytes_v2(publication))
        self.publisher._published[snapshot.closure_sha256] = (
            publisher_module._PublishedClosureV2(
                publication=exact,
                snapshot=snapshot,
                dependencies=dependencies,
            )
        )
        return exact

    def _publications(
        self,
        *,
        split: str,
        matrix_sha256: str,
    ) -> Mapping[str, tuple[Mapping[str, object], ...]]:
        fixed = tuple(
            self._publication(
                split=split,
                family="best_fixed",
                stable_id=identifier,
                matrix_sha256=matrix_sha256,
                score=100.0 - identifier,
            )
            for identifier in FIXED_DESCRIPTOR_IDS
        )
        conventional = tuple(
            self._publication(
                split=split,
                family="conventional",
                stable_id=identifier,
                matrix_sha256=matrix_sha256,
                score=90.0 + ordinal,
            )
            for ordinal, identifier in enumerate(CONVENTIONAL_ALGORITHM_IDS)
        )
        non_ash = (
            self._publication(
                split=split,
                family="non_ash_selector",
                stable_id=_digest(f"{split}:selected-rule"),
                matrix_sha256=matrix_sha256,
                score=88.0,
            ),
        )
        return {
            "best_fixed": fixed,
            "conventional": conventional,
            "non_ash_selector": non_ash,
        }

    def _non_ash_input(
        self,
        *,
        split: str,
        include_extra: bool = False,
    ) -> NonAshControlSelectionInputV2:
        stage = (
            "development_provisional"
            if split == "development"
            else "validation_final"
        )
        documents = [
            (
                "selection",
                SELECTION_KIND,
                {
                    "artifact_kind": SELECTION_KIND,
                    "selection_stage": stage,
                    "split": split,
                },
            ),
            (
                "development-ledger",
                ATTEMPT_LEDGER_KIND,
                {"artifact_kind": ATTEMPT_LEDGER_KIND, "split": "development"},
            ),
        ]
        if split == "validation":
            documents.extend(
                (
                    (
                        "development-selection",
                        SELECTION_KIND,
                        {
                            "artifact_kind": SELECTION_KIND,
                            "selection_stage": "development_provisional",
                            "split": "development",
                        },
                    ),
                    (
                        "validation-neighbors",
                        NEIGHBOR_MANIFEST_KIND,
                        {
                            "artifact_kind": NEIGHBOR_MANIFEST_KIND,
                            "target_split": "validation",
                        },
                    ),
                )
            )
        entries = []
        bindings = {}
        for name, kind, document in documents:
            payload = canonical_json_file_bytes_v2(document)
            binding = _binding(
                kind=kind,
                path=f"non-ash/{split}/{name}-{_digest(name + split)}.json",
                payload=payload,
            )
            bindings[name] = binding
            entries.append((binding, payload))
        if include_extra:
            payload = b"unreferenced-extra-dependency\n"
            extra = _binding(
                kind=EXTRA_KIND,
                schema_sha256=_digest("extra-schema"),
                path=f"non-ash/{split}/extra.bin",
                payload=payload,
            )
            entries.append((extra, payload))
        entries.sort(key=lambda item: item[0].path)
        predecessor_bindings = {
            "development_ledger": bindings["development-ledger"]
        }
        if split == "validation":
            predecessor_bindings.update(
                {
                    "development_selection": bindings[
                        "development-selection"
                    ],
                    "validation_neighbor_manifest": bindings[
                        "validation-neighbors"
                    ],
                }
            )
        return NonAshControlSelectionInputV2(
            selection_binding=bindings["selection"],
            predecessor_bindings=predecessor_bindings,
            dependency_bindings=tuple(binding for binding, _ in entries),
            evidence_snapshot=_snapshot(tuple(entries)),
        )

    @staticmethod
    def _admission():
        payload = canonical_json_file_bytes_v2(
            {
                "artifact_kind": (
                    "p06_validation_candidate_development_evidence_v2"
                ),
                "admission": "test",
            }
        )
        binding = _binding(
            kind="p06_validation_candidate_development_evidence_v2",
            path="admission/validation.json",
            payload=payload,
        )
        return binding, _snapshot(((binding, payload),))

    def request(
        self,
        *,
        split: str,
        include_extra: bool = False,
    ) -> ProductionControlSelectionRequestV2:
        current = (
            self.development_publications
            if split == "development"
            else self.validation_publications
        )
        if split == "development":
            return ProductionControlSelectionRequestV2(
                run_id=RUN_ID,
                split="development",
                shared_bank_configuration_sha256=BANK,
                degradation_policy_sha256=DEGRADATION,
                source_profile_matrix_sha256=DEVELOPMENT_MATRIX,
                best_fixed_publications=current["best_fixed"],
                conventional_publications=current["conventional"],
                non_ash_selector_publications=current["non_ash_selector"],
                non_ash_profile=self.profile,
                non_ash_evaluation_scope=self.evaluation_scope,
                non_ash_selection=self._non_ash_input(
                    split="development",
                    include_extra=include_extra,
                ),
            )
        admission, admission_snapshot = self._admission()
        return ProductionControlSelectionRequestV2(
            run_id=RUN_ID,
            split="validation",
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=DEGRADATION,
            source_profile_matrix_sha256=VALIDATION_MATRIX,
            best_fixed_publications=current["best_fixed"],
            conventional_publications=current["conventional"],
            non_ash_selector_publications=current["non_ash_selector"],
            non_ash_profile=self.profile,
            non_ash_evaluation_scope=self.evaluation_scope,
            non_ash_selection=self._non_ash_input(
                split="validation",
                include_extra=include_extra,
            ),
            development_source_profile_matrix_sha256=DEVELOPMENT_MATRIX,
            development_best_fixed_publications=(
                self.development_publications["best_fixed"]
            ),
            development_conventional_publications=(
                self.development_publications["conventional"]
            ),
            development_non_ash_selector_publications=(
                self.development_publications["non_ash_selector"]
            ),
            validation_admission=admission,
            validation_admission_snapshot=admission_snapshot,
            validation_admission_semantic_verifier=(
                lambda _binding, document: document
            ),
        )


def _patched_verifier(
    verifier: ControlAuthorizationVerifierV2,
):
    stack = ExitStack()

    def consume(*, resolver, **_kwargs):
        for binding in resolver.declared:
            if binding.artifact_kind != EXTRA_KIND:
                resolver.require_binding(binding)
        return {}

    stack.enter_context(
        patch.object(verifier, "_verify_ranked_control", side_effect=consume)
    )
    stack.enter_context(
        patch.object(verifier, "_verify_non_ash_control", side_effect=consume)
    )
    stack.enter_context(
        patch.object(
            verifier,
            "_verify_validation_admission",
            side_effect=consume,
        )
    )
    return stack


def _document(
    result,
    binding: TypedArtifactBindingV2,
) -> Mapping[str, object]:
    return json.loads(
        result.evidence_snapshot.payload(binding.closure_binding())
    )


class _RealProductionClosure:
    def __init__(self) -> None:
        self.bank = _digest("real-integration-bank")
        self.degradation = str(DEGRADATION_POLICY["policy_sha256"])
        self.configuration = {
            "shared_bank_configuration_sha256": self.bank
        }
        self.configuration_sha256 = hashlib.sha256(
            canonical_json_bytes_v2(self.configuration)
        ).hexdigest()
        self.producer_identity = _producer_identity(
            self.configuration_sha256
        )
        self.publisher = RawControlAuthorizationArtifactPublisherV2(
            run_id=RUN_ID,
            control_execution_producer_identity=self.producer_identity,
        )
        self.adapter = CandidateAdapter(
            candidate_id="real-control-selection-v2-integration",
            configuration=self.configuration,
            configuration_sha256=self.configuration_sha256,
            callable=lambda frame, context: frame,
        )
        self.prepared = _prepared_cases()
        self._identity_index = {
            (
                str(item.metadata["source_asset_id"]),
                str(item.profile["id"]),
            ): index
            for index, item in enumerate(self.prepared)
        }
        self.fixed_publications = tuple(
            self._publish(
                family="best_fixed",
                stable_id=identifier,
                request=fixed_control_request(identifier, self.bank),
            )
            for identifier in FIXED_DESCRIPTOR_IDS
        )
        self.conventional_publications = tuple(
            self._publish(
                family="conventional",
                stable_id=identifier,
                request=conventional_control_request(identifier, self.bank),
            )
            for identifier in CONVENTIONAL_ALGORITHM_IDS
        )
        self.matrix_sha256 = str(
            self.fixed_publications[0]["source_profile_matrix_sha256"]
        )
        self.non_ash_publications: list[Mapping[str, object]] = []
        self.non_ash_input, self.profile, self.evaluation_scope = (
            self._build_non_ash_input()
        )

    @staticmethod
    def _request_rank(request: Mapping[str, object]) -> int:
        parameters = request["parameters"]
        assert isinstance(parameters, dict)
        mode = request["control_mode"]
        if mode == "fixed_descriptor_uniform":
            return int(parameters["descriptor_id"])
        if mode == "conventional_uniform":
            return CONVENTIONAL_ALGORITHM_IDS.index(
                str(parameters["algorithm_id"])
            )
        if mode == "non_ash_selector_q15":
            rule = parameters["selected_rule_configuration"]
            assert isinstance(rule, dict)
            return sum(abs(int(value)) for value in rule.values())
        raise AssertionError("integration control request mode differs")

    @staticmethod
    def _output(
        target: PlanarFrame,
        *,
        rank: int,
        identity_index: int,
    ) -> PlanarFrame:
        amplitude = 0.0005 + rank * 0.00008
        y_index, x_index = np.indices(target.y.shape, dtype=np.float64)
        y_pattern = (
            (
                3.0 * x_index
                + 5.0 * y_index
                + float(identity_index)
            )
            % 13.0
            - 6.0
        ) / 6.0
        c_y, c_x = np.indices(target.cb.shape, dtype=np.float64)
        cb_pattern = (
            (2.0 * c_x + 3.0 * c_y + float(identity_index)) % 11.0
            - 5.0
        ) / 5.0
        cr_pattern = (
            (5.0 * c_x + 2.0 * c_y + float(identity_index)) % 9.0
            - 4.0
        ) / 4.0
        return PlanarFrame(
            y=np.clip(target.y + amplitude * y_pattern, 0.0, 1.0),
            cb=np.clip(
                target.cb + 0.8 * amplitude * cb_pattern,
                -0.5,
                0.5,
            ),
            cr=np.clip(
                target.cr + 0.7 * amplitude * cr_pattern,
                -0.5,
                0.5,
            ),
        )

    def _publish(
        self,
        *,
        family: str,
        stable_id: object,
        request: Mapping[str, object],
    ) -> Mapping[str, object]:
        rows = []
        rank = self._request_rank(request)
        for identity_index, item in enumerate(self.prepared):
            output = self._output(
                item.target,
                rank=rank,
                identity_index=identity_index,
            )
            parameters = deepcopy(request["parameters"])
            record = {
                "control_key": request["control_key"],
                "control_mode": request["control_mode"],
                "request_sha256": request["request_sha256"],
                "configuration_sha256": request["configuration_sha256"],
                "shared_bank_configuration_sha256": self.bank,
                "input_frame_sha256": frame_sha256(item.low_resolution),
                "output_frame_sha256": frame_sha256(output),
                "target_route": item.context.target_route,
                "parameters": parameters,
                "parameters_sha256": hashlib.sha256(
                    canonical_json_bytes_v2(parameters)
                ).hexdigest(),
            }
            record["record_sha256"] = hashlib.sha256(
                canonical_json_bytes_v2(record)
            ).hexdigest()
            rows.append(
                RawControlMeasurementPublicationV2(
                    metadata=dict(item.metadata),
                    profile=dict(item.profile),
                    target=item.target,
                    low_resolution=item.low_resolution,
                    raw_output=output,
                    native_execution_record=record,
                )
            )
        publication = self.publisher.publish_raw_control_aggregate_v2(
            adapter=self.adapter,
            run_id=RUN_ID,
            split="development",
            control_family=family,
            stable_id=stable_id,
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=self.degradation,
            control_request=request,
            rows=tuple(rows),
        )
        return json.loads(canonical_json_bytes_v2(publication))

    def _outcome(
        self,
        *,
        rule: Mapping[str, object],
        profile: NonAshSelectorExecutionProfileV2,
        scope: NonAshSelectorEvaluationScopeV2,
        evidence: dict[str, bytes],
    ) -> NonAshSelectorEvaluationV2:
        values = canonical_rule_values_v2(rule, profile)
        rule_sha256 = rule_sha256_v2(values, profile)
        request = non_ash_control_request_for_selector_v2(
            rule_mapping_v2(values, profile),
            self.bank,
            selector_id=profile.selector_id,
        )
        publication = self._publish(
            family="non_ash_selector",
            stable_id=rule_sha256,
            request=request,
        )
        self.non_ash_publications.append(publication)
        objective_binding = TypedArtifactBindingV2.from_document(
            publication["objective_summary"]
        )
        snapshot = self.publisher.snapshot_for(publication)
        summary = json.loads(
            snapshot.payload(objective_binding.closure_binding())
        )
        objective = tuple(float(value) for value in summary["means"])
        output_binding = TypedArtifactBindingV2.from_document(
            publication["output_manifest"]
        )
        payload = canonical_evaluation_evidence_bytes_v2(
            selector_id=profile.selector_id,
            split="development",
            evaluation_scope=scope,
            rule_sha256=rule_sha256,
            objective_summary_sha256=objective_binding.sha256,
            output_manifest_sha256=output_binding.sha256,
            objective_means=objective,
        )
        evaluation_sha256 = hashlib.sha256(payload).hexdigest()
        evidence[evaluation_sha256] = payload
        return NonAshSelectorEvaluationV2(
            split="development",
            scope=scope,
            rule_sha256=rule_sha256,
            evaluation_sha256=evaluation_sha256,
            objective_summary_sha256=objective_binding.sha256,
            output_manifest_sha256=output_binding.sha256,
            objective_means=objective,
        )

    def _build_non_ash_input(
        self,
    ) -> tuple[
        NonAshControlSelectionInputV2,
        NonAshSelectorExecutionProfileV2,
        NonAshSelectorEvaluationScopeV2,
    ]:
        fixture = type(
            "_RealNonAshArtifactFixture",
            (non_ash_fixture_module.NonAshSelectorArtifactV2Tests,),
            {"__test__": False},
        )
        fixture.setUpClass()
        cached_payload = b"cached-16-operator-output-manifest"
        scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=self.degradation,
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256=hashlib.sha256(
                cached_payload
            ).hexdigest(),
        )
        fixture.scope = scope
        evidence: dict[str, bytes] = {}
        outcomes: dict[str, NonAshSelectorEvaluationV2] = {}

        def evaluate(rule):
            outcome = self._outcome(
                rule=rule,
                profile=fixture.profile,
                scope=scope,
                evidence=evidence,
            )
            outcomes[outcome.evaluation_sha256] = outcome
            return outcome

        result = run_non_ash_development_search_v2(
            fixture.profile,
            scope,
            evaluate,
            lambda digest: outcomes[digest],
        )
        assert result.terminal_rule_values == tuple(
            0 for _ in fixture.profile.coordinate_order
        )
        fixture.development_result = result
        fixture.development_evidence = evidence
        fixture.development_outcomes = outcomes
        fixture.immutable_content = {}
        fixture.ledger = fixture._ledger_document()
        fixture.development_selection = (
            fixture._development_selection_document()
        )

        entries: list[tuple[TypedArtifactBindingV2, bytes]] = []

        def add_document(
            name: str,
            kind: str,
            document: Mapping[str, object],
        ) -> TypedArtifactBindingV2:
            payload = canonical_artifact_bytes_v2(document)
            binding = _binding(
                kind=kind,
                path=f"real-non-ash/{name}-{hashlib.sha256(payload).hexdigest()}.json",
                payload=payload,
            )
            entries.append((binding, payload))
            return binding

        ledger_binding = add_document(
            "development-ledger",
            ATTEMPT_LEDGER_KIND,
            fixture.ledger,
        )
        selection_binding = add_document(
            "development-selection",
            SELECTION_KIND,
            fixture.development_selection,
        )
        for digest, payload in evidence.items():
            assert hashlib.sha256(payload).hexdigest() == digest
            entries.append(
                (
                    _binding(
                        kind=EVALUATION_EVIDENCE_KIND,
                        path=f"real-non-ash/evaluations/{digest}.json",
                        payload=payload,
                    ),
                    payload,
                )
            )
        entries.append(
            (
                _binding(
                    kind=CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
                    schema_sha256=_digest("cached-operator-schema"),
                    path=(
                        "real-non-ash/immutable/"
                        f"{scope.cached_16_operator_output_manifest_sha256}.json"
                    ),
                    payload=cached_payload,
                ),
                cached_payload,
            )
        )
        entries.sort(key=lambda item: item[0].path)
        non_ash_input = NonAshControlSelectionInputV2(
            selection_binding=selection_binding,
            predecessor_bindings={
                "development_ledger": ledger_binding
            },
            dependency_bindings=tuple(binding for binding, _ in entries),
            evidence_snapshot=_snapshot(tuple(entries)),
        )
        return non_ash_input, fixture.profile, scope

    def authenticate_execution(
        self,
        binding: TypedArtifactBindingV2,
        document: Mapping[str, object],
        context: ControlExecutionSemanticContextV2,
    ) -> Mapping[str, object]:
        assert binding.artifact_kind == (
            "p06_control_execution_provenance_v2"
        )
        assert hashlib.sha256(canonical_json_bytes_v2(document)).hexdigest() == (
            binding.sha256
        )
        request = json.loads(context.expected_control_request_bytes)
        identity = json.loads(context.source_profile_identity_bytes)
        target = decode_control_measurement_frame_bytes_v2(
            context.source_target_frame_bytes
        )
        identity_index = self._identity_index[
            (
                str(identity["source_asset_id"]),
                str(identity["degradation_profile_id"]),
            )
        ]
        expected = self._output(
            target,
            rank=self._request_rank(request),
            identity_index=identity_index,
        )
        assert canonical_control_measurement_frame_bytes_v2(expected) == (
            context.raw_output_frame_bytes
        )
        return json.loads(canonical_json_bytes_v2(document))

    def request(self) -> ProductionControlSelectionRequestV2:
        return ProductionControlSelectionRequestV2(
            run_id=RUN_ID,
            split="development",
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=self.degradation,
            source_profile_matrix_sha256=self.matrix_sha256,
            best_fixed_publications=self.fixed_publications,
            conventional_publications=self.conventional_publications,
            non_ash_selector_publications=tuple(
                self.non_ash_publications
            ),
            non_ash_profile=self.profile,
            non_ash_evaluation_scope=self.evaluation_scope,
            non_ash_selection=self.non_ash_input,
        )

    def forge_objective(
        self,
        publication: Mapping[str, object],
    ) -> Mapping[str, object]:
        exact = json.loads(canonical_json_bytes_v2(publication))
        snapshot = self.publisher.snapshot_for(exact)
        dependencies = self.publisher.dependency_bindings_for(exact)
        old_summary = TypedArtifactBindingV2.from_document(
            exact["objective_summary"]
        )
        summary = json.loads(snapshot.payload(old_summary.closure_binding()))
        summary["means"][0] += 0.25
        summary = finalize_artifact_sha256_v2(summary)
        payload = canonical_json_file_bytes_v2(summary)
        new_summary = _binding(
            kind=OBJECTIVE_SUMMARY_KIND,
            path=(
                "control-v2/p06_control_objective_summary_v2/"
                f"{hashlib.sha256(payload).hexdigest()}.json"
            ),
            payload=payload,
        )
        new_dependencies = tuple(
            sorted(
                (
                    new_summary if binding == old_summary else binding
                    for binding in dependencies
                ),
                key=lambda binding: binding.path,
            )
        )
        entries = []
        for binding in new_dependencies:
            entries.append(
                (
                    binding,
                    payload
                    if binding == new_summary
                    else snapshot.payload(binding.closure_binding()),
                )
            )
        new_snapshot = _snapshot(tuple(entries))
        exact["objective_summary"] = new_summary.as_document()
        exact["dependency_bindings"] = [
            binding.as_document() for binding in new_dependencies
        ]
        exact["dependency_set_sha256"] = dependency_set_sha256_v2(
            new_dependencies
        )
        exact["closure_sha256"] = new_snapshot.closure_sha256
        exact = json.loads(canonical_json_bytes_v2(exact))
        self.publisher._published[new_snapshot.closure_sha256] = (
            publisher_module._PublishedClosureV2(
                publication=exact,
                snapshot=new_snapshot,
                dependencies=new_dependencies,
            )
        )
        return exact


def test_development_builds_exact_v2_ranked_selections_and_bundle(
    tmp_path: Path,
) -> None:
    fixture = _Fixture()
    verifier = ControlAuthorizationVerifierV2()
    service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "store",
        verifier=verifier,
    )
    with _patched_verifier(verifier):
        result = service.authorize(fixture.request(split="development"))

    fixed, conventional, non_ash = result.control_selection_bindings
    assert fixed.artifact_kind == FIXED_SELECTION_KIND
    assert conventional.artifact_kind == CONVENTIONAL_SELECTION_KIND
    assert non_ash.artifact_kind == SELECTION_KIND
    fixed_document = _document(result, fixed)
    conventional_document = _document(result, conventional)
    assert fixed_document["selection_stage"] == "development_provisional"
    assert fixed_document["provisional_descriptor_id"] == 0
    assert conventional_document["provisional_algorithm_id"] == (
        CONVENTIONAL_ALGORITHM_IDS[-1]
    )
    assert result.bundle_binding.artifact_kind == CONTROL_AUTHORIZATION_BUNDLE_KIND
    assert result.bundle_document["split"] == "development"
    assert result.verified.document == dict(result.bundle_document)
    resolver = authorization._SnapshotResolverV2(
        result.evidence_snapshot,
        result.dependency_bindings,
    )
    assert verifier._new_document(
        fixed,
        resolver,
        expected_kind=FIXED_SELECTION_KIND,
    ) == fixed_document
    assert verifier._new_document(
        conventional,
        resolver,
        expected_kind=CONVENTIONAL_SELECTION_KIND,
    ) == conventional_document


def test_validation_rebuilds_development_predecessors_and_is_restart_identical(
    tmp_path: Path,
) -> None:
    fixture = _Fixture()
    request = fixture.request(split="validation")
    first_verifier = ControlAuthorizationVerifierV2()
    first_service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "store",
        verifier=first_verifier,
    )
    with _patched_verifier(first_verifier):
        first = first_service.authorize(request)

    fixed_document = _document(first, first.control_selection_bindings[0])
    assert fixed_document["selection_stage"] == "validation_final"
    assert fixed_document["chosen_descriptor_id"] == 0
    assert fixed_document["development_selection"]["artifact_kind"] == (
        FIXED_SELECTION_KIND
    )
    assert first.bundle_document[
        "development_source_profile_matrix_sha256"
    ] == DEVELOPMENT_MATRIX
    assert first.bundle_document["validation_admission"] == (
        request.validation_admission.as_document()
    )

    second_verifier = ControlAuthorizationVerifierV2()
    second_service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "store",
        verifier=second_verifier,
    )
    with _patched_verifier(second_verifier):
        second = second_service.authorize(request)
    assert second.bundle_binding == first.bundle_binding
    assert second.bundle_document == first.bundle_document
    assert second.dependency_bindings == first.dependency_bindings
    assert second.evidence_snapshot.bindings == first.evidence_snapshot.bindings
    for binding in first.evidence_snapshot.bindings:
        assert second.evidence_snapshot.payload(binding) == (
            first.evidence_snapshot.payload(binding)
        )


def test_split_boundaries_and_v1_inputs_fail_closed(tmp_path: Path) -> None:
    fixture = _Fixture()
    development = fixture.request(split="development")
    admission, admission_snapshot = fixture._admission()
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="development request contains validation predecessors",
    ):
        replace(
            development,
            validation_admission=admission,
            validation_admission_snapshot=admission_snapshot,
            validation_admission_semantic_verifier=(
                lambda _binding, document: document
            ),
        )
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="validation request predecessors are invalid",
    ):
        replace(development, split="validation")

    v1_publication = dict(development.best_fixed_publications[0])
    v1_publication["artifact_kind"] = "p06_raw_control_aggregate_publication"
    request = replace(
        development,
        best_fixed_publications=(
            v1_publication,
            *development.best_fixed_publications[1:],
        ),
    )
    verifier = ControlAuthorizationVerifierV2()
    service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "v1-rejection-store",
        verifier=verifier,
    )
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="raw V2 publication scope differs",
    ):
        service.authorize(request)

    selection_payload = b'{"artifact_kind":"p06_non_ash_selector_selection"}\n'
    v1_binding = _binding(
        kind="p06_non_ash_selector_selection",
        schema_sha256=_digest("v1-schema"),
        path="non-ash/v1-selection.json",
        payload=selection_payload,
    )
    ledger = development.non_ash_selection.predecessor_bindings[
        "development_ledger"
    ]
    ledger_payload = development.non_ash_selection.evidence_snapshot.payload(
        ledger.closure_binding()
    )
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="non-ASH selection input bindings are invalid",
    ):
        NonAshControlSelectionInputV2(
            selection_binding=v1_binding,
            predecessor_bindings={"development_ledger": ledger},
            dependency_bindings=tuple(
                sorted((v1_binding, ledger), key=lambda item: item.path)
            ),
            evidence_snapshot=_snapshot(
                tuple(
                    sorted(
                        (
                            (v1_binding, selection_payload),
                            (ledger, ledger_payload),
                        ),
                        key=lambda item: item[0].path,
                    )
                )
            ),
        )


def test_mutated_missing_and_extra_dependencies_fail_closed(tmp_path: Path) -> None:
    fixture = _Fixture()
    development = fixture.request(split="development")
    mutated = dict(development.conventional_publications[0])
    mutated["dependency_set_sha256"] = _digest("mutated-dependency-set")
    request = replace(
        development,
        conventional_publications=(
            mutated,
            *development.conventional_publications[1:],
        ),
    )
    verifier = ControlAuthorizationVerifierV2()
    service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "mutated",
        verifier=verifier,
    )
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="was not issued by the raw publisher",
    ):
        service.authorize(request)

    missing = replace(
        development,
        best_fixed_publications=development.best_fixed_publications[:-1],
    )
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="publication coverage differs",
    ):
        service.authorize(missing)

    extra = fixture.request(split="development", include_extra=True)
    extra_verifier = ControlAuthorizationVerifierV2()
    extra_service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "extra",
        verifier=extra_verifier,
    )
    with _patched_verifier(extra_verifier), pytest.raises(
        ProductionControlSelectionV2Error,
        match="complete V2 control authorization replay failed",
    ):
        extra_service.authorize(extra)

    original = development.non_ash_selection
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="selection or predecessor binding is omitted",
    ):
        NonAshControlSelectionInputV2(
            selection_binding=original.selection_binding,
            predecessor_bindings=dict(original.predecessor_bindings),
            dependency_bindings=original.dependency_bindings[:-1],
            evidence_snapshot=original.evidence_snapshot,
        )


def test_real_unpatched_verifier_accepts_production_closure_and_rejects_semantic_mutation(
    tmp_path: Path,
) -> None:
    fixture = _RealProductionClosure()
    request = fixture.request()
    verifier = ControlAuthorizationVerifierV2(
        control_execution_semantic_verifier=(
            fixture.authenticate_execution
        ),
        control_execution_producer_identity=fixture.producer_identity,
    )
    service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "real-store",
        verifier=verifier,
    )
    result = service.authorize(request)
    assert result.verified.document == dict(result.bundle_document)
    assert result.bundle_document["split"] == "development"
    assert len(fixture.non_ash_publications) == 163

    forged = fixture.forge_objective(request.best_fixed_publications[0])
    forged_request = replace(
        request,
        best_fixed_publications=(
            forged,
            *request.best_fixed_publications[1:],
        ),
    )
    forged_verifier = ControlAuthorizationVerifierV2(
        control_execution_semantic_verifier=(
            fixture.authenticate_execution
        ),
        control_execution_producer_identity=fixture.producer_identity,
    )
    forged_service = ProductionControlSelectionV2(
        raw_publisher=fixture.publisher,
        artifact_root=tmp_path / "forged-store",
        verifier=forged_verifier,
    )
    with pytest.raises(
        ProductionControlSelectionV2Error,
        match="complete V2 control authorization replay failed",
    ) as caught:
        forged_service.authorize(forged_request)
    assert isinstance(caught.value.__cause__, ControlAuthorizationV2Error)
    assert "control objective hierarchy or means differ" in str(
        caught.value.__cause__
    )
