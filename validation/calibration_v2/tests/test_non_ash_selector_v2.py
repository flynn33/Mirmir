from __future__ import annotations

from collections.abc import Mapping
import copy
from dataclasses import replace
import hashlib
import json
from pathlib import Path
from typing import Callable, Dict, Optional, Tuple
import unittest

from validation.calibration_v2.baseline_ablation_budget_v2 import (
    parse_baseline_ablation_budget_v2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    CALIBRATION_PLAN_V2_FILE_SHA256,
    DEVELOPMENT_SPLIT,
    DEVELOPMENT_STATUS_ABORTED,
    DEVELOPMENT_STATUS_CONVERGED,
    DEVELOPMENT_STATUS_MAXIMUM_SWEEPS_EXHAUSTED,
    FAILURE_TYPE_CONSTRAINT,
    FAILURE_TYPE_EVALUATION,
    FAILURE_TYPE_EVIDENCE_INTEGRITY,
    VALIDATION_SPLIT,
    VALIDATION_STATUS_FAILED_ALL_CANDIDATES,
    VALIDATION_STATUS_SELECTED,
    VALIDATION_STATUS_ABORTED_EVIDENCE_INTEGRITY,
    NonAshSelectorAttemptRecordV2,
    NonAshSelectorEvaluationFailureV2,
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorEvaluationV2,
    NonAshSelectorV2Error,
    canonical_rule_values_v2,
    development_attempt_record_sha256_v2,
    non_ash_validation_neighborhood_v2,
    replay_non_ash_development_search_v2,
    rule_mapping_v2,
    rule_sha256_v2,
    run_non_ash_development_search_v2,
    run_non_ash_validation_selection_v2,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"


class FlippingMapping(Mapping[str, object]):
    def __init__(self, source: Mapping[str, object]) -> None:
        self.source = dict(source)
        self.read_counts = {name: 0 for name in self.source}

    def __iter__(self):
        return iter(self.source)

    def __len__(self) -> int:
        return len(self.source)

    def __getitem__(self, name: str) -> object:
        self.read_counts[name] += 1
        if self.read_counts[name] > 1:
            return 128
        return self.source[name]


class DuplicateItemsMapping(Mapping[str, object]):
    def __init__(self, source: Mapping[str, object]) -> None:
        self.source = dict(source)

    def __iter__(self):
        return iter(self.source)

    def __len__(self) -> int:
        return len(self.source)

    def __getitem__(self, name: str) -> object:
        return self.source[name]

    def items(self):
        items = list(self.source.items())
        return items + [items[0]]


class NonAshSelectorV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        overlay_payload = (
            CALIBRATION_ROOT / "contracts/baseline-ablation-budget-v2.json"
        ).read_bytes()
        schema_payload = (
            CALIBRATION_ROOT / "schemas/baseline-ablation-budget-v2.schema.json"
        ).read_bytes()
        overlay = json.loads(overlay_payload)
        authority_payloads = {
            binding["id"]: (ROOT / binding["path"]).read_bytes()
            for binding in overlay["authority_bindings"]
        }
        cls.profile = parse_baseline_ablation_budget_v2(
            overlay_payload,
            schema_payload=schema_payload,
            authority_payloads=authority_payloads,
        )
        cls.scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256="a" * 64,
            degradation_policy_sha256="b" * 64,
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256="e" * 64,
        )
        cls.zero_rule = {
            name: 0 for name in cls.profile.coordinate_order
        }

    @staticmethod
    def digest(label: str, rule_sha256: str) -> str:
        return hashlib.sha256(
            f"{label}:{rule_sha256}".encode("utf-8")
        ).hexdigest()

    def evaluation(
        self,
        rule: Mapping[str, object],
        *,
        split: str,
        objective: Tuple[object, ...],
        scope: Optional[NonAshSelectorEvaluationScopeV2] = None,
    ) -> NonAshSelectorEvaluationV2:
        values = canonical_rule_values_v2(rule, self.profile)
        rule_sha256 = rule_sha256_v2(values, self.profile)
        return NonAshSelectorEvaluationV2(
            split=split,
            scope=self.scope if scope is None else scope,
            rule_sha256=rule_sha256,
            evaluation_sha256=self.digest("evaluation", rule_sha256),
            objective_summary_sha256=self.digest("objective", rule_sha256),
            output_manifest_sha256=self.digest("outputs", rule_sha256),
            objective_means=objective,
        )

    def failure(
        self,
        rule: Mapping[str, object],
        *,
        split: str,
        scope: Optional[NonAshSelectorEvaluationScopeV2] = None,
        failure_type: str = FAILURE_TYPE_EVALUATION,
    ) -> NonAshSelectorEvaluationFailureV2:
        values = canonical_rule_values_v2(rule, self.profile)
        rule_sha256 = rule_sha256_v2(values, self.profile)
        return NonAshSelectorEvaluationFailureV2(
            split=split,
            scope=self.scope if scope is None else scope,
            rule_sha256=rule_sha256,
            failure_type=failure_type,
            attempt_failure_sha256=self.digest("failure", rule_sha256),
        )

    def run_development(
        self,
        objective: Callable[[Tuple[int, ...]], Tuple[object, ...]],
    ):
        evidence: Dict[str, NonAshSelectorEvaluationV2] = {}
        calls = {"evaluate": 0, "reopen": 0}

        def evaluator(rule: Mapping[str, int]):
            calls["evaluate"] += 1
            values = canonical_rule_values_v2(rule, self.profile)
            result = self.evaluation(
                rule,
                split=DEVELOPMENT_SPLIT,
                objective=objective(values),
            )
            evidence[result.evaluation_sha256] = result
            return result

        def reopener(evaluation_sha256: str):
            calls["reopen"] += 1
            return evidence[evaluation_sha256]

        result = run_non_ash_development_search_v2(
            self.profile,
            self.scope,
            evaluator,
            reopener,
        )
        return result, calls

    def rehash(
        self,
        record: NonAshSelectorAttemptRecordV2,
        **changes: object,
    ) -> NonAshSelectorAttemptRecordV2:
        changed = replace(record, record_sha256="1" * 64, **changes)
        return replace(
            changed,
            record_sha256=development_attempt_record_sha256_v2(changed),
        )

    @staticmethod
    def trace_evidence_reopener(
        records: Tuple[NonAshSelectorAttemptRecordV2, ...],
    ):
        evidence = {
            record.outcome.evaluation_sha256: record.outcome
            for record in records
            if type(record.outcome) is NonAshSelectorEvaluationV2
        }

        def reopen(evaluation_sha256: str):
            return evidence[evaluation_sha256]

        return reopen

    def test_rule_hash_preserves_frozen_v1_object_bytes(self) -> None:
        zero_values = canonical_rule_values_v2(self.zero_rule, self.profile)
        self.assertEqual(
            rule_sha256_v2(zero_values, self.profile),
            "e0d562c9d2c87b3c11166734ff93a47bd0c218709834bc8d73a68bfca8b45542",
        )
        first_negative = list(zero_values)
        first_negative[0] = -384
        self.assertEqual(
            rule_sha256_v2(tuple(first_negative), self.profile),
            "8557db376620ec41b6a72a9960aaca6368f1e08d77a861aa55895b082d352959",
        )
        first_positive = list(zero_values)
        first_positive[0] = 128
        self.assertEqual(
            rule_sha256_v2(tuple(first_positive), self.profile),
            "2b4c78bc61ce47bfec6558da4f85e27fe04a280e175767d4348b2d89efa553b2",
        )
        self.assertNotEqual(
            rule_sha256_v2(zero_values, self.profile),
            hashlib.sha256(canonical_json_bytes(list(zero_values))).hexdigest(),
        )

    def test_rule_boundary_snapshots_once_and_rejects_aliases(self) -> None:
        flipping = FlippingMapping(self.zero_rule)
        self.assertEqual(
            canonical_rule_values_v2(flipping, self.profile),
            (0,) * 27,
        )
        self.assertEqual(set(flipping.read_counts.values()), {1})
        with self.assertRaisesRegex(NonAshSelectorV2Error, "invalid field"):
            canonical_rule_values_v2(
                DuplicateItemsMapping(self.zero_rule),
                self.profile,
            )
        for changed in (
            {**self.zero_rule, self.profile.coordinate_order[0]: True},
            {**self.zero_rule, "extra": 0},
            dict(list(self.zero_rule.items())[1:]),
        ):
            with self.subTest(changed=len(changed)), self.assertRaises(
                NonAshSelectorV2Error
            ):
                canonical_rule_values_v2(changed, self.profile)

    def test_evaluation_scope_and_objective_are_strict(self) -> None:
        for values in (
            (
                "0" * 64,
                "b" * 64,
                CALIBRATION_PLAN_V2_FILE_SHA256,
                "e" * 64,
            ),
            (
                "a" * 64,
                "0" * 64,
                CALIBRATION_PLAN_V2_FILE_SHA256,
                "e" * 64,
            ),
            ("a" * 64, "b" * 64, "c" * 64, "e" * 64),
            (
                "a" * 64,
                "b" * 64,
                CALIBRATION_PLAN_V2_FILE_SHA256,
                "0" * 64,
            ),
        ):
            with self.subTest(values=values), self.assertRaises(
                NonAshSelectorV2Error
            ):
                NonAshSelectorEvaluationScopeV2(*values)
        for objective in (
            (0, 0, 0, 0),
            (0, 0, 0, 0, True),
            (0, 0, 0, 0, float("nan")),
            (0, 0, 0, 0, float("inf")),
        ):
            with self.subTest(objective=objective), self.assertRaises(
                NonAshSelectorV2Error
            ):
                self.evaluation(
                    self.zero_rule,
                    split=DEVELOPMENT_SPLIT,
                    objective=objective,
                )
        huge = 10**1000
        result = self.evaluation(
            self.zero_rule,
            split=DEVELOPMENT_SPLIT,
            objective=(huge, 0, 0, 0, 0),
        )
        self.assertEqual(result.objective_means[0], huge)

    def test_mutated_frozen_profile_scope_and_outcome_fail_closed(self) -> None:
        bad_selector = copy.deepcopy(self.profile)
        object.__setattr__(bad_selector, "selector_id", "continuous-linear-bank-selector-q15-v1")
        bad_coordinates = copy.deepcopy(self.profile)
        object.__setattr__(
            bad_coordinates,
            "coordinate_order",
            ([],) + self.profile.coordinate_order[1:],
        )
        bad_authority = copy.deepcopy(self.profile)
        authority = copy.deepcopy(bad_authority.authority_identity)
        object.__setattr__(authority, "overlay_file_sha256", "0" * 64)
        object.__setattr__(bad_authority, "authority_identity", authority)
        for profile in (bad_selector, bad_coordinates, bad_authority):
            with self.subTest(profile=profile), self.assertRaises(
                NonAshSelectorV2Error
            ):
                canonical_rule_values_v2(self.zero_rule, profile)

        bad_scope = copy.deepcopy(self.scope)
        object.__setattr__(bad_scope, "shared_bank_configuration_sha256", "0" * 64)
        with self.assertRaises(NonAshSelectorV2Error):
            run_non_ash_development_search_v2(
                self.profile,
                bad_scope,
                lambda rule: None,
                lambda digest: None,
            )

        result, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        outcome = copy.deepcopy(result.attempt_records[0].outcome)
        object.__setattr__(outcome, "evaluation_sha256", "0" * 64)
        malformed = replace(result.attempt_records[0], outcome=outcome)
        with self.assertRaises(NonAshSelectorV2Error):
            development_attempt_record_sha256_v2(malformed)

    def test_hash_and_replay_reject_boolean_aliases(self) -> None:
        result, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        tampered = list(result.attempt_records)
        values = list(tampered[4].canonical_rule_values)
        values[0] = False
        changed = replace(
            tampered[4],
            coordinate_ordinal=False,
            coordinate_value=False,
            canonical_rule_values=tuple(values),
            record_sha256="1" * 64,
        )
        with self.assertRaises(NonAshSelectorV2Error):
            development_attempt_record_sha256_v2(changed)
        tampered[4] = replace(changed, record_sha256="c" * 64)
        with self.assertRaises(NonAshSelectorV2Error):
            replay_non_ash_development_search_v2(
                self.profile,
                self.scope,
                tampered,
            )

    def test_attempt_record_field_deletion_always_raises_typed_error(self) -> None:
        result, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        field_names = tuple(
            NonAshSelectorAttemptRecordV2.__dataclass_fields__
        )
        for field_name in field_names:
            record = copy.deepcopy(result.attempt_records[0])
            object.__delattr__(record, field_name)
            with self.subTest(field_name=field_name), self.assertRaises(
                NonAshSelectorV2Error
            ):
                development_attempt_record_sha256_v2(record)

    def test_cached_rule_replay_accepts_only_integrity_failure(self) -> None:
        result, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        for failure_type in (
            FAILURE_TYPE_CONSTRAINT,
            FAILURE_TYPE_EVALUATION,
        ):
            failure = self.failure(
                self.zero_rule,
                split=DEVELOPMENT_SPLIT,
                failure_type=failure_type,
            )
            changed = replace(
                result.attempt_records[4],
                cache_hit=False,
                outcome=failure,
                record_sha256="1" * 64,
            )
            changed = replace(
                changed,
                record_sha256=development_attempt_record_sha256_v2(changed),
            )
            records = result.attempt_records[:4] + (changed,)
            with self.subTest(failure_type=failure_type), self.assertRaises(
                NonAshSelectorV2Error
            ):
                replay_non_ash_development_search_v2(
                    self.profile,
                    self.scope,
                    records,
                )

        integrity = self.failure(
            self.zero_rule,
            split=DEVELOPMENT_SPLIT,
            failure_type=FAILURE_TYPE_EVIDENCE_INTEGRITY,
        )
        changed = replace(
            result.attempt_records[4],
            cache_hit=False,
            outcome=integrity,
            record_sha256="1" * 64,
        )
        changed = replace(
            changed,
            record_sha256=development_attempt_record_sha256_v2(changed),
        )
        replayed = replay_non_ash_development_search_v2(
            self.profile,
            self.scope,
            result.attempt_records[:4] + (changed,),
        )
        self.assertEqual(replayed.status, DEVELOPMENT_STATUS_ABORTED)

    def test_callback_exceptions_are_wrapped_at_every_boundary(self) -> None:
        def raising(*args):
            raise KeyError("provider failure")

        with self.assertRaisesRegex(
            NonAshSelectorV2Error,
            "development evaluator exception",
        ):
            run_non_ash_development_search_v2(
                self.profile,
                self.scope,
                raising,
                raising,
            )

        evidence: Dict[str, NonAshSelectorEvaluationV2] = {}

        def evaluator(rule: Mapping[str, int]):
            result = self.evaluation(
                rule,
                split=DEVELOPMENT_SPLIT,
                objective=(-sum(abs(value) for value in rule.values()), 0, 0, 0, 0),
            )
            evidence[result.evaluation_sha256] = result
            return result

        with self.assertRaisesRegex(
            NonAshSelectorV2Error,
            "development cache exception",
        ):
            run_non_ash_development_search_v2(
                self.profile,
                self.scope,
                evaluator,
                raising,
            )

        development, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        with self.assertRaisesRegex(
            NonAshSelectorV2Error,
            "validation evaluator exception",
        ):
            run_non_ash_validation_selection_v2(
                self.profile,
                self.scope,
                development.attempt_records,
                self.trace_evidence_reopener(development.attempt_records),
                raising,
            )

    def test_cache_reopen_rejects_byte_distinct_numeric_aliases(self) -> None:
        evidence: Dict[str, NonAshSelectorEvaluationV2] = {}

        def evaluator(rule: Mapping[str, int]):
            result = self.evaluation(
                rule,
                split=DEVELOPMENT_SPLIT,
                objective=(-sum(abs(value) for value in rule.values()), 0, 0, 0, 0),
            )
            evidence[result.evaluation_sha256] = result
            return result

        def reopener(evaluation_sha256: str):
            reopened = evidence[evaluation_sha256]
            return replace(
                reopened,
                objective_means=tuple(float(value) for value in reopened.objective_means),
            )

        with self.assertRaisesRegex(NonAshSelectorV2Error, "different evidence"):
            run_non_ash_development_search_v2(
                self.profile,
                self.scope,
                evaluator,
                reopener,
            )

    def test_one_sweep_convergence_records_cache_reopens(self) -> None:
        result, calls = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        self.assertEqual(result.status, DEVELOPMENT_STATUS_CONVERGED)
        self.assertEqual(result.completed_sweeps, 1)
        self.assertEqual(result.attempt_count, 190)
        self.assertEqual(result.unique_evaluation_count, 163)
        self.assertEqual(calls, {"evaluate": 163, "reopen": 27})
        self.assertEqual(result.terminal_rule_values, (0,) * 27)
        self.assertEqual(
            sum(record.cache_hit for record in result.attempt_records),
            27,
        )
        self.assertEqual(
            replay_non_ash_development_search_v2(
                self.profile,
                self.scope,
                result.attempt_records,
            ),
            result,
        )

    def test_equal_objectives_use_v1_canonical_object_byte_order(self) -> None:
        result, _ = self.run_development(lambda values: (0, 0, 0, 0, 0))
        self.assertEqual(result.status, DEVELOPMENT_STATUS_CONVERGED)
        self.assertEqual(result.completed_sweeps, 2)
        self.assertEqual(result.terminal_rule_values, (-128,) * 27)

    def test_exact_3403_convergence_on_unchanged_sweep_18(self) -> None:
        def objective(values: Tuple[int, ...]) -> Tuple[object, ...]:
            wave = values[-17:]
            bits = tuple(value == 128 for value in wave)
            penalty = sum(value != 0 for value in values[:-17]) + sum(
                value not in {0, 128} for value in wave
            )
            score = (1 << 18) * int(bits[-1]) + sum(
                (1 << index) * int(bits[index] == bits[index + 1])
                for index in range(16)
            ) - 1_000_000_000 * penalty
            return (score, 0, 0, 0, 0)

        result, calls = self.run_development(objective)
        self.assertEqual(result.status, DEVELOPMENT_STATUS_CONVERGED)
        self.assertEqual(result.completed_sweeps, 18)
        self.assertEqual(result.attempt_count, 3403)
        self.assertEqual(result.unique_evaluation_count, 2799)
        self.assertEqual(calls, {"evaluate": 2799, "reopen": 604})
        self.assertEqual(result.attempt_records[-1].attempt_ordinal, 3402)
        self.assertEqual(result.terminal_rule_values[-17:], (128,) * 17)

    def test_changed_sweep_18_is_typed_maximum_exhaustion(self) -> None:
        def objective(values: Tuple[int, ...]) -> Tuple[object, ...]:
            wave = values[-18:]
            bits = tuple(value == 128 for value in wave)
            penalty = sum(value != 0 for value in values[:-18]) + sum(
                value not in {0, 128} for value in wave
            )
            score = (1 << 19) * int(bits[-1]) + sum(
                (1 << index) * int(bits[index] == bits[index + 1])
                for index in range(17)
            ) - 1_000_000_000 * penalty
            return (score, 0, 0, 0, 0)

        result, calls = self.run_development(objective)
        self.assertEqual(
            result.status,
            DEVELOPMENT_STATUS_MAXIMUM_SWEEPS_EXHAUSTED,
        )
        self.assertEqual(result.completed_sweeps, 18)
        self.assertEqual(result.attempt_count, 3403)
        self.assertEqual(result.unique_evaluation_count, 2900)
        self.assertLessEqual(result.unique_evaluation_count, 2917)
        self.assertEqual(calls, {"evaluate": 2900, "reopen": 503})
        self.assertIsNone(result.terminal_rule_values)
        self.assertIsNone(result.terminal_rule_sha256)
        self.assertEqual(result.incumbent_rule_values[-18:], (128,) * 18)
        self.assertEqual(
            replay_non_ash_development_search_v2(
                self.profile,
                self.scope,
                result.attempt_records,
            ),
            result,
        )

    def test_ceiling_trace_has_exact_schedule_and_hash_chain(self) -> None:
        def objective(values: Tuple[int, ...]) -> Tuple[object, ...]:
            wave = values[-18:]
            bits = tuple(value == 128 for value in wave)
            penalty = sum(value != 0 for value in values[:-18]) + sum(
                value not in {0, 128} for value in wave
            )
            score = (1 << 19) * int(bits[-1]) + sum(
                (1 << index) * int(bits[index] == bits[index + 1])
                for index in range(17)
            ) - 1_000_000_000 * penalty
            return (score, 0, 0, 0, 0)

        result, _ = self.run_development(objective)
        for ordinal, record in enumerate(result.attempt_records):
            self.assertEqual(record.attempt_ordinal, ordinal)
            self.assertEqual(
                record.previous_record_sha256,
                None if ordinal == 0 else result.attempt_records[ordinal - 1].record_sha256,
            )
            self.assertEqual(
                record.record_sha256,
                development_attempt_record_sha256_v2(record),
            )
            if ordinal == 0:
                self.assertEqual(
                    (record.phase, record.sweep, record.coordinate_ordinal),
                    ("initial", 0, None),
                )
                continue
            offset = ordinal - 1
            sweep = 1 + offset // 189
            coordinate_ordinal = (offset % 189) // 7
            value_ordinal = offset % 7
            self.assertEqual(record.phase, "coordinate_scan")
            self.assertEqual(record.sweep, sweep)
            self.assertEqual(record.coordinate_ordinal, coordinate_ordinal)
            self.assertEqual(
                record.coordinate_name,
                self.profile.coordinate_order[coordinate_ordinal],
            )
            self.assertEqual(
                record.coordinate_value,
                self.profile.values[value_ordinal],
            )

    def test_typed_development_failure_aborts_without_terminal(self) -> None:
        evidence: Dict[str, NonAshSelectorEvaluationV2] = {}
        calls = 0

        def evaluator(rule: Mapping[str, int]):
            nonlocal calls
            calls += 1
            if calls == 2:
                return self.failure(rule, split=DEVELOPMENT_SPLIT)
            result = self.evaluation(
                rule,
                split=DEVELOPMENT_SPLIT,
                objective=(0, 0, 0, 0, 0),
            )
            evidence[result.evaluation_sha256] = result
            return result

        result = run_non_ash_development_search_v2(
            self.profile,
            self.scope,
            evaluator,
            lambda digest: evidence[digest],
        )
        self.assertEqual(result.status, DEVELOPMENT_STATUS_ABORTED)
        self.assertEqual(result.completed_sweeps, 0)
        self.assertEqual(result.attempt_count, 2)
        self.assertEqual(result.unique_evaluation_count, 1)
        self.assertIsNotNone(result.incumbent_rule_values)
        self.assertIsNone(result.terminal_rule_values)
        self.assertIsInstance(
            result.attempt_records[-1].outcome,
            NonAshSelectorEvaluationFailureV2,
        )

    def test_cache_reopen_failure_is_a_typed_aborted_attempt(self) -> None:
        evidence: Dict[str, NonAshSelectorEvaluationV2] = {}

        def evaluator(rule: Mapping[str, int]):
            result = self.evaluation(
                rule,
                split=DEVELOPMENT_SPLIT,
                objective=(0, 0, 0, 0, 0),
            )
            evidence[result.evaluation_sha256] = result
            return result

        def reopener(evaluation_sha256: str):
            reopened = evidence[evaluation_sha256]
            return NonAshSelectorEvaluationFailureV2(
                split=DEVELOPMENT_SPLIT,
                scope=self.scope,
                rule_sha256=reopened.rule_sha256,
                failure_type=FAILURE_TYPE_EVIDENCE_INTEGRITY,
                attempt_failure_sha256=self.digest(
                    "cache-reopen-failure",
                    reopened.rule_sha256,
                ),
            )

        result = run_non_ash_development_search_v2(
            self.profile,
            self.scope,
            evaluator,
            reopener,
        )
        self.assertEqual(result.status, DEVELOPMENT_STATUS_ABORTED)
        self.assertEqual(result.attempt_count, 5)
        self.assertFalse(result.attempt_records[-1].cache_hit)
        self.assertIsInstance(
            result.attempt_records[-1].outcome,
            NonAshSelectorEvaluationFailureV2,
        )

    def test_mixed_bank_degradation_and_reopened_evidence_fail_closed(self) -> None:
        other_bank = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256="c" * 64,
            degradation_policy_sha256=self.scope.degradation_policy_sha256,
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256=(
                self.scope.cached_16_operator_output_manifest_sha256
            ),
        )
        other_degradation = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=self.scope.shared_bank_configuration_sha256,
            degradation_policy_sha256="d" * 64,
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256=(
                self.scope.cached_16_operator_output_manifest_sha256
            ),
        )
        other_cache = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=(
                self.scope.shared_bank_configuration_sha256
            ),
            degradation_policy_sha256=self.scope.degradation_policy_sha256,
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256="f" * 64,
        )
        for scope in (other_bank, other_degradation, other_cache):
            with self.subTest(scope=scope), self.assertRaisesRegex(
                NonAshSelectorV2Error,
                "mixed or stale evidence",
            ):
                run_non_ash_development_search_v2(
                    self.profile,
                    self.scope,
                    lambda rule, scope=scope: self.evaluation(
                        rule,
                        split=DEVELOPMENT_SPLIT,
                        objective=(0, 0, 0, 0, 0),
                        scope=scope,
                    ),
                    lambda digest: None,
                )

        evidence: Dict[str, NonAshSelectorEvaluationV2] = {}

        def evaluator(rule: Mapping[str, int]):
            result = self.evaluation(
                rule,
                split=DEVELOPMENT_SPLIT,
                objective=(-sum(abs(value) for value in rule.values()), 0, 0, 0, 0),
            )
            evidence[result.evaluation_sha256] = result
            return result

        def stale_reopener(evaluation_sha256: str):
            reopened = evidence[evaluation_sha256]
            return replace(reopened, scope=other_bank)

        with self.assertRaisesRegex(
            NonAshSelectorV2Error,
            "mixed or stale evidence",
        ):
            run_non_ash_development_search_v2(
                self.profile,
                self.scope,
                evaluator,
                stale_reopener,
            )

    def test_replay_rejects_context_tampering_and_incomplete_trace(self) -> None:
        result, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        other_scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256="c" * 64,
            degradation_policy_sha256=self.scope.degradation_policy_sha256,
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256=(
                self.scope.cached_16_operator_output_manifest_sha256
            ),
        )
        with self.assertRaises(NonAshSelectorV2Error):
            replay_non_ash_development_search_v2(
                self.profile,
                other_scope,
                result.attempt_records,
            )
        with self.assertRaisesRegex(NonAshSelectorV2Error, "before a terminal"):
            replay_non_ash_development_search_v2(
                self.profile,
                self.scope,
                result.attempt_records[:-1],
            )
        tampered = list(result.attempt_records)
        tampered[1] = self.rehash(
            tampered[1],
            coordinate_name=self.profile.coordinate_order[1],
        )
        with self.assertRaisesRegex(NonAshSelectorV2Error, "differs from the schedule"):
            replay_non_ash_development_search_v2(
                self.profile,
                self.scope,
                tampered,
            )

    def test_validation_neighborhood_is_exact_and_ordered(self) -> None:
        candidates = non_ash_validation_neighborhood_v2(
            self.profile,
            self.zero_rule,
        )
        self.assertEqual(len(candidates), 163)
        self.assertTrue(candidates[0].terminal)
        self.assertEqual(candidates[0].canonical_rule_values, (0,) * 27)
        self.assertEqual(len({candidate.rule_sha256 for candidate in candidates}), 163)
        expected_values = (-384, -256, -128, 128, 256, 384)
        for coordinate_ordinal in range(27):
            group = candidates[1 + coordinate_ordinal * 6 : 7 + coordinate_ordinal * 6]
            self.assertEqual(
                tuple(candidate.candidate_ordinal for candidate in group),
                tuple(range(1 + coordinate_ordinal * 6, 7 + coordinate_ordinal * 6)),
            )
            self.assertEqual(
                tuple(candidate.coordinate_ordinal for candidate in group),
                (coordinate_ordinal,) * 6,
            )
            self.assertEqual(
                tuple(candidate.to_value for candidate in group),
                expected_values,
            )
            for candidate in group:
                differences = sum(
                    left != right
                    for left, right in zip(
                        candidate.canonical_rule_values,
                        candidates[0].canonical_rule_values,
                    )
                )
                self.assertEqual(differences, 1)

    def test_validation_evaluates_all_163_and_selects_terminal(self) -> None:
        calls = 0
        development, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )

        def evaluator(rule: Mapping[str, int]):
            nonlocal calls
            calls += 1
            return self.evaluation(
                rule,
                split=VALIDATION_SPLIT,
                objective=(-sum(abs(value) for value in rule.values()), 0, 0, 0, 0),
            )

        result = run_non_ash_validation_selection_v2(
            self.profile,
            self.scope,
            development.attempt_records,
            self.trace_evidence_reopener(development.attempt_records),
            evaluator,
        )
        self.assertEqual(result.status, VALIDATION_STATUS_SELECTED)
        self.assertEqual(calls, 163)
        self.assertEqual(len(result.outcomes), 163)
        self.assertTrue(result.selected_candidate.terminal)
        self.assertEqual(result.selected_candidate.candidate_ordinal, 0)

    def test_validation_continues_typed_failures_and_can_fail_all(self) -> None:
        calls = 0
        development, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )

        def evaluator(rule: Mapping[str, int]):
            nonlocal calls
            calls += 1
            return self.failure(rule, split=VALIDATION_SPLIT)

        result = run_non_ash_validation_selection_v2(
            self.profile,
            self.scope,
            development.attempt_records,
            self.trace_evidence_reopener(development.attempt_records),
            evaluator,
        )
        self.assertEqual(result.status, VALIDATION_STATUS_FAILED_ALL_CANDIDATES)
        self.assertEqual(calls, 163)
        self.assertEqual(len(result.outcomes), 163)
        self.assertIsNone(result.selected_candidate)
        self.assertIsNone(result.selected_evaluation)

    def test_validation_integrity_failure_aborts_without_a_winner(self) -> None:
        development, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        calls = 0

        def evaluator(rule: Mapping[str, int]):
            nonlocal calls
            calls += 1
            if calls == 5:
                return self.failure(
                    rule,
                    split=VALIDATION_SPLIT,
                    failure_type=FAILURE_TYPE_EVIDENCE_INTEGRITY,
                )
            return self.evaluation(
                rule,
                split=VALIDATION_SPLIT,
                objective=(0, 0, 0, 0, 0),
            )

        result = run_non_ash_validation_selection_v2(
            self.profile,
            self.scope,
            development.attempt_records,
            self.trace_evidence_reopener(development.attempt_records),
            evaluator,
        )
        self.assertEqual(
            result.status,
            VALIDATION_STATUS_ABORTED_EVIDENCE_INTEGRITY,
        )
        self.assertEqual(calls, 5)
        self.assertEqual(len(result.outcomes), 5)
        self.assertIsNone(result.selected_candidate)
        self.assertIsNone(result.selected_evaluation)

    def test_validation_capability_is_blocked_before_development_freeze(self) -> None:
        calls = 0

        def evaluator(rule: Mapping[str, int]):
            nonlocal calls
            calls += 1
            return self.evaluation(
                rule,
                split=VALIDATION_SPLIT,
                objective=(0, 0, 0, 0, 0),
            )

        with self.assertRaises(NonAshSelectorV2Error):
            run_non_ash_validation_selection_v2(
                self.profile,
                self.scope,
                (),
                self.trace_evidence_reopener(()),
                evaluator,
            )
        self.assertEqual(calls, 0)

    def test_validation_admission_reopens_all_development_evidence(self) -> None:
        development, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        validation_calls = 0

        def validation_evaluator(rule: Mapping[str, int]):
            nonlocal validation_calls
            validation_calls += 1
            return self.evaluation(
                rule,
                split=VALIDATION_SPLIT,
                objective=(0, 0, 0, 0, 0),
            )

        def missing(evaluation_sha256: str):
            raise KeyError(evaluation_sha256)

        with self.assertRaisesRegex(
            NonAshSelectorV2Error,
            "could not be reopened",
        ):
            run_non_ash_validation_selection_v2(
                self.profile,
                self.scope,
                development.attempt_records,
                missing,
                validation_evaluator,
            )
        self.assertEqual(validation_calls, 0)

        evidence_reopener = self.trace_evidence_reopener(
            development.attempt_records
        )

        def changed(evaluation_sha256: str):
            reopened = evidence_reopener(evaluation_sha256)
            return replace(reopened, output_manifest_sha256="c" * 64)

        with self.assertRaisesRegex(
            NonAshSelectorV2Error,
            "differs from the frozen trace",
        ):
            run_non_ash_validation_selection_v2(
                self.profile,
                self.scope,
                development.attempt_records,
                changed,
                validation_evaluator,
            )
        self.assertEqual(validation_calls, 0)

        result = run_non_ash_validation_selection_v2(
            self.profile,
            self.scope,
            development.attempt_records,
            evidence_reopener,
            validation_evaluator,
        )
        self.assertEqual(
            result.development_admission.reopened_unique_evaluation_count,
            development.unique_evaluation_count,
        )
        self.assertEqual(
            len(result.development_admission.development_evaluation_sha256s),
            163,
        )

    def test_validation_tie_freezes_object_bytes_when_vector_disagrees(self) -> None:
        development, _ = self.run_development(
            lambda values: (-sum(abs(value) for value in values), 0, 0, 0, 0)
        )
        candidates = non_ash_validation_neighborhood_v2(
            self.profile,
            self.zero_rule,
        )
        magnitude = next(
            candidate
            for candidate in candidates
            if candidate.coordinate_name == "weight_magnitude_q8_8"
            and candidate.to_value == -384
        )
        chroma = next(
            candidate
            for candidate in candidates
            if candidate.coordinate_name == "weight_chroma_alignment_q8_8"
            and candidate.to_value == -384
        )
        self.assertLess(
            canonical_json_bytes(list(magnitude.canonical_rule_values)),
            canonical_json_bytes(list(chroma.canonical_rule_values)),
        )
        self.assertGreater(
            canonical_json_bytes(
                rule_mapping_v2(magnitude.canonical_rule_values, self.profile)
            ),
            canonical_json_bytes(
                rule_mapping_v2(chroma.canonical_rule_values, self.profile)
            ),
        )
        successful = {magnitude.rule_sha256, chroma.rule_sha256}

        def evaluator(rule: Mapping[str, int]):
            values = canonical_rule_values_v2(rule, self.profile)
            rule_sha256 = rule_sha256_v2(values, self.profile)
            if rule_sha256 in successful:
                return self.evaluation(
                    rule,
                    split=VALIDATION_SPLIT,
                    objective=(1, 1, 1, 1, 1),
                )
            return self.failure(rule, split=VALIDATION_SPLIT)

        result = run_non_ash_validation_selection_v2(
            self.profile,
            self.scope,
            development.attempt_records,
            self.trace_evidence_reopener(development.attempt_records),
            evaluator,
        )
        self.assertEqual(result.status, VALIDATION_STATUS_SELECTED)
        self.assertEqual(result.selected_candidate, chroma)


if __name__ == "__main__":
    unittest.main()
