from __future__ import annotations

import hashlib
import inspect
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest import mock

from validation.calibration_v2.calibration_persistence_v2 import (
    FileBindingV2,
    canonical_json_file_bytes_v2,
)
from validation.calibration_v2.calibration_plan_codec import (
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    DEVELOPMENT_SPLIT,
    EvaluationCacheIdentityV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    TypedArtifactBindingV2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.production_candidate_provider_v2 import (
    RAW_MEASUREMENT_KIND,
    NativeCandidateMeasurementV2,
    ProductionCandidateEvaluationProviderV2,
    ProductionCandidateProviderV2Error,
    ProductionNativeCandidateMeasurementSessionV2,
    ProductionNativeCandidateMeasurementSourceV2,
    SourceGateEvidenceV2,
    production_candidate_evaluation_provider_v2,
)
from validation.calibration_v2.production_control_selection_v2 import (
    ProductionControlSelectionRequestV2,
    ProductionControlSelectionResultV2,
    ProductionControlSelectionV2,
)
from validation.calibration_v2.production_coordinator_v2 import (
    CandidateEvaluationRequestV2,
    CandidateEvaluationSuccessV2,
    P06ProductionCoordinatorV2,
    RunArtifactProvenanceV2,
)
from validation.calibration_v2.production_providers import (
    NativeControlExecutionCapabilityProviderV2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.calibration_v2.shared_bank_artifacts_v2 import (
    SharedBankArtifactMaterializerV2,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64
SHA_D = "d" * 64


def _typed_bundle() -> TypedArtifactBindingV2:
    return TypedArtifactBindingV2(
        artifact_kind=CONTROL_AUTHORIZATION_BUNDLE_KIND,
        schema_sha256=schema_sha256_for_kind_v2(
            CONTROL_AUTHORIZATION_BUNDLE_KIND
        ),
        path=f"control-selection-v2/bundle/{SHA_A}.json",
        sha256=SHA_A,
        size_bytes=1,
    )


def _control_result(root: Path | None = None) -> ProductionControlSelectionResultV2:
    binding = _typed_bundle()
    if root is not None:
        payload = canonical_json_file_bytes_v2(
            {
                "schema_version": "2.0.1",
                "artifact_kind": CONTROL_AUTHORIZATION_BUNDLE_KIND,
            }
        )
        digest = hashlib.sha256(payload).hexdigest()
        binding = TypedArtifactBindingV2(
            artifact_kind=CONTROL_AUTHORIZATION_BUNDLE_KIND,
            schema_sha256=schema_sha256_for_kind_v2(
                CONTROL_AUTHORIZATION_BUNDLE_KIND
            ),
            path=f"control-selection-v2/bundle/{digest}.json",
            sha256=digest,
            size_bytes=len(payload),
        )
        target = root / binding.path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
    return ProductionControlSelectionResultV2(
        bundle_document={},
        bundle_binding=binding,
        evidence_snapshot=object(),  # test seam; provider reads only the binding
        dependency_bindings=(),
        control_selection_bindings=(),
        verified=object(),
    )


def _control_request(
    request: CandidateEvaluationRequestV2,
    *,
    bank: str,
) -> ProductionControlSelectionRequestV2:
    # Construct the exact production type while keeping this unit test independent
    # of the separately tested exhaustive control-selection document fixtures.
    value = object.__new__(ProductionControlSelectionRequestV2)
    scope = type("TestNonAshScope", (), {})()
    scope.shared_bank_configuration_sha256 = bank
    scope.degradation_policy_sha256 = SHA_B
    scope.calibration_plan_file_sha256 = (
        request.cache_identity.calibration_plan_file_sha256
    )
    object.__setattr__(value, "run_id", request.run_id)
    object.__setattr__(value, "split", request.split)
    object.__setattr__(value, "shared_bank_configuration_sha256", bank)
    object.__setattr__(value, "degradation_policy_sha256", SHA_B)
    object.__setattr__(value, "source_profile_matrix_sha256", SHA_C)
    object.__setattr__(value, "non_ash_evaluation_scope", scope)
    object.__setattr__(value, "validation_admission", None)
    return value


class _Session(ProductionNativeCandidateMeasurementSessionV2):
    def __init__(
        self,
        request: CandidateEvaluationRequestV2,
        control_request: ProductionControlSelectionRequestV2,
        control_result: ProductionControlSelectionResultV2,
        events: list[str],
        *,
        raw_schema_version: str = "2.0.0",
    ) -> None:
        self.request = request
        self.control_request = control_request
        self.control_result = control_result
        self.events = events
        self.raw_schema_version = raw_schema_version
        self.service: ProductionControlSelectionV2 | None = None

    def control_selection_request(self) -> ProductionControlSelectionRequestV2:
        self.events.append("controls-measured")
        return self.control_request

    def control_selection_service(self) -> ProductionControlSelectionV2:
        if self.service is None:
            raise AssertionError("test session has no control service")
        return self.service

    def measure_authorized_candidate(
        self,
        control_selection: ProductionControlSelectionResultV2,
    ) -> NativeCandidateMeasurementV2:
        self.events.append("candidate-measured")
        if control_selection is not self.control_result:
            raise AssertionError("candidate did not receive exact authorization")
        physical = dict(self.request.physical_candidate_items)
        bank = self.control_request.shared_bank_configuration_sha256
        configuration = {
            "schema_version": "2.0.0",
            "implementation_role": "production_swift_format_1_2",
            "configuration_id": "ash-p06-test",
            "physical_candidate_vector": physical,
            "serialized_candidate_vector_sha256": (
                self.request.cache_identity.candidate_vector_sha256
            ),
            "shared_bank_configuration_sha256": bank,
            "calibration_plan_sha256": (
                self.request.cache_identity.calibration_plan_file_sha256
            ),
            "compiler_input_file_sha256": SHA_A,
            "compiler_inputs_sha256": SHA_B,
            "candidate_lut_runtime_manifest_sha256": SHA_C,
            "route_luts": {
                "direct-2x": {
                    "whole_file_sha256": SHA_A,
                    "payload_sha256": SHA_B,
                },
                "direct-3over2": {
                    "whole_file_sha256": SHA_C,
                    "payload_sha256": SHA_D,
                },
            },
        }
        configuration_bytes = canonical_json_bytes(configuration)
        raw = {
            "schema_version": self.raw_schema_version,
            "artifact_kind": RAW_MEASUREMENT_KIND,
            "run_id": self.request.run_id,
            "split": self.request.split,
            "candidate_id": "ash-p06-test-native",
            "candidate_vector_sha256": (
                self.request.cache_identity.candidate_vector_sha256
            ),
            "adapter_configuration_sha256": hashlib.sha256(
                configuration_bytes
            ).hexdigest(),
            "control_authorization_bundle_sha256": (
                control_selection.bundle_binding.sha256
            ),
            "source_profile_matrix_sha256": (
                self.control_request.source_profile_matrix_sha256
            ),
            "corpus_asset_results": [],
            "analytic_fixture_results": [],
            "checks": {},
            "performance": {},
            "dispatch_measurement": {},
        }
        return NativeCandidateMeasurementV2(
            request=self.request,
            control_selection=control_selection,
            candidate_id="ash-p06-test-native",
            adapter_configuration_bytes=configuration_bytes,
            raw_measurement_bytes=canonical_json_bytes(raw),
        )

    def close(self) -> None:
        self.events.append("closed")


class _Source(ProductionNativeCandidateMeasurementSourceV2):
    def __init__(
        self,
        control_result: ProductionControlSelectionResultV2,
        plan,
        events: list[str],
        *,
        raw_schema_version: str = "2.0.0",
    ) -> None:
        self.control_result = control_result
        self.plan = plan
        self.events = events
        self.raw_schema_version = raw_schema_version
        self.service: ProductionControlSelectionV2 | None = None

    def open_session(
        self,
        request: CandidateEvaluationRequestV2,
    ) -> ProductionNativeCandidateMeasurementSessionV2:
        self.events.append("opened")
        bank = shared_bank_configuration_sha256_v2(
            dict(request.physical_candidate_items), self.plan
        )
        session = _Session(
            request,
            _control_request(request, bank=bank),
            self.control_result,
            self.events,
            raw_schema_version=self.raw_schema_version,
        )
        session.service = self.service
        return session


class ProductionCandidateProviderV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.plan = SharedBankArtifactMaterializerV2(REPOSITORY_ROOT).plan
        logical = {
            ATOMIC_STRUCTURAL_COORDINATE: 0,
            **dict(self.plan.scalar_initial_values),
        }
        self.physical = dict(materialize_candidate_vector_v2(logical, self.plan))
        candidate_sha256 = candidate_vector_sha256_v2(
            self.physical, self.plan
        )
        self.request = CandidateEvaluationRequestV2(
            run_id="provider-v2-test",
            split=DEVELOPMENT_SPLIT,
            logical_candidate_items=tuple(logical.items()),
            physical_candidate_items=tuple(self.physical.items()),
            cache_identity=EvaluationCacheIdentityV2(
                split=DEVELOPMENT_SPLIT,
                candidate_vector_sha256=candidate_sha256,
                calibration_plan_file_sha256=self.plan.plan_file_sha256,
            ),
            validation_admission=None,
        )
        self.tolerances = json.loads(
            (
                REPOSITORY_ROOT
                / "validation/calibration_v2/contracts/metric-performance-tolerances-v1.json"
            ).read_bytes()
        )

    @staticmethod
    def _gates(root: Path) -> tuple[SourceGateEvidenceV2, ...]:
        gates = []
        for identifier in ("G04", "G05", "G06"):
            relative = f"source-gates/{identifier}.json"
            payload = (identifier + " exact evidence\n").encode()
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            gates.append(
                SourceGateEvidenceV2(
                    identifier,
                    FileBindingV2(
                        relative,
                        hashlib.sha256(payload).hexdigest(),
                        len(payload),
                    ),
                )
            )
        return tuple(gates)

    @staticmethod
    def _summary() -> dict[str, object]:
        return {
            "engine_raw": {
                "mean_y_psnr_delta_vs_fixed_db": 1.0,
                "mean_y_psnr_delta_vs_non_ash_db": 2.0,
                "mean_ms_ssim_delta_vs_conventional": 0.1,
                "maximum_ringing_excursion": 0.01,
                "maximum_alias_ratio": 0.02,
                "estimated_dispatch_cost": 3.0,
                "bootstraps": {
                    "y_vs_fixed": {"ci_low": 0.5},
                    "y_vs_non_ash": {"ci_low": 0.6},
                    "y_vs_conventional": {"ci_low": 0.7},
                },
            }
        }

    def _provider(
        self,
        root: Path,
        source: ProductionNativeCandidateMeasurementSourceV2,
        result: ProductionControlSelectionResultV2,
        events: list[str],
    ) -> ProductionCandidateEvaluationProviderV2:
        service = object.__new__(ProductionControlSelectionV2)

        def authorize(request):
            del request
            events.append("authorized")
            return result

        service.authorize = authorize
        source.service = service
        capability = object.__new__(NativeControlExecutionCapabilityProviderV2)
        return ProductionCandidateEvaluationProviderV2(
            measurement_source=source,
            control_capability_provider=capability,
            metric_tolerances=self.tolerances,
            source_gates=self._gates(root),
            artifact_root=root,
            plan=self.plan,
        )

    def test_authorization_precedes_measurement_and_emits_schema_2(self) -> None:
        with TemporaryDirectory(prefix="mirmir-provider-v2-") as value:
            root = Path(value)
            events: list[str] = []
            result = _control_result()
            source = _Source(result, self.plan, events)
            provider = self._provider(root, source, result, events)
            with mock.patch(
                "validation.calibration_v2.production_candidate_provider_v2.summarize_evaluation",
                return_value=self._summary(),
            ) as summarize, mock.patch(
                "validation.calibration_v2.production_candidate_provider_v2.evaluation_feasible",
                return_value=(True, ()),
            ) as feasible:
                outcome = provider(self.request)

        self.assertIs(type(outcome), CandidateEvaluationSuccessV2)
        self.assertEqual(
            events,
            ["opened", "controls-measured", "authorized", "candidate-measured", "closed"],
        )
        self.assertEqual(outcome.document["schema_version"], "2.0.3")
        self.assertEqual(
            [item["id"] for item in outcome.document["source_evidence_sha256_bindings"]],
            ["G04", "G05", "G06"],
        )
        self.assertEqual(
            outcome.document["evaluation"]["objective"],
            {
                "mean_y_psnr_delta_vs_fixed_db": 1.0,
                "mean_y_psnr_delta_vs_non_ash_db": 2.0,
                "mean_ms_ssim_delta_vs_conventional": 0.1,
                "maximum_ringing_excursion": 0.01,
                "maximum_alias_ratio": 0.02,
                "estimated_dispatch_cost": 3.0,
            },
        )
        summarize.assert_called_once()
        feasible.assert_called_once()

    def test_historical_raw_measurement_is_rejected_and_session_closes(self) -> None:
        with TemporaryDirectory(prefix="mirmir-provider-v1-reject-") as value:
            root = Path(value)
            events: list[str] = []
            result = _control_result()
            source = _Source(
                result,
                self.plan,
                events,
                raw_schema_version="1.1.0",
            )
            provider = self._provider(root, source, result, events)
            with self.assertRaisesRegex(
                ProductionCandidateProviderV2Error,
                "scope or field set differs",
            ):
                provider(self.request)
        self.assertEqual(events[-1], "closed")

    def test_provider_bundle_is_accepted_only_at_authoritative_schema_2_0_1(
        self,
    ) -> None:
        with TemporaryDirectory(prefix="mirmir-provider-coordinator-") as value:
            root = Path(value)
            events: list[str] = []
            result = _control_result(root)
            provider = self._provider(
                root,
                _Source(result, self.plan, events),
                result,
                events,
            )
            coordinator = P06ProductionCoordinatorV2(
                artifact_root=root,
                run_id=self.request.run_id,
                provider=provider,
                provenance=RunArtifactProvenanceV2(
                    created_utc="2026-07-16T00:00:00Z",
                    project_commit="1" * 40,
                    producer="provider-v2-test",
                    command="provider-v2-test",
                    platform="macOS",
                    machine="test",
                ),
            )
            with mock.patch(
                "validation.calibration_v2.production_candidate_provider_v2.summarize_evaluation",
                return_value=self._summary(),
            ), mock.patch(
                "validation.calibration_v2.production_candidate_provider_v2.evaluation_feasible",
                return_value=(True, ()),
            ):
                outcome = coordinator._provider_outcome(self.request)
        self.assertIs(type(outcome), CandidateEvaluationSuccessV2)

    def test_mutated_g06_is_rejected_before_opening_native_session(self) -> None:
        with TemporaryDirectory(prefix="mirmir-provider-gate-") as value:
            root = Path(value)
            events: list[str] = []
            result = _control_result()
            source = _Source(result, self.plan, events)
            provider = self._provider(root, source, result, events)
            (root / "source-gates/G06.json").write_bytes(b"changed\n")
            with self.assertRaisesRegex(
                ProductionCandidateProviderV2Error,
                "G06 changed",
            ):
                provider(self.request)
        self.assertEqual(events, [])

    def test_control_capability_delegates_exact_request(self) -> None:
        with TemporaryDirectory(prefix="mirmir-provider-capability-") as value:
            root = Path(value)
            events: list[str] = []
            result = _control_result()
            provider = self._provider(
                root,
                _Source(result, self.plan, events),
                result,
                events,
            )
            request = object()
            expected = object()
            with mock.patch.object(
                NativeControlExecutionCapabilityProviderV2,
                "__call__",
                return_value=expected,
            ) as delegated:
                actual = provider.control_producer_capabilities(request)
        self.assertIs(actual, expected)
        delegated.assert_called_once_with(request)

    def test_public_factory_exposes_no_analytic_or_fake_argument(self) -> None:
        parameters = inspect.signature(
            production_candidate_evaluation_provider_v2
        ).parameters
        self.assertNotIn("analytic", parameters)
        self.assertNotIn("fake", parameters)
        self.assertIn("native_factory", parameters)


if __name__ == "__main__":
    unittest.main()
