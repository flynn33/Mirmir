from __future__ import annotations

from collections import Counter
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import unittest

from validation.calibration_v2 import runner
from validation.calibration_v2.calibration_plan_codec import (
    CalibrationPlanCodecError,
    ParsedCalibrationPlanV2,
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
    serialized_candidate_vector_v2,
    validate_candidate_constraints_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    ATTEMPTS_PER_COMPLETE_SWEEP,
    ATTEMPT_STATUS_CONSTRAINT_FAILURE,
    ATTEMPT_STATUS_EVALUATION_FAILURE,
    ATTEMPT_STATUS_FEASIBLE,
    DEVELOPMENT_SPLIT,
    MAXIMUM_DEVELOPMENT_ATTEMPTS,
    SCALAR_ATTEMPTS_PER_SWEEP,
    STATUS_FAILED_INFEASIBLE_FIXED_POINT,
    STATUS_FAILED_MAXIMUM_SWEEPS,
    STATUS_FAILED_NO_ELIGIBLE_STRUCTURAL,
    STATUS_IN_PROGRESS,
    STATUS_TERMINATED_FEASIBLE,
    STRUCTURAL_ATTEMPTS_PER_SWEEP,
    VALIDATION_SPLIT,
    ArtifactBindingV2,
    AttemptRecordV2,
    AuthenticatedDevelopmentEvaluationFailureV2,
    AuthenticatedDevelopmentEvaluationV2,
    CalibrationSchedulerV2Error,
    DevelopmentEvaluationV2,
    EvaluationCacheIdentityV2,
    attempt_record_sha256_v2,
    canonical_development_failure_reasons_v2,
    development_search_key_v2,
    evaluation_cache_identity_v2,
    replay_development_attempts_v2,
    run_development_search_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
PLAN_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"
ZERO_SHA256 = "0" * 64


def parsed_plan() -> ParsedCalibrationPlanV2:
    plan_document = json.loads(PLAN_PATH.read_bytes())
    bound_payloads = {
        binding["id"]: (ROOT / binding["path"]).read_bytes()
        for binding in plan_document["input_bindings"]
    }
    return parse_calibration_plan_v2(
        PLAN_PATH.read_bytes(),
        bound_payloads=bound_payloads,
    )


def evaluation(
    score: object,
    *,
    feasible: bool = True,
    failures: tuple[str, ...] = (),
) -> DevelopmentEvaluationV2:
    return DevelopmentEvaluationV2(
        feasible=feasible,
        failure_reasons=failures,
        mean_y_psnr_delta_vs_fixed_db=score,
        mean_y_psnr_delta_vs_non_ash_db=score,
        mean_ms_ssim_delta_vs_conventional=score,
        maximum_ringing_excursion=0,
        maximum_alias_ratio=0,
        estimated_dispatch_cost=0,
    )


class PreferredInitialEvaluator:
    def __init__(self, plan: ParsedCalibrationPlanV2) -> None:
        self.initial = dict(plan.scalar_initial_values)
        self.calls: list[EvaluationCacheIdentityV2] = []

    def __call__(
        self,
        logical: dict[str, object],
        physical: dict[str, object],
        identity: EvaluationCacheIdentityV2,
    ) -> DevelopmentEvaluationV2:
        del physical
        self.calls.append(identity)
        deviations = sum(
            logical[name] != value for name, value in self.initial.items()
        )
        score = -(
            1_000 * int(logical[ATOMIC_STRUCTURAL_COORDINATE]) + deviations
        )
        return evaluation(score)


def artifact_binding(label: str, *, directory: str = "evaluations") -> ArtifactBindingV2:
    digest = hashlib.sha256(label.encode("utf-8")).hexdigest()
    return ArtifactBindingV2(
        path=f"{directory}/{digest}.json",
        sha256=digest,
        size_bytes=123,
    )


class AuthenticatedPreferredInitialEvaluator(PreferredInitialEvaluator):
    def __call__(
        self,
        logical: dict[str, object],
        physical: dict[str, object],
        identity: EvaluationCacheIdentityV2,
    ) -> AuthenticatedDevelopmentEvaluationV2:
        result = super().__call__(logical, physical, identity)
        return AuthenticatedDevelopmentEvaluationV2(
            evaluation=result,
            artifact=artifact_binding(identity.candidate_vector_sha256),
        )


class WaveEvaluator:
    """A static objective whose backward dependency wave exceeds eight sweeps."""

    def __init__(self, plan: ParsedCalibrationPlanV2) -> None:
        self.initial = dict(plan.scalar_initial_values)
        self.wave_names = plan.scalar_parameter_order[-9:]
        self.calls = 0
        domains = dict(plan.scalar_domains)
        if any(len(domains[name]) < 2 for name in self.wave_names):
            raise AssertionError("wave coordinate lacks an alternative")

    def __call__(
        self,
        logical: dict[str, object],
        physical: dict[str, object],
        identity: EvaluationCacheIdentityV2,
    ) -> DevelopmentEvaluationV2:
        del physical, identity
        self.calls += 1
        bits = [int(logical[name] != self.initial[name]) for name in self.wave_names]
        matches = sum(
            (1 << index) * int(bits[index] == bits[index + 1])
            for index in range(len(bits) - 1)
        )
        outside_deviations = sum(
            logical[name] != initial
            for name, initial in self.initial.items()
            if name not in self.wave_names
        )
        score = (
            matches
            + 512 * bits[-1]
            - 10_000 * outside_deviations
            - 10_000 * int(logical[ATOMIC_STRUCTURAL_COORDINATE])
        )
        return evaluation(score)


def rechain(records: tuple[AttemptRecordV2, ...]) -> tuple[AttemptRecordV2, ...]:
    result = []
    previous = ZERO_SHA256
    for sequence, source in enumerate(records):
        draft = replace(
            source,
            sequence=sequence,
            previous_record_sha256=previous,
            record_sha256=ZERO_SHA256,
        )
        record = replace(draft, record_sha256=attempt_record_sha256_v2(draft))
        result.append(record)
        previous = record.record_sha256
    return tuple(result)


class CalibrationSchedulerV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = parsed_plan()

    def run_preferred(self):
        evaluator = PreferredInitialEvaluator(self.plan)
        result = run_development_search_v2(self.plan, evaluator)
        return result, evaluator

    def test_first_sweep_exact_trace_and_no_structural_default(self) -> None:
        result, _ = self.run_preferred()
        self.assertEqual(result.status, STATUS_TERMINATED_FEASIBLE)
        self.assertEqual(result.attempt_count, 2 * ATTEMPTS_PER_COMPLETE_SWEEP)
        self.assertEqual(STRUCTURAL_ATTEMPTS_PER_SWEEP, 256)
        self.assertEqual(SCALAR_ATTEMPTS_PER_SWEEP, 155)
        self.assertEqual(ATTEMPTS_PER_COMPLETE_SWEEP, 411)

        first_sweep = result.attempt_records[:ATTEMPTS_PER_COMPLETE_SWEEP]
        self.assertEqual(
            [record.value for record in first_sweep[:256]],
            list(range(256)),
        )
        self.assertTrue(
            all(record.phase == "structural_scan" for record in first_sweep[:256])
        )
        second_sweep = result.attempt_records[ATTEMPTS_PER_COMPLETE_SWEEP:]
        self.assertEqual(
            [
                dict(record.physical_candidate_items)[
                    ATOMIC_STRUCTURAL_COORDINATE
                ]
                for record in second_sweep[:256]
            ],
            list(range(256)),
        )
        first_scalar = first_sweep[256]
        self.assertEqual(first_scalar.phase, "scalar_scan")
        self.assertEqual(first_scalar.coordinate, self.plan.scalar_parameter_order[0])
        self.assertEqual(
            first_scalar.value,
            dict(self.plan.scalar_domains)[self.plan.scalar_parameter_order[0]][0],
        )
        final_scalar = first_sweep[410]
        self.assertEqual(final_scalar.coordinate, self.plan.scalar_parameter_order[-1])
        self.assertEqual(
            final_scalar.value,
            dict(self.plan.scalar_domains)[self.plan.scalar_parameter_order[-1]][-1],
        )
        first_second_sweep = result.attempt_records[411]
        self.assertEqual(first_second_sweep.sweep, 2)
        self.assertEqual(first_second_sweep.phase, "structural_scan")
        self.assertEqual(first_second_sweep.value, 0)
        self.assertEqual(
            dict(first_second_sweep.physical_candidate_items)[
                ATOMIC_STRUCTURAL_COORDINATE
            ],
            0,
        )

        before_scan = replay_development_attempts_v2(
            self.plan,
            result.attempt_records[:255],
        )
        self.assertEqual(before_scan.status, STATUS_IN_PROGRESS)
        self.assertIsNone(before_scan.incumbent_candidate_sha256)
        after_scan = replay_development_attempts_v2(
            self.plan,
            result.attempt_records[:256],
        )
        self.assertEqual(after_scan.status, STATUS_IN_PROGRESS)
        self.assertIsNotNone(after_scan.incumbent_candidate_sha256)

    def test_authenticated_artifacts_are_hashed_and_reused_on_cache_hits(self) -> None:
        evaluator = AuthenticatedPreferredInitialEvaluator(self.plan)
        result = run_development_search_v2(self.plan, evaluator)
        evaluated = [
            record
            for record in result.attempt_records
            if record.evaluation is not None
        ]
        self.assertTrue(evaluated)
        self.assertTrue(
            all(record.evaluation_artifact is not None for record in evaluated)
        )
        self.assertTrue(
            all(record.failure_artifact is None for record in evaluated)
        )
        first_by_candidate: dict[str, ArtifactBindingV2] = {}
        cache_hit = None
        for record in evaluated:
            binding = record.evaluation_artifact
            self.assertIsNotNone(binding)
            previous = first_by_candidate.setdefault(
                record.candidate_vector_sha256,
                binding,
            )
            self.assertEqual(binding, previous)
            if record.cache_hit and cache_hit is None:
                cache_hit = record
        self.assertIsNotNone(cache_hit)

        replacement = artifact_binding("different-evaluation")
        tampered = tuple(
            replace(record, evaluation_artifact=replacement)
            if record.sequence == cache_hit.sequence
            else record
            for record in result.attempt_records
        )
        rechained = rechain(tampered)
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "cache-hit semantics are invalid",
        ):
            replay_development_attempts_v2(self.plan, rechained)

    def test_authenticated_failure_and_constraint_bindings_are_disjoint(self) -> None:
        failure = AuthenticatedDevelopmentEvaluationFailureV2(
            failure_reasons=("native evaluator failed",),
            artifact=artifact_binding("native evaluator failed", directory="failures"),
        )
        result = run_development_search_v2(
            self.plan,
            lambda logical, physical, identity: failure,
        )
        failed = next(
            record
            for record in result.attempt_records
            if record.status == ATTEMPT_STATUS_EVALUATION_FAILURE
        )
        self.assertIsNone(failed.evaluation)
        self.assertIsNone(failed.evaluation_artifact)
        self.assertEqual(failed.failure_artifact, failure.artifact)

        preferred, _ = self.run_preferred()
        constraint = next(
            record
            for record in preferred.attempt_records
            if record.status == ATTEMPT_STATUS_CONSTRAINT_FAILURE
        )
        tampered = tuple(
            replace(record, failure_artifact=failure.artifact)
            if record.sequence == constraint.sequence
            else record
            for record in preferred.attempt_records
        )
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "constraint-failure attempt semantics are invalid",
        ):
            replay_development_attempts_v2(self.plan, rechain(tampered))

    def test_artifact_binding_rejects_ambiguous_paths_and_sizes(self) -> None:
        digest = hashlib.sha256(b"artifact").hexdigest()
        for path, sha256, size_bytes in (
            (f"/evaluations/{digest}.json", digest, 1),
            (f"evaluations/../{digest}.json", digest, 1),
            (f"evaluations/{'f' * 64}.json", digest, 1),
            (f"evaluations/{'0' * 64}.json", "0" * 64, 1),
            (f"evaluations/{digest}.json", digest, True),
            (f"evaluations/{digest}.json", digest, 0),
        ):
            with self.subTest(path=path, size_bytes=size_bytes):
                with self.assertRaises(CalibrationSchedulerV2Error):
                    ArtifactBindingV2(
                        path=path,
                        sha256=sha256,
                        size_bytes=size_bytes,
                    )

        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "not in evaluations",
        ):
            AuthenticatedDevelopmentEvaluationV2(
                evaluation=evaluation(1),
                artifact=artifact_binding("wrong-directory", directory="failures"),
            )
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "not in failures",
        ):
            AuthenticatedDevelopmentEvaluationFailureV2(
                failure_reasons=("typed failure",),
                artifact=artifact_binding("wrong-directory", directory="evaluations"),
            )

    def test_first_incumbent_forces_second_complete_sweep(self) -> None:
        result, _ = self.run_preferred()
        expected_logical = {
            ATOMIC_STRUCTURAL_COORDINATE: 0,
            **dict(self.plan.scalar_initial_values),
        }
        expected_physical = materialize_candidate_vector_v2(
            expected_logical,
            self.plan,
        )
        expected_identity = evaluation_cache_identity_v2(
            DEVELOPMENT_SPLIT,
            expected_physical,
            self.plan,
        )
        self.assertEqual(result.completed_sweeps, 2)
        self.assertEqual(result.attempt_count, 822)
        self.assertEqual(
            result.incumbent_candidate_sha256,
            expected_identity.candidate_vector_sha256,
        )

    def test_ranking_and_tie_break_use_inherited_semantics_and_48_values(self) -> None:
        physical_2 = materialize_candidate_vector_v2(
            {
                ATOMIC_STRUCTURAL_COORDINATE: 2,
                **dict(self.plan.scalar_initial_values),
            },
            self.plan,
        )
        physical_10 = materialize_candidate_vector_v2(
            {
                ATOMIC_STRUCTURAL_COORDINATE: 10,
                **dict(self.plan.scalar_initial_values),
            },
            self.plan,
        )
        tied = evaluation(0)
        selected = min(
            (physical_2, physical_10),
            key=lambda physical: development_search_key_v2(
                tied,
                physical,
                self.plan,
            ),
        )
        self.assertEqual(
            serialized_candidate_vector_v2(physical_10, self.plan)
            < serialized_candidate_vector_v2(physical_2, self.plan),
            True,
        )
        self.assertEqual(selected, physical_10)

        feasible = evaluation(-100)
        infeasible = evaluation(
            100,
            feasible=False,
            failures=("engine_raw:state_causality",),
        )
        self.assertLess(
            development_search_key_v2(feasible, physical_2, self.plan),
            development_search_key_v2(infeasible, physical_2, self.plan),
        )
        failures = (
            "engine_raw:state_causality",
            "container_decoded:state_causality",
            "engine_raw:bootstrap:y_vs_fixed",
        )
        self.assertEqual(
            canonical_development_failure_reasons_v2(failures),
            runner.canonical_development_failure_reasons(failures),
        )

    def test_development_evaluation_rejects_negative_rank_costs(self) -> None:
        baseline = evaluation(0)
        for name in (
            "maximum_ringing_excursion",
            "maximum_alias_ratio",
            "estimated_dispatch_cost",
        ):
            with self.subTest(name=name), self.assertRaises(
                CalibrationSchedulerV2Error
            ):
                replace(baseline, **{name: -1})

    def test_cache_identity_attempt_accounting_and_constraint_identity(self) -> None:
        result, evaluator = self.run_preferred()
        self.assertEqual(
            len(evaluator.calls),
            result.evaluator_invocation_count,
        )
        self.assertGreater(result.cache_hit_count, 0)
        identity_counts = Counter(
            record.cache_identity for record in result.attempt_records
        )
        self.assertTrue(
            any(count > 1 for count in identity_counts.values())
        )
        self.assertTrue(
            any(
                record.cache_hit and identity_counts[record.cache_identity] > 1
                for record in result.attempt_records
            )
        )

        constraint = next(
            record
            for record in result.attempt_records
            if record.status == ATTEMPT_STATUS_CONSTRAINT_FAILURE
        )
        self.assertEqual(len(constraint.candidate_vector_sha256), 64)
        self.assertFalse(constraint.cache_hit)
        self.assertNotIn(constraint.cache_identity, evaluator.calls)

        development = result.attempt_records[0].cache_identity
        validation = replace(development, split=VALIDATION_SPLIT)
        other_plan = EvaluationCacheIdentityV2(
            split=DEVELOPMENT_SPLIT,
            candidate_vector_sha256=development.candidate_vector_sha256,
            calibration_plan_file_sha256="a" * 64,
        )
        self.assertNotEqual(development, validation)
        self.assertNotEqual(development, other_plan)

    def test_evaluation_failure_is_recorded_and_ineligible(self) -> None:
        calls = []

        def evaluator_with_failure(logical, physical, identity):
            del physical
            calls.append(identity)
            ordinal = int(logical[ATOMIC_STRUCTURAL_COORDINATE])
            if ordinal == 0:
                raise RuntimeError("injected evaluator failure")
            return evaluation(-ordinal)

        result = run_development_search_v2(self.plan, evaluator_with_failure)
        self.assertEqual(result.status, STATUS_TERMINATED_FEASIBLE)
        self.assertTrue(
            any(
                record.status == ATTEMPT_STATUS_EVALUATION_FAILURE
                for record in result.attempt_records
            )
        )
        incumbent = dict(result.incumbent_logical_candidate_items or ())
        self.assertEqual(incumbent[ATOMIC_STRUCTURAL_COORDINATE], 1)
        self.assertTrue(calls)

    def test_declared_fatal_evaluator_exception_is_not_recorded(self) -> None:
        class FatalEvaluatorError(RuntimeError):
            pass

        expected = FatalEvaluatorError("authenticated provider contract drift")

        def evaluator(logical, physical, identity):
            del logical, physical, identity
            raise expected

        with self.assertRaises(FatalEvaluatorError) as raised:
            run_development_search_v2(
                self.plan,
                evaluator,
                fatal_evaluator_exceptions=(FatalEvaluatorError,),
            )
        self.assertIs(raised.exception, expected)

    def test_all_evaluation_failures_end_without_an_incumbent(self) -> None:
        def failing_evaluator(logical, physical, identity):
            del logical, physical, identity
            raise RuntimeError("injected total evaluator failure")

        result = run_development_search_v2(self.plan, failing_evaluator)
        self.assertEqual(result.status, STATUS_FAILED_NO_ELIGIBLE_STRUCTURAL)
        self.assertEqual(result.attempt_count, STRUCTURAL_ATTEMPTS_PER_SWEEP)
        self.assertEqual(result.completed_sweeps, 0)
        self.assertIsNone(result.incumbent_candidate_sha256)
        self.assertEqual(result.cache_hit_count, 0)
        self.assertTrue(
            all(
                record.status == ATTEMPT_STATUS_EVALUATION_FAILURE
                for record in result.attempt_records
            )
        )

    def test_infeasible_restoration_retains_complete_scalar_candidate(self) -> None:
        initial = dict(self.plan.scalar_initial_values)
        coordinate = self.plan.scalar_parameter_order[0]
        target = None
        for value in dict(self.plan.scalar_domains)[coordinate]:
            if value == initial[coordinate]:
                continue
            logical = {
                ATOMIC_STRUCTURAL_COORDINATE: 0,
                **initial,
                coordinate: value,
            }
            try:
                validate_candidate_constraints_v2(
                    materialize_candidate_vector_v2(logical, self.plan),
                    self.plan,
                )
            except CalibrationPlanCodecError:
                continue
            target = value
            break
        self.assertIsNotNone(target)

        def infeasible_evaluator(logical, physical, identity):
            del physical, identity
            other_deviations = sum(
                logical[name] != value
                for name, value in initial.items()
                if name != coordinate
            )
            score = (
                1_000 * int(logical[coordinate] == target)
                - 100 * int(logical[ATOMIC_STRUCTURAL_COORDINATE])
                - other_deviations
            )
            return evaluation(
                score,
                feasible=False,
                failures=("engine_raw:state_causality",),
            )

        result = run_development_search_v2(self.plan, infeasible_evaluator)
        self.assertEqual(result.status, STATUS_FAILED_INFEASIBLE_FIXED_POINT)
        self.assertEqual(result.completed_sweeps, 2)
        self.assertEqual(result.attempt_count, 2 * ATTEMPTS_PER_COMPLETE_SWEEP)
        incumbent = dict(result.incumbent_logical_candidate_items or ())
        self.assertEqual(incumbent[ATOMIC_STRUCTURAL_COORDINATE], 0)
        self.assertEqual(incumbent[coordinate], target)
        for name, value in initial.items():
            if name != coordinate:
                self.assertEqual(incumbent[name], value)

    def test_eight_changed_sweeps_exhaust_exact_budget(self) -> None:
        evaluator = WaveEvaluator(self.plan)
        result = run_development_search_v2(self.plan, evaluator)
        self.assertEqual(result.status, STATUS_FAILED_MAXIMUM_SWEEPS)
        self.assertEqual(result.completed_sweeps, 8)
        self.assertEqual(result.attempt_count, MAXIMUM_DEVELOPMENT_ATTEMPTS)
        self.assertEqual(result.attempt_records[-1].sequence, 3287)
        self.assertGreater(result.cache_hit_count, 0)
        self.assertTrue(
            any(
                record.status == ATTEMPT_STATUS_CONSTRAINT_FAILURE
                for record in result.attempt_records
            )
        )

    def test_resume_prefix_matches_uninterrupted_execution(self) -> None:
        reference, _ = self.run_preferred()
        for count in (1, 255, 256, 257, 410, 411, 822):
            with self.subTest(count=count):
                prefix = reference.attempt_records[:count]
                evaluator = PreferredInitialEvaluator(self.plan)
                resumed = run_development_search_v2(
                    self.plan,
                    evaluator,
                    resume_records=prefix,
                    expected_resume_attempt_count=count,
                    expected_resume_last_record_sha256=prefix[-1].record_sha256,
                )
                self.assertEqual(resumed, reference)
                expected_suffix_calls = sum(
                    not record.cache_hit
                    and record.status != ATTEMPT_STATUS_CONSTRAINT_FAILURE
                    for record in reference.attempt_records[count:]
                )
                self.assertEqual(len(evaluator.calls), expected_suffix_calls)

        with self.assertRaises(CalibrationSchedulerV2Error):
            run_development_search_v2(
                self.plan,
                PreferredInitialEvaluator(self.plan),
                resume_records=reference.attempt_records[:1],
            )

    def test_semantic_replay_rejects_self_consistent_tampering(self) -> None:
        reference, _ = self.run_preferred()
        records = reference.attempt_records
        cache_hit_index = next(
            index for index, record in enumerate(records) if record.cache_hit
        )

        swapped = list(records)
        swapped[0], swapped[1] = swapped[1], swapped[0]
        duplicated = (records[0], *records)
        wrong_value = list(records)
        wrong_value[0] = replace(wrong_value[0], value=1)
        wrong_cache = list(records)
        wrong_cache[cache_hit_index] = replace(
            wrong_cache[cache_hit_index],
            cache_hit=False,
        )
        wrong_split = list(records)
        wrong_split[0] = replace(
            wrong_split[0],
            cache_identity=replace(
                wrong_split[0].cache_identity,
                split=VALIDATION_SPLIT,
            ),
        )
        wrong_candidate_hash = list(records)
        wrong_candidate_hash[0] = replace(
            wrong_candidate_hash[0],
            candidate_vector_sha256="b" * 64,
        )

        mutations = (
            rechain(tuple(swapped)),
            rechain(tuple(duplicated)),
            rechain(tuple(wrong_value)),
            rechain(tuple(wrong_cache)),
            rechain(tuple(wrong_split)),
            rechain(tuple(wrong_candidate_hash)),
        )
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(
                CalibrationSchedulerV2Error
            ):
                replay_development_attempts_v2(self.plan, mutation)

        prefix = records[:100]
        with self.assertRaises(CalibrationSchedulerV2Error):
            replay_development_attempts_v2(
                self.plan,
                prefix,
                expected_attempt_count=101,
                expected_last_record_sha256=prefix[-1].record_sha256,
            )
        with self.assertRaises(CalibrationSchedulerV2Error):
            replay_development_attempts_v2(
                self.plan,
                prefix,
                expected_attempt_count=100,
                expected_last_record_sha256="c" * 64,
            )


if __name__ == "__main__":
    unittest.main()
