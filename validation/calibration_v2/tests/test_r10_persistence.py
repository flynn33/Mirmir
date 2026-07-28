from __future__ import annotations

from dataclasses import replace
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import threading
import unittest
from unittest import mock

from validation.calibration_v2.r10_optimizer import (
    R10AbsoluteScore,
    R10Attempt,
    R10Candidate,
    R10Checkpoint,
    R10CheckpointReference,
    R10CheckpointStatus,
    R10ConstraintName,
    R10Evaluation,
    R10EvaluationCatalog,
    R10FrozenPolicy,
    R10HardConstraint,
    R10ProcessingIdentity,
    R10RunResult,
    R10RunStatus,
    R10Selection,
    R10TerminalRecord,
    optimize_r10,
)
from validation.calibration_v2.r10_persistence import (
    MAX_R10_ARTIFACT_BYTES,
    R10ArtifactBinding,
    R10PersistenceError,
    R10PersistenceStore,
)


def _identity(
    catalog: R10EvaluationCatalog,
) -> R10ProcessingIdentity:
    return R10ProcessingIdentity(
        source_commit="1" * 40,
        source_tree="2" * 40,
        optimizer_contract_sha256="a" * 64,
        fixture_catalog_sha256="b" * 64,
        evaluator_sha256=catalog.evaluator_sha256,
        persistence_contract_sha256="e" * 64,
        policy_catalog_sha256="d" * 64,
    )


def _constraints() -> tuple[R10HardConstraint, ...]:
    return tuple(
        R10HardConstraint(
            name=name,
            observed=0,
            minimum=0,
            maximum=1,
        )
        for name in R10ConstraintName
    )


def _candidate(candidate_id: str, quality: int) -> R10Candidate:
    return R10Candidate(
        candidate_id=candidate_id,
        causal_variables=(("quality_q16", quality),),
        constraints=_constraints(),
    )


def _score(quality: int) -> R10AbsoluteScore:
    return R10AbsoluteScore(
        quality_q16=quality,
        temporal_stability_q16=50_000,
        protected_region_fidelity_q16=50_000,
        resource_efficiency_q16=50_000,
        safety_margin_q16=50_000,
    )


def _quality(candidate: R10Candidate) -> int:
    return int(dict(candidate.causal_variables)["quality_q16"])


def _catalog(
    candidates: tuple[R10Candidate, ...],
) -> R10EvaluationCatalog:
    return R10EvaluationCatalog(
        tuple(
            R10Evaluation.create(
                candidate=candidate,
                score=_score(_quality(candidate)),
            )
            for candidate in candidates
            if not candidate.failed_constraints
        )
    )


def _optimize(
    candidates: tuple[R10Candidate, ...],
    *,
    checkpoint_sink=None,
    cancellation_requested=None,
    catalog: R10EvaluationCatalog | None = None,
):
    selected_catalog = _catalog(candidates) if catalog is None else catalog
    return optimize_r10(
        processing_identity=_identity(selected_catalog),
        candidates=candidates,
        maximum_candidates=len(candidates),
        evaluation_catalog=selected_catalog,
        checkpoint_sink=checkpoint_sink,
        cancellation_requested=cancellation_requested,
    )


class R10PersistenceTests(unittest.TestCase):
    def test_each_incremental_checkpoint_is_content_addressed_and_reopens(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-checkpoints-") as value:
            store = R10PersistenceStore(Path(value) / "artifacts")
            bindings: list[R10ArtifactBinding] = []

            def persist(checkpoint):
                binding = store.publish_checkpoint(checkpoint)
                bindings.append(binding)

            candidates = (
                _candidate("candidate-c", 3),
                _candidate("candidate-a", 1),
                _candidate("candidate-b", 2),
            )
            result = _optimize(
                candidates,
                checkpoint_sink=persist,
            )

            self.assertEqual(len(bindings), 4)
            reopened = [
                store.reopen_checkpoint(binding) for binding in bindings
            ]
            self.assertEqual(
                [checkpoint.next_candidate_index for checkpoint in reopened],
                [0, 1, 2, 3],
            )
            self.assertEqual(reopened[-1], result.checkpoint)
            for binding in bindings:
                self.assertEqual(
                    binding.path,
                    f"checkpoints/{binding.sha256}.json",
                )

    def test_success_publishes_policy_only_after_checkpoint_reopen(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-success-") as value:
            store = R10PersistenceStore(Path(value) / "artifacts")
            candidates = (
                _candidate("candidate-a", 1),
                _candidate("candidate-b", 2),
            )
            catalog = _catalog(candidates)
            result = _optimize(
                candidates,
                catalog=catalog,
                checkpoint_sink=store.publish_checkpoint,
            )
            publication = store.publish_run_result(
                result,
                evaluation_catalog=catalog,
            )

            self.assertIsNone(publication.terminal)
            self.assertIsNotNone(publication.frozen_policy)
            policy = store.reopen_frozen_policy(
                publication.frozen_policy,
                evaluation_catalog=catalog,
            )
            self.assertEqual(
                policy.selection,
                result.selection,
            )
            self.assertEqual(
                policy.processing_identity.persistence_contract_sha256,
                "e" * 64,
            )
            self.assertFalse(policy.to_document()["production_auto_authorized"])
            self.assertFalse(policy.to_document()["comparative_metrics_used"])

    def test_missing_checkpoint_prevents_frozen_policy_publication(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-dependency-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            candidates = (_candidate("candidate", 1),)
            catalog = _catalog(candidates)
            result = _optimize(candidates, catalog=catalog)
            checkpoint_binding = store.publish_checkpoint(result.checkpoint)
            reference = R10CheckpointReference(
                path=checkpoint_binding.path,
                sha256=checkpoint_binding.sha256,
                size_bytes=checkpoint_binding.size_bytes,
                checkpoint_sha256=result.checkpoint.checkpoint_sha256,
            )
            policy = R10FrozenPolicy.create(
                processing_identity=result.checkpoint.processing_identity,
                candidate_set_sha256=result.checkpoint.candidate_set_sha256,
                selection=result.selection,
                final_checkpoint=reference,
            )
            (root / checkpoint_binding.path).unlink()

            with self.assertRaisesRegex(
                R10PersistenceError,
                "unavailable",
            ):
                store.publish_frozen_policy(
                    policy,
                    evaluation_catalog=catalog,
                )
            self.assertEqual(list((root / "frozen-policies").iterdir()), [])

    def test_cancel_and_failure_publish_terminal_records_without_policy(
        self,
    ) -> None:
        cases = ("cancelled", "failed")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix=f"mirmir-r10-{case}-"
            ) as value:
                root = Path(value) / "artifacts"
                store = R10PersistenceStore(root)
                candidates = (
                    _candidate("candidate-a", 1),
                    _candidate("candidate-b", 2),
                )
                if case == "cancelled":
                    cancellation_checks: list[int] = []
                    catalog = _catalog(candidates)

                    def cancellation_requested() -> bool:
                        cancellation_checks.append(1)
                        return len(cancellation_checks) > 1

                    result = _optimize(
                        candidates,
                        catalog=catalog,
                        cancellation_requested=cancellation_requested,
                        checkpoint_sink=store.publish_checkpoint,
                    )
                    self.assertEqual(result.status, R10RunStatus.CANCELLED)
                else:
                    empty_catalog = R10EvaluationCatalog(())
                    catalog = empty_catalog
                    result = _optimize(
                        candidates,
                        catalog=empty_catalog,
                        checkpoint_sink=store.publish_checkpoint,
                    )
                    self.assertEqual(result.status, R10RunStatus.FAILED)

                publication = store.publish_run_result(
                    result,
                    evaluation_catalog=catalog,
                )
                self.assertIsNotNone(publication.terminal)
                self.assertIsNone(publication.frozen_policy)
                terminal = store.reopen_terminal_record(
                    publication.terminal,
                    evaluation_catalog=catalog,
                )
                self.assertEqual(terminal.status, result.status)
                self.assertEqual(
                    terminal.processing_identity.persistence_contract_sha256,
                    "e" * 64,
                )
                with self.assertRaisesRegex(
                    R10PersistenceError,
                    "exact R10 evaluation catalog is required",
                ):
                    store.reopen_terminal_record(publication.terminal)
                self.assertFalse(
                    terminal.to_document()["frozen_policy_published"]
                )
                self.assertEqual(
                    list((root / "frozen-policies").iterdir()),
                    [],
                )

    def test_identical_runs_publish_byte_identical_frozen_policies(self) -> None:
        candidates = (
            _candidate("candidate-a", 1),
            _candidate("candidate-b", 2),
        )
        payloads = []
        bindings = []
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-repeat-a-") as first:
            with tempfile.TemporaryDirectory(
                prefix="mirmir-r10-repeat-b-"
            ) as second:
                for value in (first, second):
                    root = Path(value) / "artifacts"
                    store = R10PersistenceStore(root)
                    catalog = _catalog(candidates)
                    result = _optimize(
                        candidates,
                        catalog=catalog,
                        checkpoint_sink=store.publish_checkpoint,
                    )
                    publication = store.publish_run_result(
                        result,
                        evaluation_catalog=catalog,
                    )
                    bindings.append(publication.frozen_policy)
                    payloads.append(
                        (root / publication.frozen_policy.path).read_bytes()
                    )

        self.assertEqual(bindings[0], bindings[1])
        self.assertEqual(payloads[0], payloads[1])

    def test_frozen_policy_name_collision_never_replaces_first_policy(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-collision-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            candidates = (
                _candidate("candidate-a", 1),
                _candidate("candidate-b", 2),
            )
            catalog = _catalog(candidates)
            first = _optimize(
                candidates,
                catalog=catalog,
                checkpoint_sink=store.publish_checkpoint,
            )
            first_publication = store.publish_run_result(
                first,
                evaluation_catalog=catalog,
            )
            first_path = root / first_publication.frozen_policy.path
            first_payload = first_path.read_bytes()

            with self.assertRaisesRegex(
                R10PersistenceError,
                "immutable-name collision",
            ):
                store._publish_named(
                    directory_name="frozen-policies",
                    file_name=first_path.name,
                    payload=first_payload + b" ",
                    label="R10 frozen fixture policy",
                )

            self.assertEqual(first_path.read_bytes(), first_payload)
            self.assertEqual(
                store.reopen_frozen_policy(
                    first_publication.frozen_policy,
                    evaluation_catalog=catalog,
                ),
                R10FrozenPolicy.create(
                    processing_identity=first.checkpoint.processing_identity,
                    candidate_set_sha256=first.checkpoint.candidate_set_sha256,
                    selection=first.selection,
                    final_checkpoint=R10CheckpointReference(
                        path=first_publication.checkpoint.path,
                        sha256=first_publication.checkpoint.sha256,
                        size_bytes=first_publication.checkpoint.size_bytes,
                        checkpoint_sha256=first.checkpoint.checkpoint_sha256,
                    ),
                ),
            )

    def test_mutated_checkpoint_is_rejected_on_reopen(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-mutation-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            result = _optimize((_candidate("candidate", 1),))
            binding = store.publish_checkpoint(result.checkpoint)
            path = root / binding.path
            path.chmod(0o600)
            path.write_bytes(path.read_bytes() + b" ")
            path.chmod(0o400)
            with self.assertRaisesRegex(
                R10PersistenceError,
                "binding differs",
            ):
                store.reopen_checkpoint(binding)

    def test_idempotent_publish_reopens_existing_exact_bytes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-idempotent-") as value:
            store = R10PersistenceStore(Path(value) / "artifacts")
            result = _optimize((_candidate("candidate", 1),))
            first = store.publish_checkpoint(result.checkpoint)
            second = store.publish_checkpoint(result.checkpoint)
            self.assertEqual(first, second)
            self.assertEqual(
                store.reopen_checkpoint(second),
                result.checkpoint,
            )

    def test_context_manager_and_idempotent_close_reject_later_use(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-close-") as value:
            root = Path(value) / "artifacts"
            result = _optimize((_candidate("candidate", 1),))
            with R10PersistenceStore(root) as store:
                binding = store.publish_checkpoint(result.checkpoint)
            store.close()
            with self.assertRaisesRegex(
                R10PersistenceError,
                "closed",
            ):
                store.reopen_checkpoint(binding)

    def test_root_swap_to_symlink_is_rejected_by_pinned_identity(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-root-swap-") as value:
            parent = Path(value)
            root = parent / "artifacts"
            moved = parent / "artifacts-retained"
            alternate = parent / "alternate"
            alternate.mkdir()
            store = R10PersistenceStore(root)
            result = _optimize((_candidate("candidate", 1),))
            binding = store.publish_checkpoint(result.checkpoint)

            root.rename(moved)
            root.symlink_to(alternate, target_is_directory=True)
            try:
                with self.assertRaisesRegex(
                    R10PersistenceError,
                    "root path",
                ):
                    store.reopen_checkpoint(binding)
                self.assertEqual(list(alternate.iterdir()), [])
            finally:
                root.unlink()
                moved.rename(root)
                store.close()

    def test_second_store_never_removes_an_unowned_active_temporary(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-active-temp-") as value:
            root = Path(value) / "artifacts"
            first = R10PersistenceStore(root)
            token = "e" * 32
            temporary_name = (
                f"{first._TEMPORARY_PREFIX}{os.getpid()}-"
                f"{token}{first._TEMPORARY_SUFFIX}"
            )
            temporary = root / "checkpoints" / temporary_name
            temporary.write_bytes(b"active-publication")

            second = R10PersistenceStore(root)
            self.assertEqual(temporary.read_bytes(), b"active-publication")
            result = _optimize((_candidate("candidate", 1),))
            with mock.patch(
                "validation.calibration_v2.r10_persistence.secrets.token_hex",
                return_value=token,
            ):
                with self.assertRaisesRegex(
                    R10PersistenceError,
                    "cannot be atomically published",
                ):
                    second.publish_checkpoint(result.checkpoint)
            self.assertEqual(temporary.read_bytes(), b"active-publication")
            temporary.unlink()
            first.close()
            second.close()

    def test_two_stores_concurrently_publish_identical_checkpoint(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-concurrent-") as value:
            root = Path(value) / "artifacts"
            first = R10PersistenceStore(root)
            second = R10PersistenceStore(root)
            result = _optimize((_candidate("candidate", 1),))
            start = threading.Event()
            bindings: list[R10ArtifactBinding] = []
            failures: list[BaseException] = []
            result_lock = threading.Lock()

            def publish(store: R10PersistenceStore) -> None:
                try:
                    if not start.wait(timeout=5):
                        raise RuntimeError("publication start timed out")
                    binding = store.publish_checkpoint(result.checkpoint)
                except BaseException as error:
                    with result_lock:
                        failures.append(error)
                else:
                    with result_lock:
                        bindings.append(binding)

            threads = (
                threading.Thread(
                    target=publish,
                    args=(first,),
                    daemon=True,
                ),
                threading.Thread(
                    target=publish,
                    args=(second,),
                    daemon=True,
                ),
            )
            for thread in threads:
                thread.start()
            start.set()
            for thread in threads:
                thread.join(timeout=5)

            self.assertFalse(any(thread.is_alive() for thread in threads))
            self.assertEqual(failures, [])
            self.assertEqual(len(bindings), 2)
            self.assertEqual(bindings[0], bindings[1])
            first.close()
            second.close()

    def test_published_artifacts_are_sealed_read_only(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-mode-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            candidates = (
                _candidate("candidate-a", 1),
                _candidate("candidate-b", 2),
            )
            catalog = _catalog(candidates)
            publication = store.publish_run_result(
                _optimize(candidates, catalog=catalog),
                evaluation_catalog=catalog,
            )

            bindings = (
                publication.checkpoint,
                publication.frozen_policy,
            )
            for binding in bindings:
                self.assertIsNotNone(binding)
                self.assertEqual(
                    stat.S_IMODE((root / binding.path).stat().st_mode),
                    0o400,
                )

    def test_exact_bounded_read_rejects_oversize_and_growth(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-bounded-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            result = _optimize((_candidate("candidate", 1),))
            binding = store.publish_checkpoint(result.checkpoint)
            path = root / binding.path
            real_read = os.read
            read_sizes: list[int] = []

            def record_read(descriptor: int, size: int) -> bytes:
                read_sizes.append(size)
                return real_read(descriptor, size)

            with mock.patch(
                "validation.calibration_v2.r10_persistence.os.read",
                side_effect=record_read,
            ):
                self.assertEqual(
                    store.reopen_checkpoint(binding),
                    result.checkpoint,
                )
            self.assertEqual(read_sizes, [binding.size_bytes, 1])

            read_sizes.clear()
            oversize_binding = replace(
                binding,
                size_bytes=binding.size_bytes + 1,
            )
            with mock.patch(
                "validation.calibration_v2.r10_persistence.os.read",
                side_effect=record_read,
            ):
                with self.assertRaisesRegex(
                    R10PersistenceError,
                    "binding differs",
                ):
                    store.reopen_checkpoint(oversize_binding)
            self.assertEqual(read_sizes, [])

            oversized_limit_binding = object.__new__(R10ArtifactBinding)
            object.__setattr__(
                oversized_limit_binding,
                "path",
                binding.path,
            )
            object.__setattr__(
                oversized_limit_binding,
                "sha256",
                binding.sha256,
            )
            object.__setattr__(
                oversized_limit_binding,
                "size_bytes",
                MAX_R10_ARTIFACT_BYTES + 1,
            )
            with mock.patch(
                "validation.calibration_v2.r10_persistence.os.read",
            ) as read:
                with self.assertRaisesRegex(
                    R10PersistenceError,
                    "fixed artifact boundary",
                ):
                    store.reopen_checkpoint(oversized_limit_binding)
            read.assert_not_called()

            grew = False

            def grow_after_exact_read(
                descriptor: int,
                size: int,
            ) -> bytes:
                nonlocal grew
                payload = real_read(descriptor, size)
                if not grew:
                    grew = True
                    path.chmod(0o600)
                    append_descriptor = os.open(path, os.O_WRONLY | os.O_APPEND)
                    try:
                        os.write(append_descriptor, b" ")
                    finally:
                        os.close(append_descriptor)
                    path.chmod(0o400)
                return payload

            with mock.patch(
                "validation.calibration_v2.r10_persistence.os.read",
                side_effect=grow_after_exact_read,
            ):
                with self.assertRaisesRegex(
                    R10PersistenceError,
                    "changed while reading",
                ):
                    store.reopen_checkpoint(binding)

    def test_outcomes_require_exact_bound_evaluation_catalog(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-catalog-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            candidates = (_candidate("candidate", 1),)
            catalog = _catalog(candidates)
            result = _optimize(candidates, catalog=catalog)

            with self.assertRaisesRegex(
                R10PersistenceError,
                "exact R10 evaluation catalog is required",
            ):
                store.publish_run_result(result)
            self.assertEqual(list((root / "checkpoints").iterdir()), [])

            with self.assertRaisesRegex(
                R10PersistenceError,
                "catalog identity differs",
            ):
                store.publish_run_result(
                    result,
                    evaluation_catalog=R10EvaluationCatalog(()),
                )
            self.assertEqual(list((root / "checkpoints").iterdir()), [])

            publication = store.publish_run_result(
                result,
                evaluation_catalog=catalog,
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "exact R10 evaluation catalog is required",
            ):
                store.reopen_frozen_policy(publication.frozen_policy)
            with self.assertRaisesRegex(
                R10PersistenceError,
                "catalog identity differs",
            ):
                store.reopen_frozen_policy(
                    publication.frozen_policy,
                    evaluation_catalog=R10EvaluationCatalog(()),
                )

    def test_forged_scored_checkpoint_cannot_publish_or_reopen_policy(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-forged-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            candidates = (_candidate("candidate", 1),)
            catalog = _catalog(candidates)
            legitimate = _optimize(candidates, catalog=catalog)
            original_attempt = legitimate.checkpoint.attempts[0]
            forged_attempt = R10Attempt.create(
                ordinal=original_attempt.ordinal,
                previous_attempt_sha256=(
                    original_attempt.previous_attempt_sha256
                ),
                candidate=original_attempt.candidate,
                score=_score(60_000),
            )
            forged_checkpoint = R10Checkpoint.create(
                processing_identity=legitimate.checkpoint.processing_identity,
                candidate_set_sha256=(
                    legitimate.checkpoint.candidate_set_sha256
                ),
                candidate_count=legitimate.checkpoint.candidate_count,
                maximum_candidates=legitimate.checkpoint.maximum_candidates,
                attempts=(forged_attempt,),
                status=R10CheckpointStatus.COMPLETED,
            )
            forged_selection = R10Selection.create((forged_attempt,))
            forged_result = R10RunResult(
                status=R10RunStatus.SUCCEEDED,
                checkpoint=forged_checkpoint,
                selection=forged_selection,
                terminal_code=None,
                evaluation_observation_count=1,
            )

            with self.assertRaisesRegex(
                R10PersistenceError,
                "scored attempt differs",
            ):
                store.publish_run_result(
                    forged_result,
                    evaluation_catalog=catalog,
                )
            self.assertEqual(list((root / "checkpoints").iterdir()), [])

            checkpoint_binding = store.publish_checkpoint(forged_checkpoint)
            checkpoint_reference = R10CheckpointReference(
                path=checkpoint_binding.path,
                sha256=checkpoint_binding.sha256,
                size_bytes=checkpoint_binding.size_bytes,
                checkpoint_sha256=forged_checkpoint.checkpoint_sha256,
            )
            forged_policy = R10FrozenPolicy.create(
                processing_identity=forged_checkpoint.processing_identity,
                candidate_set_sha256=forged_checkpoint.candidate_set_sha256,
                selection=forged_selection,
                final_checkpoint=checkpoint_reference,
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "scored attempt differs",
            ):
                store.publish_frozen_policy(
                    forged_policy,
                    evaluation_catalog=catalog,
                )
            self.assertEqual(list((root / "frozen-policies").iterdir()), [])

            policy_binding = store._publish_named(
                directory_name="frozen-policies",
                file_name=(
                    f"{forged_checkpoint.processing_identity.identity_sha256}"
                    ".json"
                ),
                payload=forged_policy.canonical_file_bytes,
                label="R10 frozen fixture policy",
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "scored attempt differs",
            ):
                store.reopen_frozen_policy(
                    policy_binding,
                    evaluation_catalog=catalog,
                )

    def test_forged_scored_checkpoint_cannot_publish_or_reopen_terminal(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-r10-forged-terminal-"
        ) as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            candidates = (
                _candidate("candidate-a", 1),
                _candidate("candidate-b", 2),
            )
            catalog = _catalog(candidates)
            cancellation_checks: list[int] = []

            def cancellation_requested() -> bool:
                cancellation_checks.append(1)
                return len(cancellation_checks) > 1

            legitimate = _optimize(
                candidates,
                catalog=catalog,
                cancellation_requested=cancellation_requested,
            )
            original_attempt = legitimate.checkpoint.attempts[0]
            forged_attempt = R10Attempt.create(
                ordinal=original_attempt.ordinal,
                previous_attempt_sha256=(
                    original_attempt.previous_attempt_sha256
                ),
                candidate=original_attempt.candidate,
                score=_score(60_000),
            )
            forged_checkpoint = R10Checkpoint.create(
                processing_identity=legitimate.checkpoint.processing_identity,
                candidate_set_sha256=(
                    legitimate.checkpoint.candidate_set_sha256
                ),
                candidate_count=legitimate.checkpoint.candidate_count,
                maximum_candidates=legitimate.checkpoint.maximum_candidates,
                attempts=(forged_attempt,),
                status=R10CheckpointStatus.CANCELLED,
                terminal_code=legitimate.terminal_code,
            )
            forged_result = R10RunResult(
                status=R10RunStatus.CANCELLED,
                checkpoint=forged_checkpoint,
                selection=None,
                terminal_code=legitimate.terminal_code,
                evaluation_observation_count=1,
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "scored attempt differs",
            ):
                store.publish_run_result(
                    forged_result,
                    evaluation_catalog=catalog,
                )

            checkpoint_binding = store.publish_checkpoint(forged_checkpoint)
            checkpoint_reference = R10CheckpointReference(
                path=checkpoint_binding.path,
                sha256=checkpoint_binding.sha256,
                size_bytes=checkpoint_binding.size_bytes,
                checkpoint_sha256=forged_checkpoint.checkpoint_sha256,
            )
            forged_terminal = R10TerminalRecord.create(
                processing_identity=forged_checkpoint.processing_identity,
                candidate_set_sha256=forged_checkpoint.candidate_set_sha256,
                status=forged_result.status,
                terminal_code=forged_result.terminal_code,
                checkpoint=checkpoint_reference,
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "scored attempt differs",
            ):
                store.publish_terminal_record(
                    forged_terminal,
                    evaluation_catalog=catalog,
                )

            payload = forged_terminal.canonical_file_bytes
            terminal_binding = store._publish_named(
                directory_name="terminals",
                file_name=f"{hashlib.sha256(payload).hexdigest()}.json",
                payload=payload,
                label="R10 terminal record",
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "scored attempt differs",
            ):
                store.reopen_terminal_record(
                    terminal_binding,
                    evaluation_catalog=catalog,
                )

    def test_reopened_outcomes_reject_dangling_checkpoint_dependency(
        self,
    ) -> None:
        for outcome in ("policy", "terminal"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory(
                prefix=f"mirmir-r10-dangling-{outcome}-"
            ) as value:
                root = Path(value) / "artifacts"
                store = R10PersistenceStore(root)
                candidates = (_candidate("candidate", 1),)
                if outcome == "policy":
                    catalog = _catalog(candidates)
                    result = _optimize(candidates, catalog=catalog)
                else:
                    catalog = R10EvaluationCatalog(())
                    result = _optimize(
                        candidates,
                        catalog=catalog,
                    )
                publication = store.publish_run_result(
                    result,
                    evaluation_catalog=catalog,
                )
                (root / publication.checkpoint.path).unlink()

                with self.assertRaisesRegex(
                    R10PersistenceError,
                    "unavailable",
                ):
                    if outcome == "policy":
                        store.reopen_frozen_policy(
                            publication.frozen_policy,
                            evaluation_catalog=catalog,
                        )
                    else:
                        store.reopen_terminal_record(
                            publication.terminal,
                            evaluation_catalog=catalog,
                        )

    def test_reopened_outcomes_replay_checkpoint_semantics(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-replay-") as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            candidates = (
                _candidate("candidate-a", 1),
                _candidate("candidate-b", 2),
            )
            catalog = _catalog(candidates)
            result = _optimize(candidates, catalog=catalog)
            checkpoint_binding = store.publish_checkpoint(result.checkpoint)
            checkpoint_reference = R10CheckpointReference(
                path=checkpoint_binding.path,
                sha256=checkpoint_binding.sha256,
                size_bytes=checkpoint_binding.size_bytes,
                checkpoint_sha256=result.checkpoint.checkpoint_sha256,
            )
            attempt_order_selection = R10Selection.create(
                result.checkpoint.attempts
            )
            reversed_selection = R10Selection.create(
                tuple(reversed(result.checkpoint.attempts))
            )
            invalid_selection = (
                attempt_order_selection
                if attempt_order_selection != result.selection
                else reversed_selection
            )
            invalid_policy = R10FrozenPolicy.create(
                processing_identity=result.checkpoint.processing_identity,
                candidate_set_sha256=result.checkpoint.candidate_set_sha256,
                selection=invalid_selection,
                final_checkpoint=checkpoint_reference,
            )
            policy_binding = store._publish_named(
                directory_name="frozen-policies",
                file_name=(
                    f"{result.checkpoint.processing_identity.identity_sha256}"
                    ".json"
                ),
                payload=invalid_policy.canonical_file_bytes,
                label="R10 frozen fixture policy",
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "selection differs",
            ):
                store.reopen_frozen_policy(
                    policy_binding,
                    evaluation_catalog=catalog,
                )

        with tempfile.TemporaryDirectory(
            prefix="mirmir-r10-terminal-replay-"
        ) as value:
            root = Path(value) / "artifacts"
            store = R10PersistenceStore(root)
            catalog = R10EvaluationCatalog(())
            failed = _optimize(
                (_candidate("candidate", 1),),
                catalog=catalog,
            )
            checkpoint_binding = store.publish_checkpoint(failed.checkpoint)
            checkpoint_reference = R10CheckpointReference(
                path=checkpoint_binding.path,
                sha256=checkpoint_binding.sha256,
                size_bytes=checkpoint_binding.size_bytes,
                checkpoint_sha256=failed.checkpoint.checkpoint_sha256,
            )
            invalid_terminal = R10TerminalRecord.create(
                processing_identity=failed.checkpoint.processing_identity,
                candidate_set_sha256=failed.checkpoint.candidate_set_sha256,
                status=failed.status,
                terminal_code="different_terminal_code",
                checkpoint=checkpoint_reference,
            )
            payload = invalid_terminal.canonical_file_bytes
            terminal_binding = store._publish_named(
                directory_name="terminals",
                file_name=f"{hashlib.sha256(payload).hexdigest()}.json",
                payload=payload,
                label="R10 terminal record",
            )
            with self.assertRaisesRegex(
                R10PersistenceError,
                "checkpoint dependency differs",
            ):
                store.reopen_terminal_record(
                    terminal_binding,
                    evaluation_catalog=catalog,
                )


if __name__ == "__main__":
    unittest.main()
