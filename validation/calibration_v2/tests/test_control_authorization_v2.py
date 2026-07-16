from __future__ import annotations

from copy import deepcopy
import hashlib
import importlib
import json
from pathlib import Path
from typing import Mapping
import unittest
from unittest.mock import patch

from jsonschema import Draft202012Validator
import numpy as np

from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
    ClosureFileBindingV2,
    ClosureFileSnapshotV2,
)
from validation.calibration_v2 import control_authorization_v2 as control
from validation.calibration_v2.control_authorization_v2 import (
    CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
    CONVENTIONAL_SELECTION_KIND,
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    CONTROL_MEASUREMENT_EVIDENCE_KIND,
    CONTROL_OUTPUT_BYTES_KIND,
    CONTROL_TARGET_FRAME_BYTES_KIND,
    CONTROL_WRITER_DECODED_PAYLOAD_BYTES_KIND,
    CONTROL_WRITER_ENCODED_CONTAINER_BYTES_KIND,
    CONTROL_WRITER_EVIDENCE_BYTES_KIND,
    CONTROL_WRITER_REPORT_BYTES_KIND,
    FIXED_SELECTION_KIND,
    NON_ASH_IMMUTABLE_CONTENT_KIND,
    OBJECTIVE_SUMMARY_KIND,
    OUTPUT_MANIFEST_KIND,
    ControlAuthorizationScopeV2,
    ControlAuthorizationV2Error,
    ControlAuthorizationVerifierV2,
    TypedArtifactBindingV2,
    VALIDATION_ADMISSION_KIND,
    authority_bindings_v2,
    canonical_json_bytes_v2,
    canonical_json_file_bytes_v2,
    dependency_set_sha256_v2,
    finalize_artifact_sha256_v2,
    finalize_control_authorization_bundle_v2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    ATTEMPT_LEDGER_KIND,
    EVALUATION_EVIDENCE_KIND,
    NEIGHBOR_MANIFEST_KIND,
    SELECTION_KIND,
    NonAshSelectorArtifactV2Error,
    canonical_evaluation_evidence_bytes_v2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    NonAshSelectorEvaluationScopeV2,
    rule_mapping_v2,
)
from validation.calibration_v2.production_evaluator import (
    CONTROL_MEASUREMENT_FRAME_ENCODING_V2,
    ControlExecutionProducerIdentityV2,
    ControlExecutionSemanticContextV2,
    ControlWriterProducerIdentityV2,
    ControlWriterSemanticContextV2,
    NON_ASH_SELECTOR_ID_V2,
    canonical_control_measurement_frame_bytes_v2,
    conventional_control_request,
    conventional_control_configuration_sha256_v2,
    corpus_metric_bundle,
    fixed_control_request,
    fixed_control_configuration_sha256_v2,
    hierarchical_control_objective_v2,
    non_ash_control_configuration_sha256_v2,
    non_ash_control_request_for_selector_v2,
)
from validation.quality.src.mirmir_quality.arrays import (
    PlanarFrame,
    frame_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
SCHEMA_ROOT = ROOT / "validation/calibration_v2/schemas"
NEW_SCHEMA_NAMES = (
    "control-objective-summary-v2.schema.json",
    "control-output-manifest-v2.schema.json",
    "fixed-control-selection-v2.schema.json",
    "conventional-control-selection-v2.schema.json",
    "non-ash-selector-evaluation-evidence-v2.schema.json",
    "p06-control-authorization-bundle-v2.schema.json",
)
EXPECTED_SCHEMA_DIGESTS = {
    "control-objective-summary-v2.schema.json": (
        "be8f13114ed4b91a86a8d69eee3f97d6f614ea8f57567e69c0d38b302b2807df"
    ),
    "control-output-manifest-v2.schema.json": (
        "61300b90a010a35e979d7798fd74ae59349f83565d46a11dab647725ef124597"
    ),
    "fixed-control-selection-v2.schema.json": (
        "543db7e687bb7bcbdbb987b3c53c575d7a24a9473487098608601e9661fa2db1"
    ),
    "conventional-control-selection-v2.schema.json": (
        "1c6a87b852dc258f7202c7152f6dfb590da1a83ed88070739e1ce132f1f949df"
    ),
    "non-ash-selector-evaluation-evidence-v2.schema.json": (
        "15ac9960c73ead2b810c39d7c4c7f21c7773d74c15f29ea4ee6f128dc657ad43"
    ),
    "p06-control-authorization-bundle-v2.schema.json": (
        "c5d79fa2b6b8b574532d4a83d95a4e543f6a9dde769bc8c3f3969d5167729582"
    ),
}


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


_FIXTURE_ADAPTER_IDENTITY = {
    "adapter_configuration_sha256": _digest(
        "trusted-adapter-configuration"
    ),
    "native_source_manifest_sha256": _digest(
        "trusted-native-source-manifest"
    ),
    "native_executable_sha256": _digest("trusted-native-executable"),
    "native_implementation_source_sha256": _digest(
        "trusted-native-implementation-source"
    ),
}
_FIXTURE_WRITER_SETTINGS = {
    "writer_id": "fixture-locked-writer-v2",
    "pixel_contract": "fixture-bt709-video-range-v2",
    "isolation": "one-frame-per-container",
}
_FIXTURE_WRITER_IDENTITY = {
    "writer_executable_sha256": _digest("trusted-writer-executable"),
    "writer_settings_source_sha256": _digest(
        "trusted-writer-settings-source"
    ),
    "writer_source_manifest_sha256": _digest(
        "trusted-writer-source-manifest"
    ),
    "writer_implementation_source_sha256": _digest(
        "trusted-writer-implementation-source"
    ),
}
_FIXTURE_PHYSICAL_ITEMS = [
    [f"fixture_physical_field_{index:02d}", index]
    for index in range(48)
]


def _execution_producer_identity() -> ControlExecutionProducerIdentityV2:
    return ControlExecutionProducerIdentityV2(
        physical_candidate_items_bytes=canonical_json_bytes_v2(
            _FIXTURE_PHYSICAL_ITEMS
        ),
        candidate_vector_sha256=hashlib.sha256(
            canonical_json_bytes_v2(
                [item[1] for item in _FIXTURE_PHYSICAL_ITEMS]
            )
        ).hexdigest(),
        adapter_configuration_sha256=_FIXTURE_ADAPTER_IDENTITY[
            "adapter_configuration_sha256"
        ],
        authenticated_adapter_identity_bytes=canonical_json_bytes_v2(
            _FIXTURE_ADAPTER_IDENTITY
        ),
    )


def _writer_producer_identity() -> ControlWriterProducerIdentityV2:
    return ControlWriterProducerIdentityV2(
        writer_settings_bytes=canonical_json_bytes_v2(
            _FIXTURE_WRITER_SETTINGS
        ),
        writer_settings_sha256=hashlib.sha256(
            canonical_json_bytes_v2(_FIXTURE_WRITER_SETTINGS)
        ).hexdigest(),
        authenticated_writer_identity_bytes=canonical_json_bytes_v2(
            _FIXTURE_WRITER_IDENTITY
        ),
    )


def _binding_document(binding: TypedArtifactBindingV2) -> dict[str, object]:
    return binding.as_document()


class EvidenceBuilder:
    def __init__(self) -> None:
        self.files: dict[str, tuple[TypedArtifactBindingV2, bytes]] = {}
        self.authenticated_executions: dict[
            str, dict[str, object]
        ] = {}
        self.authenticated_writers: dict[str, dict[str, object]] = {}
        self.locked_profiles: dict[str, dict[str, object]] = {}

    def add_bytes(
        self,
        *,
        artifact_kind: str,
        schema_sha256: str,
        path: str,
        payload: bytes,
    ) -> TypedArtifactBindingV2:
        binding = TypedArtifactBindingV2(
            artifact_kind=artifact_kind,
            schema_sha256=schema_sha256,
            path=path,
            sha256=hashlib.sha256(payload).hexdigest(),
            size_bytes=len(payload),
        )
        if path in self.files:
            raise AssertionError(f"duplicate fixture path {path}")
        if any(prior.sha256 == binding.sha256 for prior, _ in self.files.values()):
            raise AssertionError(f"duplicate fixture digest {path}")
        self.files[path] = (binding, payload)
        return binding

    def add_or_reuse_bytes(
        self,
        *,
        artifact_kind: str,
        schema_sha256: str,
        path: str,
        payload: bytes,
    ) -> TypedArtifactBindingV2:
        digest = hashlib.sha256(payload).hexdigest()
        for binding, prior_payload in self.files.values():
            if binding.sha256 != digest:
                continue
            if (
                prior_payload != payload
                or binding.artifact_kind != artifact_kind
                or binding.schema_sha256 != schema_sha256
            ):
                raise AssertionError("fixture digest aliases a different type")
            return binding
        return self.add_bytes(
            artifact_kind=artifact_kind,
            schema_sha256=schema_sha256,
            path=path,
            payload=payload,
        )

    def add_new_document(
        self,
        document: dict[str, object],
        *,
        artifact_kind: str,
        label: str,
    ) -> tuple[TypedArtifactBindingV2, dict[str, object]]:
        finalized = finalize_artifact_sha256_v2(document)
        payload = canonical_json_file_bytes_v2(finalized)
        digest = hashlib.sha256(payload).hexdigest()
        binding = self.add_bytes(
            artifact_kind=artifact_kind,
            schema_sha256=schema_sha256_for_kind_v2(artifact_kind),
            path=f"documents/{label}-{digest}.json",
            payload=payload,
        )
        return binding, finalized

    def add_existing_document(
        self,
        document: dict[str, object],
        *,
        artifact_kind: str,
        label: str,
    ) -> TypedArtifactBindingV2:
        payload = canonical_json_bytes_v2(document)
        digest = hashlib.sha256(payload).hexdigest()
        return self.add_bytes(
            artifact_kind=artifact_kind,
            schema_sha256=schema_sha256_for_kind_v2(artifact_kind),
            path=f"existing/{label}-{digest}.json",
            payload=payload,
        )

    def add_authenticated_execution(
        self,
        document: dict[str, object],
        *,
        label: str,
    ) -> TypedArtifactBindingV2:
        payload = canonical_json_bytes_v2(document)
        binding = self.add_or_reuse_bytes(
            artifact_kind=control.CONTROL_EXECUTION_PROVENANCE_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path=f"executions/{label}-{hashlib.sha256(payload).hexdigest()}.json",
            payload=payload,
        )
        self.authenticated_executions[binding.sha256] = deepcopy(document)
        return binding

    def authenticate_execution(
        self,
        binding: TypedArtifactBindingV2,
        document: Mapping[str, object],
        context: ControlExecutionSemanticContextV2,
    ) -> Mapping[str, object]:
        expected = self.authenticated_executions.get(binding.sha256)
        profile = json.loads(context.degradation_profile_bytes)
        profile_binding = document.get("degradation_profile", {})
        producer_identity = _execution_producer_identity()
        if (
            expected is None
            or expected != document
            or type(context) is not ControlExecutionSemanticContextV2
            or not isinstance(profile_binding, dict)
            or self.locked_profiles.get(profile_binding.get("sha256"))
            != profile
            or context.expected_control_request_bytes
            != canonical_json_bytes_v2(document["control_request"])
            or hashlib.sha256(context.low_resolution_input_frame_bytes)
            .hexdigest()
            != document["low_resolution_input"]["sha256"]
            or hashlib.sha256(context.raw_output_frame_bytes).hexdigest()
            != document["output"]["sha256"]
            or context.physical_candidate_items_bytes
            != producer_identity.physical_candidate_items_bytes
            or context.candidate_vector_sha256
            != producer_identity.candidate_vector_sha256
            or context.adapter_configuration_sha256
            != producer_identity.adapter_configuration_sha256
            or context.authenticated_adapter_identity_bytes
            != producer_identity.authenticated_adapter_identity_bytes
        ):
            raise ValueError("execution is not in the trusted native receipt set")
        return deepcopy(expected)

    def add_authenticated_writer(
        self,
        document: dict[str, object],
        *,
        label: str,
    ) -> TypedArtifactBindingV2:
        payload = canonical_json_bytes_v2(document)
        binding = self.add_bytes(
            artifact_kind=CONTROL_WRITER_EVIDENCE_BYTES_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path=f"writer/{label}-{hashlib.sha256(payload).hexdigest()}.json",
            payload=payload,
        )
        self.authenticated_writers[binding.sha256] = deepcopy(document)
        return binding

    def authenticate_writer(
        self,
        binding: TypedArtifactBindingV2,
        document: Mapping[str, object],
        context: ControlWriterSemanticContextV2,
    ) -> Mapping[str, object]:
        expected = self.authenticated_writers.get(binding.sha256)
        producer_identity = _writer_producer_identity()
        if (
            expected is None
            or expected != document
            or type(context) is not ControlWriterSemanticContextV2
            or context.writer_provenance_bytes
            != canonical_json_bytes_v2(document)
            or hashlib.sha256(context.raw_output_frame_bytes).hexdigest()
            != document["raw_output"]["sha256"]
            or hashlib.sha256(context.decoded_output_frame_bytes).hexdigest()
            != document["decoded_output"]["sha256"]
            or hashlib.sha256(context.decoded_payload_bytes).hexdigest()
            != document["decoded_payload"]["sha256"]
            or hashlib.sha256(context.encoded_container_bytes).hexdigest()
            != document["encoded_container"]["sha256"]
            or hashlib.sha256(context.writer_report_bytes).hexdigest()
            != document["writer_report"]["sha256"]
            or context.writer_settings_bytes
            != producer_identity.writer_settings_bytes
            or context.writer_settings_sha256
            != producer_identity.writer_settings_sha256
            or context.authenticated_writer_identity_bytes
            != producer_identity.authenticated_writer_identity_bytes
        ):
            raise ValueError("writer is not in the trusted round-trip receipt set")
        return deepcopy(expected)

    def dependencies(self) -> tuple[TypedArtifactBindingV2, ...]:
        return tuple(
            sorted(
                (binding for binding, _ in self.files.values()),
                key=control._binding_sort_key,
            )
        )

    def snapshot(self) -> AuthenticatedClosureSnapshotV2:
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
                for binding, payload in self.files.values()
            )
        )

    def clone_without(self, path: str) -> "EvidenceBuilder":
        clone = EvidenceBuilder()
        clone.files = {
            name: value for name, value in self.files.items() if name != path
        }
        clone.authenticated_executions = deepcopy(
            self.authenticated_executions
        )
        clone.authenticated_writers = deepcopy(self.authenticated_writers)
        clone.locked_profiles = deepcopy(self.locked_profiles)
        return clone


def _trusted_verifier(builder: EvidenceBuilder) -> ControlAuthorizationVerifierV2:
    return ControlAuthorizationVerifierV2(
        control_execution_semantic_verifier=builder.authenticate_execution,
        control_writer_semantic_verifier=builder.authenticate_writer,
        control_execution_producer_identity=_execution_producer_identity(),
        control_writer_producer_identity=_writer_producer_identity(),
    )


class RankedControlFixture:
    RUN_ID = "control-authorization-fixture"
    BANK = _digest("shared-bank")
    DEGRADATION = _digest("degradation-policy")

    def __init__(
        self,
        builder: EvidenceBuilder,
        *,
        family: str,
        admission: TypedArtifactBindingV2,
        forged_summary: bool = False,
        noncanonical_winner: bool = False,
    ) -> None:
        self.builder = builder
        self.family = family
        self.admission = admission
        self.target_frames: dict[tuple[str, int], PlanarFrame] = {}
        self.target_bindings: dict[
            tuple[str, int], TypedArtifactBindingV2
        ] = {}
        self.development_matrix = self._matrix("development")
        self.matrix = self._matrix("validation")
        self.development_matrix_sha256 = hashlib.sha256(
            canonical_json_bytes_v2(self.development_matrix)
        ).hexdigest()
        self.matrix_sha256 = hashlib.sha256(
            canonical_json_bytes_v2(self.matrix)
        ).hexdigest()
        self.ids = (
            tuple(range(16))
            if family == "best_fixed"
            else (
                "bilinear-separable-v1",
                "keys-cubic-a-minus-0.5-separable-v1",
                "lanczos3-separable-v1",
            )
        )
        self.kind = (
            FIXED_SELECTION_KIND
            if family == "best_fixed"
            else CONVENTIONAL_SELECTION_KIND
        )
        self.id_field = (
            "descriptor_id" if family == "best_fixed" else "algorithm_id"
        )
        self.dev_results = self._results(
            "development",
            forged_summary=forged_summary,
            tie_first_two=noncanonical_winner,
        )
        self.validation_results = self._results(
            "validation",
            forged_summary=False,
            tie_first_two=noncanonical_winner,
        )
        self.development_binding, self.development = self._development(
            chosen_override=(self.ids[1] if noncanonical_winner else None)
        )
        self.final_binding, self.final = self._final(
            chosen_override=(self.ids[1] if noncanonical_winner else None)
        )

    def _matrix(self, split: str) -> list[dict[str, object]]:
        values = []
        output_schema = schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND)
        for source_index, route in enumerate(("direct-2x", "direct-3over2")):
            source_id = f"{split}-source-{source_index}"
            family_id = f"{split}-family-{source_index}"
            categories = ["natural", f"route-{source_index}"]
            target_frame = self._target_frame(source_index, split=split)
            target_payload = canonical_control_measurement_frame_bytes_v2(
                target_frame
            )
            target_binding = self.builder.add_or_reuse_bytes(
                artifact_kind=CONTROL_TARGET_FRAME_BYTES_KIND,
                schema_sha256=output_schema,
                path=f"targets/{_digest(f'{split}:source:{source_index}')}.bin",
                payload=target_payload,
            )
            self.target_frames[(split, source_index)] = target_frame
            self.target_bindings[(split, source_index)] = target_binding
            source_record = {
                "schema_version": "2.0.0",
                "artifact_kind": control.CONTROL_SOURCE_TARGET_PROVENANCE_KIND,
                "source_asset_id": source_id,
                "source_family_id": family_id,
                "categories": categories,
                "target_route": route,
                "target_frame": _binding_document(target_binding),
                "target_frame_sha256": frame_sha256(target_frame),
            }
            source_payload = canonical_json_bytes_v2(source_record)
            source_binding = self.builder.add_or_reuse_bytes(
                artifact_kind=control.CONTROL_SOURCE_TARGET_PROVENANCE_KIND,
                schema_sha256=output_schema,
                path=(
                    f"source-provenance/{_digest(f'{split}:{source_index}')}.json"
                ),
                payload=source_payload,
            )
            for profile_index in range(3):
                profile_id = f"profile-{profile_index}"
                profile_definition = {
                    "id": profile_id,
                    "target_route": route,
                    "kind": "fixture_locked_degradation",
                    "fixture_operator": "locked-box-decimation-v1",
                    "profile_index": profile_index,
                }
                profile_record = {
                    "schema_version": "2.0.0",
                    "artifact_kind": control.CONTROL_DEGRADATION_PROFILE_KIND,
                    "degradation_policy_sha256": self.DEGRADATION,
                    "degradation_profile_id": profile_id,
                    "profile_definition": profile_definition,
                }
                profile_payload = canonical_json_bytes_v2(profile_record)
                profile_binding = self.builder.add_or_reuse_bytes(
                    artifact_kind=control.CONTROL_DEGRADATION_PROFILE_KIND,
                    schema_sha256=output_schema,
                    path=(
                        "profiles/"
                        f"{_digest(f'{split}:{source_index}:{profile_index}')}.json"
                    ),
                    payload=profile_payload,
                )
                self.builder.locked_profiles[profile_binding.sha256] = (
                    deepcopy(profile_record)
                )
                values.append(
                    {
                        "source_asset_id": source_id,
                        "source_family_id": family_id,
                        "categories": categories,
                        "target_route": route,
                        "degradation_profile_id": profile_id,
                        "degradation_profile_sha256": hashlib.sha256(
                            canonical_json_bytes_v2(profile_definition)
                        ).hexdigest(),
                        "source_target_provenance": _binding_document(
                            source_binding
                        ),
                        "degradation_profile": _binding_document(
                            profile_binding
                        ),
                    }
                )
        return values

    @staticmethod
    def _score(identifier: object) -> float:
        if type(identifier) is int:
            return 100.0 - identifier
        return {
            "bilinear-separable-v1": 100.0,
            "keys-cubic-a-minus-0.5-separable-v1": 99.0,
            "lanczos3-separable-v1": 98.0,
        }[identifier]

    def _configuration(self, identifier: object) -> str:
        if self.family == "best_fixed":
            return fixed_control_configuration_sha256_v2(
                identifier,
                self.BANK,
            )
        return conventional_control_configuration_sha256_v2(
            identifier,
            self.BANK,
        )

    def _control_request(self, identifier: object) -> Mapping[str, object]:
        if self.family == "best_fixed":
            return fixed_control_request(identifier, self.BANK)
        return conventional_control_request(identifier, self.BANK)

    @staticmethod
    def _target_frame(identity_index: int, *, split: str) -> PlanarFrame:
        y_index, x_index = np.indices((32, 32), dtype=np.float64)
        split_offset = 0.002 if split == "validation" else 0.0
        identity_offset = identity_index * 0.0002
        y = (
            0.25
            + 0.5 * ((x_index + 2.0 * y_index) % 31.0) / 30.0
            + split_offset
            + identity_offset
        )
        cb = (
            0.08 * np.sin((x_index + identity_index) / 5.0)
            + split_offset
        )
        cr = (
            0.08 * np.cos((y_index + identity_index) / 6.0)
            - split_offset
        )
        return PlanarFrame(y=y, cb=cb, cr=cr)

    @staticmethod
    def _output_frame(
        target: PlanarFrame,
        *,
        score: float,
        identity_index: int,
        decoded: bool,
    ) -> PlanarFrame:
        y_index, x_index = np.indices(target.y.shape, dtype=np.float64)
        amplitude = 0.0015 + (100.0 - score) * 0.00055
        pattern = (
            ((3.0 * x_index + 5.0 * y_index + identity_index) % 11.0)
            - 5.0
        ) / 5.0
        cb_pattern = np.roll(pattern, identity_index + 1, axis=0)
        cr_pattern = np.roll(pattern, identity_index + 1, axis=1)
        writer_scale = 0.0003 if decoded else 0.0
        writer_pattern = (
            ((x_index + 7.0 * y_index + identity_index) % 9.0) - 4.0
        ) / 4.0
        return PlanarFrame(
            y=target.y + amplitude * pattern + writer_scale * writer_pattern,
            cb=(
                target.cb
                + 0.8 * amplitude * cb_pattern
                + 0.5 * writer_scale * writer_pattern
            ),
            cr=(
                target.cr
                + 0.7 * amplitude * cr_pattern
                - 0.4 * writer_scale * writer_pattern
            ),
        )

    @staticmethod
    def _low_resolution_frame(
        target: PlanarFrame,
        *,
        profile_index: int,
    ) -> PlanarFrame:
        offset = (profile_index - 1) * 0.0004
        return PlanarFrame(
            y=target.y[::2, ::2] + offset,
            cb=target.cb[::2, ::2] + 0.5 * offset,
            cr=target.cr[::2, ::2] - 0.5 * offset,
        )

    def _aggregate(
        self,
        split: str,
        identifier: object,
        *,
        score: float,
        forge_summary: bool,
    ) -> tuple[TypedArtifactBindingV2, TypedArtifactBindingV2, list[float]]:
        configuration = self._configuration(identifier)
        matrix = (
            self.development_matrix
            if split == "development"
            else self.matrix
        )
        matrix_sha256 = (
            self.development_matrix_sha256
            if split == "development"
            else self.matrix_sha256
        )
        rows = []
        raw_metric_rows = []
        raw_y_psnr_by_index: dict[int, float] = {}
        raw_execution_by_index: dict[int, TypedArtifactBindingV2] = {}
        input_binding_by_index: dict[int, TypedArtifactBindingV2] = {}
        raw_output_by_index: dict[int, TypedArtifactBindingV2] = {}
        raw_output_frame_sha_by_index: dict[int, str] = {}
        output_schema = schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND)
        control_request = self._control_request(identifier)
        for domain in ("engine_raw", "container_decoded"):
            for index, identity in enumerate(matrix):
                label = f"{self.family}:{split}:{identifier}:{domain}:{index}"
                source_index = index // 3
                profile_index = index % 3
                target_frame = self.target_frames[(split, source_index)]
                output_frame = self._output_frame(
                    target_frame,
                    score=score,
                    identity_index=index,
                    decoded=domain == "container_decoded",
                )
                target = self.target_bindings[(split, source_index)]
                input_frame = self._low_resolution_frame(
                    target_frame,
                    profile_index=profile_index,
                )
                input_payload = canonical_control_measurement_frame_bytes_v2(
                    input_frame
                )
                input_binding = self.builder.add_or_reuse_bytes(
                    artifact_kind=control.CONTROL_LOW_RESOLUTION_INPUT_BYTES_KIND,
                    schema_sha256=output_schema,
                    path=f"inputs/{_digest(f'{split}:input:{index}')}.bin",
                    payload=input_payload,
                )
                output_payload = canonical_control_measurement_frame_bytes_v2(
                    output_frame
                )
                output = self.builder.add_or_reuse_bytes(
                    artifact_kind=CONTROL_OUTPUT_BYTES_KIND,
                    schema_sha256=output_schema,
                    path=f"payloads/{_digest(label)}.bin",
                    payload=output_payload,
                )
                metrics = dict(
                    corpus_metric_bundle(target_frame, output_frame)
                )
                writer = None
                if domain == "container_decoded":
                    metrics["writer_y_psnr_contribution_db"] = (
                        float(metrics["y_psnr_db"])
                        - raw_y_psnr_by_index[index]
                    )
                    writer_label = f"writer:{label}"
                    encoded_payload = (
                        b"fixture-encoded-container-v2\0"
                        + writer_label.encode("utf-8")
                    )
                    encoded_container = self.builder.add_bytes(
                        artifact_kind=(
                            CONTROL_WRITER_ENCODED_CONTAINER_BYTES_KIND
                        ),
                        schema_sha256=output_schema,
                        path=f"writer/encoded-{_digest(writer_label)}.bin",
                        payload=encoded_payload,
                    )
                    report_payload = canonical_json_bytes_v2(
                        {
                            "artifact_kind": "fixture_writer_report_v2",
                            "control_key": control_request["control_key"],
                            "encoded_sha256": encoded_container.sha256,
                            "decoded_frame_sha256": frame_sha256(
                                output_frame
                            ),
                            "target_route": identity["target_route"],
                        }
                    )
                    writer_report = self.builder.add_bytes(
                        artifact_kind=CONTROL_WRITER_REPORT_BYTES_KIND,
                        schema_sha256=output_schema,
                        path=f"writer/report-{_digest(writer_label)}.json",
                        payload=report_payload,
                    )
                    decoded_writer_payload = (
                        b"fixture-decoded-writer-payload-v2\0"
                        + writer_label.encode("utf-8")
                    )
                    decoded_payload = self.builder.add_bytes(
                        artifact_kind=(
                            CONTROL_WRITER_DECODED_PAYLOAD_BYTES_KIND
                        ),
                        schema_sha256=output_schema,
                        path=(
                            "writer/decoded-payload-"
                            f"{_digest(writer_label)}.bin"
                        ),
                        payload=decoded_writer_payload,
                    )
                    writer_settings_sha256 = hashlib.sha256(
                        canonical_json_bytes_v2(_FIXTURE_WRITER_SETTINGS)
                    ).hexdigest()
                    native_writer_record = {
                        "schema_version": "1.0.0",
                        "artifact_kind": (
                            "p06_isolated_production_writer_evidence"
                        ),
                        "control_key": control_request["control_key"],
                        "input_frame_sha256": (
                            raw_output_frame_sha_by_index[index]
                        ),
                        "decoded_frame_sha256": frame_sha256(output_frame),
                        "settings_sha256": writer_settings_sha256,
                        "encoded_sha256": encoded_container.sha256,
                        "report_sha256": writer_report.sha256,
                        "decoded_payload_sha256": decoded_payload.sha256,
                        "comparison_domain": "container_decoded",
                        "target_route": identity["target_route"],
                        "reopened_and_verified": True,
                    }
                    writer_document = {
                        "schema_version": "2.0.0",
                        "artifact_kind": CONTROL_WRITER_EVIDENCE_BYTES_KIND,
                        "source_profile_identity_sha256": hashlib.sha256(
                            canonical_json_bytes_v2(identity)
                        ).hexdigest(),
                        "target_route": identity["target_route"],
                        "control_key": control_request["control_key"],
                        "raw_output": _binding_document(
                            raw_output_by_index[index]
                        ),
                        "raw_output_frame_sha256": (
                            raw_output_frame_sha_by_index[index]
                        ),
                        "decoded_output": _binding_document(output),
                        "decoded_output_frame_sha256": frame_sha256(
                            output_frame
                        ),
                        "writer_settings": deepcopy(
                            _FIXTURE_WRITER_SETTINGS
                        ),
                        "writer_settings_sha256": (
                            writer_settings_sha256
                        ),
                        "authenticated_writer_identity": deepcopy(
                            _FIXTURE_WRITER_IDENTITY
                        ),
                        "encoded_container": _binding_document(
                            encoded_container
                        ),
                        "encoded_container_sha256": (
                            encoded_container.sha256
                        ),
                        "writer_report": _binding_document(writer_report),
                        "writer_report_sha256": writer_report.sha256,
                        "decoded_payload": _binding_document(
                            decoded_payload
                        ),
                        "decoded_payload_sha256": decoded_payload.sha256,
                        "native_writer_round_trip_record": (
                            native_writer_record
                        ),
                        "native_writer_round_trip_record_sha256": (
                            hashlib.sha256(
                                canonical_json_bytes_v2(
                                    native_writer_record
                                )
                            ).hexdigest()
                        ),
                    }
                    writer = self.builder.add_authenticated_writer(
                        writer_document,
                        label=_digest(writer_label),
                    )
                else:
                    raw_y_psnr_by_index[index] = float(metrics["y_psnr_db"])
                    native_record = {
                        "control_key": control_request["control_key"],
                        "control_mode": control_request["control_mode"],
                        "request_sha256": control_request["request_sha256"],
                        "configuration_sha256": configuration,
                        "shared_bank_configuration_sha256": self.BANK,
                        "input_frame_sha256": frame_sha256(input_frame),
                        "output_frame_sha256": frame_sha256(output_frame),
                        "target_route": identity["target_route"],
                        "parameters": deepcopy(control_request["parameters"]),
                        "parameters_sha256": hashlib.sha256(
                            canonical_json_bytes_v2(
                                control_request["parameters"]
                            )
                        ).hexdigest(),
                        "native_invocation_id": _digest(
                            f"native:{label}"
                        ),
                    }
                    native_record["record_sha256"] = hashlib.sha256(
                        canonical_json_bytes_v2(native_record)
                    ).hexdigest()
                    execution_document = {
                        "schema_version": "2.0.0",
                        "artifact_kind": (
                            control.CONTROL_EXECUTION_PROVENANCE_KIND
                        ),
                        "source_profile_identity_sha256": hashlib.sha256(
                            canonical_json_bytes_v2(identity)
                        ).hexdigest(),
                        "source_target_provenance": deepcopy(
                            identity["source_target_provenance"]
                        ),
                        "degradation_profile": deepcopy(
                            identity["degradation_profile"]
                        ),
                        "low_resolution_input": _binding_document(
                            input_binding
                        ),
                        "input_frame_sha256": frame_sha256(input_frame),
                        "control_request": deepcopy(control_request),
                        "output": _binding_document(output),
                        "output_frame_sha256": frame_sha256(output_frame),
                        "authenticated_adapter_identity": deepcopy(
                            _FIXTURE_ADAPTER_IDENTITY
                        ),
                        "native_execution_record": native_record,
                    }
                    execution = self.builder.add_authenticated_execution(
                        execution_document,
                        label=_digest(f"execution:{label}"),
                    )
                    raw_execution_by_index[index] = execution
                    input_binding_by_index[index] = input_binding
                    raw_output_by_index[index] = output
                    raw_output_frame_sha_by_index[index] = frame_sha256(
                        output_frame
                    )
                if domain == "container_decoded":
                    execution = raw_execution_by_index[index]
                    input_binding = input_binding_by_index[index]
                measurement = {
                    "artifact_kind": CONTROL_MEASUREMENT_EVIDENCE_KIND,
                    "metric_algorithm": control.CONTROL_METRIC_ALGORITHM,
                    "frame_encoding": CONTROL_MEASUREMENT_FRAME_ENCODING_V2,
                    "source_profile_identity_sha256": hashlib.sha256(
                        canonical_json_bytes_v2(identity)
                    ).hexdigest(),
                    "source_target_provenance": deepcopy(
                        identity["source_target_provenance"]
                    ),
                    "degradation_profile": deepcopy(
                        identity["degradation_profile"]
                    ),
                    "low_resolution_input": _binding_document(input_binding),
                    "input_frame_sha256": frame_sha256(input_frame),
                    "control_execution": _binding_document(execution),
                    "target": _binding_document(target),
                    "target_frame_sha256": frame_sha256(target_frame),
                    "output": _binding_document(output),
                    "output_frame_sha256": frame_sha256(output_frame),
                    "metrics": metrics,
                    "writer_evidence": (
                        None if writer is None else _binding_document(writer)
                    ),
                }
                rows.append(
                    {
                        **deepcopy(identity),
                        "degradation_policy_sha256": self.DEGRADATION,
                        "comparison_domain": domain,
                        "measurement_evidence": measurement,
                        "control_configuration_sha256": configuration,
                        "shared_bank_configuration_sha256": self.BANK,
                    }
                )
                if domain == "engine_raw":
                    raw_metric_rows.append(
                        {
                            "source_asset_id": identity["source_asset_id"],
                            "metrics": metrics,
                        }
                    )
        source_order = list(
            dict.fromkeys(identity["source_asset_id"] for identity in matrix)
        )
        per_source_means, objective_tuple = hierarchical_control_objective_v2(
            raw_metric_rows,
            source_order,
        )
        manifest = {
            "schema_version": "2.0.0",
            "artifact_kind": OUTPUT_MANIFEST_KIND,
            "authority_bindings": authority_bindings_v2(),
            "run_id": self.RUN_ID,
            "split": split,
            "control_family": self.family,
            "stable_id": identifier,
            "uniform_application": True,
            "shared_bank_configuration_sha256": self.BANK,
            "degradation_policy_sha256": self.DEGRADATION,
            "control_configuration_sha256": configuration,
            "source_profile_matrix_sha256": matrix_sha256,
            "source_profile_matrix": deepcopy(matrix),
            "source_order": source_order,
            "comparison_domains": ["engine_raw", "container_decoded"],
            "rows": rows,
            "artifact_sha256": _digest("placeholder"),
        }
        manifest_binding, _ = self.builder.add_new_document(
            manifest,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label=f"manifest-{self.family}-{split}-{identifier}",
        )
        objective = list(objective_tuple)
        recorded = list(objective)
        if forge_summary:
            recorded[0] += 1.0
        summary = {
            "schema_version": "2.0.0",
            "artifact_kind": OBJECTIVE_SUMMARY_KIND,
            "authority_bindings": authority_bindings_v2(),
            "run_id": self.RUN_ID,
            "split": split,
            "control_family": self.family,
            "stable_id": identifier,
            "comparison_domain": "engine_raw",
            "metric_order": list(control.SELECTION_METRICS),
            "profiles_per_source": 3,
            "source_count": 2,
            "per_source_means": list(per_source_means),
            "means": list(recorded),
            "selection_tuple": control.SELECTION_TUPLE_DESCRIPTION,
            "shared_bank_configuration_sha256": self.BANK,
            "degradation_policy_sha256": self.DEGRADATION,
            "control_configuration_sha256": configuration,
            "source_profile_matrix_sha256": matrix_sha256,
            "artifact_sha256": _digest("placeholder"),
        }
        summary_binding, _ = self.builder.add_new_document(
            summary,
            artifact_kind=OBJECTIVE_SUMMARY_KIND,
            label=f"summary-{self.family}-{split}-{identifier}",
        )
        return summary_binding, manifest_binding, recorded

    def _results(
        self,
        split: str,
        *,
        forged_summary: bool,
        tie_first_two: bool,
    ) -> list[dict[str, object]]:
        rows = []
        for index, identifier in enumerate(self.ids):
            score = self._score(identifier)
            if tie_first_two and index == 1:
                score = self._score(self.ids[0])
            summary, manifest, objective = self._aggregate(
                split,
                identifier,
                score=score,
                forge_summary=forged_summary and index == 0,
            )
            rows.append(
                {
                    self.id_field: identifier,
                    "control_configuration_sha256": self._configuration(
                        identifier
                    ),
                    "engine_raw_corpus_mean_tuple": objective,
                    "objective_summary": _binding_document(summary),
                    "output_manifest": _binding_document(manifest),
                }
            )
        return rows

    def _development(
        self,
        *,
        chosen_override: object | None,
    ) -> tuple[TypedArtifactBindingV2, dict[str, object]]:
        fixed = self.family == "best_fixed"
        selected = self.ids[0] if chosen_override is None else chosen_override
        document = {
            "schema_version": "2.0.0",
            "artifact_kind": self.kind,
            "authority_bindings": authority_bindings_v2(),
            "run_id": self.RUN_ID,
            "selection_stage": "development_provisional",
            "split": "development",
            "shared_bank_configuration_sha256": self.BANK,
            "degradation_policy_sha256": self.DEGRADATION,
            "source_profile_matrix_sha256": (
                self.development_matrix_sha256
            ),
            "uniform_application": True,
            "candidate_ids": list(self.ids),
            "selection_objective": deepcopy(control.SELECTION_OBJECTIVE),
            "development_results": deepcopy(self.dev_results),
            (
                "provisional_descriptor_id"
                if fixed
                else "provisional_algorithm_id"
            ): selected,
            "tie_break": (
                "lexicographically maximize the development engine_raw "
                "corpus-mean tuple, then choose the numerically smallest "
                "descriptor ID"
                if fixed
                else "lexicographically maximize the development engine_raw "
                "corpus-mean tuple, then choose the lexicographically "
                "ascending stable algorithm ID"
            ),
            "data_access": {
                "development_metrics_accessed": True,
                "validation_accessed": False,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": _digest("placeholder"),
        }
        return self.builder.add_new_document(
            document,
            artifact_kind=self.kind,
            label=f"selection-{self.family}-development",
        )

    def _final(
        self,
        *,
        chosen_override: object | None,
    ) -> tuple[TypedArtifactBindingV2, dict[str, object]]:
        fixed = self.family == "best_fixed"
        selected = self.ids[0] if chosen_override is None else chosen_override
        document = {
            "schema_version": "2.0.0",
            "artifact_kind": self.kind,
            "authority_bindings": authority_bindings_v2(),
            "run_id": self.RUN_ID,
            "selection_stage": "validation_final",
            "split": "validation",
            "shared_bank_configuration_sha256": self.BANK,
            "degradation_policy_sha256": self.DEGRADATION,
            "source_profile_matrix_sha256": self.matrix_sha256,
            "uniform_application": True,
            "candidate_ids": list(self.ids),
            "selection_objective": deepcopy(control.SELECTION_OBJECTIVE),
            "development_selection": _binding_document(
                self.development_binding
            ),
            "validation_admission": _binding_document(self.admission),
            "validation_results": deepcopy(self.validation_results),
            "chosen_descriptor_id" if fixed else "chosen_algorithm_id": selected,
            "tie_break": (
                "lexicographically maximize the validation engine_raw "
                "corpus-mean tuple, then choose the numerically smallest "
                "descriptor ID"
                if fixed
                else "lexicographically maximize the validation engine_raw "
                "corpus-mean tuple, then choose the lexicographically "
                "ascending stable algorithm ID"
            ),
            "data_access": {
                "development_metrics_accessed": True,
                "validation_accessed": True,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": _digest("placeholder"),
        }
        return self.builder.add_new_document(
            document,
            artifact_kind=self.kind,
            label=f"selection-{self.family}-validation",
        )

    def scope(self) -> ControlAuthorizationScopeV2:
        return ControlAuthorizationScopeV2(
            run_id=self.RUN_ID,
            split="validation",
            shared_bank_configuration_sha256=self.BANK,
            degradation_policy_sha256=self.DEGRADATION,
            source_profile_matrix_sha256=self.matrix_sha256,
            development_source_profile_matrix_sha256=(
                self.development_matrix_sha256
            ),
            validation_admission=self.admission,
        )


class ControlAuthorizationV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        fixture_module = importlib.import_module(
            "validation.calibration_v2.tests."
            "test_non_ash_selector_artifacts_v2"
        )
        cls.non_ash_fixture = getattr(
            fixture_module,
            "NonAshSelectorArtifactV2Tests",
        )
        cls.non_ash_fixture.setUpClass()

        cls.builder = EvidenceBuilder()
        cls.admission = cls.builder.add_bytes(
            artifact_kind=VALIDATION_ADMISSION_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
            path="admission/validation-admission.json",
            payload=b'{"admission":"fixture"}\n',
        )
        cls.fixed = RankedControlFixture(
            cls.builder,
            family="best_fixed",
            admission=cls.admission,
        )
        cls.conventional = RankedControlFixture(
            cls.builder,
            family="conventional",
            admission=cls.admission,
        )
        if cls.fixed.matrix_sha256 != cls.conventional.matrix_sha256:
            raise AssertionError("ranked fixture matrix identities differ")

    def test_schemas_are_canonical_valid_and_bound_to_exact_six_authorities(
        self,
    ) -> None:
        expected_authorities = authority_bindings_v2()
        self.assertEqual(
            tuple(expected_authorities),
            (
                "baseline_ablation_budget_v2",
                "calibration_plan_v2",
                "candidate_evidence_policy_v2",
                "compiler_contract_v2",
                "control_execution_producer_identity_v2",
                "shared_bank_configuration_identity_v2",
            ),
        )
        self.assertEqual(
            expected_authorities["candidate_evidence_policy_v2"],
            {
                "file_sha256": (
                    "d6df835467485f59b253e12d8e80cb8c8fa21dd308566ab3634495ccc8604433"
                ),
                "schema_file_sha256": (
                    "581a3bb6ba0ec3ea288076685124a9e7fd332aa883ee2165f18a27a4fb1c249e"
                ),
                "self_sha256": (
                    "70860c19f36efe41401e16381c80d6102b37f683056b2e3210a67e9d0b66dc75"
                ),
            },
        )
        self.assertEqual(
            expected_authorities["compiler_contract_v2"],
            {
                "file_sha256": (
                    "8c2f532ff126fd5517040a05c9f8669d2a83d1d7220f61fed5933d5fa470470a"
                ),
                "schema_file_sha256": (
                    "5f7a49e1f585e4f0e108e733ae3c6f28b47869b3cc2909419688714e76f57897"
                ),
                "self_sha256": (
                    "797d6fda359a6bfaca9487a31b0078a5eba8e41fdb6fd0985390e20c25df8237"
                ),
            },
        )
        self.assertEqual(
            expected_authorities["control_execution_producer_identity_v2"],
            {
                "file_sha256": (
                    "9de7970c089e3ef6627a81c5e8a23c29e3ca7567b8d868058de52108b53a5363"
                ),
                "schema_file_sha256": (
                    "99032fc9490d5b41f2e9793ab99fb8d9cda2b5d6cd0ff7f9b367c6f4b2d96c46"
                ),
                "self_sha256": (
                    "dc76d231d0b90a663153678b5651da9eead185eee622897c89e30951603f40f5"
                ),
            },
        )
        for name in NEW_SCHEMA_NAMES:
            with self.subTest(schema=name):
                path = SCHEMA_ROOT / name
                payload = path.read_bytes()
                schema = json.loads(payload)
                Draft202012Validator.check_schema(schema)
                self.assertEqual(
                    payload,
                    canonical_json_file_bytes_v2(schema),
                )
                self.assertEqual(
                    hashlib.sha256(payload).hexdigest(),
                    EXPECTED_SCHEMA_DIGESTS[name],
                )
                if "authorityBindings" in schema.get("$defs", {}):
                    self.assertEqual(
                        schema["$defs"]["authorityBindings"]["const"],
                        expected_authorities,
                    )

    def test_producer_identity_authority_reopens_contract_schema_and_self(
        self,
    ) -> None:
        identity = _execution_producer_identity()
        ControlAuthorizationVerifierV2(
            control_execution_producer_identity=identity,
        )
        authority_id = "control_execution_producer_identity_v2"
        spec = control._AUTHORITY_SPECS[authority_id]
        original_reader = control._read_regular_file

        for target_key in ("path", "schema_path"):
            target = Path(spec[target_key])

            def drift_reader(path, *, label, target=target):
                payload = original_reader(path, label=label)
                if Path(path) == target:
                    return bytes([payload[0] ^ 1]) + payload[1:]
                return payload

            with self.subTest(target=target_key), patch.object(
                control,
                "_read_regular_file",
                side_effect=drift_reader,
            ), self.assertRaisesRegex(
                ControlAuthorizationV2Error,
                "byte identity differs",
            ):
                ControlAuthorizationVerifierV2(
                    control_execution_producer_identity=identity,
                )

        contract_payload = original_reader(
            spec["path"],
            label=f"authority {authority_id}",
        )
        self_drift = json.loads(contract_payload)
        self_drift["artifact_sha256"] = _digest("producer-self-drift")
        self_drift_payload = canonical_json_file_bytes_v2(self_drift)
        schema_payload = original_reader(
            spec["schema_path"],
            label=f"authority schema {authority_id}",
        )
        self_drift_schema = json.loads(schema_payload)
        self_drift_schema["const"] = self_drift
        self_drift_schema_payload = canonical_json_file_bytes_v2(
            self_drift_schema
        )

        def self_drift_reader(path, *, label):
            if Path(path) == Path(spec["path"]):
                return self_drift_payload
            if Path(path) == Path(spec["schema_path"]):
                return self_drift_schema_payload
            return original_reader(path, label=label)

        with patch.dict(
            spec,
            {
                "file_sha256": hashlib.sha256(
                    self_drift_payload
                ).hexdigest(),
                "schema_file_sha256": hashlib.sha256(
                    self_drift_schema_payload
                ).hexdigest(),
            },
        ), patch.object(
            control,
            "_read_regular_file",
            side_effect=self_drift_reader,
        ), self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "self identity differs",
        ):
            ControlAuthorizationVerifierV2(
                control_execution_producer_identity=identity,
            )

    def test_typed_binding_and_dependency_set_reject_aliases_and_reordering(
        self,
    ) -> None:
        binding = TypedArtifactBindingV2(
            artifact_kind=OBJECTIVE_SUMMARY_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                OBJECTIVE_SUMMARY_KIND
            ),
            path="documents/objective.json",
            sha256=_digest("objective"),
            size_bytes=1,
        )
        self.assertEqual(
            dependency_set_sha256_v2([binding]),
            dependency_set_sha256_v2((binding,)),
        )
        second = TypedArtifactBindingV2(
            artifact_kind=OUTPUT_MANIFEST_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path="documents/output.json",
            sha256=_digest("output"),
            size_bytes=1,
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "sorted and unique",
        ):
            dependency_set_sha256_v2([second, binding])
        with self.assertRaises(ControlAuthorizationV2Error):
            TypedArtifactBindingV2(
                artifact_kind="p06_bad_v1",
                schema_sha256=binding.schema_sha256,
                path="../escape.json",
                sha256=binding.sha256,
                size_bytes=1,
            )

    def test_fixed_and_conventional_replay_every_aggregate_row_dependency(
        self,
    ) -> None:
        snapshot = self.builder.snapshot()
        dependencies = self.builder.dependencies()
        verifier = _trusted_verifier(self.builder)
        fixed_resolver = control._SnapshotResolverV2(snapshot, dependencies)
        fixed = verifier._verify_ranked_control(
            binding=self.fixed.final_binding,
            family="best_fixed",
            resolver=fixed_resolver,
            scope=self.fixed.scope(),
        )
        self.assertEqual(fixed["chosen_descriptor_id"], 0)
        first_output = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["output_manifest"]
        )
        self.assertIn(first_output, fixed_resolver.expected)
        output_document = json.loads(
            self.builder.files[first_output.path][1]
        )
        first_payload = TypedArtifactBindingV2.from_document(
            output_document["rows"][0]["measurement_evidence"]["output"]
        )
        self.assertIn(first_payload, fixed_resolver.expected)

        conventional_resolver = control._SnapshotResolverV2(
            snapshot,
            dependencies,
        )
        conventional = verifier._verify_ranked_control(
            binding=self.conventional.final_binding,
            family="conventional",
            resolver=conventional_resolver,
            scope=self.conventional.scope(),
        )
        self.assertEqual(
            conventional["chosen_algorithm_id"],
            "bilinear-separable-v1",
        )

    def test_ranked_configuration_hashes_are_derived_from_production_semantics(
        self,
    ) -> None:
        self.assertEqual(
            self.fixed._configuration(0),
            "b045f920bc3ae9f73b6c7966bb46945e0ca9c68b5c231c8f709ec2695d629944",
        )
        self.assertEqual(
            self.fixed._configuration(15),
            "d8eb05797495c8bde88a80fa84796b2dd457d2a427744a2c3c69961214a34dd5",
        )
        self.assertEqual(
            self.conventional._configuration("bilinear-separable-v1"),
            "296cab585c270bd5d9105075eb224b49974439dd41d1e84eef27bffbc44bff91",
        )
        self.assertEqual(
            self.conventional._configuration(
                "keys-cubic-a-minus-0.5-separable-v1"
            ),
            "ed62bd2f2b7b05058112cfb920a4f0aea62cc26c14e8b3694d670b3513d94977",
        )
        self.assertEqual(
            self.conventional._configuration("lanczos3-separable-v1"),
            "0f6a1a5c26281c6b6ff6687e624f3fa040e0319bc22cc9f40fabf864eead9fa4",
        )

        forged_builder = EvidenceBuilder()
        forged_builder.files = dict(self.builder.files)
        forged_builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        forged_builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        forged_builder.locked_profiles = deepcopy(self.builder.locked_profiles)
        forged_selection = deepcopy(self.fixed.final)
        forged_selection["validation_results"][0][
            "control_configuration_sha256"
        ] = _digest("self-consistent-but-nonproduction-configuration")
        forged_binding, _ = forged_builder.add_new_document(
            forged_selection,
            artifact_kind=FIXED_SELECTION_KIND,
            label="nonproduction-fixed-configuration",
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "differs from production request semantics",
        ):
            _trusted_verifier(forged_builder)._verify_ranked_control(
                binding=forged_binding,
                family="best_fixed",
                resolver=control._SnapshotResolverV2(
                    forged_builder.snapshot(),
                    forged_builder.dependencies(),
                ),
                scope=self.fixed.scope(),
            )

    def test_control_metric_replay_rejects_arbitrary_output_bytes(self) -> None:
        first_output_manifest = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["output_manifest"]
        )
        output_document = json.loads(
            self.builder.files[first_output_manifest.path][1]
        )
        forged_builder = EvidenceBuilder()
        forged_builder.files = dict(self.builder.files)
        forged_builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        forged_builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        forged_builder.locked_profiles = deepcopy(self.builder.locked_profiles)
        ascii_output = forged_builder.add_bytes(
            artifact_kind=CONTROL_OUTPUT_BYTES_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                OUTPUT_MANIFEST_KIND
            ),
            path="payloads/arbitrary-ascii-output.bin",
            payload=b"output:best_fixed:validation:0:engine_raw:0\n",
        )
        forged_document = deepcopy(output_document)
        forged_document["rows"][0]["measurement_evidence"][
            "output"
        ] = _binding_document(ascii_output)
        forged_manifest, _ = forged_builder.add_new_document(
            forged_document,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="arbitrary-ascii-output-manifest",
        )
        objective_summary = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["objective_summary"]
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "frame evidence is invalid",
        ):
            _trusted_verifier(forged_builder)._aggregate_from_bindings(
                objective_binding=objective_summary,
                output_binding=forged_manifest,
                resolver=control._SnapshotResolverV2(
                    forged_builder.snapshot(),
                    forged_builder.dependencies(),
                ),
                scope=self.fixed.scope(),
                expected_family="best_fixed",
                expected_split="validation",
                expected_stable_id=0,
                expected_control_configuration_sha256=(
                    self.fixed._configuration(0)
                ),
                expected_control_request=self.fixed._control_request(0),
            )

    def test_raw_only_selection_manifest_accepts_no_writer_capability(
        self,
    ) -> None:
        base_binding = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["output_manifest"]
        )
        base_document = json.loads(self.builder.files[base_binding.path][1])
        raw_only = deepcopy(base_document)
        raw_only["comparison_domains"] = ["engine_raw"]
        raw_only["rows"] = raw_only["rows"][: len(raw_only["source_profile_matrix"])]
        manifest, _ = self.builder.add_new_document(
            raw_only,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="raw-only-selection-manifest",
        )
        objective = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["objective_summary"]
        )
        verifier = ControlAuthorizationVerifierV2(
            control_execution_semantic_verifier=(
                self.builder.authenticate_execution
            ),
            control_execution_producer_identity=(
                _execution_producer_identity()
            ),
        )
        observed = verifier._aggregate_from_bindings(
            objective_binding=objective,
            output_binding=manifest,
            resolver=control._SnapshotResolverV2(
                self.builder.snapshot(),
                self.builder.dependencies(),
            ),
            scope=self.fixed.scope(),
            expected_family="best_fixed",
            expected_split="validation",
            expected_stable_id=0,
            expected_control_configuration_sha256=(
                self.fixed._configuration(0)
            ),
            expected_control_request=self.fixed._control_request(0),
        )
        self.assertEqual(
            observed,
            tuple(
                self.fixed.final["validation_results"][0][
                    "engine_raw_corpus_mean_tuple"
                ]
            ),
        )

    def test_forged_decoded_output_and_writer_artifacts_fail_closed(
        self,
    ) -> None:
        base_binding = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["output_manifest"]
        )
        base_document = json.loads(self.builder.files[base_binding.path][1])
        objective = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["objective_summary"]
        )
        matrix_count = len(base_document["source_profile_matrix"])
        decoded_index = matrix_count

        perfect_builder = EvidenceBuilder()
        perfect_builder.files = dict(self.builder.files)
        perfect_builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        perfect_builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        perfect_builder.locked_profiles = deepcopy(
            self.builder.locked_profiles
        )
        perfect = deepcopy(base_document)
        perfect_measurement = perfect["rows"][decoded_index][
            "measurement_evidence"
        ]
        target_binding = TypedArtifactBindingV2.from_document(
            perfect_measurement["target"]
        )
        target_payload = perfect_builder.files[target_binding.path][1]
        perfect_output = TypedArtifactBindingV2(
            artifact_kind=CONTROL_OUTPUT_BYTES_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path="payloads/forged-perfect-decoded-output.bin",
            sha256=hashlib.sha256(target_payload).hexdigest(),
            size_bytes=len(target_payload),
        )
        perfect_builder.files[perfect_output.path] = (
            perfect_output,
            target_payload,
        )
        perfect_measurement["output"] = _binding_document(perfect_output)
        perfect_measurement["output_frame_sha256"] = perfect_measurement[
            "target_frame_sha256"
        ]
        perfect_manifest, _ = perfect_builder.add_new_document(
            perfect,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="forged-perfect-decoded-output-manifest",
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "declared dependency binding identities repeat|metric recomputation failed",
        ):
            _trusted_verifier(perfect_builder)._aggregate_from_bindings(
                objective_binding=objective,
                output_binding=perfect_manifest,
                resolver=control._SnapshotResolverV2(
                    perfect_builder.snapshot(),
                    perfect_builder.dependencies(),
                ),
                scope=self.fixed.scope(),
                expected_family="best_fixed",
                expected_split="validation",
                expected_stable_id=0,
                expected_control_configuration_sha256=(
                    self.fixed._configuration(0)
                ),
                expected_control_request=self.fixed._control_request(0),
            )

        builder = EvidenceBuilder()
        builder.files = dict(self.builder.files)
        builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        builder.locked_profiles = deepcopy(self.builder.locked_profiles)
        forged = deepcopy(base_document)
        raw_measurement = forged["rows"][0]["measurement_evidence"]
        decoded_measurement = forged["rows"][decoded_index][
            "measurement_evidence"
        ]
        target = self.fixed.target_frames[("validation", 0)]
        near_perfect = PlanarFrame(
            y=np.nextafter(target.y, np.ones_like(target.y)),
            cb=np.nextafter(target.cb, np.ones_like(target.cb)),
            cr=np.nextafter(target.cr, np.ones_like(target.cr)),
        )
        decoded_payload = canonical_control_measurement_frame_bytes_v2(
            near_perfect
        )
        forged_decoded = builder.add_bytes(
            artifact_kind=CONTROL_OUTPUT_BYTES_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path="payloads/forged-decoded-near-perfect.bin",
            payload=decoded_payload,
        )
        decoded_metrics = dict(corpus_metric_bundle(target, near_perfect))
        decoded_metrics["writer_y_psnr_contribution_db"] = (
            float(decoded_metrics["y_psnr_db"])
            - float(raw_measurement["metrics"]["y_psnr_db"])
        )
        decoded_measurement["output"] = _binding_document(forged_decoded)
        decoded_measurement["output_frame_sha256"] = frame_sha256(
            near_perfect
        )
        decoded_measurement["metrics"] = decoded_metrics
        original_writer = TypedArtifactBindingV2.from_document(
            decoded_measurement["writer_evidence"]
        )
        writer_document = json.loads(builder.files[original_writer.path][1])
        writer_document["decoded_output"] = _binding_document(
            forged_decoded
        )
        writer_document["decoded_output_frame_sha256"] = frame_sha256(
            near_perfect
        )
        native_writer = writer_document[
            "native_writer_round_trip_record"
        ]
        native_writer["decoded_frame_sha256"] = frame_sha256(near_perfect)
        writer_document["native_writer_round_trip_record_sha256"] = (
            hashlib.sha256(
                canonical_json_bytes_v2(native_writer)
            ).hexdigest()
        )
        writer_payload = canonical_json_bytes_v2(writer_document)
        forged_writer = builder.add_bytes(
            artifact_kind=CONTROL_WRITER_EVIDENCE_BYTES_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path="writer/forged-decoded-near-perfect.json",
            payload=writer_payload,
        )
        decoded_measurement["writer_evidence"] = _binding_document(
            forged_writer
        )
        forged_manifest, _ = builder.add_new_document(
            forged,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="forged-decoded-near-perfect-manifest",
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "writer provenance authentication failed",
        ):
            _trusted_verifier(builder)._aggregate_from_bindings(
                objective_binding=objective,
                output_binding=forged_manifest,
                resolver=control._SnapshotResolverV2(
                    builder.snapshot(),
                    builder.dependencies(),
                ),
                scope=self.fixed.scope(),
                expected_family="best_fixed",
                expected_split="validation",
                expected_stable_id=0,
                expected_control_configuration_sha256=(
                    self.fixed._configuration(0)
                ),
                expected_control_request=self.fixed._control_request(0),
            )

        for field, kind, payload in (
            (
                "encoded_container",
                CONTROL_WRITER_ENCODED_CONTAINER_BYTES_KIND,
                b"forged-encoded-container",
            ),
            (
                "writer_report",
                CONTROL_WRITER_REPORT_BYTES_KIND,
                b'{"forged_writer_report":true}',
            ),
        ):
            with self.subTest(field=field):
                artifact_builder = EvidenceBuilder()
                artifact_builder.files = dict(self.builder.files)
                artifact_builder.authenticated_executions = deepcopy(
                    self.builder.authenticated_executions
                )
                artifact_builder.authenticated_writers = deepcopy(
                    self.builder.authenticated_writers
                )
                artifact_builder.locked_profiles = deepcopy(
                    self.builder.locked_profiles
                )
                artifact_manifest = deepcopy(base_document)
                artifact_measurement = artifact_manifest["rows"][
                    decoded_index
                ]["measurement_evidence"]
                writer_binding = TypedArtifactBindingV2.from_document(
                    artifact_measurement["writer_evidence"]
                )
                artifact_writer = json.loads(
                    artifact_builder.files[writer_binding.path][1]
                )
                replacement = artifact_builder.add_bytes(
                    artifact_kind=kind,
                    schema_sha256=schema_sha256_for_kind_v2(
                        OUTPUT_MANIFEST_KIND
                    ),
                    path=f"writer/forged-{field}.bin",
                    payload=payload,
                )
                artifact_writer[field] = _binding_document(replacement)
                artifact_writer[f"{field}_sha256"] = replacement.sha256
                native = artifact_writer[
                    "native_writer_round_trip_record"
                ]
                native[
                    "encoded_sha256"
                    if field == "encoded_container"
                    else "report_sha256"
                ] = replacement.sha256
                artifact_writer[
                    "native_writer_round_trip_record_sha256"
                ] = hashlib.sha256(
                    canonical_json_bytes_v2(native)
                ).hexdigest()
                artifact_payload = canonical_json_bytes_v2(
                    artifact_writer
                )
                replacement_writer = artifact_builder.add_bytes(
                    artifact_kind=CONTROL_WRITER_EVIDENCE_BYTES_KIND,
                    schema_sha256=schema_sha256_for_kind_v2(
                        OUTPUT_MANIFEST_KIND
                    ),
                    path=f"writer/forged-{field}-provenance.json",
                    payload=artifact_payload,
                )
                artifact_measurement["writer_evidence"] = (
                    _binding_document(replacement_writer)
                )
                artifact_manifest_binding, _ = (
                    artifact_builder.add_new_document(
                        artifact_manifest,
                        artifact_kind=OUTPUT_MANIFEST_KIND,
                        label=f"forged-{field}-manifest",
                    )
                )
                with self.assertRaisesRegex(
                    ControlAuthorizationV2Error,
                    "writer provenance authentication failed",
                ):
                    _trusted_verifier(
                        artifact_builder
                    )._aggregate_from_bindings(
                        objective_binding=objective,
                        output_binding=artifact_manifest_binding,
                        resolver=control._SnapshotResolverV2(
                            artifact_builder.snapshot(),
                            artifact_builder.dependencies(),
                        ),
                        scope=self.fixed.scope(),
                        expected_family="best_fixed",
                        expected_split="validation",
                        expected_stable_id=0,
                        expected_control_configuration_sha256=(
                            self.fixed._configuration(0)
                        ),
                        expected_control_request=(
                            self.fixed._control_request(0)
                        ),
                    )

    def test_control_replay_rejects_source_and_profile_substitution(self) -> None:
        base_binding = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["output_manifest"]
        )
        base_document = json.loads(self.builder.files[base_binding.path][1])
        objective = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["objective_summary"]
        )
        for field in ("source_target_provenance", "degradation_profile"):
            with self.subTest(field=field):
                builder = EvidenceBuilder()
                builder.files = dict(self.builder.files)
                builder.authenticated_executions = deepcopy(
                    self.builder.authenticated_executions
                )
                builder.authenticated_writers = deepcopy(
                    self.builder.authenticated_writers
                )
                builder.locked_profiles = deepcopy(
                    self.builder.locked_profiles
                )
                forged = deepcopy(base_document)
                replacement_index = (
                    3 if field == "source_target_provenance" else 1
                )
                forged["rows"][0]["measurement_evidence"][field] = deepcopy(
                    forged["rows"][replacement_index][field]
                )
                manifest, _ = builder.add_new_document(
                    forged,
                    artifact_kind=OUTPUT_MANIFEST_KIND,
                    label=f"substituted-{field}",
                )
                with self.assertRaisesRegex(
                    ControlAuthorizationV2Error,
                    "provenance binding differs",
                ):
                    _trusted_verifier(builder)._aggregate_from_bindings(
                        objective_binding=objective,
                        output_binding=manifest,
                        resolver=control._SnapshotResolverV2(
                            builder.snapshot(),
                            builder.dependencies(),
                        ),
                        scope=self.fixed.scope(),
                        expected_family="best_fixed",
                        expected_split="validation",
                        expected_stable_id=0,
                        expected_control_configuration_sha256=(
                            self.fixed._configuration(0)
                        ),
                        expected_control_request=(
                            self.fixed._control_request(0)
                        ),
                    )

    def test_forged_perfect_and_untrusted_near_perfect_outputs_fail_closed(
        self,
    ) -> None:
        base_binding = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["output_manifest"]
        )
        base_document = json.loads(self.builder.files[base_binding.path][1])
        objective = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["objective_summary"]
        )

        perfect_builder = EvidenceBuilder()
        perfect_builder.files = dict(self.builder.files)
        perfect_builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        perfect_builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        perfect_builder.locked_profiles = deepcopy(
            self.builder.locked_profiles
        )
        perfect = deepcopy(base_document)
        target_document = deepcopy(
            perfect["rows"][0]["measurement_evidence"]["target"]
        )
        target_document["artifact_kind"] = CONTROL_OUTPUT_BYTES_KIND
        perfect["rows"][0]["measurement_evidence"]["output"] = (
            target_document
        )
        perfect["rows"][0]["measurement_evidence"][
            "output_frame_sha256"
        ] = perfect["rows"][0]["measurement_evidence"][
            "target_frame_sha256"
        ]
        perfect_manifest, _ = perfect_builder.add_new_document(
            perfect,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="forged-perfect-output",
        )
        with self.assertRaises(ControlAuthorizationV2Error):
            _trusted_verifier(perfect_builder)._aggregate_from_bindings(
                objective_binding=objective,
                output_binding=perfect_manifest,
                resolver=control._SnapshotResolverV2(
                    perfect_builder.snapshot(),
                    perfect_builder.dependencies(),
                ),
                scope=self.fixed.scope(),
                expected_family="best_fixed",
                expected_split="validation",
                expected_stable_id=0,
                expected_control_configuration_sha256=(
                    self.fixed._configuration(0)
                ),
                expected_control_request=self.fixed._control_request(0),
            )

        forged_builder = EvidenceBuilder()
        forged_builder.files = dict(self.builder.files)
        forged_builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        forged_builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        forged_builder.locked_profiles = deepcopy(self.builder.locked_profiles)
        forged = deepcopy(base_document)
        measurement = forged["rows"][0]["measurement_evidence"]
        target = self.fixed.target_frames[("validation", 0)]
        near_perfect = PlanarFrame(
            y=np.nextafter(target.y, np.ones_like(target.y)),
            cb=np.nextafter(target.cb, np.ones_like(target.cb)),
            cr=np.nextafter(target.cr, np.ones_like(target.cr)),
        )
        payload = canonical_control_measurement_frame_bytes_v2(near_perfect)
        output = forged_builder.add_bytes(
            artifact_kind=CONTROL_OUTPUT_BYTES_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path="payloads/forged-near-perfect-output.bin",
            payload=payload,
        )
        measurement["output"] = _binding_document(output)
        measurement["output_frame_sha256"] = frame_sha256(near_perfect)
        measurement["metrics"] = dict(corpus_metric_bundle(target, near_perfect))
        original_execution = TypedArtifactBindingV2.from_document(
            measurement["control_execution"]
        )
        execution = json.loads(
            forged_builder.files[original_execution.path][1]
        )
        execution["output"] = _binding_document(output)
        execution["output_frame_sha256"] = frame_sha256(near_perfect)
        native = execution["native_execution_record"]
        native["output_frame_sha256"] = frame_sha256(near_perfect)
        native["native_invocation_id"] = _digest("forged-native-invocation")
        native.pop("record_sha256")
        native["record_sha256"] = hashlib.sha256(
            canonical_json_bytes_v2(native)
        ).hexdigest()
        execution_payload = canonical_json_bytes_v2(execution)
        forged_execution = forged_builder.add_bytes(
            artifact_kind=control.CONTROL_EXECUTION_PROVENANCE_KIND,
            schema_sha256=schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND),
            path="executions/forged-near-perfect.json",
            payload=execution_payload,
        )
        measurement["control_execution"] = _binding_document(forged_execution)
        forged_manifest, _ = forged_builder.add_new_document(
            forged,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="forged-near-perfect-output-manifest",
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "provenance authentication failed",
        ):
            _trusted_verifier(forged_builder)._aggregate_from_bindings(
                objective_binding=objective,
                output_binding=forged_manifest,
                resolver=control._SnapshotResolverV2(
                    forged_builder.snapshot(),
                    forged_builder.dependencies(),
                ),
                scope=self.fixed.scope(),
                expected_family="best_fixed",
                expected_split="validation",
                expected_stable_id=0,
                expected_control_configuration_sha256=(
                    self.fixed._configuration(0)
                ),
                expected_control_request=self.fixed._control_request(0),
            )

    def test_ranked_replay_rejects_forged_summary_and_omitted_row_bytes(
        self,
    ) -> None:
        forged_builder = EvidenceBuilder()
        admission = forged_builder.add_bytes(
            artifact_kind=VALIDATION_ADMISSION_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
            path="admission/forged.json",
            payload=b"forged-admission\n",
        )
        forged = RankedControlFixture(
            forged_builder,
            family="conventional",
            admission=admission,
            forged_summary=True,
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "objective hierarchy or means differ",
        ):
            _trusted_verifier(forged_builder)._verify_ranked_control(
                binding=forged.final_binding,
                family="conventional",
                resolver=control._SnapshotResolverV2(
                    forged_builder.snapshot(),
                    forged_builder.dependencies(),
                ),
                scope=forged.scope(),
            )

        first_output_manifest = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["output_manifest"]
        )
        output_document = json.loads(
            self.builder.files[first_output_manifest.path][1]
        )
        substituted_builder = EvidenceBuilder()
        substituted_builder.files = dict(self.builder.files)
        substituted_builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        substituted_builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        substituted_builder.locked_profiles = deepcopy(
            self.builder.locked_profiles
        )
        substituted_document = deepcopy(output_document)
        substituted_document["rows"][0]["measurement_evidence"][
            "output"
        ] = deepcopy(
            substituted_document["rows"][1]["measurement_evidence"][
                "output"
            ]
        )
        substituted_manifest, _ = substituted_builder.add_new_document(
            substituted_document,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="substituted-row-manifest",
        )
        objective_summary = TypedArtifactBindingV2.from_document(
            self.fixed.final["validation_results"][0]["objective_summary"]
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "frame identity or geometry differs|reused or swapped",
        ):
            _trusted_verifier(substituted_builder)._aggregate_from_bindings(
                objective_binding=objective_summary,
                output_binding=substituted_manifest,
                resolver=control._SnapshotResolverV2(
                    substituted_builder.snapshot(),
                    substituted_builder.dependencies(),
                ),
                scope=self.fixed.scope(),
                expected_family="best_fixed",
                expected_split="validation",
                expected_stable_id=0,
                expected_control_configuration_sha256=(
                    self.fixed._configuration(0)
                ),
                expected_control_request=self.fixed._control_request(0),
            )

        forged_output_builder = EvidenceBuilder()
        forged_output_builder.files = dict(self.builder.files)
        forged_output_builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        forged_output_builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        forged_output_builder.locked_profiles = deepcopy(
            self.builder.locked_profiles
        )
        forged_output_document = deepcopy(output_document)
        forged_output_document["rows"][0]["measurement_evidence"][
            "metrics"
        ]["y_psnr_db"] += 9.0
        forged_output_manifest, _ = forged_output_builder.add_new_document(
            forged_output_document,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="forged-metric-output-manifest",
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "metrics differ from frame evidence",
        ):
            _trusted_verifier(forged_output_builder)._aggregate_from_bindings(
                objective_binding=objective_summary,
                output_binding=forged_output_manifest,
                resolver=control._SnapshotResolverV2(
                    forged_output_builder.snapshot(),
                    forged_output_builder.dependencies(),
                ),
                scope=self.fixed.scope(),
                expected_family="best_fixed",
                expected_split="validation",
                expected_stable_id=0,
                expected_control_configuration_sha256=(
                    self.fixed._configuration(0)
                ),
                expected_control_request=self.fixed._control_request(0),
            )

        omitted = TypedArtifactBindingV2.from_document(
            output_document["rows"][0]["measurement_evidence"]["output"]
        )
        incomplete = self.builder.clone_without(omitted.path)
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "snapshot bytes differ",
        ):
            _trusted_verifier(incomplete)._verify_ranked_control(
                binding=self.fixed.final_binding,
                family="best_fixed",
                resolver=control._SnapshotResolverV2(
                    incomplete.snapshot(),
                    self.builder.dependencies(),
                ),
                scope=self.fixed.scope(),
            )

    def test_equal_objective_ranked_tie_rejects_noncanonical_winner(self) -> None:
        tie_builder = EvidenceBuilder()
        admission = tie_builder.add_bytes(
            artifact_kind=VALIDATION_ADMISSION_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
            path="admission/tie.json",
            payload=b"tie-admission\n",
        )
        tied = RankedControlFixture(
            tie_builder,
            family="conventional",
            admission=admission,
            noncanonical_winner=True,
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "development winner differs|validation winner differs",
        ):
            _trusted_verifier(tie_builder)._verify_ranked_control(
                binding=tied.final_binding,
                family="conventional",
                resolver=control._SnapshotResolverV2(
                    tie_builder.snapshot(),
                    tie_builder.dependencies(),
                ),
                scope=tied.scope(),
            )

    def test_ranked_scope_rejects_wrong_run_bank_source_and_admission(self) -> None:
        base = self.fixed.scope()
        variants = (
            ControlAuthorizationScopeV2(
                run_id="wrong-run",
                split="validation",
                shared_bank_configuration_sha256=base.shared_bank_configuration_sha256,
                degradation_policy_sha256=base.degradation_policy_sha256,
                source_profile_matrix_sha256=base.source_profile_matrix_sha256,
                development_source_profile_matrix_sha256=(
                    base.development_source_profile_matrix_sha256
                ),
                validation_admission=base.validation_admission,
            ),
            ControlAuthorizationScopeV2(
                run_id=base.run_id,
                split="validation",
                shared_bank_configuration_sha256=_digest("wrong-bank"),
                degradation_policy_sha256=base.degradation_policy_sha256,
                source_profile_matrix_sha256=base.source_profile_matrix_sha256,
                development_source_profile_matrix_sha256=(
                    base.development_source_profile_matrix_sha256
                ),
                validation_admission=base.validation_admission,
            ),
            ControlAuthorizationScopeV2(
                run_id=base.run_id,
                split="validation",
                shared_bank_configuration_sha256=base.shared_bank_configuration_sha256,
                degradation_policy_sha256=_digest("wrong-degradation"),
                source_profile_matrix_sha256=base.source_profile_matrix_sha256,
                development_source_profile_matrix_sha256=(
                    base.development_source_profile_matrix_sha256
                ),
                validation_admission=base.validation_admission,
            ),
            ControlAuthorizationScopeV2(
                run_id=base.run_id,
                split="validation",
                shared_bank_configuration_sha256=base.shared_bank_configuration_sha256,
                degradation_policy_sha256=base.degradation_policy_sha256,
                source_profile_matrix_sha256=_digest("wrong-matrix"),
                development_source_profile_matrix_sha256=(
                    base.development_source_profile_matrix_sha256
                ),
                validation_admission=base.validation_admission,
            ),
            ControlAuthorizationScopeV2(
                run_id=base.run_id,
                split="validation",
                shared_bank_configuration_sha256=base.shared_bank_configuration_sha256,
                degradation_policy_sha256=base.degradation_policy_sha256,
                source_profile_matrix_sha256=base.source_profile_matrix_sha256,
                development_source_profile_matrix_sha256=(
                    base.development_source_profile_matrix_sha256
                ),
                validation_admission=TypedArtifactBindingV2(
                    artifact_kind=VALIDATION_ADMISSION_KIND,
                    schema_sha256=schema_sha256_for_kind_v2(
                        VALIDATION_ADMISSION_KIND
                    ),
                    path="admission/other.json",
                    sha256=_digest("other-admission"),
                    size_bytes=1,
                ),
            ),
        )
        for variant in variants:
            with self.subTest(scope=variant):
                with self.assertRaises(ControlAuthorizationV2Error):
                    _trusted_verifier(self.builder)._verify_ranked_control(
                        binding=self.fixed.final_binding,
                        family="best_fixed",
                        resolver=control._SnapshotResolverV2(
                            self.builder.snapshot(),
                            self.builder.dependencies(),
                        ),
                        scope=variant,
                    )

    def test_v1_control_binding_is_rejected_at_v2_boundary(self) -> None:
        legacy = TypedArtifactBindingV2(
            artifact_kind="p06_fixed_control_selection",
            schema_sha256=(
                "646919f448ffd335e3fa168a392944c41e9c9a9403a3b523273f0fceb01439ba"
            ),
            path=self.fixed.final_binding.path,
            sha256=self.fixed.final_binding.sha256,
            size_bytes=self.fixed.final_binding.size_bytes,
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "kind differs",
        ):
            ControlAuthorizationVerifierV2()._verify_ranked_control(
                binding=legacy,
                family="best_fixed",
                resolver=control._SnapshotResolverV2(
                    self.builder.snapshot(),
                    self.builder.dependencies(),
                ),
                scope=self.fixed.scope(),
            )

    def test_non_ash_evaluation_recomputes_real_frame_metrics_unmocked(
        self,
    ) -> None:
        builder = EvidenceBuilder()
        builder.files = dict(self.builder.files)
        builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        builder.locked_profiles = deepcopy(self.builder.locked_profiles)
        profile = self.non_ash_fixture.profile
        rule_values = tuple(
            profile.initial_value for _ in profile.coordinate_order
        )
        rule = rule_mapping_v2(rule_values, profile)
        rule_sha256 = hashlib.sha256(
            canonical_json_bytes_v2(rule)
        ).hexdigest()
        configuration_sha256 = non_ash_control_configuration_sha256_v2(
            selector_id=NON_ASH_SELECTOR_ID_V2,
            rule_sha256=rule_sha256,
            shared_bank_configuration_sha256=self.fixed.BANK,
        )
        self.assertEqual(
            configuration_sha256,
            "fbd29c2117ba76723d4893c7330f825f2ad8c01030bface373312847f5d42884",
        )
        self.assertNotEqual(configuration_sha256, rule_sha256)
        control_request = non_ash_control_request_for_selector_v2(
            rule,
            self.fixed.BANK,
            selector_id=NON_ASH_SELECTOR_ID_V2,
        )

        base_result = self.fixed.final["validation_results"][0]
        base_manifest_binding = TypedArtifactBindingV2.from_document(
            base_result["output_manifest"]
        )
        manifest = json.loads(
            builder.files[base_manifest_binding.path][1]
        )
        manifest["control_family"] = "non_ash_selector"
        manifest["stable_id"] = rule_sha256
        manifest["control_configuration_sha256"] = configuration_sha256
        matrix_count = len(manifest["source_profile_matrix"])
        manifest["comparison_domains"] = ["engine_raw"]
        manifest["rows"] = manifest["rows"][:matrix_count]
        for row in manifest["rows"]:
            row["control_configuration_sha256"] = configuration_sha256
        for index in range(matrix_count):
            measurement = manifest["rows"][index]["measurement_evidence"]
            original = TypedArtifactBindingV2.from_document(
                measurement["control_execution"]
            )
            execution = json.loads(builder.files[original.path][1])
            execution["control_request"] = deepcopy(control_request)
            native = execution["native_execution_record"]
            native["control_key"] = control_request["control_key"]
            native["control_mode"] = control_request["control_mode"]
            native["request_sha256"] = control_request["request_sha256"]
            native["configuration_sha256"] = configuration_sha256
            native["parameters"] = deepcopy(control_request["parameters"])
            native["parameters_sha256"] = hashlib.sha256(
                canonical_json_bytes_v2(control_request["parameters"])
            ).hexdigest()
            native["native_invocation_id"] = _digest(
                f"trusted-non-ash:{index}"
            )
            native.pop("record_sha256")
            native["record_sha256"] = hashlib.sha256(
                canonical_json_bytes_v2(native)
            ).hexdigest()
            authenticated = builder.add_authenticated_execution(
                execution,
                label=f"trusted-non-ash-{index}",
            )
            binding_document = _binding_document(authenticated)
            measurement["control_execution"] = binding_document
        manifest_binding, _ = builder.add_new_document(
            manifest,
            artifact_kind=OUTPUT_MANIFEST_KIND,
            label="non-ash-real-frame-manifest",
        )

        base_summary_binding = TypedArtifactBindingV2.from_document(
            base_result["objective_summary"]
        )
        summary = json.loads(builder.files[base_summary_binding.path][1])
        summary["control_family"] = "non_ash_selector"
        summary["stable_id"] = rule_sha256
        summary["control_configuration_sha256"] = configuration_sha256
        summary_binding, finalized_summary = builder.add_new_document(
            summary,
            artifact_kind=OBJECTIVE_SUMMARY_KIND,
            label="non-ash-real-frame-summary",
        )
        objective = tuple(finalized_summary["means"])

        evaluation_scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=self.fixed.BANK,
            degradation_policy_sha256=self.fixed.DEGRADATION,
            calibration_plan_file_sha256=(
                control._AUTHORITY_SPECS["calibration_plan_v2"][
                    "file_sha256"
                ]
            ),
            cached_16_operator_output_manifest_sha256=_digest(
                "unmocked-cached-operator-manifest"
            ),
        )
        evaluation_payload = canonical_evaluation_evidence_bytes_v2(
            selector_id=NON_ASH_SELECTOR_ID_V2,
            split="validation",
            evaluation_scope=evaluation_scope,
            rule_sha256=rule_sha256,
            objective_summary_sha256=summary_binding.sha256,
            output_manifest_sha256=manifest_binding.sha256,
            objective_means=objective,
        )
        evaluation_binding = builder.add_bytes(
            artifact_kind=EVALUATION_EVIDENCE_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                EVALUATION_EVIDENCE_KIND
            ),
            path=f"non-ash/evaluation-{_digest('unmocked')}.json",
            payload=evaluation_payload,
        )
        _trusted_verifier(builder)._non_ash_evaluation(
            digest=evaluation_binding.sha256,
            expected_split="validation",
            expected_rule_sha256=rule_sha256,
            expected_rule_values=list(rule_values),
            expected_objective_summary_sha256=summary_binding.sha256,
            expected_output_manifest_sha256=manifest_binding.sha256,
            expected_objective=list(objective),
            resolver=control._SnapshotResolverV2(
                builder.snapshot(),
                builder.dependencies(),
            ),
            scope=self.fixed.scope(),
            evaluation_scope=evaluation_scope,
            profile=profile,
        )

    def _bundle_fixture(
        self,
        *,
        extra_dependency: bool = False,
        mutate_bundle=None,
    ):
        builder = EvidenceBuilder()
        builder.files = dict(self.builder.files)
        builder.authenticated_executions = deepcopy(
            self.builder.authenticated_executions
        )
        builder.authenticated_writers = deepcopy(
            self.builder.authenticated_writers
        )
        builder.locked_profiles = deepcopy(self.builder.locked_profiles)
        non_ash_selection = builder.add_bytes(
            artifact_kind=SELECTION_KIND,
            schema_sha256=schema_sha256_for_kind_v2(SELECTION_KIND),
            path="non-ash/selection.json",
            payload=b"non-ash-selection-fixture\n",
        )
        development_ledger = builder.add_bytes(
            artifact_kind=ATTEMPT_LEDGER_KIND,
            schema_sha256=schema_sha256_for_kind_v2(ATTEMPT_LEDGER_KIND),
            path="non-ash/development-ledger.json",
            payload=b"non-ash-development-ledger-fixture\n",
        )
        development_selection = builder.add_bytes(
            artifact_kind=SELECTION_KIND,
            schema_sha256=schema_sha256_for_kind_v2(SELECTION_KIND),
            path="non-ash/development-selection.json",
            payload=b"non-ash-development-selection-fixture\n",
        )
        neighbor = builder.add_bytes(
            artifact_kind=NEIGHBOR_MANIFEST_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                NEIGHBOR_MANIFEST_KIND
            ),
            path="non-ash/neighbor.json",
            payload=b"non-ash-neighbor-fixture\n",
        )
        if extra_dependency:
            builder.add_bytes(
                artifact_kind=NON_ASH_IMMUTABLE_CONTENT_KIND,
                schema_sha256=_digest("extra-schema"),
                path="non-ash/unreferenced.bin",
                payload=b"unreferenced dependency\n",
            )
        dependencies = builder.dependencies()
        bundle = {
            "schema_version": "2.0.1",
            "artifact_kind": CONTROL_AUTHORIZATION_BUNDLE_KIND,
            "authority_bindings": authority_bindings_v2(),
            "run_id": self.fixed.RUN_ID,
            "split": "validation",
            "shared_bank_configuration_sha256": self.fixed.BANK,
            "degradation_policy_sha256": self.fixed.DEGRADATION,
            "source_profile_matrix_sha256": self.fixed.matrix_sha256,
            "development_source_profile_matrix_sha256": (
                self.fixed.development_matrix_sha256
            ),
            "validation_admission": _binding_document(self.admission),
            "control_selections": [
                {
                    "id": "best_fixed",
                    "selection": _binding_document(self.fixed.final_binding),
                },
                {
                    "id": "conventional",
                    "selection": _binding_document(
                        self.conventional.final_binding
                    ),
                },
                {
                    "id": "non_ash_selector",
                    "selection": _binding_document(non_ash_selection),
                },
            ],
            "non_ash_predecessors": {
                "development_ledger": _binding_document(development_ledger),
                "development_selection": _binding_document(
                    development_selection
                ),
                "validation_neighbor_manifest": _binding_document(neighbor),
            },
            "dependency_bindings": [
                _binding_document(binding) for binding in dependencies
            ],
            "dependency_set_sha256": _digest("placeholder"),
            "authorization_semantic_sha256": _digest("placeholder"),
            "data_access": {
                "development_metrics_accessed": True,
                "validation_accessed": True,
                "holdout_accessed": False,
                "media_payloads_accessed": False,
                "release_locks_written": False,
                "winner_claim_made": False,
            },
            "artifact_sha256": _digest("placeholder"),
        }
        if mutate_bundle is not None:
            mutate_bundle(bundle)
        bundle = finalize_control_authorization_bundle_v2(bundle)
        payload = canonical_json_file_bytes_v2(bundle)
        bundle_binding = builder.add_bytes(
            artifact_kind=CONTROL_AUTHORIZATION_BUNDLE_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                CONTROL_AUTHORIZATION_BUNDLE_KIND
            ),
            path=f"authorization/{hashlib.sha256(payload).hexdigest()}.json",
            payload=payload,
        )
        return (
            builder,
            bundle_binding,
            bundle,
            dependencies,
            non_ash_selection,
            {
                "development_ledger": development_ledger,
                "development_selection": development_selection,
                "validation_neighbor_manifest": neighbor,
            },
        )

    @staticmethod
    def _consume_mock_non_ash(
        *,
        binding,
        predecessor_documents,
        resolver,
        **_kwargs,
    ):
        resolver.require_binding(
            binding,
            expected_kind=SELECTION_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(SELECTION_KIND),
        )
        specs = {
            "development_ledger": ATTEMPT_LEDGER_KIND,
            "development_selection": SELECTION_KIND,
            "validation_neighbor_manifest": NEIGHBOR_MANIFEST_KIND,
        }
        for name, kind in specs.items():
            resolver.require_binding(
                TypedArtifactBindingV2.from_document(
                    predecessor_documents[name]
                ),
                expected_kind=kind,
                expected_schema_sha256=schema_sha256_for_kind_v2(kind),
            )
        return {"validation_status": "selected"}

    @staticmethod
    def _consume_mock_admission(*, binding, resolver, **_kwargs):
        resolver.require_binding(
            binding,
            expected_kind=VALIDATION_ADMISSION_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
        )
        return {"admission": "fixture"}

    def test_bundle_verifies_exact_order_scope_hashes_and_transitive_closure(
        self,
    ) -> None:
        builder, binding, bundle, dependencies, *_ = self._bundle_fixture()
        verifier = _trusted_verifier(builder)
        with patch.object(
            verifier,
            "_verify_non_ash_control",
            side_effect=self._consume_mock_non_ash,
        ), patch.object(
            verifier,
            "_verify_validation_admission",
            side_effect=self._consume_mock_admission,
        ):
            verified = verifier.verify_bundle(
                binding,
                evidence_snapshot=builder.snapshot(),
                expected_scope=self.fixed.scope(),
                non_ash_profile=self.non_ash_fixture.profile,
                non_ash_evaluation_scope=self.non_ash_fixture.scope,
                validation_admission_semantic_verifier=lambda binding, document: document,
            )
        self.assertEqual(verified.document, bundle)
        self.assertEqual(verified.dependency_bindings, dependencies)
        self.assertEqual(
            verified.dependency_set_sha256,
            dependency_set_sha256_v2(dependencies),
        )
        self.assertEqual(
            [item.artifact_kind for item in verified.control_selection_bindings],
            [FIXED_SELECTION_KIND, CONVENTIONAL_SELECTION_KIND, SELECTION_KIND],
        )

    def test_bundle_rejects_extra_omitted_swapped_and_old_five_authorities(
        self,
    ) -> None:
        builder, binding, *_ = self._bundle_fixture(extra_dependency=True)
        verifier = _trusted_verifier(builder)
        with patch.object(
            verifier,
            "_verify_non_ash_control",
            side_effect=self._consume_mock_non_ash,
        ), patch.object(
            verifier,
            "_verify_validation_admission",
            side_effect=self._consume_mock_admission,
        ):
            with self.assertRaisesRegex(
                ControlAuthorizationV2Error,
                "transitive dependency closure differs",
            ):
                verifier.verify_bundle(
                    binding,
                    evidence_snapshot=builder.snapshot(),
                    expected_scope=self.fixed.scope(),
                    non_ash_profile=self.non_ash_fixture.profile,
                    non_ash_evaluation_scope=self.non_ash_fixture.scope,
                    validation_admission_semantic_verifier=lambda binding, document: document,
                )

        def omit_first_aggregate(bundle):
            target = self.fixed.final["validation_results"][0][
                "objective_summary"
            ]["path"]
            bundle["dependency_bindings"] = [
                row
                for row in bundle["dependency_bindings"]
                if row["path"] != target
            ]

        builder, binding, *_ = self._bundle_fixture(
            mutate_bundle=omit_first_aggregate
        )
        verifier = _trusted_verifier(builder)
        with patch.object(
            verifier,
            "_verify_non_ash_control",
            side_effect=self._consume_mock_non_ash,
        ), patch.object(
            verifier,
            "_verify_validation_admission",
            side_effect=self._consume_mock_admission,
        ):
            with self.assertRaisesRegex(
                ControlAuthorizationV2Error,
                "absent from the declared dependency set",
            ):
                verifier.verify_bundle(
                    binding,
                    evidence_snapshot=builder.snapshot(),
                    expected_scope=self.fixed.scope(),
                    non_ash_profile=self.non_ash_fixture.profile,
                    non_ash_evaluation_scope=self.non_ash_fixture.scope,
                    validation_admission_semantic_verifier=lambda binding, document: document,
                )

        def swap_controls(bundle):
            bundle["control_selections"][0], bundle["control_selections"][1] = (
                bundle["control_selections"][1],
                bundle["control_selections"][0],
            )

        builder, binding, *_ = self._bundle_fixture(
            mutate_bundle=swap_controls
        )
        with self.assertRaises(ControlAuthorizationV2Error):
            ControlAuthorizationVerifierV2().verify_bundle(
                binding,
                evidence_snapshot=builder.snapshot(),
                expected_scope=self.fixed.scope(),
                non_ash_profile=self.non_ash_fixture.profile,
                non_ash_evaluation_scope=self.non_ash_fixture.scope,
                validation_admission_semantic_verifier=lambda binding, document: document,
            )

        def remove_producer_identity_authority(bundle):
            del bundle["authority_bindings"][
                "control_execution_producer_identity_v2"
            ]

        builder, binding, *_ = self._bundle_fixture(
            mutate_bundle=remove_producer_identity_authority
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "schema validation failed|six-authority",
        ):
            ControlAuthorizationVerifierV2().verify_bundle(
                binding,
                evidence_snapshot=builder.snapshot(),
                expected_scope=self.fixed.scope(),
                non_ash_profile=self.non_ash_fixture.profile,
                non_ash_evaluation_scope=self.non_ash_fixture.scope,
                validation_admission_semantic_verifier=lambda binding, document: document,
            )

    def test_bundle_rejects_wrong_bank_run_split_source_and_admission(self) -> None:
        builder, binding, *_ = self._bundle_fixture()
        base = self.fixed.scope()
        wrong_bank = ControlAuthorizationScopeV2(
            run_id=base.run_id,
            split="validation",
            shared_bank_configuration_sha256=_digest("wrong-bundle-bank"),
            degradation_policy_sha256=base.degradation_policy_sha256,
            source_profile_matrix_sha256=base.source_profile_matrix_sha256,
            development_source_profile_matrix_sha256=(
                base.development_source_profile_matrix_sha256
            ),
            validation_admission=base.validation_admission,
        )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "bundle shared_bank_configuration_sha256 differs",
        ):
            ControlAuthorizationVerifierV2().verify_bundle(
                binding,
                evidence_snapshot=builder.snapshot(),
                expected_scope=wrong_bank,
                non_ash_profile=self.non_ash_fixture.profile,
                non_ash_evaluation_scope=self.non_ash_fixture.scope,
                validation_admission_semantic_verifier=lambda binding, document: document,
            )

        def wrong_split(bundle):
            bundle["split"] = "development"

        builder, binding, *_ = self._bundle_fixture(
            mutate_bundle=wrong_split
        )
        with self.assertRaises(ControlAuthorizationV2Error):
            ControlAuthorizationVerifierV2().verify_bundle(
                binding,
                evidence_snapshot=builder.snapshot(),
                expected_scope=base,
                non_ash_profile=self.non_ash_fixture.profile,
                non_ash_evaluation_scope=self.non_ash_fixture.scope,
                validation_admission_semantic_verifier=lambda binding, document: document,
            )

    def _real_non_ash_closure(
        self,
        *,
        selection: dict[str, object] | None = None,
        validation_evidence: dict[str, bytes] | None = None,
    ):
        fixture = self.non_ash_fixture
        builder = EvidenceBuilder()
        selection_document = deepcopy(
            fixture.validation_selection if selection is None else selection
        )
        selection_binding = builder.add_existing_document(
            selection_document,
            artifact_kind=SELECTION_KIND,
            label="validation-selection",
        )
        ledger_binding = builder.add_existing_document(
            deepcopy(fixture.ledger),
            artifact_kind=ATTEMPT_LEDGER_KIND,
            label="development-ledger",
        )
        development_selection_binding = builder.add_existing_document(
            deepcopy(fixture.development_selection),
            artifact_kind=SELECTION_KIND,
            label="development-selection",
        )
        neighbor_binding = builder.add_existing_document(
            deepcopy(fixture.neighbors),
            artifact_kind=NEIGHBOR_MANIFEST_KIND,
            label="validation-neighbors",
        )
        for split, evidence in (
            ("development", fixture.development_evidence),
            (
                "validation",
                fixture.validation_evidence
                if validation_evidence is None
                else validation_evidence,
            ),
        ):
            for digest, payload in evidence.items():
                self.assertEqual(hashlib.sha256(payload).hexdigest(), digest)
                builder.add_bytes(
                    artifact_kind=EVALUATION_EVIDENCE_KIND,
                    schema_sha256=schema_sha256_for_kind_v2(
                        EVALUATION_EVIDENCE_KIND
                    ),
                    path=f"non-ash-evaluations/{split}/{digest}.json",
                    payload=payload,
                )
        for digest, payload in fixture.immutable_content.items():
            self.assertEqual(hashlib.sha256(payload).hexdigest(), digest)
            builder.add_bytes(
                artifact_kind=NON_ASH_IMMUTABLE_CONTENT_KIND,
                schema_sha256=_digest("non-ash-immutable-schema"),
                path=f"non-ash-immutable/{digest}.bin",
                payload=payload,
            )
        cached_payload = b"cached-16-operator-output-manifest"
        self.assertEqual(
            hashlib.sha256(cached_payload).hexdigest(),
            fixture.scope.cached_16_operator_output_manifest_sha256,
        )
        builder.add_bytes(
            artifact_kind=CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
            schema_sha256=_digest("cached-operator-manifest-schema"),
            path=(
                "non-ash-immutable/"
                f"{fixture.scope.cached_16_operator_output_manifest_sha256}.json"
            ),
            payload=cached_payload,
        )
        admission = TypedArtifactBindingV2(
            artifact_kind=(
                "p06_validation_candidate_development_evidence_v2"
            ),
            schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
            path="admission/non-ash-scope.json",
            sha256=_digest("non-ash-scope-admission"),
            size_bytes=1,
        )
        scope = ControlAuthorizationScopeV2(
            run_id="non-ash-full-replay-fixture",
            split="validation",
            shared_bank_configuration_sha256=(
                fixture.scope.shared_bank_configuration_sha256
            ),
            degradation_policy_sha256=fixture.scope.degradation_policy_sha256,
            source_profile_matrix_sha256=_digest(
                "non-ash-source-profile-matrix"
            ),
            development_source_profile_matrix_sha256=_digest(
                "non-ash-development-source-profile-matrix"
            ),
            validation_admission=admission,
        )
        predecessors = {
            "development_ledger": _binding_document(ledger_binding),
            "development_selection": _binding_document(
                development_selection_binding
            ),
            "validation_neighbor_manifest": _binding_document(
                neighbor_binding
            ),
        }
        return builder, selection_binding, predecessors, scope

    @staticmethod
    def _consume_non_ash_aggregate_envelope_only(**kwargs) -> None:
        kwargs["resolver"].require_digest(
            kwargs["digest"],
            expected_kind=EVALUATION_EVIDENCE_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                EVALUATION_EVIDENCE_KIND
            ),
        )

    def test_non_ash_control_uses_complete_snapshot_backed_validation_replay(
        self,
    ) -> None:
        builder, selection, predecessors, scope = self._real_non_ash_closure()
        resolver = control._SnapshotResolverV2(
            builder.snapshot(),
            builder.dependencies(),
        )
        verifier = ControlAuthorizationVerifierV2()
        with patch.object(
            verifier,
            "_non_ash_evaluation",
            side_effect=self._consume_non_ash_aggregate_envelope_only,
        ) as aggregate_replay:
            verified = verifier._verify_non_ash_control(
                binding=selection,
                predecessor_documents=predecessors,
                resolver=resolver,
                scope=scope,
                profile=self.non_ash_fixture.profile,
                evaluation_scope=self.non_ash_fixture.scope,
            )
        resolver.finish()
        self.assertEqual(verified, self.non_ash_fixture.validation_selection)
        expected_calls = (
            len(self.non_ash_fixture.ledger["records"])
            + len(self.non_ash_fixture.validation_selection["validation_results"])
        )
        self.assertEqual(aggregate_replay.call_count, expected_calls)

    def test_non_ash_equal_objective_rejects_noncanonical_complete_rule_tie(
        self,
    ) -> None:
        fixture = self.non_ash_fixture
        selection = deepcopy(fixture.validation_selection)
        winner_rule = selection["selected_control_rule_sha256"]
        winner_result = next(
            row
            for row in selection["validation_results"]
            if row["rule_sha256"] == winner_rule
        )
        winner_objective = deepcopy(
            winner_result["outcome"]["engine_raw_corpus_mean_tuple"]
        )
        winner_candidate = next(
            row
            for row in fixture.neighbors["candidates"]
            if row["rule_sha256"] == winner_rule
        )
        winner_bytes = canonical_json_bytes_v2(
            rule_mapping_v2(
                tuple(winner_candidate["canonical_rule_values"]),
                fixture.profile,
            )
        )
        alternative_candidate = next(
            row
            for row in fixture.neighbors["candidates"]
            if row["rule_sha256"] != winner_rule
            and canonical_json_bytes_v2(
                rule_mapping_v2(
                    tuple(row["canonical_rule_values"]),
                    fixture.profile,
                )
            )
            > winner_bytes
        )
        alternative_result = selection["validation_results"][
            alternative_candidate["validation_candidate_ordinal"]
        ]
        old_digest = alternative_result["outcome"]["evaluation_sha256"]
        alternative_result["outcome"][
            "engine_raw_corpus_mean_tuple"
        ] = deepcopy(winner_objective)
        replacement_payload = canonical_evaluation_evidence_bytes_v2(
            selector_id=fixture.profile.selector_id,
            split="validation",
            evaluation_scope=fixture.scope,
            rule_sha256=alternative_result["rule_sha256"],
            objective_summary_sha256=alternative_result["outcome"][
                "objective_summary_sha256"
            ],
            output_manifest_sha256=alternative_result["outcome"][
                "output_manifest_sha256"
            ],
            objective_means=tuple(winner_objective),
        )
        replacement_digest = hashlib.sha256(replacement_payload).hexdigest()
        alternative_result["outcome"]["evaluation_sha256"] = replacement_digest
        selection["selected_control_rule_sha256"] = alternative_result[
            "rule_sha256"
        ]
        selection["selected_control_rule_values"] = deepcopy(
            alternative_candidate["canonical_rule_values"]
        )
        selection["validation_objective_summary_sha256"] = alternative_result[
            "outcome"
        ]["objective_summary_sha256"]
        unhashed = deepcopy(selection)
        unhashed.pop("validation_selection_sha256")
        selection["validation_selection_sha256"] = hashlib.sha256(
            canonical_json_bytes_v2(unhashed)
        ).hexdigest()
        validation_evidence = dict(fixture.validation_evidence)
        del validation_evidence[old_digest]
        validation_evidence[replacement_digest] = replacement_payload
        builder, selection_binding, predecessors, scope = (
            self._real_non_ash_closure(
                selection=selection,
                validation_evidence=validation_evidence,
            )
        )
        resolver = control._SnapshotResolverV2(
            builder.snapshot(),
            builder.dependencies(),
        )
        verifier = ControlAuthorizationVerifierV2()
        with patch.object(
            verifier,
            "_non_ash_evaluation",
            side_effect=self._consume_non_ash_aggregate_envelope_only,
        ):
            with self.assertRaisesRegex(
                ControlAuthorizationV2Error,
                "complete non-ASH validation replay failed",
            ) as raised:
                verifier._verify_non_ash_control(
                    binding=selection_binding,
                    predecessor_documents=predecessors,
                    resolver=resolver,
                    scope=scope,
                    profile=fixture.profile,
                    evaluation_scope=fixture.scope,
                )
        self.assertIsInstance(
            raised.exception.__cause__,
            NonAshSelectorArtifactV2Error,
        )
        self.assertRegex(str(raised.exception.__cause__), "selected rule")


if __name__ == "__main__":
    unittest.main()
