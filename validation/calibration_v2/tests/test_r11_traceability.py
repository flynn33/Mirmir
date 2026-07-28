from __future__ import annotations

import copy
from dataclasses import FrozenInstanceError
import hashlib
import json
import math
import unittest

from validation.calibration_v2.r11_traceability import (
    R11AggregateState,
    R11AuthorizationAssertion,
    R11BoundaryState,
    R11ClaimDisposition,
    R11ClaimToken,
    R11EvidenceIdentity,
    R11ExecutionIdentity,
    R11ExecutionReceipt,
    R11InputIdentity,
    R11Observation,
    R11ObservationReason,
    R11ObservationState,
    R11PreprocessingIdentity,
    R11SoftwareIdentity,
    R11SourceIdentity,
    R11StateCounts,
    R11SubjectIdentity,
    R11ToolchainIdentity,
    R11TraceabilityError,
    aggregate_observations_r11,
    canonical_json_file_bytes_r11,
    decide_claim_r11,
    reopen_execution_receipt_r11,
)


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _identity(label: str = "base") -> R11EvidenceIdentity:
    return R11EvidenceIdentity(
        source=R11SourceIdentity(
            commit="1" * 40,
            tree="2" * 40,
        ),
        software=R11SoftwareIdentity(
            component_id=f"software.{label}",
            implementation_manifest_sha256=_digest(
                f"{label}.implementation"
            ),
            contract_sha256=_digest(f"{label}.contract"),
        ),
        subject=R11SubjectIdentity(
            subject_id=f"subject.{label}",
            subject_kind="declared_software_behavior",
            behavior_contract_sha256=_digest(f"{label}.behavior"),
        ),
        input=R11InputIdentity(
            input_id=f"input.{label}",
            input_kind="repository_fixture",
            payload_sha256=_digest(f"{label}.input"),
        ),
        preprocessing=R11PreprocessingIdentity(
            pipeline_id=f"pipeline.{label}",
            configuration_sha256=_digest(f"{label}.preprocessing"),
        ),
        toolchain=R11ToolchainIdentity(
            platform="macos",
            architecture="arm64",
            runtime_id="python",
            runtime_version="3.11.9",
            command_sha256=_digest(f"{label}.command"),
        ),
        execution=R11ExecutionIdentity(
            execution_id=f"execution.{label}",
            execution_mode="deterministic_fixture_simulation",
            invocation_sha256=_digest(f"{label}.invocation"),
        ),
    )


def _observations(
    identity: R11EvidenceIdentity,
) -> tuple[R11Observation, ...]:
    return (
        R11Observation(
            observation_id="a.observed",
            identity=identity,
            state=R11ObservationState.OBSERVED,
            value="software_behaved_as_declared",
            reason_code=None,
            failure_code=None,
        ),
        R11Observation(
            observation_id="b.not_applicable",
            identity=identity,
            state=R11ObservationState.NOT_APPLICABLE,
            value=None,
            reason_code=R11ObservationReason.DECLARED_NOT_APPLICABLE,
            failure_code=None,
        ),
        R11Observation(
            observation_id="c.not_observed",
            identity=identity,
            state=R11ObservationState.NOT_OBSERVED,
            value=None,
            reason_code=R11ObservationReason.SIMULATOR_NOT_OBSERVED,
            failure_code=None,
        ),
        R11Observation(
            observation_id="d.failed",
            identity=identity,
            state=R11ObservationState.FAILED,
            value=None,
            reason_code=R11ObservationReason.EXECUTION_FAILED,
            failure_code="fixture_execution_failed",
        ),
        R11Observation(
            observation_id="e.absent",
            identity=identity,
            state=R11ObservationState.ABSENT,
            value=None,
            reason_code=R11ObservationReason.SOURCE_DATA_ABSENT,
            failure_code=None,
        ),
    )


def _aggregate(identity: R11EvidenceIdentity):
    observations = _observations(identity)
    return aggregate_observations_r11(
        identity=identity,
        expected_observation_ids=tuple(
            item.observation_id for item in observations
        ),
        observations=tuple(reversed(observations)),
    )


def _receipt(
    requested_claim: str | R11ClaimToken = (
        R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT
    ),
) -> R11ExecutionReceipt:
    identity = _identity()
    observations = _observations(identity)
    aggregate = _aggregate(identity)
    return R11ExecutionReceipt(
        identity=identity,
        observations=tuple(reversed(observations)),
        aggregate=aggregate,
        claim_decision=decide_claim_r11(
            requested_claim=requested_claim,
            aggregate=aggregate,
        ),
    )


class R11TraceabilityTests(unittest.TestCase):
    maxDiff = None

    def test_identity_has_exact_seven_structured_components(self) -> None:
        identity = _identity()
        document = identity.to_document()
        self.assertEqual(
            list(document),
            [
                "source",
                "software",
                "subject",
                "input",
                "preprocessing",
                "toolchain",
                "execution",
                "derived_digest_sha256",
            ],
        )
        self.assertEqual(set(document["source"]), {"commit", "tree"})
        self.assertEqual(
            set(document["software"]),
            {
                "component_id",
                "implementation_manifest_sha256",
                "contract_sha256",
            },
        )
        self.assertEqual(
            set(document["subject"]),
            {"subject_id", "subject_kind", "behavior_contract_sha256"},
        )
        self.assertEqual(
            set(document["input"]),
            {"input_id", "input_kind", "payload_sha256"},
        )
        self.assertEqual(
            set(document["preprocessing"]),
            {"pipeline_id", "configuration_sha256"},
        )
        self.assertEqual(
            set(document["toolchain"]),
            {
                "platform",
                "architecture",
                "runtime_id",
                "runtime_version",
                "command_sha256",
            },
        )
        self.assertEqual(
            set(document["execution"]),
            {"execution_id", "execution_mode", "invocation_sha256"},
        )
        self.assertEqual(R11EvidenceIdentity.from_document(document), identity)
        self.assertEqual(
            identity.identity_sha256,
            _digest(
                json.dumps(
                    {
                        key: value
                        for key, value in document.items()
                        if key != "derived_digest_sha256"
                    },
                    ensure_ascii=False,
                    allow_nan=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
            ),
        )

    def test_identity_components_are_frozen(self) -> None:
        identity = _identity()
        with self.assertRaises(FrozenInstanceError):
            identity.source.commit = "3" * 40
        with self.assertRaises(FrozenInstanceError):
            identity.software.component_id = "changed"
        with self.assertRaises(FrozenInstanceError):
            identity.execution.execution_id = "changed"

    def test_identity_rejects_zero_malformed_and_extra_fields(self) -> None:
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "source_commit_must_be",
        ):
            R11SourceIdentity(commit="0" * 40, tree="2" * 40)
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "software_contract_must_be",
        ):
            R11SoftwareIdentity(
                component_id="component",
                implementation_manifest_sha256=_digest("manifest"),
                contract_sha256="0" * 64,
            )
        document = _identity().to_document()
        document["timestamp"] = "2026-07-23T00:00:00Z"
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "evidence_identity_keys_are_not_exact",
        ):
            R11EvidenceIdentity.from_document(document)

    def test_canonical_json_rejects_nonfinite_values(self) -> None:
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "canonical_json",
        ):
            canonical_json_file_bytes_r11({"value": math.nan})
        first = canonical_json_file_bytes_r11({"b": 2, "a": 1})
        second = canonical_json_file_bytes_r11({"a": 1, "b": 2})
        self.assertEqual(first, second)
        self.assertEqual(first, b'{"a":1,"b":2}\n')

    def test_observed_accepts_only_bounded_canonical_scalars(self) -> None:
        identity = _identity()
        for index, value in enumerate((True, 7, 1.25, "passed")):
            with self.subTest(value=value):
                observation = R11Observation(
                    observation_id=f"observed.{index}",
                    identity=identity,
                    state=R11ObservationState.OBSERVED,
                    value=value,
                    reason_code=None,
                    failure_code=None,
                )
                self.assertEqual(observation.value, value)
        for value in (
            None,
            [],
            {},
            math.inf,
            2**63,
            "/private/tmp/result",
        ):
            with self.subTest(invalid=value):
                with self.assertRaises(R11TraceabilityError):
                    R11Observation(
                        observation_id="observed.invalid",
                        identity=identity,
                        state=R11ObservationState.OBSERVED,
                        value=value,
                        reason_code=None,
                        failure_code=None,
                    )

    def test_observed_forbids_reason_and_failure_codes(self) -> None:
        identity = _identity()
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "observed_state_forbids",
        ):
            R11Observation(
                observation_id="observed.invalid",
                identity=identity,
                state=R11ObservationState.OBSERVED,
                value="passed",
                reason_code=R11ObservationReason.ENVIRONMENT_UNAVAILABLE,
                failure_code=None,
            )

    def test_not_applicable_reason_is_exact(self) -> None:
        identity = _identity()
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "reason_is_not_exact",
        ):
            R11Observation(
                observation_id="not_applicable.invalid",
                identity=identity,
                state=R11ObservationState.NOT_APPLICABLE,
                value=None,
                reason_code=R11ObservationReason.SOURCE_DATA_ABSENT,
                failure_code=None,
            )

    def test_not_observed_reason_is_closed(self) -> None:
        identity = _identity()
        for reason in (
            R11ObservationReason.ENVIRONMENT_UNAVAILABLE,
            R11ObservationReason.HARDWARE_NOT_OBSERVED,
            R11ObservationReason.SIMULATOR_NOT_OBSERVED,
            R11ObservationReason.OPERATOR_OBSERVATION_NOT_OBSERVED,
        ):
            R11Observation(
                observation_id=f"not_observed.{reason.value}",
                identity=identity,
                state=R11ObservationState.NOT_OBSERVED,
                value=None,
                reason_code=reason,
                failure_code=None,
            )
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "reason_is_not_exact",
        ):
            R11Observation(
                observation_id="not_observed.invalid",
                identity=identity,
                state=R11ObservationState.NOT_OBSERVED,
                value=None,
                reason_code=R11ObservationReason.EXECUTION_FAILED,
                failure_code=None,
            )

    def test_failed_requires_exact_reason_and_failure_code(self) -> None:
        identity = _identity()
        invalid = (
            (R11ObservationReason.EXECUTION_FAILED, None),
            (R11ObservationReason.ENVIRONMENT_UNAVAILABLE, "failed"),
        )
        for reason, failure in invalid:
            with self.subTest(reason=reason, failure=failure):
                with self.assertRaises(R11TraceabilityError):
                    R11Observation(
                        observation_id="failed.invalid",
                        identity=identity,
                        state=R11ObservationState.FAILED,
                        value=None,
                        reason_code=reason,
                        failure_code=failure,
                    )

    def test_absent_reason_is_exact_and_carries_no_value(self) -> None:
        identity = _identity()
        with self.assertRaises(R11TraceabilityError):
            R11Observation(
                observation_id="absent.invalid",
                identity=identity,
                state=R11ObservationState.ABSENT,
                value="not_allowed",
                reason_code=R11ObservationReason.SOURCE_DATA_ABSENT,
                failure_code=None,
            )

    def test_aggregate_preserves_all_five_states_and_observed_values(
        self,
    ) -> None:
        aggregate = _aggregate(_identity())
        self.assertEqual(
            aggregate.state_counts,
            R11StateCounts(
                observed=1,
                not_applicable=1,
                not_observed=1,
                failed=1,
                absent=1,
            ),
        )
        self.assertIs(aggregate.aggregate_state, R11AggregateState.MIXED)
        self.assertEqual(
            [item.to_document() for item in aggregate.observed_values],
            [
                {
                    "observation_id": "a.observed",
                    "value": "software_behaved_as_declared",
                }
            ],
        )
        rendered = json.dumps(aggregate.to_document(), sort_keys=True)
        for forbidden in (
            "average",
            "mean",
            "baseline",
            "winner",
            "delta",
            "superiority",
        ):
            self.assertNotIn(forbidden, rendered)

    def test_aggregate_is_input_order_independent(self) -> None:
        identity = _identity()
        observations = _observations(identity)
        first = aggregate_observations_r11(
            identity=identity,
            expected_observation_ids=tuple(
                item.observation_id for item in observations
            ),
            observations=observations,
        )
        second = aggregate_observations_r11(
            identity=identity,
            expected_observation_ids=first.expected_observation_ids,
            observations=tuple(reversed(observations)),
        )
        self.assertEqual(first, second)
        self.assertEqual(first.aggregate_sha256, second.aggregate_sha256)

    def test_homogeneous_aggregate_preserves_exact_state(self) -> None:
        identity = _identity()
        observations = tuple(
            R11Observation(
                observation_id=f"observed.{index}",
                identity=identity,
                state=R11ObservationState.OBSERVED,
                value=index,
                reason_code=None,
                failure_code=None,
            )
            for index in range(3)
        )
        aggregate = aggregate_observations_r11(
            identity=identity,
            expected_observation_ids=tuple(
                item.observation_id for item in observations
            ),
            observations=observations,
        )
        self.assertIs(aggregate.aggregate_state, R11AggregateState.OBSERVED)
        self.assertEqual(aggregate.state_counts.observed, 3)

    def test_aggregate_rejects_missing_observation(self) -> None:
        identity = _identity()
        observations = _observations(identity)
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "missing_observation_id",
        ):
            aggregate_observations_r11(
                identity=identity,
                expected_observation_ids=tuple(
                    item.observation_id for item in observations
                ),
                observations=observations[:-1],
            )

    def test_aggregate_rejects_duplicate_observation(self) -> None:
        identity = _identity()
        observations = _observations(identity)
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "duplicate_observation_id",
        ):
            aggregate_observations_r11(
                identity=identity,
                expected_observation_ids=tuple(
                    item.observation_id for item in observations
                ),
                observations=observations + (observations[0],),
            )

    def test_aggregate_rejects_unexpected_observation(self) -> None:
        identity = _identity()
        observations = _observations(identity)
        unexpected = R11Observation(
            observation_id="z.unexpected",
            identity=identity,
            state=R11ObservationState.OBSERVED,
            value=True,
            reason_code=None,
            failure_code=None,
        )
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "unexpected_observation_id",
        ):
            aggregate_observations_r11(
                identity=identity,
                expected_observation_ids=tuple(
                    item.observation_id for item in observations
                ),
                observations=observations[:-1] + (unexpected,),
            )

    def test_aggregate_rejects_mismatched_identity(self) -> None:
        identity = _identity()
        observations = list(_observations(identity))
        observations[0] = R11Observation(
            observation_id=observations[0].observation_id,
            identity=_identity("other"),
            state=R11ObservationState.OBSERVED,
            value=True,
            reason_code=None,
            failure_code=None,
        )
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "observation_identity_mismatch",
        ):
            aggregate_observations_r11(
                identity=identity,
                expected_observation_ids=tuple(
                    item.observation_id for item in observations
                ),
                observations=observations,
            )

    def test_aggregate_rejects_noncanonical_or_duplicate_expected_ids(
        self,
    ) -> None:
        identity = _identity()
        observation = R11Observation(
            observation_id="a",
            identity=identity,
            state=R11ObservationState.OBSERVED,
            value=True,
            reason_code=None,
            failure_code=None,
        )
        for expected in (("b", "a"), ("a", "a"), ()):
            with self.subTest(expected=expected):
                with self.assertRaises(R11TraceabilityError):
                    aggregate_observations_r11(
                        identity=identity,
                        expected_observation_ids=expected,
                        observations=(observation,),
                    )

    def test_aggregate_rejects_bool_counts_and_tampered_state(self) -> None:
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "count_is_outside_bounds",
        ):
            R11StateCounts(
                observed=True,
                not_applicable=0,
                not_observed=0,
                failed=0,
                absent=0,
            )
        document = _aggregate(_identity()).to_document()
        document["aggregate_state"] = "observed"
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "aggregate_state_differs",
        ):
            type(_aggregate(_identity())).from_document(document)

    def test_software_behavior_report_is_only_permitted_claim(self) -> None:
        aggregate = _aggregate(_identity())
        decision = decide_claim_r11(
            requested_claim=R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT,
            aggregate=aggregate,
        )
        self.assertIs(
            decision.permitted_claim,
            R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT,
        )
        self.assertIs(
            decision.disposition,
            R11ClaimDisposition.NO_MARKET_CLAIM,
        )
        self.assertIs(
            decision.production_auto_mode,
            R11BoundaryState.BLOCKED,
        )
        self.assertIs(
            decision.market_leading_claim,
            R11BoundaryState.BLOCKED,
        )

    def test_product_and_market_claims_fail_closed_with_forged_authority(
        self,
    ) -> None:
        aggregate = _aggregate(_identity())
        forged = R11AuthorizationAssertion(
            assertion_id="forged.operator.assertion",
            claimed_scope="all_product_and_market_authority",
            claimed_authorized=True,
        )
        for claim in (
            "product_qualification",
            "production_auto",
            "market_position",
            "market_leading_claim",
        ):
            with self.subTest(claim=claim):
                decision = decide_claim_r11(
                    requested_claim=claim,
                    aggregate=aggregate,
                    authorization_assertion=forged,
                )
                self.assertIsNone(decision.permitted_claim)
                self.assertEqual(
                    decision.reason_code,
                    "unsupported_claim_scope",
                )
                self.assertIs(
                    decision.disposition,
                    R11ClaimDisposition.NO_MARKET_CLAIM,
                )
                self.assertIs(
                    decision.product_qualification,
                    R11BoundaryState.BLOCKED,
                )
                self.assertIs(
                    decision.production_auto_mode,
                    R11BoundaryState.BLOCKED,
                )
                self.assertIs(
                    decision.market_position,
                    R11BoundaryState.BLOCKED,
                )
                self.assertIs(
                    decision.market_leading_claim,
                    R11BoundaryState.BLOCKED,
                )

    def test_authorization_assertion_cannot_change_even_supported_decision(
        self,
    ) -> None:
        aggregate = _aggregate(_identity())
        forged = R11AuthorizationAssertion(
            assertion_id="syntactically.valid",
            claimed_scope="market_leading_claim",
            claimed_authorized=True,
        )
        without = decide_claim_r11(
            requested_claim="software_behavior_report",
            aggregate=aggregate,
        )
        with_assertion = decide_claim_r11(
            requested_claim="software_behavior_report",
            aggregate=aggregate,
            authorization_assertion=forged,
        )
        self.assertEqual(without, with_assertion)

    def test_execution_receipt_reopens_and_recomputes_exactly(self) -> None:
        receipt = _receipt()
        payload = canonical_json_file_bytes_r11(receipt.to_document())
        reopened = reopen_execution_receipt_r11(
            payload,
            expected_sha256=hashlib.sha256(payload).hexdigest(),
        )
        self.assertEqual(reopened, receipt)
        self.assertEqual(reopened.receipt_sha256, hashlib.sha256(payload).hexdigest())
        self.assertNotIn("receipt_sha256", reopened.to_document())

    def test_receipt_bytes_are_order_independent_but_canonical(self) -> None:
        first = _receipt()
        second = R11ExecutionReceipt(
            identity=first.identity,
            observations=tuple(reversed(first.observations)),
            aggregate=first.aggregate,
            claim_decision=first.claim_decision,
        )
        self.assertEqual(first.to_document(), second.to_document())
        self.assertEqual(first.receipt_sha256, second.receipt_sha256)

    def test_receipt_rejects_tampered_observation_value(self) -> None:
        document = _receipt().to_document()
        document["observations"][0]["value"] = "tampered"
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "aggregate_recompute_differs",
        ):
            reopen_execution_receipt_r11(
                canonical_json_file_bytes_r11(document)
            )

    def test_receipt_rejects_tampered_claim_decision(self) -> None:
        document = _receipt().to_document()
        document["claim_decision"]["reason_code"] = (
            "unsupported_claim_scope"
        )
        with self.assertRaises(R11TraceabilityError):
            reopen_execution_receipt_r11(
                canonical_json_file_bytes_r11(document)
            )

    def test_receipt_rejects_comparative_and_provenance_escape_fields(
        self,
    ) -> None:
        forbidden_fields = (
            "comparative",
            "comparison_result",
            "baseline",
            "winner",
            "delta",
            "A-B",
            "superiority",
            "timestamp",
            "absolute_path",
            "receipt_sha256",
        )
        for field in forbidden_fields:
            with self.subTest(field=field):
                document = _receipt().to_document()
                document[field] = "forbidden"
                with self.assertRaisesRegex(
                    R11TraceabilityError,
                    "forbidden_field",
                ):
                    reopen_execution_receipt_r11(
                        canonical_json_file_bytes_r11(document)
                    )

    def test_receipt_rejects_duplicate_json_keys(self) -> None:
        payload = (
            b'{"schema_version":"1.0.0","schema_version":"1.0.0"}\n'
        )
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "duplicate_json_key",
        ):
            reopen_execution_receipt_r11(payload)

    def test_receipt_rejects_noncanonical_json(self) -> None:
        document = _receipt().to_document()
        payload = json.dumps(
            document,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=False,
            indent=2,
        ).encode("utf-8") + b"\n"
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "not_canonical",
        ):
            reopen_execution_receipt_r11(payload)

    def test_receipt_rejects_wrong_digest_and_byte_boundaries(self) -> None:
        payload = canonical_json_file_bytes_r11(_receipt().to_document())
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "sha256_differs",
        ):
            reopen_execution_receipt_r11(
                payload,
                expected_sha256=_digest("wrong"),
            )
        for invalid in (
            payload[:-1],
            payload.replace(b"\n", b"\r\n"),
            b"\x00" + payload,
            b"",
            b"x" * (8 * 1024 * 1024 + 1),
        ):
            with self.subTest(invalid=invalid[:20]):
                with self.assertRaisesRegex(
                    R11TraceabilityError,
                    "bytes_are_outside",
                ):
                    reopen_execution_receipt_r11(invalid)

    def test_receipt_rejects_nonfinite_json_constant(self) -> None:
        payload = b'{"value":NaN}\n'
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "nonfinite_json_constant",
        ):
            reopen_execution_receipt_r11(payload)

    def test_closed_enums_reject_unknown_states_and_reasons(self) -> None:
        document = _observations(_identity())[0].to_document()
        document["state"] = "unknown"
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "not_closed",
        ):
            R11Observation.from_document(document)
        document = _observations(_identity())[2].to_document()
        document["reason_code"] = "operator_says_it_is_fine"
        with self.assertRaisesRegex(
            R11TraceabilityError,
            "not_closed",
        ):
            R11Observation.from_document(document)


if __name__ == "__main__":
    unittest.main()
