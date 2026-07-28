from __future__ import annotations

import copy
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

from Scripts.phase_evidence import validate_json_schema_instance
from validation.calibration_v2.tools import (
    run_r10_fixture_calibration as runner_module,
)
from validation.calibration_v2.tools.run_r10_fixture_calibration import (
    EVALUATION_CATALOG_PATH,
    FIXTURE_CATALOG_PATH,
    OPTIMIZER_PATH,
    REPOSITORY_ROOT,
    R10FixtureCalibrationError,
    SOURCE_FILE_ROLES,
    _MAX_SOURCE_FILE_BYTES,
    _git_file_bytes,
    _write_receipt,
    build_argument_parser,
    run_fixture_calibration,
)


RUN_RECEIPT_SCHEMA_PATH = (
    "docs/roadmaps/evidence/schema/r10-calibration-run-receipt-v1.json"
)


def _git(repository: Path, *arguments: str) -> bytes:
    executable = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"
    result = subprocess.run(
        [executable, "-C", os.fspath(repository), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"git command failed: {arguments!r}: {result.stderr!r}"
        )
    return result.stdout


@contextmanager
def _exact_source_repository():
    with tempfile.TemporaryDirectory(prefix="mirmir-r10-cli-test-") as value:
        base = Path(value).resolve()
        repository = base / "source"
        repository.mkdir(mode=0o700)
        _git(repository, "init", "--quiet")
        for _role, relative in SOURCE_FILE_ROLES:
            source = REPOSITORY_ROOT / relative
            destination = repository / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
        _git(repository, "add", "--all")
        _git(
            repository,
            "-c",
            "user.name=R10 Test",
            "-c",
            "user.email=r10-test@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "exact R10 fixture source",
        )
        commit = _git(repository, "rev-parse", "HEAD").decode("ascii").strip()
        yield base, repository, commit


def _commit_change(repository: Path, message: str) -> str:
    _git(repository, "add", "--all")
    _git(
        repository,
        "-c",
        "user.name=R10 Test",
        "-c",
        "user.email=r10-test@example.invalid",
        "commit",
        "--quiet",
        "-m",
        message,
    )
    return _git(repository, "rev-parse", "HEAD").decode("ascii").strip()


def _tree_bytes(root: Path) -> dict[str, bytes]:
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def _schema_errors(receipt: object) -> list[str]:
    schema = json.loads(
        (REPOSITORY_ROOT / RUN_RECEIPT_SCHEMA_PATH).read_text(
            encoding="utf-8"
        )
    )
    return validate_json_schema_instance(schema, receipt)


class R10FixtureCalibrationCLITests(unittest.TestCase):
    maxDiff = None

    def test_exact_source_run_publishes_reopened_bounded_fixture_receipt(
        self,
    ) -> None:
        with _exact_source_repository() as (base, repository, commit):
            output = base / "run"
            receipt_path = run_fixture_calibration(
                source_commit=commit,
                output_root=output,
                repository_root=repository,
            )

            self.assertEqual(receipt_path, output / "run-receipt.json")
            receipt_bytes = receipt_path.read_bytes()
            receipt = json.loads(receipt_bytes)
            self.assertEqual(
                set(receipt),
                {
                    "schema_version",
                    "phase_id",
                    "artifact_kind",
                    "result_status",
                    "processing_identity",
                    "processing_identity_sha256",
                    "source_files",
                    "raw_evaluation_catalog_binding",
                    "semantic_evaluator_sha256",
                    "execution_contract",
                    "checkpoint_bindings",
                    "publication",
                },
            )
            self.assertEqual(receipt["phase_id"], "R10")
            self.assertEqual(receipt["result_status"], "succeeded")
            self.assertEqual(
                receipt["artifact_kind"],
                "r10_fixture_calibration_run_receipt",
            )
            self.assertEqual(
                [item["path"] for item in receipt["source_files"]],
                [path for _role, path in SOURCE_FILE_ROLES],
            )
            self.assertEqual(
                [item["role"] for item in receipt["source_files"]],
                [role for role, _path in SOURCE_FILE_ROLES],
            )
            self.assertEqual(len(receipt["source_files"]), 11)
            self.assertEqual(_schema_errors(receipt), [])

            evaluation_binding = next(
                item
                for item in receipt["source_files"]
                if item["path"] == EVALUATION_CATALOG_PATH
            )
            self.assertEqual(
                receipt["raw_evaluation_catalog_binding"],
                {
                    "path": evaluation_binding["path"],
                    "size_bytes": evaluation_binding["size_bytes"],
                    "sha256": evaluation_binding["sha256"],
                },
            )
            self.assertEqual(
                receipt["semantic_evaluator_sha256"],
                receipt["processing_identity"]["evaluator_sha256"],
            )
            self.assertEqual(
                receipt["processing_identity"]["source_commit"],
                commit,
            )
            self.assertEqual(
                receipt["processing_identity"]["optimizer_contract_sha256"],
                hashlib.sha256(
                    (repository / OPTIMIZER_PATH).read_bytes()
                ).hexdigest(),
            )

            execution = receipt["execution_contract"]
            self.assertEqual(execution["maximum_candidates"], 9)
            self.assertEqual(execution["candidate_count"], 9)
            self.assertEqual(execution["scored_count"], 3)
            self.assertEqual(execution["rejected_count"], 6)
            self.assertEqual(execution["evaluation_observation_count"], 3)
            self.assertEqual(
                execution["independently_rejected_constraints"],
                [
                    "route",
                    "plane",
                    "temporal",
                    "protected_region",
                    "resource",
                    "safety",
                ],
            )
            self.assertEqual(
                execution["tie_break"]["equal_score_candidate_ids"],
                ["fixture-valid-alpha", "fixture-valid-beta"],
            )
            self.assertEqual(
                execution["tie_break"]["winner_candidate_id"],
                "fixture-valid-alpha",
            )
            self.assertFalse(execution["comparison_methods_used"])
            self.assertFalse(execution["production_auto_authorized"])
            self.assertFalse(execution["holdout_authorized"])

            checkpoints = receipt["checkpoint_bindings"]
            self.assertEqual(len(checkpoints), 10)
            self.assertEqual(
                [record["next_candidate_index"] for record in checkpoints],
                list(range(10)),
            )
            self.assertEqual(
                [record["status"] for record in checkpoints],
                ["in_progress"] * 9 + ["completed"],
            )
            self.assertEqual(
                receipt["publication"]["final_checkpoint"],
                checkpoints[-1]["artifact"],
            )
            self.assertEqual(
                receipt["publication"]["selected_candidate_id"],
                "fixture-valid-alpha",
            )
            self.assertEqual(
                stat.S_IMODE(receipt_path.stat().st_mode),
                0o400,
            )
            for record in checkpoints:
                artifact = output / record["artifact"]["path"]
                self.assertTrue(artifact.is_file())
                self.assertEqual(stat.S_IMODE(artifact.stat().st_mode), 0o400)
            frozen = output / receipt["publication"]["frozen_policy"]["path"]
            self.assertTrue(frozen.is_file())
            self.assertEqual(stat.S_IMODE(frozen.stat().st_mode), 0o400)

    def test_same_commit_emits_byte_identical_receipt_and_artifacts(
        self,
    ) -> None:
        with _exact_source_repository() as (base, repository, commit):
            first = base / "run-a"
            second = base / "run-b"
            run_fixture_calibration(
                source_commit=commit,
                output_root=first,
                repository_root=repository,
            )
            run_fixture_calibration(
                source_commit=commit,
                output_root=second,
                repository_root=repository,
            )
            self.assertEqual(_tree_bytes(first), _tree_bytes(second))

    def test_existing_output_root_is_rejected_without_mutation(self) -> None:
        with _exact_source_repository() as (base, repository, commit):
            output = base / "existing"
            output.mkdir()
            sentinel = output / "operator-owned.txt"
            sentinel.write_text("preserve\n", encoding="utf-8")
            before = _tree_bytes(output)

            with self.assertRaisesRegex(
                R10FixtureCalibrationError,
                "output_root_must_be_absent",
            ):
                run_fixture_calibration(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertEqual(_tree_bytes(output), before)

    def test_output_root_inside_repository_is_rejected(self) -> None:
        with _exact_source_repository() as (_base, repository, commit):
            output = repository / "forbidden-output"
            with self.assertRaisesRegex(
                R10FixtureCalibrationError,
                "outside_source_repository",
            ):
                run_fixture_calibration(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_non_exact_source_commit_is_rejected_before_output_creation(
        self,
    ) -> None:
        with _exact_source_repository() as (base, repository, commit):
            output = base / "run"
            with self.assertRaisesRegex(
                R10FixtureCalibrationError,
                "source_commit_must_be",
            ):
                run_fixture_calibration(
                    source_commit=commit[:12],
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_runtime_source_drift_from_selected_commit_is_rejected(
        self,
    ) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            optimizer = repository / OPTIMIZER_PATH
            optimizer.write_bytes(
                optimizer.read_bytes() + b"\n# deliberate test drift\n"
            )
            drifted_commit = _commit_change(repository, "drift optimizer")
            output = base / "run"

            with self.assertRaisesRegex(
                R10FixtureCalibrationError,
                "runtime_source_differs_from_source_commit",
            ):
                run_fixture_calibration(
                    source_commit=drifted_commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_parser_runtime_and_schema_drift_are_source_bound(self) -> None:
        drift_paths = (
            "Scripts/phase_evidence.py",
            "docs/roadmaps/evidence/schema/r10-fixture-catalog-v1.json",
            "docs/roadmaps/evidence/schema/r10-evaluation-catalog-v1.json",
            "docs/roadmaps/evidence/schema/r10-policy-catalog-v1.json",
        )
        for relative in drift_paths:
            with self.subTest(relative=relative):
                with _exact_source_repository() as (
                    base,
                    repository,
                    _commit,
                ):
                    dependency = repository / relative
                    dependency.write_bytes(
                        dependency.read_bytes() + b"\n"
                    )
                    drifted_commit = _commit_change(
                        repository,
                        f"drift {relative}",
                    )
                    output = base / "run"

                    with self.assertRaisesRegex(
                        R10FixtureCalibrationError,
                        "runtime_source_differs_from_source_commit:"
                        + relative,
                    ):
                        run_fixture_calibration(
                            source_commit=drifted_commit,
                            output_root=output,
                            repository_root=repository,
                        )
                    self.assertFalse(output.exists())

    def test_oversized_source_blob_is_rejected_before_show(self) -> None:
        object_id = b"a" * 40 + b"\n"
        with mock.patch.object(
            runner_module,
            "_git_bytes",
            side_effect=[
                object_id,
                b"blob\n",
                f"{_MAX_SOURCE_FILE_BYTES + 1}\n".encode("ascii"),
            ],
        ) as bounded_git:
            with self.assertRaisesRegex(
                R10FixtureCalibrationError,
                "source_file_size_exceeds_bound",
            ):
                _git_file_bytes(
                    Path("/private/tmp"),
                    "b" * 40,
                    OPTIMIZER_PATH,
                )
        self.assertEqual(bounded_git.call_count, 3)

    def test_source_blob_must_match_preflight_size_exactly(self) -> None:
        object_id = b"a" * 40 + b"\n"
        with mock.patch.object(
            runner_module,
            "_git_bytes",
            side_effect=[
                object_id,
                b"blob\n",
                b"5\n",
                b"four",
            ],
        ):
            with self.assertRaisesRegex(
                R10FixtureCalibrationError,
                "source_file_size_differs_from_preflight",
            ):
                _git_file_bytes(
                    Path("/private/tmp"),
                    "b" * 40,
                    OPTIMIZER_PATH,
                )

    def test_post_link_failure_removes_final_success_receipt(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-r10-receipt-rollback-"
        ) as value:
            output = Path(value).resolve() / "run"
            output.mkdir(mode=0o700)
            identity = (output.stat().st_dev, output.stat().st_ino)
            real_fsync = os.fsync
            calls = 0

            def fail_first_post_link_fsync(descriptor: int) -> None:
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("deliberate post-link failure")
                real_fsync(descriptor)

            with mock.patch.object(
                runner_module.os,
                "fsync",
                side_effect=fail_first_post_link_fsync,
            ):
                with self.assertRaisesRegex(
                    R10FixtureCalibrationError,
                    "run_receipt_publication_failed",
                ):
                    _write_receipt(
                        output,
                        identity,
                        {"test_contract": "post_link_rollback"},
                    )

            self.assertGreaterEqual(calls, 3)
            self.assertFalse((output / "run-receipt.json").exists())
            self.assertFalse((output / ".run-receipt.pending").exists())

    def test_run_receipt_schema_rejects_truncated_or_reordered_contracts(
        self,
    ) -> None:
        with _exact_source_repository() as (base, repository, commit):
            receipt_path = run_fixture_calibration(
                source_commit=commit,
                output_root=base / "run",
                repository_root=repository,
            )
            receipt = json.loads(receipt_path.read_bytes())
            self.assertEqual(_schema_errors(receipt), [])

            mutations: list[tuple[str, object]] = []
            missing_source = copy.deepcopy(receipt)
            missing_source["source_files"].pop()
            mutations.append(("missing source dependency", missing_source))

            reordered_source = copy.deepcopy(receipt)
            reordered_source["source_files"][0], reordered_source[
                "source_files"
            ][1] = (
                reordered_source["source_files"][1],
                reordered_source["source_files"][0],
            )
            mutations.append(("reordered source roles", reordered_source))

            missing_constraint = copy.deepcopy(receipt)
            missing_constraint["execution_contract"][
                "independently_rejected_constraints"
            ].pop()
            mutations.append(("truncated constraint prefix", missing_constraint))

            missing_tie_member = copy.deepcopy(receipt)
            missing_tie_member["execution_contract"]["tie_break"][
                "equal_score_candidate_ids"
            ].pop()
            mutations.append(("truncated tie prefix", missing_tie_member))

            wrong_checkpoint_position = copy.deepcopy(receipt)
            wrong_checkpoint_position["checkpoint_bindings"][4][
                "next_candidate_index"
            ] = 5
            mutations.append(
                ("wrong checkpoint prefix position", wrong_checkpoint_position)
            )

            wrong_artifact_role = copy.deepcopy(receipt)
            wrong_artifact_role["publication"]["frozen_policy"]["path"] = (
                wrong_artifact_role["publication"]["final_checkpoint"]["path"]
            )
            mutations.append(("wrong artifact role", wrong_artifact_role))

            for label, mutated in mutations:
                with self.subTest(label=label):
                    self.assertTrue(_schema_errors(mutated))

    def test_tampered_catalog_contract_is_rejected_before_publication(
        self,
    ) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            fixture = repository / FIXTURE_CATALOG_PATH
            payload = fixture.read_bytes()
            changed = payload.replace(
                b'"comparison_methods_used": false',
                b'"comparison_methods_used": true',
            )
            self.assertNotEqual(changed, payload)
            fixture.write_bytes(changed)
            tampered_commit = _commit_change(repository, "tamper fixture")
            output = base / "run"

            with self.assertRaisesRegex(
                R10FixtureCalibrationError,
                "exact_source_catalog_contract_rejected",
            ):
                run_fixture_calibration(
                    source_commit=tampered_commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_parser_exposes_only_the_two_required_operational_arguments(
        self,
    ) -> None:
        parser = build_argument_parser()
        operational = [
            action.dest
            for action in parser._actions
            if action.dest != "help"
        ]
        self.assertEqual(operational, ["source_commit", "output_root"])
        parsed = parser.parse_args(
            [
                "--source-commit",
                "a" * 40,
                "--output-root",
                "/private/tmp/r10-cli-parser-test",
            ]
        )
        self.assertEqual(parsed.source_commit, "a" * 40)
        self.assertEqual(
            parsed.output_root,
            Path("/private/tmp/r10-cli-parser-test"),
        )


if __name__ == "__main__":
    unittest.main()
