"""Publish exact raw control measurements as a V2 authenticated closure.

The evaluator supplies already-executed native control rows.  This module
serializes their exact target, degraded input, output, locked-profile, and
native execution bytes into the document topology enforced by
``ControlAuthorizationVerifierV2``.  It does not manufacture a producer
identity: callers must supply the identity obtained from the native producer.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from typing import Dict, Mapping, Sequence, Tuple

from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
    ClosureFileBindingV2,
    ClosureFileSnapshotV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    CONTROL_DEGRADATION_PROFILE_KIND,
    CONTROL_EXECUTION_PROVENANCE_KIND,
    CONTROL_LOW_RESOLUTION_INPUT_BYTES_KIND,
    CONTROL_MEASUREMENT_EVIDENCE_KIND,
    CONTROL_METRIC_ALGORITHM,
    CONTROL_OUTPUT_BYTES_KIND,
    CONTROL_SOURCE_TARGET_PROVENANCE_KIND,
    CONTROL_TARGET_FRAME_BYTES_KIND,
    OBJECTIVE_SUMMARY_KIND,
    OUTPUT_MANIFEST_KIND,
    SCHEMA_VERSION_V2,
    SELECTION_TUPLE_DESCRIPTION,
    TypedArtifactBindingV2,
    authority_bindings_v2,
    canonical_json_bytes_v2,
    canonical_json_file_bytes_v2,
    dependency_set_sha256_v2,
    finalize_artifact_sha256_v2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.production_evaluator import (
    CONTROL_MEASUREMENT_FRAME_ENCODING_V2,
    CandidateAdapter,
    ControlExecutionProducerIdentityV2,
    ProductionEvaluatorError,
    RawControlMeasurementPublicationV2,
    canonical_control_measurement_frame_bytes_v2,
    corpus_metric_bundle,
    hierarchical_control_objective_v2,
)
from validation.quality.src.mirmir_quality.arrays import frame_sha256


RAW_CONTROL_AGGREGATE_PUBLICATION_KIND_V2 = (
    "p06_raw_control_aggregate_publication_v2"
)
_ZERO_SHA256 = "0" * 64
_ADAPTER_IDENTITY_FIELDS = {
    "adapter_configuration_sha256",
    "native_source_manifest_sha256",
    "native_executable_sha256",
    "native_implementation_source_sha256",
}


class ControlEvidencePublisherV2Error(ProductionEvaluatorError):
    """One producer input or emitted closure relation is invalid."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and value != _ZERO_SHA256
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _snapshot_object(value: object, *, label: str) -> Dict[str, object]:
    try:
        payload = canonical_json_bytes_v2(value)
        snapshot = json.loads(payload)
    except (TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ControlEvidencePublisherV2Error(
            f"{label} is not canonical JSON"
        ) from error
    if type(snapshot) is not dict:
        raise ControlEvidencePublisherV2Error(f"{label} is not an object")
    return snapshot


def _binding_sort_key(binding: TypedArtifactBindingV2) -> Tuple[object, ...]:
    return (
        binding.path,
        binding.artifact_kind,
        binding.schema_sha256,
        binding.sha256,
        binding.size_bytes,
    )


class _PublicationBuilderV2:
    def __init__(self) -> None:
        self._files_by_path: Dict[
            str, Tuple[TypedArtifactBindingV2, bytes]
        ] = {}
        self._files_by_sha256: Dict[
            str, Tuple[TypedArtifactBindingV2, bytes]
        ] = {}

    def add_bytes(
        self,
        *,
        artifact_kind: str,
        schema_sha256: str,
        payload: bytes,
        suffix: str,
    ) -> TypedArtifactBindingV2:
        if type(payload) is not bytes or not payload:
            raise ControlEvidencePublisherV2Error(
                "control closure payload is empty or invalid"
            )
        digest = _sha256(payload)
        prior = self._files_by_sha256.get(digest)
        if prior is not None:
            binding, prior_payload = prior
            if (
                prior_payload != payload
                or binding.artifact_kind != artifact_kind
                or binding.schema_sha256 != schema_sha256
            ):
                raise ControlEvidencePublisherV2Error(
                    "control closure digest aliases a different artifact type"
                )
            return binding
        path = f"control-v2/{artifact_kind}/{digest}.{suffix}"
        binding = TypedArtifactBindingV2(
            artifact_kind=artifact_kind,
            schema_sha256=schema_sha256,
            path=path,
            sha256=digest,
            size_bytes=len(payload),
        )
        if path in self._files_by_path:
            raise ControlEvidencePublisherV2Error(
                "control closure path identity repeats"
            )
        entry = (binding, payload)
        self._files_by_path[path] = entry
        self._files_by_sha256[digest] = entry
        return binding

    def add_new_document(
        self,
        *,
        artifact_kind: str,
        document: Mapping[str, object],
    ) -> TypedArtifactBindingV2:
        finalized = finalize_artifact_sha256_v2(document)
        return self.add_bytes(
            artifact_kind=artifact_kind,
            schema_sha256=schema_sha256_for_kind_v2(artifact_kind),
            payload=canonical_json_file_bytes_v2(finalized),
            suffix="json",
        )

    def bindings(self) -> Tuple[TypedArtifactBindingV2, ...]:
        return tuple(
            sorted(
                (binding for binding, _ in self._files_by_path.values()),
                key=_binding_sort_key,
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
                for binding, payload in self._files_by_path.values()
            )
        )


@dataclass(frozen=True)
class _PublishedClosureV2:
    publication: Mapping[str, object]
    snapshot: AuthenticatedClosureSnapshotV2
    dependencies: Tuple[TypedArtifactBindingV2, ...]


class RawControlAuthorizationArtifactPublisherV2:
    """Build immutable raw-only V2 aggregate closures from evaluator rows."""

    def __init__(
        self,
        *,
        run_id: str,
        control_execution_producer_identity: ControlExecutionProducerIdentityV2,
    ) -> None:
        if type(run_id) is not str or not run_id:
            raise ControlEvidencePublisherV2Error("publisher run ID is invalid")
        if (
            type(control_execution_producer_identity)
            is not ControlExecutionProducerIdentityV2
        ):
            raise ControlEvidencePublisherV2Error(
                "control execution producer identity is absent"
            )
        try:
            adapter_identity = json.loads(
                control_execution_producer_identity.authenticated_adapter_identity_bytes
            )
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ControlEvidencePublisherV2Error(
                "authenticated adapter identity is invalid"
            ) from error
        if (
            type(adapter_identity) is not dict
            or set(adapter_identity) != _ADAPTER_IDENTITY_FIELDS
            or any(not _is_sha256(adapter_identity.get(field)) for field in adapter_identity)
            or canonical_json_bytes_v2(adapter_identity)
            != control_execution_producer_identity.authenticated_adapter_identity_bytes
        ):
            raise ControlEvidencePublisherV2Error(
                "authenticated adapter identity field set differs"
            )
        self.run_id = run_id
        self.control_execution_producer_identity = (
            control_execution_producer_identity
        )
        self._adapter_identity = adapter_identity
        self._published: Dict[str, _PublishedClosureV2] = {}

    @staticmethod
    def _publication_key(publication: Mapping[str, object]) -> str:
        key = publication.get("closure_sha256")
        if not _is_sha256(key):
            raise ControlEvidencePublisherV2Error(
                "control publication closure identity is invalid"
            )
        return str(key)

    def snapshot_for(
        self,
        publication: Mapping[str, object],
    ) -> AuthenticatedClosureSnapshotV2:
        key = self._publication_key(publication)
        stored = self._published.get(key)
        if stored is None or stored.publication != publication:
            raise ControlEvidencePublisherV2Error(
                "control publication is absent from this publisher"
            )
        return stored.snapshot

    def dependency_bindings_for(
        self,
        publication: Mapping[str, object],
    ) -> Tuple[TypedArtifactBindingV2, ...]:
        key = self._publication_key(publication)
        stored = self._published.get(key)
        if stored is None or stored.publication != publication:
            raise ControlEvidencePublisherV2Error(
                "control publication is absent from this publisher"
            )
        return stored.dependencies

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
        if run_id != self.run_id:
            raise ControlEvidencePublisherV2Error("publisher run ID differs")
        if split not in {"development", "validation"}:
            raise ControlEvidencePublisherV2Error("control split is invalid")
        if control_family not in {
            "best_fixed",
            "conventional",
            "non_ash_selector",
        }:
            raise ControlEvidencePublisherV2Error(
                "control family is invalid"
            )
        if (
            not _is_sha256(shared_bank_configuration_sha256)
            or not _is_sha256(degradation_policy_sha256)
            or type(adapter) is not CandidateAdapter
            or adapter.configuration_sha256
            != self.control_execution_producer_identity.adapter_configuration_sha256
            or adapter.configuration.get("shared_bank_configuration_sha256")
            != shared_bank_configuration_sha256
        ):
            raise ControlEvidencePublisherV2Error(
                "control producer or shared-bank identity differs"
            )
        request = _snapshot_object(control_request, label="control request")
        request_unhashed = dict(request)
        request_sha256 = request_unhashed.pop("request_sha256", None)
        if (
            request.get("operation") != "reconstruct_control"
            or request.get("shared_bank_configuration_sha256")
            != shared_bank_configuration_sha256
            or not _is_sha256(request.get("configuration_sha256"))
            or request_sha256 != _sha256(canonical_json_bytes_v2(request_unhashed))
        ):
            raise ControlEvidencePublisherV2Error(
                "control request identity is invalid"
            )
        if (
            type(rows) not in {list, tuple}
            or len(rows) < 6
            or any(type(row) is not RawControlMeasurementPublicationV2 for row in rows)
        ):
            raise ControlEvidencePublisherV2Error(
                "raw control publication rows are invalid"
            )

        builder = _PublicationBuilderV2()
        output_schema_sha256 = schema_sha256_for_kind_v2(
            OUTPUT_MANIFEST_KIND
        )
        matrix = []
        row_parts = []
        source_identity: Dict[str, Tuple[object, ...]] = {}
        source_counts: Dict[str, int] = {}
        pair_identities = []
        portable_pair_identities = []

        for row_index, publication_row in enumerate(rows):
            metadata = _snapshot_object(
                publication_row.metadata,
                label=f"control metadata {row_index}",
            )
            profile = _snapshot_object(
                publication_row.profile,
                label=f"degradation profile {row_index}",
            )
            source_id = metadata.get("source_asset_id")
            family_id = metadata.get("source_family_id")
            categories = metadata.get("categories")
            route = metadata.get("target_route")
            profile_id = profile.get("id")
            if (
                type(source_id) is not str
                or not source_id
                or type(family_id) is not str
                or not family_id
                or type(categories) is not list
                or not categories
                or any(type(category) is not str or not category for category in categories)
                or len(categories) != len(set(categories))
                or route not in {"direct-2x", "direct-3over2"}
                or type(profile_id) is not str
                or not profile_id
                or profile.get("target_route") != route
            ):
                raise ControlEvidencePublisherV2Error(
                    f"control source/profile identity {row_index} is invalid"
                )

            target_payload = canonical_control_measurement_frame_bytes_v2(
                publication_row.target
            )
            target_binding = builder.add_bytes(
                artifact_kind=CONTROL_TARGET_FRAME_BYTES_KIND,
                schema_sha256=output_schema_sha256,
                payload=target_payload,
                suffix="bin",
            )
            source_record = {
                "schema_version": SCHEMA_VERSION_V2,
                "artifact_kind": CONTROL_SOURCE_TARGET_PROVENANCE_KIND,
                "source_asset_id": source_id,
                "source_family_id": family_id,
                "categories": categories,
                "target_route": route,
                "target_frame": target_binding.as_document(),
                "target_frame_sha256": frame_sha256(publication_row.target),
            }
            source_binding = builder.add_bytes(
                artifact_kind=CONTROL_SOURCE_TARGET_PROVENANCE_KIND,
                schema_sha256=output_schema_sha256,
                payload=canonical_json_bytes_v2(source_record),
                suffix="json",
            )
            profile_record = {
                "schema_version": SCHEMA_VERSION_V2,
                "artifact_kind": CONTROL_DEGRADATION_PROFILE_KIND,
                "degradation_policy_sha256": degradation_policy_sha256,
                "degradation_profile_id": profile_id,
                "profile_definition": profile,
            }
            profile_binding = builder.add_bytes(
                artifact_kind=CONTROL_DEGRADATION_PROFILE_KIND,
                schema_sha256=output_schema_sha256,
                payload=canonical_json_bytes_v2(profile_record),
                suffix="json",
            )
            identity = {
                "source_asset_id": source_id,
                "source_family_id": family_id,
                "categories": categories,
                "target_route": route,
                "degradation_profile_id": profile_id,
                "degradation_profile_sha256": _sha256(
                    canonical_json_bytes_v2(profile)
                ),
                "source_target_provenance": source_binding.as_document(),
                "degradation_profile": profile_binding.as_document(),
            }
            stable_source_identity = (
                family_id,
                canonical_json_bytes_v2(categories),
                route,
                source_binding,
                target_binding,
            )
            prior_source_identity = source_identity.get(source_id)
            if (
                prior_source_identity is not None
                and prior_source_identity != stable_source_identity
            ):
                raise ControlEvidencePublisherV2Error(
                    "source target provenance changes across profiles"
                )
            source_identity[source_id] = stable_source_identity
            source_counts[source_id] = source_counts.get(source_id, 0) + 1
            pair_identities.append((source_id, profile_id))
            portable_pair_identities.append(
                (source_id.casefold(), profile_id.casefold())
            )
            matrix.append(identity)
            row_parts.append(
                (
                    publication_row,
                    identity,
                    source_binding,
                    profile_binding,
                    target_binding,
                )
            )

        if (
            len(source_identity) < 2
            or set(source_counts.values()) != {3}
            or {identity["target_route"] for identity in matrix}
            != {"direct-2x", "direct-3over2"}
            or len(pair_identities) != len(set(pair_identities))
            or len(portable_pair_identities)
            != len(set(portable_pair_identities))
        ):
            raise ControlEvidencePublisherV2Error(
                "control source/profile matrix coverage differs"
            )

        source_order = list(
            dict.fromkeys(identity["source_asset_id"] for identity in matrix)
        )
        source_profile_matrix_sha256 = _sha256(
            canonical_json_bytes_v2(matrix)
        )
        manifest_rows = []
        raw_metric_rows = []
        output_bindings = []
        for row_index, row_part in enumerate(row_parts):
            (
                publication_row,
                identity,
                source_binding,
                profile_binding,
                target_binding,
            ) = row_part
            input_payload = canonical_control_measurement_frame_bytes_v2(
                publication_row.low_resolution
            )
            input_binding = builder.add_bytes(
                artifact_kind=CONTROL_LOW_RESOLUTION_INPUT_BYTES_KIND,
                schema_sha256=output_schema_sha256,
                payload=input_payload,
                suffix="bin",
            )
            output_payload = canonical_control_measurement_frame_bytes_v2(
                publication_row.raw_output
            )
            output_binding = builder.add_bytes(
                artifact_kind=CONTROL_OUTPUT_BYTES_KIND,
                schema_sha256=output_schema_sha256,
                payload=output_payload,
                suffix="bin",
            )
            if output_binding in output_bindings:
                raise ControlEvidencePublisherV2Error(
                    "raw control output evidence is reused across rows"
                )
            output_bindings.append(output_binding)
            native_record = _snapshot_object(
                publication_row.native_execution_record,
                label=f"native execution record {row_index}",
            )
            native_unhashed = dict(native_record)
            native_sha256 = native_unhashed.pop("record_sha256", None)
            if (
                native_sha256
                != _sha256(canonical_json_bytes_v2(native_unhashed))
                or native_record.get("control_key") != request.get("control_key")
                or native_record.get("control_mode") != request.get("control_mode")
                or native_record.get("request_sha256") != request.get("request_sha256")
                or native_record.get("configuration_sha256")
                != request.get("configuration_sha256")
                or native_record.get("shared_bank_configuration_sha256")
                != shared_bank_configuration_sha256
                or native_record.get("input_frame_sha256")
                != frame_sha256(publication_row.low_resolution)
                or native_record.get("output_frame_sha256")
                != frame_sha256(publication_row.raw_output)
                or native_record.get("target_route")
                != identity["target_route"]
                or native_record.get("parameters") != request.get("parameters")
                or native_record.get("parameters_sha256")
                != _sha256(canonical_json_bytes_v2(request.get("parameters")))
            ):
                raise ControlEvidencePublisherV2Error(
                    f"native execution record {row_index} differs"
                )
            source_profile_identity_sha256 = _sha256(
                canonical_json_bytes_v2(identity)
            )
            execution_document = {
                "schema_version": SCHEMA_VERSION_V2,
                "artifact_kind": CONTROL_EXECUTION_PROVENANCE_KIND,
                "source_profile_identity_sha256": (
                    source_profile_identity_sha256
                ),
                "source_target_provenance": source_binding.as_document(),
                "degradation_profile": profile_binding.as_document(),
                "low_resolution_input": input_binding.as_document(),
                "input_frame_sha256": frame_sha256(
                    publication_row.low_resolution
                ),
                "control_request": request,
                "output": output_binding.as_document(),
                "output_frame_sha256": frame_sha256(
                    publication_row.raw_output
                ),
                "authenticated_adapter_identity": self._adapter_identity,
                "native_execution_record": native_record,
            }
            execution_binding = builder.add_bytes(
                artifact_kind=CONTROL_EXECUTION_PROVENANCE_KIND,
                schema_sha256=output_schema_sha256,
                payload=canonical_json_bytes_v2(execution_document),
                suffix="json",
            )
            metrics = dict(
                corpus_metric_bundle(
                    publication_row.target,
                    publication_row.raw_output,
                )
            )
            measurement = {
                "artifact_kind": CONTROL_MEASUREMENT_EVIDENCE_KIND,
                "metric_algorithm": CONTROL_METRIC_ALGORITHM,
                "frame_encoding": CONTROL_MEASUREMENT_FRAME_ENCODING_V2,
                "source_profile_identity_sha256": (
                    source_profile_identity_sha256
                ),
                "source_target_provenance": source_binding.as_document(),
                "degradation_profile": profile_binding.as_document(),
                "low_resolution_input": input_binding.as_document(),
                "input_frame_sha256": frame_sha256(
                    publication_row.low_resolution
                ),
                "control_execution": execution_binding.as_document(),
                "target": target_binding.as_document(),
                "target_frame_sha256": frame_sha256(publication_row.target),
                "output": output_binding.as_document(),
                "output_frame_sha256": frame_sha256(
                    publication_row.raw_output
                ),
                "metrics": metrics,
                "writer_evidence": None,
            }
            manifest_row = {
                **identity,
                "degradation_policy_sha256": degradation_policy_sha256,
                "comparison_domain": "engine_raw",
                "measurement_evidence": measurement,
                "control_configuration_sha256": request[
                    "configuration_sha256"
                ],
                "shared_bank_configuration_sha256": (
                    shared_bank_configuration_sha256
                ),
            }
            manifest_rows.append(manifest_row)
            raw_metric_rows.append(
                {
                    "source_asset_id": identity["source_asset_id"],
                    "metrics": metrics,
                }
            )

        per_source_means, objective_means = hierarchical_control_objective_v2(
            raw_metric_rows,
            source_order,
        )
        common = {
            "authority_bindings": authority_bindings_v2(),
            "run_id": run_id,
            "split": split,
            "control_family": control_family,
            "stable_id": stable_id,
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": degradation_policy_sha256,
            "control_configuration_sha256": request[
                "configuration_sha256"
            ],
            "source_profile_matrix_sha256": (
                source_profile_matrix_sha256
            ),
        }
        output_manifest = {
            "schema_version": SCHEMA_VERSION_V2,
            "artifact_kind": OUTPUT_MANIFEST_KIND,
            **common,
            "uniform_application": True,
            "source_profile_matrix": matrix,
            "source_order": source_order,
            "comparison_domains": ["engine_raw"],
            "rows": manifest_rows,
            "artifact_sha256": _ZERO_SHA256,
        }
        output_binding = builder.add_new_document(
            artifact_kind=OUTPUT_MANIFEST_KIND,
            document=output_manifest,
        )
        objective_summary = {
            "schema_version": SCHEMA_VERSION_V2,
            "artifact_kind": OBJECTIVE_SUMMARY_KIND,
            **common,
            "comparison_domain": "engine_raw",
            "metric_order": [
                "y_psnr_db",
                "y_ms_ssim",
                "y_ssim",
                "cb_psnr_db",
                "cr_psnr_db",
            ],
            "profiles_per_source": 3,
            "source_count": len(source_order),
            "per_source_means": list(per_source_means),
            "means": list(objective_means),
            "selection_tuple": SELECTION_TUPLE_DESCRIPTION,
            "artifact_sha256": _ZERO_SHA256,
        }
        objective_binding = builder.add_new_document(
            artifact_kind=OBJECTIVE_SUMMARY_KIND,
            document=objective_summary,
        )
        dependencies = builder.bindings()
        dependency_set_sha256 = dependency_set_sha256_v2(dependencies)
        snapshot = builder.snapshot()
        publication = {
            "schema_version": SCHEMA_VERSION_V2,
            "artifact_kind": RAW_CONTROL_AGGREGATE_PUBLICATION_KIND_V2,
            "run_id": run_id,
            "split": split,
            "control_family": control_family,
            "stable_id": stable_id,
            "source_profile_matrix_sha256": (
                source_profile_matrix_sha256
            ),
            "comparison_domains": ["engine_raw"],
            "objective_summary": objective_binding.as_document(),
            "output_manifest": output_binding.as_document(),
            "dependency_bindings": [
                binding.as_document() for binding in dependencies
            ],
            "dependency_set_sha256": dependency_set_sha256,
            "closure_sha256": snapshot.closure_sha256,
        }
        publication = _snapshot_object(
            publication,
            label="raw control aggregate publication",
        )
        existing = self._published.get(snapshot.closure_sha256)
        if existing is not None and existing.publication != publication:
            raise ControlEvidencePublisherV2Error(
                "control publication closure aliases different metadata"
            )
        self._published[snapshot.closure_sha256] = _PublishedClosureV2(
            publication=publication,
            snapshot=snapshot,
            dependencies=dependencies,
        )
        return publication


__all__ = [
    "ControlEvidencePublisherV2Error",
    "RAW_CONTROL_AGGREGATE_PUBLICATION_KIND_V2",
    "RawControlAuthorizationArtifactPublisherV2",
]
