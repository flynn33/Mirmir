"""Concrete Apple-native measurement source for the P06 schema-2 coordinator."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import stat
from types import MappingProxyType
from typing import Dict, Mapping, Optional, Sequence, Tuple

from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
    ClosureFileBindingV2,
    ClosureFileSnapshotV2,
)
from validation.calibration_v2.baseline_ablation_budget_v2 import (
    NonAshSelectorExecutionProfileV2,
)
from validation.calibration_v2.calibration_persistence_v2 import (
    CandidateControlProducerRequestV2,
    FileBindingV2,
    canonical_json_bytes_v2,
    _read_regular_file,
)
from validation.calibration_v2.calibration_plan_codec import (
    ParsedCalibrationPlanV2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_selection_persistence_v2 import (
    CalibrationSelectionPersistenceAdapterV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    ControlAuthorizationVerifierV2,
    TypedArtifactBindingV2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.control_evidence_publisher_v2 import (
    RawControlAuthorizationArtifactPublisherV2,
)
from validation.calibration_v2.native_adapter.factory import (
    NativeCandidateAdapterFactory,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    DEVELOPMENT_SPLIT,
    VALIDATION_SPLIT,
    NonAshSelectorEvaluationScopeV2,
)
from validation.calibration_v2.production_candidate_provider_v2 import (
    NativeCandidateMeasurementV2,
    ProductionCandidateProviderV2Error,
    ProductionNativeCandidateMeasurementSessionV2,
    ProductionNativeCandidateMeasurementSourceV2,
)
from validation.calibration_v2.production_control_selection_v2 import (
    ProductionControlSelectionRequestV2,
    ProductionControlSelectionResultV2,
    ProductionControlSelectionV2,
)
from validation.calibration_v2.production_evaluator import (
    CONVENTIONAL_ALGORITHM_IDS,
    FIXED_DESCRIPTOR_IDS,
    ProductionCandidateEvaluator,
    conventional_control_request,
    fixed_control_request,
    non_ash_control_request_for_selector_v2,
    production_candidate_evaluator,
)
from validation.calibration_v2.production_factory import (
    ProductionCalibrationAssembly,
)
from validation.calibration_v2.production_non_ash_control_v2 import (
    build_production_non_ash_selection_v2,
)
from validation.calibration_v2.production_providers import (
    native_control_execution_capability_provider_v2,
    native_control_execution_producer_identity_v2,
)
from validation.calibration_v2.runner import (
    BoundInputs,
    LockedDegradationCache,
    _evaluation_view,
    load_development_samples,
    load_split_metadata,
    load_validation_samples,
)
from validation.quality.src.mirmir_quality.arrays import (
    PlanarFrame,
    frame_sha256,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


VALIDATION_ADMISSION_KIND = (
    "p06_validation_candidate_development_evidence_v2"
)
_CACHED_MANIFEST_KIND = "p06_cached_16_operator_output_manifest_v2"


class ProductionNativeCandidateSourceV2Error(
    ProductionCandidateProviderV2Error
):
    """A native input, control measurement, or session closure differs."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and value != "0" * 64
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _publication(aggregate: object, *, label: str) -> Mapping[str, object]:
    publication = getattr(aggregate, "authorization_v2", None)
    if not isinstance(publication, Mapping):
        raise ProductionNativeCandidateSourceV2Error(
            f"{label} lacks its raw V2 publication"
        )
    return json.loads(canonical_json_bytes_v2(publication))


def _matrix_sha256(
    publications: Sequence[Mapping[str, object]],
    *,
    label: str,
) -> str:
    values = {
        publication.get("source_profile_matrix_sha256")
        for publication in publications
    }
    if len(values) != 1:
        raise ProductionNativeCandidateSourceV2Error(
            f"{label} source/profile matrix identity differs"
        )
    value = next(iter(values))
    if not _is_sha256(value):
        raise ProductionNativeCandidateSourceV2Error(
            f"{label} source/profile matrix identity is invalid"
        )
    return str(value)


def _canonical_cached_manifest(
    *,
    bank_sha256: str,
    degradation_policy_sha256: str,
    development_fixed_publications: Sequence[Mapping[str, object]],
) -> bytes:
    rows = []
    for descriptor_id, publication in zip(
        FIXED_DESCRIPTOR_IDS,
        development_fixed_publications,
    ):
        if publication.get("stable_id") != descriptor_id:
            raise ProductionNativeCandidateSourceV2Error(
                "development fixed-control publication order differs"
            )
        output = publication.get("output_manifest")
        if not isinstance(output, Mapping) or not _is_sha256(
            output.get("sha256")
        ):
            raise ProductionNativeCandidateSourceV2Error(
                "development fixed-control output binding is absent"
            )
        rows.append(
            {
                "descriptor_id": descriptor_id,
                "output_manifest_sha256": output["sha256"],
            }
        )
    return canonical_json_bytes_v2(
        {
            "schema_version": "2.0.0",
            "artifact_kind": _CACHED_MANIFEST_KIND,
            "shared_bank_configuration_sha256": bank_sha256,
            "degradation_policy_sha256": degradation_policy_sha256,
            "descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
            "development_fixed_output_manifests": rows,
            "validation_content_included": False,
            "holdout_content_included": False,
        }
    )


@dataclass(frozen=True)
class _ExternalControlSelectionV2:
    selection_stage: str
    shared_bank_configuration_sha256: str
    artifacts: Mapping[str, Mapping[str, object]]
    full_ash_development_candidates_frozen_sha256: Optional[str]


class ProductionAppleNativeCandidateMeasurementSourceV2(
    ProductionNativeCandidateMeasurementSourceV2
):
    """Load only locked open splits and create real native Swift sessions."""

    def __init__(
        self,
        *,
        assembly: ProductionCalibrationAssembly,
        open_split_root: Path,
        artifact_root: Path,
        evaluation_bound_inputs: BoundInputs,
        plan: ParsedCalibrationPlanV2,
        non_ash_profile: NonAshSelectorExecutionProfileV2,
    ) -> None:
        if (
            type(assembly) is not ProductionCalibrationAssembly
            or type(assembly.adapter_factory) is not NativeCandidateAdapterFactory
            or type(evaluation_bound_inputs) is not BoundInputs
            or type(plan) is not ParsedCalibrationPlanV2
            or type(non_ash_profile) is not NonAshSelectorExecutionProfileV2
        ):
            raise ProductionNativeCandidateSourceV2Error(
                "production native source capabilities are invalid"
            )
        root = Path(open_split_root)
        try:
            metadata = os.stat(root, follow_symlinks=False)
        except OSError as error:
            raise ProductionNativeCandidateSourceV2Error(
                "open-split root is absent"
            ) from error
        if root.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise ProductionNativeCandidateSourceV2Error(
                "open-split root is symbolic or not a directory"
            )
        self.assembly = assembly
        self.native_factory = assembly.adapter_factory
        self.native_bound = assembly.adapter_factory.bound
        self.bound = evaluation_bound_inputs
        self.open_split_root = root.resolve(strict=True)
        self.artifact_root = Path(artifact_root)
        self.plan = plan
        self.non_ash_profile = non_ash_profile
        self._loaded: Dict[
            str,
            Tuple[Tuple[Mapping[str, object], ...], Tuple[PlanarFrame, ...]],
        ] = {}
        native_plan = self.native_bound.documents.get("calibration_plan")
        evaluation_plan = self.bound.documents.get("calibration_plan")
        if (
            not isinstance(native_plan, Mapping)
            or native_plan.get("schema_version") != "2.0.0"
            or not isinstance(evaluation_plan, Mapping)
            or evaluation_plan.get("schema_version") != "1.0.0"
        ):
            raise ProductionNativeCandidateSourceV2Error(
                "native and inherited evaluation plan boundaries differ"
            )

    def _split(
        self,
        split: str,
    ) -> Tuple[Tuple[Mapping[str, object], ...], Tuple[PlanarFrame, ...]]:
        if split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}:
            raise ProductionNativeCandidateSourceV2Error(
                "native source cannot open a sealed split"
            )
        cached = self._loaded.get(split)
        if cached is not None:
            return cached
        self.bound.verify_unchanged()
        samples = load_split_metadata(self.bound, split)
        loader = (
            load_development_samples
            if split == DEVELOPMENT_SPLIT
            else load_validation_samples
        )
        loaded = loader(
            self.bound.documents[f"{split}_sample_lock"],
            self.bound.documents["corpus_lock"],
            sample_root=self.open_split_root,
            asset_root=self.open_split_root,
        )
        if [row.get("source_asset_id") for row, _ in loaded] != [
            row["source_asset_id"] for row in samples
        ]:
            raise ProductionNativeCandidateSourceV2Error(
                "open-split sample order differs from its lock"
            )
        frames = []
        for sample, (_, frame) in zip(samples, loaded):
            if frame_sha256(frame) != sample.get("target_frame_sha256"):
                raise ProductionNativeCandidateSourceV2Error(
                    "open-split pixels differ from their lock"
                )
            frames.append(LockedDegradationCache._freeze(frame))
        result = (tuple(samples), tuple(frames))
        self.bound.verify_unchanged()
        self._loaded[split] = result
        return result

    def evaluation_view(self, split: str):
        samples, frames = self._split(split)
        return _evaluation_view(self.bound, split, samples, frames)

    def evaluator(self) -> ProductionCandidateEvaluator:
        documents = self.bound.documents
        return production_candidate_evaluator(
            degradation_policy=documents["degradation_policy"],
            metric_policy=documents["metric_policy_seed"],
            baseline_ablation_contract=documents["baseline_ablation_contract"],
            baseline_ablation_contract_sha256=str(
                self.bound.record("baseline_ablation_contract")["sha256"]
            ),
            writer=self.assembly.writer,
            analytic_fixtures=self.assembly.analytic_fixtures,
            evidence_store=self.assembly.evidence_store,
            evaluation_evidence_provider=(
                self.assembly.evaluation_evidence_provider
            ),
        )

    def open_session(self, request):
        return _ProductionAppleNativeCandidateMeasurementSessionV2(
            source=self,
            request=request,
        )


class _ProductionAppleNativeCandidateMeasurementSessionV2(
    ProductionNativeCandidateMeasurementSessionV2
):
    def __init__(
        self,
        *,
        source: ProductionAppleNativeCandidateMeasurementSourceV2,
        request: object,
    ) -> None:
        from validation.calibration_v2.production_coordinator_v2 import (
            CandidateEvaluationRequestV2,
        )

        if type(request) is not CandidateEvaluationRequestV2:
            raise ProductionNativeCandidateSourceV2Error(
                "native session request has the wrong type"
            )
        self.source = source
        self.request = request
        self.logical = dict(request.logical_candidate_items)
        self.physical = dict(request.physical_candidate_items)
        self.bank = shared_bank_configuration_sha256_v2(
            self.physical,
            source.plan,
        )
        self.adapter = source.native_factory(self.logical, request.split)
        if (
            self.adapter.configuration.get(
                "serialized_candidate_vector_sha256"
            )
            != request.cache_identity.candidate_vector_sha256
            or self.adapter.configuration.get(
                "shared_bank_configuration_sha256"
            )
            != self.bank
        ):
            self.adapter.callable.close()
            raise ProductionNativeCandidateSourceV2Error(
                "native session candidate identity differs"
            )
        self.evaluator = source.evaluator()
        self.cache = LockedDegradationCache(
            str(source.bound.documents["degradation_policy"]["policy_sha256"])
        )
        self.physical_items_bytes = canonical_json_bytes_v2(
            [list(item) for item in request.physical_candidate_items]
        )
        self.producer_identity = native_control_execution_producer_identity_v2(
            factory=source.native_factory,
            adapter=self.adapter,
            physical_candidate_items_bytes=self.physical_items_bytes,
            candidate_vector_sha256=(
                request.cache_identity.candidate_vector_sha256
            ),
        )
        self.publisher = RawControlAuthorizationArtifactPublisherV2(
            run_id=request.run_id,
            control_execution_producer_identity=self.producer_identity,
        )
        self.evaluator.configure_control_authorization_artifact_publisher_v2(
            self.publisher
        )
        self._control_request: Optional[
            ProductionControlSelectionRequestV2
        ] = None
        self._control_service: Optional[ProductionControlSelectionV2] = None
        self._replay_owner: object = None
        self._development_adapter: object = None
        self._closed = False

    def _prepared(self, split: str, adapter: object):
        captured = self.evaluator._capture(
            self.source.evaluation_view(split)
        )
        return self.evaluator._prepare_cases(captured, self.cache)

    def _ranked(
        self,
        *,
        split: str,
        adapter: object,
        prepared: Sequence[object],
    ) -> Tuple[
        Tuple[Mapping[str, object], ...],
        Tuple[Mapping[str, object], ...],
    ]:
        fixed = tuple(
            _publication(
                self.evaluator._uniform_control_evidence(
                    adapter=adapter,
                    prepared=prepared,
                    request=fixed_control_request(descriptor_id, self.bank),
                    split=split,
                    stable_id=descriptor_id,
                ),
                label=f"{split} fixed control {descriptor_id}",
            )
            for descriptor_id in FIXED_DESCRIPTOR_IDS
        )
        conventional = tuple(
            _publication(
                self.evaluator._uniform_control_evidence(
                    adapter=adapter,
                    prepared=prepared,
                    request=conventional_control_request(
                        algorithm_id,
                        self.bank,
                    ),
                    split=split,
                    stable_id=algorithm_id,
                ),
                label=f"{split} conventional control {algorithm_id}",
            )
            for algorithm_id in CONVENTIONAL_ALGORITHM_IDS
        )
        return fixed, conventional

    def _admission(self):
        binding = self.request.validation_admission
        if binding is None:
            return None, None, None, None
        payload = _read_regular_file(
            self.source.artifact_root / binding.path,
            label="validation admission",
        )
        if len(payload) != binding.size_bytes or _sha256(payload) != binding.sha256:
            raise ProductionNativeCandidateSourceV2Error(
                "validation admission binding differs"
            )
        typed = TypedArtifactBindingV2(
            artifact_kind=VALIDATION_ADMISSION_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
            path=binding.path,
            sha256=binding.sha256,
            size_bytes=binding.size_bytes,
        )
        snapshot = AuthenticatedClosureSnapshotV2(
            (
                ClosureFileSnapshotV2(
                    ClosureFileBindingV2(
                        typed.path,
                        typed.sha256,
                        typed.size_bytes,
                    ),
                    payload,
                ),
            )
        )
        persistence = CalibrationSelectionPersistenceAdapterV2(
            self.source.artifact_root,
            _control_producer_capability_provider=(
                native_control_execution_capability_provider_v2(
                    self.source.native_factory
                )
            ),
        )

        def verify(
            supplied_binding: TypedArtifactBindingV2,
            supplied_document: Mapping[str, object],
        ) -> Mapping[str, object]:
            if supplied_binding != typed:
                raise ProductionNativeCandidateSourceV2Error(
                    "validation admission typed binding differs"
                )
            verified = persistence.reopen_validation_admission(binding)
            if verified.document != supplied_document:
                raise ProductionNativeCandidateSourceV2Error(
                    "validation admission semantic replay differs"
                )
            return verified.document

        document = json.loads(payload)
        frozen = document.get("artifact_sha256")
        if not _is_sha256(frozen):
            raise ProductionNativeCandidateSourceV2Error(
                "validation admission semantic identity is absent"
            )
        return typed, snapshot, verify, payload

    def _service(
        self,
        request: ProductionControlSelectionRequestV2,
    ) -> ProductionControlSelectionV2:
        first = request.best_fixed_publications[0]
        snapshot = self.publisher.snapshot_for(first)
        dependencies = self.publisher.dependency_bindings_for(first)
        output_binding = TypedArtifactBindingV2.from_document(
            first["output_manifest"]
        )
        producer_request = CandidateControlProducerRequestV2(
            evidence_snapshot=snapshot,
            bundle_binding=output_binding,
            dependency_bindings=dependencies,
            physical_candidate_items_bytes=self.physical_items_bytes,
            candidate_vector_sha256=(
                self.request.cache_identity.candidate_vector_sha256
            ),
            authorization_scope=request.authorization_scope(),
            non_ash_evaluation_scope=request.non_ash_evaluation_scope,
        )
        capabilities = native_control_execution_capability_provider_v2(
            self.source.native_factory
        )(producer_request)
        self._replay_owner = getattr(
            capabilities.control_execution_semantic_verifier,
            "__self__",
            None,
        )
        verifier = ControlAuthorizationVerifierV2(
            control_execution_semantic_verifier=(
                capabilities.control_execution_semantic_verifier
            ),
            control_execution_producer_identity=(
                capabilities.control_execution_producer_identity
            ),
        )
        return ProductionControlSelectionV2(
            raw_publisher=self.publisher,
            artifact_root=self.source.artifact_root,
            verifier=verifier,
        )

    def control_selection_request(self) -> ProductionControlSelectionRequestV2:
        if self._control_request is not None:
            return self._control_request
        current_prepared = self._prepared(self.request.split, self.adapter)
        if self.request.split == DEVELOPMENT_SPLIT:
            development_adapter = self.adapter
            development_prepared = current_prepared
        else:
            development_adapter = self.source.native_factory(
                self.logical,
                DEVELOPMENT_SPLIT,
            )
            self._development_adapter = development_adapter
            development_prepared = self._prepared(
                DEVELOPMENT_SPLIT,
                development_adapter,
            )
        development_fixed, development_conventional = self._ranked(
            split=DEVELOPMENT_SPLIT,
            adapter=development_adapter,
            prepared=development_prepared,
        )
        development_matrix = _matrix_sha256(
            (*development_fixed, *development_conventional),
            label="development ranked controls",
        )
        if self.request.split == DEVELOPMENT_SPLIT:
            current_fixed = development_fixed
            current_conventional = development_conventional
            current_matrix = development_matrix
        else:
            current_fixed, current_conventional = self._ranked(
                split=VALIDATION_SPLIT,
                adapter=self.adapter,
                prepared=current_prepared,
            )
            current_matrix = _matrix_sha256(
                (*current_fixed, *current_conventional),
                label="validation ranked controls",
            )
            if current_matrix == development_matrix:
                raise ProductionNativeCandidateSourceV2Error(
                    "development and validation matrix identities alias"
                )
        cached_payload = _canonical_cached_manifest(
            bank_sha256=self.bank,
            degradation_policy_sha256=str(
                self.source.bound.documents["degradation_policy"][
                    "policy_sha256"
                ]
            ),
            development_fixed_publications=development_fixed,
        )
        scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=str(
                self.source.bound.documents["degradation_policy"][
                    "policy_sha256"
                ]
            ),
            calibration_plan_file_sha256=self.source.plan.plan_file_sha256,
            cached_16_operator_output_manifest_sha256=_sha256(cached_payload),
        )
        admission, admission_snapshot, admission_verifier, admission_payload = (
            self._admission()
        )

        def evaluate(target_split: str, rule: Mapping[str, int]):
            selected_adapter = (
                development_adapter
                if target_split == DEVELOPMENT_SPLIT
                else self.adapter
            )
            selected_prepared = (
                development_prepared
                if target_split == DEVELOPMENT_SPLIT
                else current_prepared
            )
            request = non_ash_control_request_for_selector_v2(
                rule,
                self.bank,
                selector_id=self.source.non_ash_profile.selector_id,
            )
            return self.evaluator._uniform_control_evidence(
                adapter=selected_adapter,
                prepared=selected_prepared,
                request=request,
                split=target_split,
                stable_id=request["parameters"]["selected_rule_sha256"],
            )

        non_ash = build_production_non_ash_selection_v2(
            artifact_root=self.source.artifact_root,
            run_id=self.request.run_id,
            split=self.request.split,
            profile=self.source.non_ash_profile,
            scope=scope,
            cached_manifest_payload=cached_payload,
            evaluator=evaluate,
            validation_admission_payload=admission_payload,
        )
        if self.request.split == VALIDATION_SPLIT:
            development_adapter.callable.close()
            self._development_adapter = None
        request = ProductionControlSelectionRequestV2(
            run_id=self.request.run_id,
            split=self.request.split,
            shared_bank_configuration_sha256=self.bank,
            degradation_policy_sha256=scope.degradation_policy_sha256,
            source_profile_matrix_sha256=current_matrix,
            best_fixed_publications=current_fixed,
            conventional_publications=current_conventional,
            non_ash_selector_publications=non_ash.current_publications,
            non_ash_profile=self.source.non_ash_profile,
            non_ash_evaluation_scope=scope,
            non_ash_selection=non_ash.selection_input,
            development_source_profile_matrix_sha256=(
                development_matrix
                if self.request.split == VALIDATION_SPLIT
                else None
            ),
            development_best_fixed_publications=(
                development_fixed
                if self.request.split == VALIDATION_SPLIT
                else ()
            ),
            development_conventional_publications=(
                development_conventional
                if self.request.split == VALIDATION_SPLIT
                else ()
            ),
            development_non_ash_selector_publications=(
                non_ash.development_publications
                if self.request.split == VALIDATION_SPLIT
                else ()
            ),
            validation_admission=admission,
            validation_admission_snapshot=admission_snapshot,
            validation_admission_semantic_verifier=admission_verifier,
        )
        self._control_request = request
        self._control_service = self._service(request)
        return request

    def control_selection_service(self) -> ProductionControlSelectionV2:
        if self._control_service is None:
            raise ProductionNativeCandidateSourceV2Error(
                "control selection was requested before measurement"
            )
        return self._control_service

    @staticmethod
    def _selection_context(
        result: ProductionControlSelectionResultV2,
        *,
        admission_payload: Optional[bytes],
    ) -> _ExternalControlSelectionV2:
        if len(result.control_selection_bindings) != 3:
            raise ProductionNativeCandidateSourceV2Error(
                "authorized control selection count differs"
            )
        artifacts = {}
        for name, binding in zip(
            ("best_fixed", "conventional", "non_ash_selector"),
            result.control_selection_bindings,
        ):
            payload = result.evidence_snapshot.payload(
                binding.closure_binding()
            )
            document = json.loads(payload)
            artifacts[name] = {
                "sha256": canonical_sha256(document),
                "document": document,
            }
        frozen = None
        if admission_payload is not None:
            admission = json.loads(admission_payload)
            frozen = admission.get("artifact_sha256")
            if not _is_sha256(frozen):
                raise ProductionNativeCandidateSourceV2Error(
                    "validation admission semantic identity is absent"
                )
        return _ExternalControlSelectionV2(
            selection_stage=(
                "development_provisional"
                if admission_payload is None
                else "validation_final"
            ),
            shared_bank_configuration_sha256=str(
                result.bundle_document[
                    "shared_bank_configuration_sha256"
                ]
            ),
            artifacts=MappingProxyType(artifacts),
            full_ash_development_candidates_frozen_sha256=frozen,
        )

    def _close_replay(self) -> None:
        owner = self._replay_owner
        self._replay_owner = None
        close = getattr(owner, "close", None)
        if callable(close):
            close()

    def measure_authorized_candidate(
        self,
        control_selection: ProductionControlSelectionResultV2,
    ) -> NativeCandidateMeasurementV2:
        if (
            self._control_request is None
            or type(control_selection) is not ProductionControlSelectionResultV2
            or control_selection.bundle_document.get("run_id")
            != self.request.run_id
            or control_selection.bundle_document.get("split")
            != self.request.split
        ):
            raise ProductionNativeCandidateSourceV2Error(
                "candidate control authorization scope differs"
            )
        self._close_replay()
        admission_payload = None
        if self.request.validation_admission is not None:
            admission_payload = _read_regular_file(
                self.source.artifact_root
                / self.request.validation_admission.path,
                label="validation admission",
            )
        external = self._selection_context(
            control_selection,
            admission_payload=admission_payload,
        )
        evaluation = self.evaluator(
            self.adapter,
            self.logical,
            self.source.evaluation_view(self.request.split),
            self.cache,
            external,
        )
        required = {
            "corpus_asset_results",
            "analytic_fixture_results",
            "checks",
            "performance",
            "dispatch_measurement",
        }
        if not required.issubset(evaluation):
            raise ProductionNativeCandidateSourceV2Error(
                "native production evaluation evidence is incomplete"
            )
        raw = {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_native_candidate_measurements_v2",
            "run_id": self.request.run_id,
            "split": self.request.split,
            "candidate_id": self.adapter.candidate_id,
            "candidate_vector_sha256": (
                self.request.cache_identity.candidate_vector_sha256
            ),
            "adapter_configuration_sha256": self.adapter.configuration_sha256,
            "control_authorization_bundle_sha256": (
                control_selection.bundle_binding.sha256
            ),
            "source_profile_matrix_sha256": (
                self._control_request.source_profile_matrix_sha256
            ),
            "corpus_asset_results": evaluation["corpus_asset_results"],
            "analytic_fixture_results": evaluation[
                "analytic_fixture_results"
            ],
            "checks": evaluation["checks"],
            "performance": evaluation["performance"],
            "dispatch_measurement": evaluation["dispatch_measurement"],
        }
        return NativeCandidateMeasurementV2(
            request=self.request,
            control_selection=control_selection,
            candidate_id=self.adapter.candidate_id,
            adapter_configuration_bytes=canonical_json_bytes_v2(
                self.adapter.configuration
            ),
            raw_measurement_bytes=canonical_json_bytes_v2(raw),
        )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._close_replay()
        development = self._development_adapter
        self._development_adapter = None
        close = getattr(getattr(development, "callable", None), "close", None)
        if callable(close):
            close()
        self.adapter.callable.close()


def production_apple_native_candidate_measurement_source_v2(
    *,
    assembly: ProductionCalibrationAssembly,
    open_split_root: Path,
    artifact_root: Path,
    evaluation_bound_inputs: BoundInputs,
    plan: ParsedCalibrationPlanV2,
    non_ash_profile: NonAshSelectorExecutionProfileV2,
) -> ProductionAppleNativeCandidateMeasurementSourceV2:
    """Construct the sole supported schema-2 native measurement source."""

    return ProductionAppleNativeCandidateMeasurementSourceV2(
        assembly=assembly,
        open_split_root=open_split_root,
        artifact_root=artifact_root,
        evaluation_bound_inputs=evaluation_bound_inputs,
        plan=plan,
        non_ash_profile=non_ash_profile,
    )


__all__ = [
    "ProductionAppleNativeCandidateMeasurementSourceV2",
    "ProductionNativeCandidateSourceV2Error",
    "production_apple_native_candidate_measurement_source_v2",
]
