from __future__ import annotations

from dataclasses import FrozenInstanceError, replace
import math
import unittest

from validation.calibration_v2.r10_optimizer import (
    R10AbsoluteScore,
    R10Attempt,
    R10AttemptDisposition,
    R10Candidate,
    R10Checkpoint,
    R10CheckpointReference,
    R10CheckpointStatus,
    R10ConstraintName,
    R10Evaluation,
    R10EvaluationCatalog,
    R10EvaluationMismatchError,
    R10EvaluationMissingError,
    R10FrozenPolicy,
    R10HardConstraint,
    R10OptimizerError,
    R10ProcessingIdentity,
    R10RunStatus,
    canonical_json_file_bytes_r10,
    checkpoint_from_document_r10,
    frozen_policy_from_document_r10,
    optimize_r10,
)


def _constraints(
    failed: R10ConstraintName | None = None,
) -> tuple[R10HardConstraint, ...]:
    return tuple(
        R10HardConstraint(
            name=name,
            observed=2 if name is failed else 0,
            minimum=0,
            maximum=1,
        )
        for name in reversed(tuple(R10ConstraintName))
    )


def _candidate(
    candidate_id: str,
    quality: int,
    *,
    failed: R10ConstraintName | None = None,
) -> R10Candidate:
    return R10Candidate(
        candidate_id=candidate_id,
        causal_variables=(
            ("quality_q16", quality),
            ("minimum_dwell_frames", 12),
        ),
        constraints=_constraints(failed),
    )


def _score(quality: int = 32_768) -> R10AbsoluteScore:
    return R10AbsoluteScore(
        quality_q16=quality,
        temporal_stability_q16=40_000,
        protected_region_fidelity_q16=50_000,
        resource_efficiency_q16=30_000,
        safety_margin_q16=60_000,
    )


def _quality(candidate: R10Candidate) -> int:
    return int(dict(candidate.causal_variables)["quality_q16"])


def _catalog(
    candidates: tuple[R10Candidate, ...],
    *,
    fixed_score: R10AbsoluteScore | None = None,
) -> R10EvaluationCatalog:
    return R10EvaluationCatalog(
        tuple(
            R10Evaluation.create(
                candidate=candidate,
                score=(
                    fixed_score
                    if fixed_score is not None
                    else _score(_quality(candidate))
                ),
            )
            for candidate in candidates
            if not candidate.failed_constraints
        )
    )


def _identity(
    catalog: R10EvaluationCatalog,
    seed: str = "1",
) -> R10ProcessingIdentity:
    values = [character for character in "abcdef"]
    offset = int(seed, 16) % len(values)
    return R10ProcessingIdentity(
        source_commit=seed * 40,
        source_tree=values[offset] * 40,
        optimizer_contract_sha256="a" * 64,
        persistence_contract_sha256="e" * 64,
        fixture_catalog_sha256="b" * 64,
        evaluator_sha256=catalog.evaluator_sha256,
        policy_catalog_sha256="d" * 64,
    )


def _attempts(
    candidates: tuple[R10Candidate, ...],
) -> tuple[R10Attempt, ...]:
    attempts: tuple[R10Attempt, ...] = ()
    previous = "0" * 64
    for ordinal, candidate in enumerate(candidates):
        attempt = R10Attempt.create(
            ordinal=ordinal,
            previous_attempt_sha256=previous,
            candidate=candidate,
            score=(
                None
                if candidate.failed_constraints
                else _score(_quality(candidate))
            ),
        )
        attempts = (*attempts, attempt)
        previous = attempt.attempt_sha256
    return attempts


class R10OptimizerContractTests(unittest.TestCase):
    def test_persistence_contract_identity_is_independent_and_propagated(
        self,
    ) -> None:
        candidate = _candidate("persistence-identity", 9)
        catalog = _catalog((candidate,))
        identity = _identity(catalog)
        changed = replace(
            identity,
            persistence_contract_sha256="f" * 64,
        )
        self.assertEqual(
            identity.optimizer_contract_sha256,
            changed.optimizer_contract_sha256,
        )
        self.assertNotEqual(
            identity.persistence_contract_sha256,
            changed.persistence_contract_sha256,
        )
        self.assertNotEqual(
            identity.identity_sha256,
            changed.identity_sha256,
        )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "persistence_contract_sha256",
        ):
            replace(
                identity,
                persistence_contract_sha256="not-a-sha256",
            )

        result = optimize_r10(
            processing_identity=identity,
            candidates=(candidate,),
            maximum_candidates=1,
            evaluation_catalog=catalog,
        )
        checkpoint_document = result.checkpoint.to_document()
        self.assertEqual(
            checkpoint_document["processing_identity"][
                "persistence_contract_sha256"
            ],
            identity.persistence_contract_sha256,
        )
        self.assertEqual(
            checkpoint_from_document_r10(checkpoint_document),
            result.checkpoint,
        )
        reference = R10CheckpointReference(
            path="checkpoints/persistence-identity.json",
            sha256="9" * 64,
            size_bytes=len(result.checkpoint.canonical_file_bytes),
            checkpoint_sha256=result.checkpoint.checkpoint_sha256,
        )
        assert result.selection is not None
        policy = R10FrozenPolicy.create(
            processing_identity=identity,
            candidate_set_sha256=result.checkpoint.candidate_set_sha256,
            selection=result.selection,
            final_checkpoint=reference,
        )
        changed_policy = R10FrozenPolicy.create(
            processing_identity=changed,
            candidate_set_sha256=result.checkpoint.candidate_set_sha256,
            selection=result.selection,
            final_checkpoint=reference,
        )
        self.assertEqual(
            frozen_policy_from_document_r10(policy.to_document()),
            policy,
        )
        self.assertNotEqual(
            policy.policy_sha256,
            changed_policy.policy_sha256,
        )

    def test_invalid_duplicate_and_nonfinite_inputs_fail_closed(self) -> None:
        large_integer = 10**400
        self.assertTrue(
            R10HardConstraint(
                name=R10ConstraintName.ROUTE,
                observed=large_integer,
                minimum=0,
                maximum=large_integer,
            ).satisfied
        )
        with self.assertRaisesRegex(R10OptimizerError, "name repeats"):
            R10Candidate(
                candidate_id="duplicate-variable",
                causal_variables=(("weight", 1), ("weight", 2)),
                constraints=_constraints(),
            )
        with self.assertRaisesRegex(R10OptimizerError, "must be finite"):
            R10Candidate(
                candidate_id="nonfinite-variable",
                causal_variables=(("weight", math.inf),),
                constraints=_constraints(),
            )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "finite built-in number",
        ):
            R10HardConstraint(
                name=R10ConstraintName.ROUTE,
                observed=math.nan,
                minimum=0,
                maximum=1,
            )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "finite built-in number",
        ):
            _score(math.inf)

        duplicate_id = (
            _candidate("same", 1),
            _candidate("same", 2),
        )
        catalog = R10EvaluationCatalog(())
        with self.assertRaisesRegex(R10OptimizerError, "candidate ID repeats"):
            optimize_r10(
                processing_identity=_identity(catalog),
                candidates=duplicate_id,
                maximum_candidates=2,
                evaluation_catalog=catalog,
            )

    def test_evaluation_catalog_is_canonical_immutable_and_unique(self) -> None:
        candidates = (
            _candidate("catalog-z", 3),
            _candidate("catalog-a", 4),
        )
        evaluations = tuple(
            R10Evaluation.create(
                candidate=candidate,
                score=_score(_quality(candidate)),
            )
            for candidate in candidates
        )
        first = R10EvaluationCatalog(evaluations)
        second = R10EvaluationCatalog(tuple(reversed(evaluations)))

        self.assertEqual(first, second)
        self.assertEqual(first.canonical_bytes, second.canonical_bytes)
        self.assertEqual(first.evaluator_sha256, second.evaluator_sha256)
        with self.assertRaises(FrozenInstanceError):
            first.evaluations = ()
        with self.assertRaisesRegex(
            R10OptimizerError,
            "candidate ID repeats",
        ):
            R10EvaluationCatalog((evaluations[0], evaluations[0]))

    def test_finite_bound_caps_catalog_observations(self) -> None:
        candidates = tuple(
            _candidate(f"candidate-{index:02d}", 10_000 + index)
            for index in range(8)
        )
        catalog = _catalog(candidates)
        result = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=8,
            evaluation_catalog=catalog,
        )

        self.assertEqual(result.status, R10RunStatus.SUCCEEDED)
        self.assertEqual(len(result.checkpoint.attempts), 8)
        self.assertEqual(result.evaluation_observation_count, 8)
        self.assertEqual(
            result.checkpoint.status,
            R10CheckpointStatus.COMPLETED,
        )

        with self.assertRaisesRegex(R10OptimizerError, "finite bound"):
            optimize_r10(
                processing_identity=_identity(catalog),
                candidates=candidates,
                maximum_candidates=7,
                evaluation_catalog=catalog,
            )

    def test_each_hard_constraint_rejects_before_catalog_observation(
        self,
    ) -> None:
        for constraint_name in R10ConstraintName:
            with self.subTest(constraint=constraint_name.value):
                rejected = _candidate(
                    f"rejected-{constraint_name.value}",
                    65_536,
                    failed=constraint_name,
                )
                accepted = _candidate(
                    f"accepted-{constraint_name.value}",
                    1,
                )
                catalog = _catalog((accepted,))
                result = optimize_r10(
                    processing_identity=_identity(catalog),
                    candidates=(rejected, accepted),
                    maximum_candidates=2,
                    evaluation_catalog=catalog,
                )

                self.assertEqual(
                    result.evaluation_observation_count,
                    1,
                )
                rejected_attempt = next(
                    attempt
                    for attempt in result.checkpoint.attempts
                    if attempt.candidate == rejected
                )
                self.assertEqual(
                    rejected_attempt.disposition,
                    R10AttemptDisposition.REJECTED,
                )
                self.assertEqual(
                    rejected_attempt.rejected_constraints,
                    (constraint_name,),
                )
                self.assertEqual(
                    result.selection.selected_candidate,
                    accepted,
                )

    def test_permutation_and_exact_tie_are_byte_deterministic(self) -> None:
        candidates = (
            _candidate("candidate-z", 10),
            _candidate("candidate-a", 10),
            _candidate("candidate-m", 10),
        )
        catalog = _catalog(candidates, fixed_score=_score())
        first = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=3,
            evaluation_catalog=catalog,
        )
        second = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=tuple(reversed(candidates)),
            maximum_candidates=3,
            evaluation_catalog=catalog,
        )

        self.assertEqual(first.selection, second.selection)
        self.assertEqual(
            first.checkpoint.canonical_file_bytes,
            second.checkpoint.canonical_file_bytes,
        )
        expected = min(
            candidates,
            key=lambda candidate: candidate.canonical_bytes,
        )
        self.assertEqual(first.selection.selected_candidate, expected)

    def test_exact_resume_matches_uninterrupted_bytes(self) -> None:
        candidates = tuple(
            _candidate(f"resume-{index}", 20_000 + index)
            for index in range(5)
        )
        catalog = _catalog(candidates)
        checkpoints: list[R10Checkpoint] = []
        uninterrupted = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=5,
            evaluation_catalog=catalog,
            checkpoint_sink=checkpoints.append,
        )
        prefix = next(
            checkpoint
            for checkpoint in checkpoints
            if checkpoint.next_candidate_index == 2
            and checkpoint.status is R10CheckpointStatus.IN_PROGRESS
        )
        resumed = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=tuple(reversed(candidates)),
            maximum_candidates=5,
            evaluation_catalog=catalog,
            resume_checkpoint=prefix,
        )

        self.assertEqual(resumed.evaluation_observation_count, 5)
        self.assertEqual(resumed, uninterrupted)

    def test_resume_mismatch_fails_before_catalog_observation(self) -> None:
        candidates = (
            _candidate("resume-a", 1),
            _candidate("resume-b", 2),
        )
        catalog = _catalog(candidates)
        checkpoints: list[R10Checkpoint] = []
        optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=2,
            evaluation_catalog=catalog,
            checkpoint_sink=checkpoints.append,
        )
        prefix = checkpoints[1]
        with self.assertRaisesRegex(
            R10OptimizerError,
            "processing identity differs",
        ):
            optimize_r10(
                processing_identity=_identity(catalog, "2"),
                candidates=candidates,
                maximum_candidates=2,
                evaluation_catalog=catalog,
                resume_checkpoint=prefix,
            )

        with self.assertRaisesRegex(
            R10OptimizerError,
            "candidate-set binding differs",
        ):
            optimize_r10(
                processing_identity=_identity(catalog),
                candidates=candidates,
                maximum_candidates=3,
                evaluation_catalog=catalog,
                resume_checkpoint=prefix,
            )

    def test_cancellation_occurs_between_candidates_and_resumes_exactly(
        self,
    ) -> None:
        candidates = tuple(
            _candidate(f"cancel-{index}", index)
            for index in range(4)
        )
        catalog = _catalog(candidates)
        reference = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=4,
            evaluation_catalog=catalog,
        )
        requested_checks = 0

        def cancellation_requested() -> bool:
            nonlocal requested_checks
            requested_checks += 1
            return requested_checks == 3

        cancelled = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=4,
            evaluation_catalog=catalog,
            cancellation_requested=cancellation_requested,
        )

        self.assertEqual(cancelled.status, R10RunStatus.CANCELLED)
        self.assertEqual(cancelled.checkpoint.next_candidate_index, 2)
        self.assertEqual(cancelled.evaluation_observation_count, 2)
        resumed = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=4,
            evaluation_catalog=catalog,
            resume_checkpoint=cancelled.checkpoint,
        )
        self.assertEqual(resumed.evaluation_observation_count, 4)
        self.assertEqual(resumed, reference)

    def test_cancellation_exception_is_deterministic_transactional_failure(
        self,
    ) -> None:
        candidates = tuple(
            _candidate(f"cancel-error-{index}", 100 + index)
            for index in range(4)
        )
        catalog = _catalog(candidates)
        identity = _identity(catalog)
        reference = optimize_r10(
            processing_identity=identity,
            candidates=candidates,
            maximum_candidates=4,
            evaluation_catalog=catalog,
        )

        def run_failure():
            checks = 0

            def cancellation_requested() -> bool:
                nonlocal checks
                checks += 1
                if checks == 3:
                    raise RuntimeError("non-authoritative callback detail")
                return False

            return optimize_r10(
                processing_identity=identity,
                candidates=candidates,
                maximum_candidates=4,
                evaluation_catalog=catalog,
                cancellation_requested=cancellation_requested,
            )

        first = run_failure()
        second = run_failure()
        self.assertEqual(first.status, R10RunStatus.FAILED)
        self.assertEqual(
            first.terminal_code,
            "cancellation_check_failure:builtins.RuntimeError",
        )
        self.assertEqual(first.checkpoint.next_candidate_index, 2)
        self.assertEqual(first.evaluation_observation_count, 2)
        self.assertEqual(
            first.checkpoint.attempts[-1],
            reference.checkpoint.attempts[1],
        )
        self.assertEqual(
            first.checkpoint.canonical_file_bytes,
            second.checkpoint.canonical_file_bytes,
        )

        resumed = optimize_r10(
            processing_identity=identity,
            candidates=candidates,
            maximum_candidates=4,
            evaluation_catalog=catalog,
            resume_checkpoint=first.checkpoint,
        )
        self.assertEqual(resumed.evaluation_observation_count, 4)
        self.assertEqual(resumed, reference)

    def test_catalog_missing_and_candidate_mismatch_fail_transactionally(
        self,
    ) -> None:
        candidates = tuple(
            _candidate(f"catalog-failure-{index}", 200 + index)
            for index in range(3)
        )
        ordered = tuple(
            sorted(
                candidates,
                key=lambda candidate: candidate.canonical_bytes,
            )
        )
        missing_catalog = _catalog((ordered[0],))
        missing = optimize_r10(
            processing_identity=_identity(missing_catalog),
            candidates=candidates,
            maximum_candidates=3,
            evaluation_catalog=missing_catalog,
        )
        self.assertEqual(missing.status, R10RunStatus.FAILED)
        self.assertEqual(
            missing.terminal_code,
            "evaluation_missing_for_candidate",
        )
        self.assertEqual(missing.checkpoint.next_candidate_index, 1)
        self.assertEqual(missing.evaluation_observation_count, 2)
        self.assertEqual(
            missing.checkpoint.attempts[0].candidate,
            ordered[0],
        )
        with self.assertRaises(R10EvaluationMissingError):
            missing_catalog.score_for(ordered[1])

        original = _candidate("catalog-mismatch", 300)
        changed = _candidate("catalog-mismatch", 301)
        mismatch_catalog = _catalog((original,))
        mismatch = optimize_r10(
            processing_identity=_identity(mismatch_catalog),
            candidates=(changed,),
            maximum_candidates=1,
            evaluation_catalog=mismatch_catalog,
        )
        self.assertEqual(mismatch.status, R10RunStatus.FAILED)
        self.assertEqual(
            mismatch.terminal_code,
            "evaluation_candidate_identity_mismatch",
        )
        self.assertEqual(mismatch.checkpoint.next_candidate_index, 0)
        self.assertEqual(mismatch.evaluation_observation_count, 1)
        with self.assertRaises(R10EvaluationMismatchError):
            mismatch_catalog.score_for(changed)

    def test_catalog_substitution_cannot_change_bound_scores(self) -> None:
        candidate = _candidate("catalog-substitution", 12)
        original_catalog = _catalog(
            (candidate,),
            fixed_score=_score(10),
        )
        substituted_catalog = _catalog(
            (candidate,),
            fixed_score=_score(60_000),
        )
        identity = _identity(original_catalog)
        original = optimize_r10(
            processing_identity=identity,
            candidates=(candidate,),
            maximum_candidates=1,
            evaluation_catalog=original_catalog,
        )
        substituted = optimize_r10(
            processing_identity=identity,
            candidates=(candidate,),
            maximum_candidates=1,
            evaluation_catalog=substituted_catalog,
        )

        self.assertEqual(original.status, R10RunStatus.SUCCEEDED)
        self.assertEqual(substituted.status, R10RunStatus.FAILED)
        self.assertEqual(
            substituted.terminal_code,
            "evaluation_catalog_identity_mismatch",
        )
        self.assertEqual(substituted.checkpoint.next_candidate_index, 0)
        self.assertEqual(substituted.evaluation_observation_count, 0)
        with self.assertRaisesRegex(TypeError, "evaluator"):
            optimize_r10(
                processing_identity=identity,
                candidates=(candidate,),
                maximum_candidates=1,
                evaluation_catalog=original_catalog,
                evaluator=lambda _candidate_value: _score(60_000),
            )

    def test_completed_resume_replays_scores_and_reproduces_exact_result(
        self,
    ) -> None:
        accepted = _candidate("complete-accepted", 42)
        rejected = _candidate(
            "complete-rejected",
            43,
            failed=R10ConstraintName.ROUTE,
        )
        candidates = (accepted, rejected)
        catalog = _catalog(candidates)
        completed = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=2,
            evaluation_catalog=catalog,
        )
        reopened = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=2,
            evaluation_catalog=catalog,
            resume_checkpoint=completed.checkpoint,
        )
        self.assertEqual(completed.evaluation_observation_count, 1)
        self.assertEqual(reopened.evaluation_observation_count, 1)
        self.assertEqual(reopened, completed)

    def test_completed_resume_rejects_structurally_valid_forged_score(
        self,
    ) -> None:
        candidate = _candidate("completed-score-forgery", 44)
        catalog = _catalog((candidate,), fixed_score=_score(10))
        identity = _identity(catalog)
        reference = optimize_r10(
            processing_identity=identity,
            candidates=(candidate,),
            maximum_candidates=1,
            evaluation_catalog=catalog,
        )
        forged_attempt = R10Attempt.create(
            ordinal=0,
            previous_attempt_sha256="0" * 64,
            candidate=candidate,
            score=_score(60_000),
        )
        forged_checkpoint = R10Checkpoint.create(
            processing_identity=identity,
            candidate_set_sha256=reference.checkpoint.candidate_set_sha256,
            candidate_count=1,
            maximum_candidates=1,
            attempts=(forged_attempt,),
            status=R10CheckpointStatus.COMPLETED,
        )

        result = optimize_r10(
            processing_identity=identity,
            candidates=(candidate,),
            maximum_candidates=1,
            evaluation_catalog=catalog,
            resume_checkpoint=forged_checkpoint,
        )
        self.assertEqual(result.status, R10RunStatus.FAILED)
        self.assertEqual(result.terminal_code, "evaluation_score_mismatch")
        self.assertEqual(result.evaluation_observation_count, 1)
        self.assertEqual(result.checkpoint.attempts, (forged_attempt,))
        self.assertIsNone(result.selection)

    def test_every_partial_resume_status_replays_prior_scores(self) -> None:
        candidates = (
            _candidate("partial-forgery-a", 45),
            _candidate("partial-forgery-b", 46),
        )
        ordered = tuple(
            sorted(
                candidates,
                key=lambda candidate: candidate.canonical_bytes,
            )
        )
        catalog = _catalog(candidates)
        identity = _identity(catalog)
        reference = optimize_r10(
            processing_identity=identity,
            candidates=candidates,
            maximum_candidates=2,
            evaluation_catalog=catalog,
        )
        forged_attempt = R10Attempt.create(
            ordinal=0,
            previous_attempt_sha256="0" * 64,
            candidate=ordered[0],
            score=_score(60_000),
        )

        for status in (
            R10CheckpointStatus.IN_PROGRESS,
            R10CheckpointStatus.CANCELLED,
            R10CheckpointStatus.FAILED,
        ):
            with self.subTest(status=status.value):
                checkpoint = R10Checkpoint.create(
                    processing_identity=identity,
                    candidate_set_sha256=(
                        reference.checkpoint.candidate_set_sha256
                    ),
                    candidate_count=2,
                    maximum_candidates=2,
                    attempts=(forged_attempt,),
                    status=status,
                    terminal_code=(
                        None
                        if status is R10CheckpointStatus.IN_PROGRESS
                        else f"fixture_{status.value}"
                    ),
                )
                result = optimize_r10(
                    processing_identity=identity,
                    candidates=candidates,
                    maximum_candidates=2,
                    evaluation_catalog=catalog,
                    resume_checkpoint=checkpoint,
                )
                self.assertEqual(result.status, R10RunStatus.FAILED)
                self.assertEqual(
                    result.terminal_code,
                    "evaluation_score_mismatch",
                )
                self.assertEqual(
                    result.evaluation_observation_count,
                    1,
                )
                self.assertEqual(
                    result.checkpoint.attempts,
                    (forged_attempt,),
                )

    def test_resume_replay_missing_and_mismatch_are_transactional(
        self,
    ) -> None:
        missing_candidate = _candidate("replay-missing", 47)
        reference_catalog = _catalog((missing_candidate,))
        reference = optimize_r10(
            processing_identity=_identity(reference_catalog),
            candidates=(missing_candidate,),
            maximum_candidates=1,
            evaluation_catalog=reference_catalog,
        )
        missing_catalog = R10EvaluationCatalog(())
        missing_identity = _identity(missing_catalog)
        missing_attempt = R10Attempt.create(
            ordinal=0,
            previous_attempt_sha256="0" * 64,
            candidate=missing_candidate,
            score=_score(47),
        )
        missing_checkpoint = R10Checkpoint.create(
            processing_identity=missing_identity,
            candidate_set_sha256=reference.checkpoint.candidate_set_sha256,
            candidate_count=1,
            maximum_candidates=1,
            attempts=(missing_attempt,),
            status=R10CheckpointStatus.COMPLETED,
        )
        missing = optimize_r10(
            processing_identity=missing_identity,
            candidates=(missing_candidate,),
            maximum_candidates=1,
            evaluation_catalog=missing_catalog,
            resume_checkpoint=missing_checkpoint,
        )
        self.assertEqual(missing.status, R10RunStatus.FAILED)
        self.assertEqual(
            missing.terminal_code,
            "evaluation_missing_for_candidate",
        )
        self.assertEqual(missing.evaluation_observation_count, 1)
        self.assertEqual(
            missing.checkpoint.attempts,
            (missing_attempt,),
        )

        original = _candidate("replay-mismatch", 48)
        changed = _candidate("replay-mismatch", 49)
        mismatch_catalog = _catalog((original,))
        changed_catalog = _catalog((changed,))
        changed_reference = optimize_r10(
            processing_identity=_identity(changed_catalog),
            candidates=(changed,),
            maximum_candidates=1,
            evaluation_catalog=changed_catalog,
        )
        mismatch_identity = _identity(mismatch_catalog)
        mismatch_attempt = R10Attempt.create(
            ordinal=0,
            previous_attempt_sha256="0" * 64,
            candidate=changed,
            score=mismatch_catalog.evaluations[0].score,
        )
        mismatch_checkpoint = R10Checkpoint.create(
            processing_identity=mismatch_identity,
            candidate_set_sha256=(
                changed_reference.checkpoint.candidate_set_sha256
            ),
            candidate_count=1,
            maximum_candidates=1,
            attempts=(mismatch_attempt,),
            status=R10CheckpointStatus.COMPLETED,
        )
        mismatch = optimize_r10(
            processing_identity=mismatch_identity,
            candidates=(changed,),
            maximum_candidates=1,
            evaluation_catalog=mismatch_catalog,
            resume_checkpoint=mismatch_checkpoint,
        )
        self.assertEqual(mismatch.status, R10RunStatus.FAILED)
        self.assertEqual(
            mismatch.terminal_code,
            "evaluation_candidate_identity_mismatch",
        )
        self.assertEqual(mismatch.evaluation_observation_count, 1)
        self.assertEqual(
            mismatch.checkpoint.attempts,
            (mismatch_attempt,),
        )

    def test_all_rejected_is_typed_failure_without_catalog_observation(
        self,
    ) -> None:
        candidates = tuple(
            _candidate(
                f"rejected-{name.value}",
                1,
                failed=name,
            )
            for name in R10ConstraintName
        )
        catalog = R10EvaluationCatalog(())
        result = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=6,
            evaluation_catalog=catalog,
        )
        self.assertEqual(result.evaluation_observation_count, 0)
        self.assertEqual(result.status, R10RunStatus.FAILED)
        self.assertEqual(
            result.terminal_code,
            "no_constraint_valid_scored_candidate",
        )

    def test_completed_checkpoint_reconstructs_full_candidate_contract(
        self,
    ) -> None:
        candidates = (
            _candidate("checkpoint-a", 10),
            _candidate("checkpoint-b", 11),
        )
        catalog = _catalog(candidates)
        result = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=candidates,
            maximum_candidates=3,
            evaluation_catalog=catalog,
        )
        checkpoint = result.checkpoint
        self.assertEqual(
            checkpoint_from_document_r10(checkpoint.to_document()),
            checkpoint,
        )

        with self.assertRaisesRegex(
            R10OptimizerError,
            "candidate-set SHA-256 differs",
        ):
            R10Checkpoint.create(
                processing_identity=checkpoint.processing_identity,
                candidate_set_sha256="f" * 64,
                candidate_count=2,
                maximum_candidates=3,
                attempts=checkpoint.attempts,
                status=R10CheckpointStatus.COMPLETED,
            )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "completed checkpoint semantics",
        ):
            R10Checkpoint.create(
                processing_identity=checkpoint.processing_identity,
                candidate_set_sha256=checkpoint.candidate_set_sha256,
                candidate_count=3,
                maximum_candidates=3,
                attempts=checkpoint.attempts,
                status=R10CheckpointStatus.COMPLETED,
            )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "candidate bounds",
        ):
            R10Checkpoint.create(
                processing_identity=checkpoint.processing_identity,
                candidate_set_sha256=checkpoint.candidate_set_sha256,
                candidate_count=2,
                maximum_candidates=1,
                attempts=checkpoint.attempts,
                status=R10CheckpointStatus.COMPLETED,
            )

        duplicate = _candidate("checkpoint-duplicate", 12)
        with self.assertRaisesRegex(
            R10OptimizerError,
            "candidate ID repeats",
        ):
            R10Checkpoint.create(
                processing_identity=checkpoint.processing_identity,
                candidate_set_sha256="e" * 64,
                candidate_count=2,
                maximum_candidates=2,
                attempts=_attempts((duplicate, duplicate)),
                status=R10CheckpointStatus.COMPLETED,
            )

        ordered = tuple(
            sorted(
                candidates,
                key=lambda candidate: candidate.canonical_bytes,
            )
        )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "canonical candidate order",
        ):
            R10Checkpoint.create(
                processing_identity=checkpoint.processing_identity,
                candidate_set_sha256=checkpoint.candidate_set_sha256,
                candidate_count=2,
                maximum_candidates=2,
                attempts=_attempts(tuple(reversed(ordered))),
                status=R10CheckpointStatus.COMPLETED,
            )

        rejected = _candidate(
            "checkpoint-rejected",
            13,
            failed=R10ConstraintName.SAFETY,
        )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "no scored candidate",
        ):
            R10Checkpoint.create(
                processing_identity=checkpoint.processing_identity,
                candidate_set_sha256="e" * 64,
                candidate_count=1,
                maximum_candidates=1,
                attempts=_attempts((rejected,)),
                status=R10CheckpointStatus.COMPLETED,
            )

    def test_checkpoint_value_cannot_be_replaced_without_detection(self) -> None:
        candidate = _candidate("immutable", 5)
        catalog = _catalog((candidate,))
        result = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=(candidate,),
            maximum_candidates=1,
            evaluation_catalog=catalog,
        )
        with self.assertRaisesRegex(
            R10OptimizerError,
            "candidate-set SHA-256 differs",
        ):
            replace(
                result.checkpoint,
                candidate_set_sha256="f" * 64,
            )

        document = result.checkpoint.to_document()
        document["checkpoint_sha256"] = "f" * 64
        with self.assertRaisesRegex(
            R10OptimizerError,
            "semantic SHA-256 differs",
        ):
            checkpoint_from_document_r10(document)

        forged_candidate_hash = result.checkpoint.to_document()
        forged_candidate_hash["attempts"][0][
            "candidate_sha256"
        ] = "f" * 64
        with self.assertRaisesRegex(
            R10OptimizerError,
            "candidate SHA-256 differs",
        ):
            checkpoint_from_document_r10(forged_candidate_hash)

    def test_checkpoint_bytes_remain_canonical_json(self) -> None:
        candidate = _candidate("canonical-checkpoint", 7)
        catalog = _catalog((candidate,))
        result = optimize_r10(
            processing_identity=_identity(catalog),
            candidates=(candidate,),
            maximum_candidates=1,
            evaluation_catalog=catalog,
        )
        self.assertEqual(
            canonical_json_file_bytes_r10(
                result.checkpoint.to_document()
            ),
            result.checkpoint.canonical_file_bytes,
        )


if __name__ == "__main__":
    unittest.main()
