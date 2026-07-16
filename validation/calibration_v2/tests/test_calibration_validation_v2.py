from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import unittest

from validation.calibration_v2.calibration_plan_codec import (
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
    serialized_candidate_vector_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    DEVELOPMENT_SPLIT,
    MAXIMUM_VALIDATION_NEIGHBORHOOD,
    VALIDATION_SPLIT,
    CalibrationSchedulerV2Error,
    DevelopmentEvaluationV2,
    ScoredValidationCandidateV2,
    ValidationEvaluationFailureV2,
    ValidationEvaluationV2,
    attempt_record_sha256_v2,
    run_development_search_v2,
    select_validation_candidate_v2,
    validation_admission_v2,
    validation_neighborhood_v2,
    validation_objective_key_v2,
    validation_pareto_frontier_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
PLAN_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"
ZERO_SHA256 = "0" * 64
EXPECTED_TERMINAL_SHA256 = (
    "5ef8b175db2a957509037f5a8c48f1a1238de6e08cf57d7511f44552e1dfb1dc"
)


def parsed_plan():
    plan_document = json.loads(PLAN_PATH.read_bytes())
    bound_payloads = {
        binding["id"]: (ROOT / binding["path"]).read_bytes()
        for binding in plan_document["input_bindings"]
    }
    return parse_calibration_plan_v2(
        PLAN_PATH.read_bytes(),
        bound_payloads=bound_payloads,
    )


def development_evaluation(
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


def validation_evaluation(
    *,
    feasible: bool = True,
    failures: tuple[str, ...] = (),
    y_fixed: object = 5,
    y_non_ash: object = 5,
    y_conventional: object = 5,
    ms_ssim: object = 5,
    ringing: object = 5,
    alias: object = 5,
    cost: object = 5,
) -> ValidationEvaluationV2:
    return ValidationEvaluationV2(
        feasible=feasible,
        failure_reasons=failures,
        y_vs_fixed_ci_low=y_fixed,
        y_vs_non_ash_ci_low=y_non_ash,
        y_vs_conventional_ci_low=y_conventional,
        mean_ms_ssim_delta_vs_conventional=ms_ssim,
        maximum_ringing_excursion=ringing,
        maximum_alias_ratio=alias,
        estimated_dispatch_cost=cost,
    )


class PreferredInitialEvaluator:
    def __init__(self, plan) -> None:
        self.initial = dict(plan.scalar_initial_values)

    def __call__(self, logical, physical, identity):
        del physical, identity
        deviations = sum(
            logical[name] != value for name, value in self.initial.items()
        )
        score = -(
            1_000 * int(logical[ATOMIC_STRUCTURAL_COORDINATE]) + deviations
        )
        return development_evaluation(score)


def rechain(records):
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


class CalibrationValidationV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = parsed_plan()
        cls.initial_logical = {
            ATOMIC_STRUCTURAL_COORDINATE: 0,
            **dict(cls.plan.scalar_initial_values),
        }
        cls.neighborhood = validation_neighborhood_v2(
            cls.initial_logical,
            cls.plan,
        )
        cls.development = run_development_search_v2(
            cls.plan,
            PreferredInitialEvaluator(cls.plan),
        )
        cls.admission = validation_admission_v2(
            cls.plan,
            cls.development.attempt_records,
            expected_attempt_count=cls.development.attempt_count,
            expected_last_record_sha256=cls.development.last_record_sha256,
        )

    def candidate_for_ordinal(self, ordinal):
        return next(
            candidate
            for candidate in self.admission.admitted_candidates
            if dict(candidate.logical_candidate_items)[
                ATOMIC_STRUCTURAL_COORDINATE
            ]
            == ordinal
            and all(
                dict(candidate.logical_candidate_items)[name] == value
                for name, value in self.plan.scalar_initial_values
            )
        )

    def complete_validation_scores(self, overrides=(), *, omitted=()):
        by_sha256 = {
            scored.candidate.candidate_vector_sha256: scored.evaluation
            for scored in overrides
        }
        omitted_sha256 = {
            candidate.candidate_vector_sha256 for candidate in omitted
        }
        default = validation_evaluation(
            feasible=False,
            failures=("engine_raw:background_fixture",),
            y_fixed=-100,
            y_non_ash=-100,
            y_conventional=-100,
            ms_ssim=-100,
            ringing=100,
            alias=100,
            cost=100,
        )
        return tuple(
            ScoredValidationCandidateV2(
                candidate,
                by_sha256.get(candidate.candidate_vector_sha256, default),
            )
            for candidate in self.admission.admitted_candidates
            if candidate.candidate_vector_sha256 not in omitted_sha256
        )

    def test_neighborhood_has_exact_unique_atomic_set_and_counts(self) -> None:
        neighborhood = self.neighborhood
        self.assertEqual(
            neighborhood.candidate_count_before_constraint_filtering,
            MAXIMUM_VALIDATION_NEIGHBORHOOD,
        )
        self.assertEqual(neighborhood.constraint_valid_candidate_count, 361)
        self.assertEqual(
            neighborhood.terminal_candidate_sha256,
            EXPECTED_TERMINAL_SHA256,
        )
        self.assertEqual(
            len(
                {
                    candidate.candidate_vector_sha256
                    for candidate in neighborhood.candidates_before_constraint_filtering
                }
            ),
            374,
        )
        self.assertTrue(
            all(
                len(candidate.physical_candidate_items) == 48
                for candidate in neighborhood.candidates_before_constraint_filtering
            )
        )

        terminal = self.initial_logical
        structural = []
        scalar = []
        terminal_physical = materialize_candidate_vector_v2(terminal, self.plan)
        for candidate in neighborhood.candidates_before_constraint_filtering:
            logical = dict(candidate.logical_candidate_items)
            differences = [
                name
                for name in self.plan.logical_parameter_order
                if logical[name] != terminal[name]
            ]
            if not differences or differences == [ATOMIC_STRUCTURAL_COORDINATE]:
                structural.append(candidate)
                self.assertTrue(
                    all(
                        logical[name] == terminal[name]
                        for name in self.plan.scalar_parameter_order
                    )
                )
                self.assertEqual(
                    dict(candidate.physical_candidate_items),
                    materialize_candidate_vector_v2(logical, self.plan),
                )
            else:
                scalar.append(candidate)
                self.assertEqual(len(differences), 1)
                self.assertNotEqual(differences[0], ATOMIC_STRUCTURAL_COORDINATE)
                self.assertEqual(
                    tuple(dict(candidate.physical_candidate_items).items())[:11],
                    tuple(terminal_physical.items())[:11],
                )
            self.assertEqual(
                candidate.development_cache_identity.split,
                DEVELOPMENT_SPLIT,
            )
            self.assertEqual(
                candidate.validation_cache_identity.split,
                VALIDATION_SPLIT,
            )
            self.assertNotEqual(
                candidate.development_cache_identity,
                candidate.validation_cache_identity,
            )
        self.assertEqual(len(structural), 256)
        self.assertEqual(len(scalar), 118)

    def test_widest_threshold_terminal_keeps_all_374_candidates_valid(self) -> None:
        logical = dict(self.initial_logical)
        domains = dict(self.plan.scalar_domains)
        for band in (
            "edge_present",
            "coherent_structure",
            "texture_high_frequency",
            "alias_or_ringing_risk",
            "chroma_luma_structure_aligned",
        ):
            logical[f"{band}_low_unorm15"] = min(
                domains[f"{band}_low_unorm15"]
            )
            logical[f"{band}_high_unorm15"] = max(
                domains[f"{band}_high_unorm15"]
            )
        neighborhood = validation_neighborhood_v2(logical, self.plan)
        self.assertEqual(
            neighborhood.candidate_count_before_constraint_filtering,
            374,
        )
        self.assertEqual(neighborhood.constraint_valid_candidate_count, 374)

    def test_admission_requires_complete_development_evidence(self) -> None:
        admission = self.admission
        self.assertEqual(admission.development_evidence_count, 361)
        self.assertEqual(admission.admitted_candidate_count, 361)
        self.assertEqual(
            {
                row.candidate.candidate_vector_sha256
                for row in admission.development_evidence
            },
            {
                candidate.candidate_vector_sha256
                for candidate in admission.neighborhood.constraint_valid_candidates
            },
        )
        self.assertIn(
            admission.neighborhood.terminal_candidate_sha256,
            {
                candidate.candidate_vector_sha256
                for candidate in admission.admitted_candidates
            },
        )

        def missing_neighbor_evaluator(logical, physical, identity):
            ordinal = logical[ATOMIC_STRUCTURAL_COORDINATE]
            if ordinal == 255:
                raise RuntimeError("injected missing neighbor evidence")
            return PreferredInitialEvaluator(self.plan)(
                logical,
                physical,
                identity,
            )

        missing = run_development_search_v2(
            self.plan,
            missing_neighbor_evaluator,
        )
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "lacks development evidence",
        ):
            validation_admission_v2(
                self.plan,
                missing.attempt_records,
                expected_attempt_count=missing.attempt_count,
                expected_last_record_sha256=missing.last_record_sha256,
            )

        tampered = list(self.development.attempt_records)
        tampered[0] = replace(
            tampered[0],
            cache_identity=replace(
                tampered[0].cache_identity,
                split=VALIDATION_SPLIT,
            ),
        )
        rechained = rechain(tuple(tampered))
        with self.assertRaises(CalibrationSchedulerV2Error):
            validation_admission_v2(
                self.plan,
                rechained,
                expected_attempt_count=self.development.attempt_count,
                expected_last_record_sha256=rechained[-1].record_sha256,
            )

    def test_development_infeasible_neighbor_is_evidenced_but_not_admitted(self) -> None:
        initial = dict(self.plan.scalar_initial_values)

        def one_infeasible(logical, physical, identity):
            del physical, identity
            ordinal = int(logical[ATOMIC_STRUCTURAL_COORDINATE])
            deviations = sum(
                logical[name] != value for name, value in initial.items()
            )
            score = -(1_000 * ordinal + deviations)
            if ordinal == 255:
                return development_evaluation(
                    score,
                    feasible=False,
                    failures=("engine_raw:state_causality",),
                )
            return development_evaluation(score)

        result = run_development_search_v2(self.plan, one_infeasible)
        admission = validation_admission_v2(
            self.plan,
            result.attempt_records,
            expected_attempt_count=result.attempt_count,
            expected_last_record_sha256=result.last_record_sha256,
        )
        ordinal_255_evidence = [
            row
            for row in admission.development_evidence
            if dict(row.candidate.logical_candidate_items)[
                ATOMIC_STRUCTURAL_COORDINATE
            ]
            == 255
        ]
        self.assertEqual(len(ordinal_255_evidence), 1)
        self.assertFalse(ordinal_255_evidence[0].evaluation.feasible)
        self.assertNotIn(
            ordinal_255_evidence[0].candidate.candidate_vector_sha256,
            {
                candidate.candidate_vector_sha256
                for candidate in admission.admitted_candidates
            },
        )

    def test_validation_rank_directions_and_full_vector_tie_break(self) -> None:
        candidate = self.candidate_for_ordinal(2)
        physical = dict(candidate.physical_candidate_items)
        baseline = validation_evaluation()
        baseline_key = validation_objective_key_v2(
            baseline,
            physical,
            self.plan,
        )
        improvements = (
            replace(baseline, y_vs_fixed_ci_low=6),
            replace(baseline, y_vs_non_ash_ci_low=6),
            replace(baseline, y_vs_conventional_ci_low=6),
            replace(baseline, mean_ms_ssim_delta_vs_conventional=6),
            replace(baseline, maximum_ringing_excursion=4),
            replace(baseline, maximum_alias_ratio=4),
            replace(baseline, estimated_dispatch_cost=4),
        )
        for index, improved in enumerate(improvements):
            with self.subTest(index=index):
                self.assertLess(
                    validation_objective_key_v2(improved, physical, self.plan),
                    baseline_key,
                )

        candidate_10 = self.candidate_for_ordinal(10)
        tied = validation_evaluation()
        preferred = (
            ScoredValidationCandidateV2(candidate, tied),
            ScoredValidationCandidateV2(candidate_10, tied),
        )
        selection = select_validation_candidate_v2(
            self.admission,
            self.complete_validation_scores(preferred),
            self.plan,
            evaluation_failures=(),
        )
        self.assertLess(
            serialized_candidate_vector_v2(
                dict(candidate_10.physical_candidate_items),
                self.plan,
            ),
            serialized_candidate_vector_v2(
                dict(candidate.physical_candidate_items),
                self.plan,
            ),
        )
        self.assertEqual(
            selection.selected.candidate.candidate_vector_sha256,
            candidate_10.candidate_vector_sha256,
        )

    def test_pareto_selection_is_feasible_and_permutation_invariant(self) -> None:
        candidates = [self.candidate_for_ordinal(value) for value in range(5)]
        equal_a = validation_evaluation()
        dominated = validation_evaluation(
            y_fixed=4,
            y_non_ash=4,
            y_conventional=4,
            ms_ssim=4,
            ringing=6,
            alias=6,
            cost=6,
        )
        tradeoff = validation_evaluation(y_fixed=6, ringing=10)
        equal_b = validation_evaluation()
        infeasible = validation_evaluation(
            feasible=False,
            failures=("container_decoded:bootstrap:y_vs_fixed",),
            y_fixed=100,
            y_non_ash=100,
            y_conventional=100,
            ms_ssim=100,
            ringing=0,
            alias=0,
            cost=0,
        )
        scored = tuple(
            ScoredValidationCandidateV2(candidate, observed)
            for candidate, observed in zip(
                candidates,
                (equal_a, dominated, tradeoff, equal_b, infeasible),
            )
        )
        frontier = validation_pareto_frontier_v2(scored, self.plan)
        expected = {
            candidates[0].candidate_vector_sha256,
            candidates[2].candidate_vector_sha256,
            candidates[3].candidate_vector_sha256,
        }
        self.assertEqual(
            {item.candidate.candidate_vector_sha256 for item in frontier},
            expected,
        )
        self.assertEqual(
            validation_pareto_frontier_v2(tuple(reversed(scored)), self.plan),
            frontier,
        )
        complete_scored = self.complete_validation_scores(scored)
        selection = select_validation_candidate_v2(
            self.admission,
            complete_scored,
            self.plan,
            evaluation_failures=(),
        )
        reversed_selection = select_validation_candidate_v2(
            self.admission,
            tuple(reversed(complete_scored)),
            self.plan,
            evaluation_failures=(),
        )
        self.assertEqual(selection, reversed_selection)
        self.assertEqual(
            selection.selected.candidate.candidate_vector_sha256,
            candidates[2].candidate_vector_sha256,
        )

    def test_selection_rejects_nonmembers_duplicates_empty_and_invalid_metrics(self) -> None:
        constraint_invalid = next(
            candidate
            for candidate in self.neighborhood.candidates_before_constraint_filtering
            if candidate.candidate_vector_sha256
            not in {
                valid.candidate_vector_sha256
                for valid in self.neighborhood.constraint_valid_candidates
            }
        )
        with self.assertRaises(CalibrationSchedulerV2Error):
            select_validation_candidate_v2(
                self.admission,
                (
                    ScoredValidationCandidateV2(
                        constraint_invalid,
                        validation_evaluation(),
                    ),
                ),
                self.plan,
                evaluation_failures=(),
            )

        candidate = self.candidate_for_ordinal(0)
        scored = ScoredValidationCandidateV2(candidate, validation_evaluation())
        with self.assertRaises(CalibrationSchedulerV2Error):
            validation_pareto_frontier_v2((scored, scored), self.plan)
        with self.assertRaises(CalibrationSchedulerV2Error):
            validation_pareto_frontier_v2(
                (
                    ScoredValidationCandidateV2(
                        candidate,
                        validation_evaluation(
                            feasible=False,
                            failures=("engine_raw:ringing",),
                        ),
                    ),
                ),
                self.plan,
            )
        with self.assertRaises(CalibrationSchedulerV2Error):
            validation_evaluation(y_fixed=float("nan"))
        with self.assertRaises(CalibrationSchedulerV2Error):
            validation_evaluation(cost=True)
        with self.assertRaises(CalibrationSchedulerV2Error):
            validation_evaluation(cost=10**10000)
        for name in ("ringing", "alias", "cost"):
            with self.subTest(name=name):
                with self.assertRaises(CalibrationSchedulerV2Error):
                    validation_evaluation(**{name: -1})
        with self.assertRaises(CalibrationSchedulerV2Error):
            validation_evaluation(
                feasible=False,
                failures=("engine_raw:ringing", "engine_raw:ringing"),
            )

    def test_selection_requires_exact_outcomes_and_typed_failures(self) -> None:
        candidate = self.candidate_for_ordinal(0)
        scored = ScoredValidationCandidateV2(candidate, validation_evaluation())
        complete = self.complete_validation_scores((scored,))
        failed_candidate = next(
            admitted
            for admitted in self.admission.admitted_candidates
            if admitted.candidate_vector_sha256
            != candidate.candidate_vector_sha256
        )
        incomplete = tuple(
            row
            for row in complete
            if row.candidate.candidate_vector_sha256
            != failed_candidate.candidate_vector_sha256
        )
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "outcomes do not exactly cover",
        ):
            select_validation_candidate_v2(
                self.admission,
                incomplete,
                self.plan,
                evaluation_failures=(),
            )

        failure = ValidationEvaluationFailureV2(
            failed_candidate,
            ("RuntimeError: injected validation evaluator failure",),
        )
        selection = select_validation_candidate_v2(
            self.admission,
            incomplete,
            self.plan,
            evaluation_failures=(failure,),
        )
        reversed_selection = select_validation_candidate_v2(
            self.admission,
            tuple(reversed(incomplete)),
            self.plan,
            evaluation_failures=(failure,),
        )
        self.assertEqual(selection, reversed_selection)
        self.assertEqual(selection.evaluation_failures, (failure,))
        self.assertEqual(
            selection.selected.candidate.candidate_vector_sha256,
            candidate.candidate_vector_sha256,
        )

        with self.assertRaises(CalibrationSchedulerV2Error):
            select_validation_candidate_v2(
                self.admission,
                complete,
                self.plan,
                evaluation_failures=(failure,),
            )
        with self.assertRaises(CalibrationSchedulerV2Error):
            select_validation_candidate_v2(
                self.admission,
                incomplete,
                self.plan,
                evaluation_failures=(failure, failure),
            )
        with self.assertRaises(CalibrationSchedulerV2Error):
            select_validation_candidate_v2(
                self.admission,
                incomplete,
                self.plan,
                evaluation_failures=(
                    ValidationEvaluationFailureV2(failed_candidate, ()),
                ),
            )
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "contains no feasible candidate",
        ):
            select_validation_candidate_v2(
                self.admission,
                (),
                self.plan,
                evaluation_failures=tuple(
                    ValidationEvaluationFailureV2(
                        admitted,
                        ("RuntimeError: injected",),
                    )
                    for admitted in self.admission.admitted_candidates
                ),
            )

    def test_selection_replays_attached_development_provenance(self) -> None:
        candidate = self.candidate_for_ordinal(0)
        complete = self.complete_validation_scores(
            (ScoredValidationCandidateV2(candidate, validation_evaluation()),)
        )
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "checkpoint last SHA-256 differs",
        ):
            select_validation_candidate_v2(
                replace(
                    self.admission,
                    development_last_record_sha256="f" * 64,
                ),
                complete,
                self.plan,
                evaluation_failures=(),
            )

        evidence = list(self.admission.development_evidence)
        evidence[0] = replace(
            evidence[0],
            evaluation=replace(
                evidence[0].evaluation,
                mean_y_psnr_delta_vs_fixed_db=(
                    evidence[0].evaluation.mean_y_psnr_delta_vs_fixed_db + 1
                ),
            ),
        )
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "differs from replayed development evidence",
        ):
            select_validation_candidate_v2(
                replace(
                    self.admission,
                    development_evidence=tuple(evidence),
                ),
                complete,
                self.plan,
                evaluation_failures=(),
            )

    def test_selection_reconstructs_exact_terminal_neighborhood(self) -> None:
        alternate_logical = dict(self.initial_logical)
        alternate_logical.update(
            {
                "edge_present_low_unorm15": 4915,
                "coherent_structure_low_unorm15": 8192,
            }
        )
        alternate = validation_neighborhood_v2(alternate_logical, self.plan)
        original_hashes = {
            candidate.candidate_vector_sha256
            for candidate in self.neighborhood.candidates_before_constraint_filtering
        }
        alternate_valid_hashes = {
            candidate.candidate_vector_sha256
            for candidate in alternate.constraint_valid_candidates
        }
        injected = next(
            candidate
            for candidate in alternate.candidates_before_constraint_filtering
            if candidate.candidate_vector_sha256 not in alternate_valid_hashes
            and candidate.candidate_vector_sha256 not in original_hashes
        )
        valid_hashes = {
            candidate.candidate_vector_sha256
            for candidate in self.admission.neighborhood.constraint_valid_candidates
        }
        invalid_index = next(
            index
            for index, candidate in enumerate(
                self.admission.neighborhood.candidates_before_constraint_filtering
            )
            if candidate.candidate_vector_sha256 not in valid_hashes
        )
        forged_candidates = list(
            self.admission.neighborhood.candidates_before_constraint_filtering
        )
        forged_candidates[invalid_index] = injected
        forged_admission = replace(
            self.admission,
            neighborhood=replace(
                self.admission.neighborhood,
                candidates_before_constraint_filtering=tuple(forged_candidates),
            ),
        )
        candidate = self.candidate_for_ordinal(0)
        with self.assertRaisesRegex(
            CalibrationSchedulerV2Error,
            "differs from exact terminal replacements",
        ):
            select_validation_candidate_v2(
                forged_admission,
                (
                    ScoredValidationCandidateV2(
                        candidate,
                        validation_evaluation(),
                    ),
                ),
                self.plan,
                evaluation_failures=(),
            )


if __name__ == "__main__":
    unittest.main()
