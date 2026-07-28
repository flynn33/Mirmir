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
from validation.calibration_v2.r11_traceability import (
    canonical_json_file_bytes_r11,
    reopen_execution_receipt_r11,
)
from validation.calibration_v2.tools import (
    run_r11_fixture_traceability as runner_module,
)
from validation.calibration_v2.tools.run_r11_fixture_traceability import (
    COMPARISON_POLICY,
    CONTRACTS_PATH,
    CORE_PATH,
    FIXTURE_CATALOG_PATH,
    FIXTURE_SCHEMA_PATH,
    LIMITATIONS,
    PHASE_EVIDENCE_PATH,
    PREDECESSOR_BINDING,
    PREREGISTRATION_PATH,
    REPOSITORY_ROOT,
    RUNNER_PATH,
    RUN_RECEIPT_SCHEMA_PATH,
    R11FixtureTraceabilityError,
    SOURCE_FILE_ROLES,
    _MAX_SOURCE_FILE_BYTES,
    _git_file_bytes,
    _validate_outer_receipt,
    _write_receipt,
    build_argument_parser,
    run_fixture_traceability,
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
    with tempfile.TemporaryDirectory(prefix="mirmir-r11-runner-test-") as value:
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
            "user.name=R11 Test",
            "-c",
            "user.email=r11-test@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "exact R11 traceability fixture source",
        )
        commit = _git(repository, "rev-parse", "HEAD").decode("ascii").strip()
        yield base, repository, commit


def _commit_change(repository: Path, message: str) -> str:
    _git(repository, "add", "--all")
    _git(
        repository,
        "-c",
        "user.name=R11 Test",
        "-c",
        "user.email=r11-test@example.invalid",
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


def _schema() -> dict[str, object]:
    return json.loads(
        (REPOSITORY_ROOT / RUN_RECEIPT_SCHEMA_PATH).read_text(
            encoding="utf-8"
        )
    )


def _schema_errors(receipt: object) -> list[str]:
    return validate_json_schema_instance(_schema(), receipt)


class R11FixtureTraceabilityCLITests(unittest.TestCase):
    maxDiff = None

    def test_exact_source_run_publishes_typed_bounded_receipt(self) -> None:
        with _exact_source_repository() as (base, repository, commit):
            output = base / "run"
            receipt_path = run_fixture_traceability(
                source_commit=commit,
                output_root=output,
                repository_root=repository,
            )

            self.assertEqual(
                receipt_path,
                output / "traceability-run-receipt.json",
            )
            receipt_bytes = receipt_path.read_bytes()
            receipt = json.loads(receipt_bytes)
            self.assertEqual(
                set(receipt),
                {
                    "schema_version",
                    "roadmap_version",
                    "phase_id",
                    "artifact_kind",
                    "source",
                    "source_files",
                    "predecessor_binding",
                    "execution_receipt",
                    "execution_receipt_sha256",
                    "comparison_policy",
                    "result_status",
                    "limitations",
                },
            )
            tree = _git(
                repository,
                "rev-parse",
                f"{commit}^{{tree}}",
            ).decode("ascii").strip()
            self.assertEqual(
                receipt["source"],
                {"commit": commit, "tree": tree},
            )
            self.assertEqual(receipt["phase_id"], "R11")
            self.assertEqual(
                receipt["artifact_kind"],
                "r11_traceability_run_receipt",
            )
            self.assertEqual(receipt["result_status"], "succeeded")
            self.assertEqual(
                [item["role"] for item in receipt["source_files"]],
                [role for role, _path in SOURCE_FILE_ROLES],
            )
            self.assertEqual(
                [item["path"] for item in receipt["source_files"]],
                [path for _role, path in SOURCE_FILE_ROLES],
            )
            self.assertEqual(len(receipt["source_files"]), 8)
            for binding in receipt["source_files"]:
                payload = (repository / binding["path"]).read_bytes()
                self.assertEqual(binding["size_bytes"], len(payload))
                self.assertEqual(
                    binding["sha256"],
                    hashlib.sha256(payload).hexdigest(),
                )
            self.assertEqual(receipt["predecessor_binding"], PREDECESSOR_BINDING)
            self.assertEqual(receipt["comparison_policy"], COMPARISON_POLICY)
            self.assertEqual(receipt["limitations"], LIMITATIONS)
            self.assertEqual(_schema_errors(receipt), [])

            nested = receipt["execution_receipt"]
            nested_payload = canonical_json_file_bytes_r11(nested)
            self.assertEqual(
                receipt["execution_receipt_sha256"],
                hashlib.sha256(nested_payload).hexdigest(),
            )
            reopened = reopen_execution_receipt_r11(
                nested_payload,
                expected_sha256=receipt["execution_receipt_sha256"],
            )
            self.assertEqual(reopened.to_document(), nested)
            self.assertEqual(
                nested["identity"]["source"],
                {"commit": commit, "tree": tree},
            )
            self.assertEqual(
                [item["observation_id"] for item in nested["observations"]],
                [
                    "observation-absent",
                    "observation-failed",
                    "observation-not-applicable",
                    "observation-not-observed",
                    "observation-observed",
                ],
            )
            self.assertEqual(
                [item["state"] for item in nested["observations"]],
                [
                    "absent",
                    "failed",
                    "not_applicable",
                    "not_observed",
                    "observed",
                ],
            )
            self.assertEqual(
                nested["aggregate"]["state_counts"],
                {
                    "absent": 1,
                    "failed": 1,
                    "not_applicable": 1,
                    "not_observed": 1,
                    "observed": 1,
                },
            )
            self.assertEqual(
                nested["aggregate"]["observed_values"],
                [
                    {
                        "observation_id": "observation-observed",
                        "value": "declared_behavior_passed",
                    }
                ],
            )
            self.assertEqual(
                nested["claim_decision"],
                {
                    "requested_claim": "software_behavior_report",
                    "permitted_claim": "software_behavior_report",
                    "disposition": "no_market_claim",
                    "reason_code": "declared_software_behavior_only",
                    "evidence_identity_sha256": (
                        nested["identity"]["derived_digest_sha256"]
                    ),
                    "aggregate_sha256": (
                        reopened.aggregate.aggregate_sha256
                    ),
                    "product_qualification": "blocked",
                    "production_auto_mode": "blocked",
                    "market_position": "blocked",
                    "market_leading_claim": "blocked",
                },
            )
            self.assertEqual(stat.S_IMODE(receipt_path.stat().st_mode), 0o400)
            self.assertFalse(
                (output / ".traceability-run-receipt.pending").exists()
            )
            self.assertNotIn(b"/Users/", receipt_bytes)
            self.assertNotIn(b"/home/", receipt_bytes)
            self.assertNotIn(b'"timestamp"', receipt_bytes)
            self.assertNotIn(b'"hostname"', receipt_bytes)

    def test_same_commit_emits_byte_identical_receipt(self) -> None:
        with _exact_source_repository() as (base, repository, commit):
            first = base / "run-a"
            second = base / "run-b"
            run_fixture_traceability(
                source_commit=commit,
                output_root=first,
                repository_root=repository,
            )
            run_fixture_traceability(
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
                R11FixtureTraceabilityError,
                "output_root_must_be_absent",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertEqual(_tree_bytes(output), before)

    def test_output_root_inside_repository_is_rejected(self) -> None:
        with _exact_source_repository() as (_base, repository, commit):
            output = repository / "forbidden-output"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "outside_source_repository",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_symlinked_output_parent_is_rejected(self) -> None:
        with _exact_source_repository() as (base, repository, commit):
            actual = base / "actual"
            actual.mkdir()
            linked = base / "linked"
            linked.symlink_to(actual, target_is_directory=True)
            output = linked / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "symlinked_parent",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse((actual / "run").exists())

    def test_non_exact_source_commit_is_rejected_before_output(self) -> None:
        with _exact_source_repository() as (base, repository, commit):
            output = base / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "source_commit_must_be",
            ):
                run_fixture_traceability(
                    source_commit=commit[:12],
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_runtime_dependencies_are_exact_source_bound(self) -> None:
        drift_paths = (
            CONTRACTS_PATH,
            PHASE_EVIDENCE_PATH,
            FIXTURE_SCHEMA_PATH,
            RUNNER_PATH,
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
                        R11FixtureTraceabilityError,
                        "runtime_source_differs_from_source_commit:"
                        + relative,
                    ):
                        run_fixture_traceability(
                            source_commit=drifted_commit,
                            output_root=output,
                            repository_root=repository,
                        )
                    self.assertFalse(output.exists())

    def test_missing_source_dependency_is_rejected_before_output(self) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            (repository / CONTRACTS_PATH).unlink()
            commit = _commit_change(repository, "remove contract parser")
            output = base / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "source_file_blob_git_command_failed",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_missing_preregistration_is_rejected_before_output(self) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            (repository / PREREGISTRATION_PATH).unlink()
            commit = _commit_change(repository, "remove preregistration")
            output = base / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "source_file_blob_git_command_failed",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_preregistration_byte_drift_is_rejected_before_output(self) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            preregistration = repository / PREREGISTRATION_PATH
            preregistration.write_bytes(
                preregistration.read_bytes() + b"\n"
            )
            commit = _commit_change(repository, "drift preregistration bytes")
            output = base / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "exact_source_preregistration_identity_differs",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_preregistration_schema_rejects_tampered_record(self) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            preregistration_path = repository / PREREGISTRATION_PATH
            preregistration = json.loads(preregistration_path.read_bytes())
            preregistration["unauthorized_field"] = True
            payload = (
                json.dumps(
                    preregistration,
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n"
            ).encode("utf-8")
            preregistration_path.write_bytes(payload)
            commit = _commit_change(
                repository,
                "tamper preregistration structure",
            )
            output = base / "run"
            with (
                mock.patch.object(
                    runner_module.r11_contracts_module,
                    "PREREGISTRATION_SIZE_BYTES",
                    len(payload),
                ),
                mock.patch.object(
                    runner_module.r11_contracts_module,
                    "PREREGISTRATION_RAW_SHA256",
                    hashlib.sha256(payload).hexdigest(),
                ),
                self.assertRaisesRegex(
                    R11FixtureTraceabilityError,
                    "exact_source_preregistration_schema_rejected",
                ),
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_preregistration_requires_exact_selected_source_bindings(
        self,
    ) -> None:
        mutations = (
            (
                "run schema",
                "schema_bindings",
                "traceability_run_receipt",
                "preregistration_traceability_run_receipt_binding_differs",
            ),
            (
                "fixture catalog",
                "fixture_catalog_binding",
                None,
                "preregistration_fixture_catalog_binding_differs",
            ),
            (
                "traceability core",
                "implementation_contract_bindings",
                "traceability_core",
                "preregistration_traceability_core_binding_differs",
            ),
        )
        for label, collection, identifier, expected_error in mutations:
            with self.subTest(label=label):
                with _exact_source_repository() as (
                    base,
                    repository,
                    _commit,
                ):
                    preregistration_path = repository / PREREGISTRATION_PATH
                    preregistration = json.loads(
                        preregistration_path.read_bytes()
                    )
                    if identifier is None:
                        binding = preregistration[collection]
                    else:
                        binding = next(
                            item
                            for item in preregistration[collection]
                            if item["id"] == identifier
                        )
                    binding["sha256"] = "f" * 64
                    payload = (
                        json.dumps(
                            preregistration,
                            ensure_ascii=False,
                            indent=2,
                        )
                        + "\n"
                    ).encode("utf-8")
                    preregistration_path.write_bytes(payload)
                    commit = _commit_change(
                        repository,
                        f"tamper preregistration {label} binding",
                    )
                    output = base / "run"
                    with (
                        mock.patch.object(
                            runner_module.r11_contracts_module,
                            "PREREGISTRATION_SIZE_BYTES",
                            len(payload),
                        ),
                        mock.patch.object(
                            runner_module.r11_contracts_module,
                            "PREREGISTRATION_RAW_SHA256",
                            hashlib.sha256(payload).hexdigest(),
                        ),
                        self.assertRaisesRegex(
                            R11FixtureTraceabilityError,
                            expected_error,
                        ),
                    ):
                        run_fixture_traceability(
                            source_commit=commit,
                            output_root=output,
                            repository_root=repository,
                        )
                    self.assertFalse(output.exists())

    def test_selected_core_drift_is_rejected_by_preregistration(self) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            core = repository / CORE_PATH
            core.write_bytes(core.read_bytes() + b"\n")
            commit = _commit_change(repository, "drift traceability core")
            output = base / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "preregistration_traceability_core_binding_differs",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_tampered_fixture_catalog_is_rejected_before_output(self) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            fixture = repository / FIXTURE_CATALOG_PATH
            payload = fixture.read_bytes()
            changed = payload.replace(
                b'"comparison_method": "absent_not_required"',
                b'"comparison_method": "historical_product_comparison"',
                1,
            )
            self.assertNotEqual(changed, payload)
            fixture.write_bytes(changed)
            commit = _commit_change(repository, "tamper fixture catalog")
            output = base / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "preregistration_fixture_catalog_binding_differs",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_tampered_run_schema_is_rejected_by_preregistration(self) -> None:
        with _exact_source_repository() as (base, repository, _commit):
            schema_path = repository / RUN_RECEIPT_SCHEMA_PATH
            schema_path.write_bytes(b"{}\n")
            commit = _commit_change(
                repository,
                "replace run receipt schema with self-validating empty schema",
            )
            output = base / "run"
            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "preregistration_traceability_run_receipt_binding_differs",
            ):
                run_fixture_traceability(
                    source_commit=commit,
                    output_root=output,
                    repository_root=repository,
                )
            self.assertFalse(output.exists())

    def test_schema_rejects_missing_reordered_or_truncated_contracts(
        self,
    ) -> None:
        with _exact_source_repository() as (base, repository, commit):
            receipt_path = run_fixture_traceability(
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

            reordered_observation = copy.deepcopy(receipt)
            reordered_observation["execution_receipt"]["observations"][
                0
            ], reordered_observation["execution_receipt"]["observations"][
                1
            ] = (
                reordered_observation["execution_receipt"]["observations"][1],
                reordered_observation["execution_receipt"]["observations"][0],
            )
            mutations.append(
                ("reordered observation prefix", reordered_observation)
            )

            missing_observation = copy.deepcopy(receipt)
            missing_observation["execution_receipt"]["observations"].pop()
            mutations.append(("missing observation", missing_observation))

            for label, mutated in mutations:
                with self.subTest(label=label):
                    self.assertTrue(_schema_errors(mutated))

    def test_nested_receipt_digest_tamper_is_rejected(self) -> None:
        with _exact_source_repository() as (base, repository, commit):
            receipt_path = run_fixture_traceability(
                source_commit=commit,
                output_root=base / "run",
                repository_root=repository,
            )
            receipt = json.loads(receipt_path.read_bytes())
            source = receipt["source"]
            expected_files = receipt["source_files"]
            receipt["execution_receipt_sha256"] = "f" * 64

            with self.assertRaisesRegex(
                R11FixtureTraceabilityError,
                "execution_receipt_binding_differs",
            ):
                _validate_outer_receipt(
                    receipt,
                    schema=_schema(),
                    source_commit=source["commit"],
                    source_tree=source["tree"],
                    expected_source_files=expected_files,
                )

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
                R11FixtureTraceabilityError,
                "source_file_size_exceeds_bound",
            ):
                _git_file_bytes(
                    Path("/private/tmp"),
                    "b" * 40,
                    CORE_PATH,
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
                R11FixtureTraceabilityError,
                "source_file_size_differs_from_preflight",
            ):
                _git_file_bytes(
                    Path("/private/tmp"),
                    "b" * 40,
                    CORE_PATH,
                )

    def test_post_link_failure_removes_final_and_temporary_receipts(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-r11-receipt-rollback-"
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
                    R11FixtureTraceabilityError,
                    "traceability_run_receipt_publication_failed",
                ):
                    _write_receipt(
                        output,
                        identity,
                        {"test_contract": "post_link_rollback"},
                    )

            self.assertGreaterEqual(calls, 3)
            self.assertFalse(
                (output / "traceability-run-receipt.json").exists()
            )
            self.assertFalse(
                (output / ".traceability-run-receipt.pending").exists()
            )

    def test_parser_exposes_only_two_required_operational_arguments(
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
                "/private/tmp/r11-cli-parser-test",
            ]
        )
        self.assertEqual(parsed.source_commit, "a" * 40)
        self.assertEqual(
            parsed.output_root,
            Path("/private/tmp/r11-cli-parser-test"),
        )


if __name__ == "__main__":
    unittest.main()
