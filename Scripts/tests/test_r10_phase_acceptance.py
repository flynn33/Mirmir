from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r10_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ACCEPTANCE_SCHEMA_PATH,
    ARTIFACT_DIRECTORY,
    CONTRACT_PATHS,
    DERIVED_CHECK_IDS,
    EXECUTION_RECEIPT_PATH,
    EXECUTION_RECEIPT_SCHEMA_PATH,
    EXPECTED_SELECTED_TEST_COUNT,
    FUNCTIONAL_CHECK_IDS,
    FUNCTIONAL_TEST_METHODS,
    IMPLEMENTATION_PATHS,
    OBSERVATION_STATUS,
    OPERATOR_OVERRIDE,
    ROADMAP_PATH,
    RUN_DIRECTORY,
    RUN_RECEIPT_PATH,
    R10PhaseAcceptanceVerifier,
    TEST_SUITES,
    UNITTEST_COMMAND,
    UNITTEST_LOG_PATH,
    _MAX_LOG_BYTES,
    _MAX_SOURCE_BLOB_BYTES,
)
from validation.calibration_v2.tools.run_r10_fixture_calibration import (  # noqa: E402
    SOURCE_FILE_ROLES as RUNNER_SOURCE_FILE_ROLES,
    run_fixture_calibration,
)


def _git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def _copy_file(source_root: Path, target_root: Path, relative: Path) -> None:
    target = target_root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((source_root / relative).read_bytes())


def _unittest_log(identifiers: tuple[str, ...]) -> bytes:
    lines = [
        (
            f"{identifier.rsplit('.', 1)[-1]} "
            f"({identifier.rsplit('.', 1)[0]}) ... ok"
        )
        for identifier in identifiers
    ]
    lines.extend(
        [
            "",
            "----------------------------------------------------------------------",
            "Ran 39 tests in 0.001s",
            "",
            "OK",
            "",
        ]
    )
    return "\n".join(lines).encode("utf-8")


@contextmanager
def acceptance_fixture():
    with tempfile.TemporaryDirectory(prefix="mirmir-r10-acceptance-") as value:
        base = Path(value).resolve()
        repository = base / "repository"
        repository.mkdir()
        required = {
            ROADMAP_PATH,
            *(path for _identifier, path in CONTRACT_PATHS),
            *(path for _identifier, path in IMPLEMENTATION_PATHS),
            *(Path(path) for _role, path in RUNNER_SOURCE_FILE_ROLES),
        }
        for relative in sorted(required):
            _copy_file(REPOSITORY_ROOT, repository, relative)
        _git(repository, "init", "-q")
        _git(repository, "config", "user.email", "r10@example.invalid")
        _git(repository, "config", "user.name", "R10 Acceptance Tests")
        _git(repository, "add", ".")
        _git(repository, "commit", "-qm", "R10 exact implementation fixture")
        commit = _git(repository, "rev-parse", "HEAD")
        verifier = R10PhaseAcceptanceVerifier(repository)
        source = verifier.resolve_source(commit)
        identifiers, errors = verifier._checkpoint_test_inventory(source)
        if errors:
            raise AssertionError(errors)
        log = base / "unittest.log"
        log.write_bytes(_unittest_log(identifiers))
        run_root = base / "calibration-run"
        run_fixture_calibration(
            source_commit=commit,
            output_root=run_root,
            repository_root=repository,
        )
        yield repository, commit, log, run_root, verifier


def _read_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected JSON object: {path}")
    return value


def _write_json(path: Path, value: object, *, mode: int | None = None) -> None:
    prior_mode = path.stat().st_mode & 0o777
    path.chmod(0o600)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    path.chmod(prior_mode if mode is None else mode)


class R10PhaseAcceptanceTests(unittest.TestCase):
    maxDiff = None

    def test_checked_in_absence_is_valid_while_r10_is_in_progress(self) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            _log,
            _run,
            verifier,
        ):
            roadmap_path = repository / ROADMAP_PATH
            roadmap = _read_json(roadmap_path)
            phases = roadmap["phases"]
            assert isinstance(phases, list)
            phase = next(
                item
                for item in phases
                if isinstance(item, dict) and item.get("id") == "R10"
            )
            phase["status"] = "in_progress"
            _write_json(roadmap_path, roadmap)
            self.assertEqual(
                next(
                    phase["status"]
                    for phase in _read_json(roadmap_path)["phases"]
                    if phase["id"] == "R10"
                ),
                "in_progress",
            )
            self.assertFalse((repository / EXECUTION_RECEIPT_PATH).exists())
            self.assertFalse((repository / ACCEPTANCE_PATH).exists())
            self.assertEqual(verifier.check(), [])

    def test_checked_in_absence_is_rejected_after_r10_passes(self) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            _log,
            _run,
            verifier,
        ):
            self.assertEqual(
                next(
                    phase["status"]
                    for phase in _read_json(repository / ROADMAP_PATH)["phases"]
                    if phase["id"] == "R10"
                ),
                "passed",
            )
            self.assertFalse((repository / EXECUTION_RECEIPT_PATH).exists())
            self.assertFalse((repository / ACCEPTANCE_PATH).exists())
            self.assertEqual(
                verifier.check(),
                [
                    "R10 generated acceptance evidence is absent while "
                    "canonical phase status is 'passed'"
                ],
            )

    def test_writer_imports_and_validates_complete_generated_bundle(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            self.assertEqual(verifier.check_generated(), [])
            self.assertEqual(verifier.check(), [])
            execution = _read_json(repository / EXECUTION_RECEIPT_PATH)
            acceptance = _read_json(repository / ACCEPTANCE_PATH)
            self.assertEqual(
                execution["test_execution"]["expected_selected_test_count"],
                39,
            )
            self.assertEqual(
                execution["run_result"],
                {
                    "result_status": "succeeded",
                    "candidate_count": 9,
                    "scored_count": 3,
                    "rejected_count": 6,
                    "checkpoint_count": 10,
                    "selected_candidate_id": "fixture-valid-alpha",
                    "typed_reopen": "passed",
                },
            )
            self.assertEqual(
                acceptance["functional_gate"]["acceptance_basis"],
                "software_does_what_it_says_it_does",
            )
            self.assertEqual(
                acceptance["functional_gate"]["phase_status_before"],
                "in_progress",
            )
            self.assertEqual(
                acceptance["functional_gate"]["phase_status_after"],
                "passed",
            )
            imported_run = repository / RUN_DIRECTORY
            self.assertEqual(
                {
                    path.relative_to(imported_run).as_posix()
                    for path in imported_run.rglob("*")
                    if path.is_file()
                },
                {
                    path.relative_to(run).as_posix()
                    for path in run.rglob("*")
                    if path.is_file()
                },
            )

    def test_derived_records_validate_against_closed_schemas(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            execution = _read_json(repository / EXECUTION_RECEIPT_PATH)
            acceptance = _read_json(repository / ACCEPTANCE_PATH)
            execution_schema = _read_json(
                repository / EXECUTION_RECEIPT_SCHEMA_PATH
            )
            acceptance_schema = _read_json(repository / ACCEPTANCE_SCHEMA_PATH)
            self.assertEqual(
                validate_json_schema_instance(execution_schema, execution),
                [],
            )
            self.assertEqual(
                validate_json_schema_instance(acceptance_schema, acceptance),
                [],
            )

    def test_exact_39_inventory_is_unique_complete_and_functionally_mapped(
        self,
    ) -> None:
        self.assertEqual(
            tuple(len(suite.methods) for suite in TEST_SUITES),
            (20, 19),
        )
        self.assertEqual(
            sum(len(suite.methods) for suite in TEST_SUITES),
            EXPECTED_SELECTED_TEST_COUNT,
        )
        mapped = [
            identifier
            for _check, identifiers in FUNCTIONAL_TEST_METHODS
            for identifier in identifiers
        ]
        expected = [
            identifier
            for suite in TEST_SUITES
            for identifier in suite.identifiers
        ]
        self.assertEqual(len(mapped), 39)
        self.assertEqual(len(set(mapped)), 39)
        self.assertEqual(set(mapped), set(expected))
        self.assertEqual(
            tuple(check for check, _identifiers in FUNCTIONAL_TEST_METHODS),
            FUNCTIONAL_CHECK_IDS,
        )
        self.assertEqual(len(FUNCTIONAL_CHECK_IDS), 12)
        self.assertEqual(len(DERIVED_CHECK_IDS), 12)
        for suite in TEST_SUITES:
            methods, errors = R10PhaseAcceptanceVerifier._suite_methods(
                (REPOSITORY_ROOT / suite.path).read_bytes(),
                suite,
            )
            self.assertEqual(errors, [])
            self.assertEqual(methods, suite.methods)

    def test_malformed_log_failure_skip_and_inventory_are_rejected(self) -> None:
        identifiers = tuple(
            identifier
            for suite in TEST_SUITES
            for identifier in suite.identifiers
        )
        valid = _unittest_log(identifiers)
        self.assertEqual(
            R10PhaseAcceptanceVerifier._test_log_errors(valid, identifiers),
            [],
        )
        for malformed in (
            valid.replace(b" ... ok", b" ... FAIL", 1),
            valid.replace(b" ... ok", b" ... skipped 'unsupported'", 1),
            valid.replace(b"Ran 39 tests", b"Ran 38 tests"),
            valid.replace(b"\nOK\n", b"\nFAILED (failures=1)\n"),
            valid.replace(
                identifiers[0].rsplit(".", 1)[0].encode("utf-8"),
                b"forged.module.Test",
                1,
            ),
        ):
            with self.subTest(malformed=malformed[-80:]):
                self.assertTrue(
                    R10PhaseAcceptanceVerifier._test_log_errors(
                        malformed, identifiers
                    )
                )
        suite = TEST_SUITES[0]
        payload = (REPOSITORY_ROOT / suite.path).read_bytes().replace(
            suite.methods[0].encode("utf-8"),
            b"test_unregistered_inventory_member",
            1,
        )
        _methods, errors = R10PhaseAcceptanceVerifier._suite_methods(
            payload, suite
        )
        self.assertTrue(errors)

    def test_input_reader_rejects_oversize_and_growth_without_unbounded_read(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-read-") as value:
            root = Path(value).resolve()
            oversized = root / "oversized.log"
            oversized.write_bytes(b"x")
            os.truncate(oversized, _MAX_LOG_BYTES + 1)
            with self.assertRaisesRegex(ValueError, "size differs"):
                R10PhaseAcceptanceVerifier(root)._read_input_file(
                    oversized,
                    context="oversized input",
                    maximum=_MAX_LOG_BYTES,
                )

            growing = root / "growing.log"
            growing.write_bytes(b"abc")
            real_read = os.read
            read_calls = 0

            def injected_growth(descriptor: int, count: int) -> bytes:
                nonlocal read_calls
                read_calls += 1
                if read_calls == 1:
                    return real_read(descriptor, count)
                return b"x"

            with mock.patch("r10_phase_acceptance.os.read", injected_growth):
                with self.assertRaisesRegex(ValueError, "grew"):
                    R10PhaseAcceptanceVerifier(root)._read_input_file(
                        growing,
                        context="growing input",
                        maximum=_MAX_LOG_BYTES,
                    )

    def test_checkpoint_reader_rejects_oversized_blob_before_show(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-r10-blob-") as value:
            repository = Path(value).resolve() / "repository"
            repository.mkdir()
            oversized = repository / "oversized.bin"
            oversized.write_bytes(b"x")
            os.truncate(oversized, _MAX_SOURCE_BLOB_BYTES + 1)
            _git(repository, "init", "-q")
            _git(repository, "config", "user.email", "r10@example.invalid")
            _git(repository, "config", "user.name", "R10 Blob Tests")
            _git(repository, "add", "oversized.bin")
            _git(repository, "commit", "-qm", "oversized blob")
            verifier = R10PhaseAcceptanceVerifier(repository)
            source = verifier.resolve_source(_git(repository, "rev-parse", "HEAD"))
            with self.assertRaisesRegex(ValueError, "fixed boundary"):
                verifier._checkpoint_bytes(source, Path("oversized.bin"))

    def test_single_byte_dynamic_artifact_drift_is_rejected(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            checkpoint = next(
                (repository / RUN_DIRECTORY / "checkpoints").glob("*.json")
            )
            payload = bytearray(checkpoint.read_bytes())
            payload[len(payload) // 2] ^= 1
            checkpoint.chmod(0o600)
            checkpoint.write_bytes(bytes(payload))
            checkpoint.chmod(0o400)
            errors = verifier.check_generated()
            self.assertTrue(errors)
            self.assertTrue(
                any(
                    "dynamic" in error
                    or "reopen" in error
                    or "closure" in error
                    for error in errors
                ),
                errors,
            )

    def test_checked_in_artifact_ancestor_symlink_escape_is_rejected(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            artifact_parent = repository / ARTIFACT_DIRECTORY.parent
            escaped_parent = repository.parent / "escaped-artifacts"
            artifact_parent.rename(escaped_parent)
            artifact_parent.symlink_to(
                escaped_parent,
                target_is_directory=True,
            )
            generated_errors = verifier.check_generated()
            check_errors = verifier.check()
            self.assertTrue(generated_errors)
            self.assertTrue(check_errors)
            self.assertTrue(
                any(
                    "ancestor" in error or "unsafe" in error
                    for error in (*generated_errors, *check_errors)
                ),
                (generated_errors, check_errors),
            )

    def test_source_tree_and_catalog_binding_drift_are_rejected(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            execution_path = repository / EXECUTION_RECEIPT_PATH
            execution = _read_json(execution_path)
            execution["source"]["tree"] = "f" * 40
            _write_json(execution_path, execution)
            self.assertTrue(
                any(
                    "source commit/tree" in error
                    for error in verifier.check_generated()
                )
            )

        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            run_receipt_path = repository / RUN_RECEIPT_PATH
            run_receipt = _read_json(run_receipt_path)
            run_receipt["raw_evaluation_catalog_binding"]["sha256"] = "f" * 64
            _write_json(run_receipt_path, run_receipt, mode=0o400)
            errors = verifier.check_generated()
            self.assertTrue(
                any(
                    "evaluation-catalog binding differs" in error
                    or "dynamic file closure differs" in error
                    for error in errors
                ),
                errors,
            )

    def test_execution_artifact_binding_drift_is_rejected(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            execution_path = repository / EXECUTION_RECEIPT_PATH
            execution = _read_json(execution_path)
            execution["artifact_bindings"][0]["sha256"] = "f" * 64
            _write_json(execution_path, execution)
            errors = verifier.check_generated()
            self.assertTrue(
                any("not exactly derived" in error for error in errors),
                errors,
            )

    def test_unsupported_claims_and_authority_expansion_are_rejected(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            execution_path = repository / EXECUTION_RECEIPT_PATH
            execution = _read_json(execution_path)
            execution["authorization_boundary"]["production_auto"] = "authorized"
            _write_json(execution_path, execution)
            errors = verifier.check_generated()
            self.assertTrue(
                any(
                    "schema" in error or "not exactly derived" in error
                    for error in errors
                ),
                errors,
            )

        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run),
                [],
            )
            acceptance_path = repository / ACCEPTANCE_PATH
            acceptance = _read_json(acceptance_path)
            acceptance["authorization_boundary"]["holdout"] = "authorized"
            _write_json(acceptance_path, acceptance)
            errors = verifier.check_generated()
            self.assertTrue(
                any(
                    "schema" in error or "not exactly derived" in error
                    for error in errors
                ),
                errors,
            )

    def test_fixture_only_noncomparative_unobserved_boundaries_are_exact(
        self,
    ) -> None:
        self.assertEqual(
            OPERATOR_OVERRIDE,
            {
                "authority": "operator",
                "acceptance_basis": "software_does_what_it_says_it_does",
                "comparison_requirement": "not_run_not_required",
                "hardware_requirement": "waived_not_a_blocker",
                "simulator_requirement": "waived_not_a_blocker",
                "operator_observation_requirement": "waived_not_a_blocker",
            },
        )
        self.assertEqual(
            OBSERVATION_STATUS,
            {
                "deterministic_software_execution": "observed",
                "deterministic_fixture_simulation": "observed",
                "physical_hardware_execution": "not_observed",
                "apple_simulator_execution": "not_observed",
                "operator_observed_operation": "not_observed",
            },
        )
        self.assertNotIn("comparison", UNITTEST_COMMAND.casefold())
        self.assertNotIn("holdout", UNITTEST_COMMAND.casefold())

    def test_invalid_log_causes_no_partial_write(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run,
            verifier,
        ):
            log.write_bytes(log.read_bytes().replace(b"\nOK\n", b"\nFAILED\n"))
            errors = verifier.write(commit, test_log=log, run_root=run)
            self.assertTrue(errors)
            for path in (
                repository / EXECUTION_RECEIPT_PATH,
                repository / ACCEPTANCE_PATH,
                repository / ARTIFACT_DIRECTORY,
            ):
                self.assertFalse(path.exists(), path)

    def test_output_failure_rolls_back_every_published_target(self) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            _log,
            _run,
            verifier,
        ):
            payloads = (
                ("unittest_log", UNITTEST_LOG_PATH, b"log\n"),
                ("calibration_run_receipt", RUN_RECEIPT_PATH, b"{}\n"),
            )
            calls = 0
            real_publish = verifier._publish_payload_at

            def fail_second(
                parent_descriptor,
                name,
                payload,
                *,
                mode,
                context,
            ):  # type: ignore[no-untyped-def]
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("injected publication failure")
                return real_publish(
                    parent_descriptor,
                    name,
                    payload,
                    mode=mode,
                    context=context,
                )

            with mock.patch.object(
                verifier,
                "_publish_payload_at",
                side_effect=fail_second,
            ):
                errors = verifier._write_bundle(
                    execution_payload=b"{}\n",
                    acceptance_payload=b"{}\n",
                    artifact_payloads=payloads,
                )
            self.assertTrue(errors)
            for path in (
                repository / EXECUTION_RECEIPT_PATH,
                repository / ACCEPTANCE_PATH,
                repository / ARTIFACT_DIRECTORY,
            ):
                self.assertFalse(path.exists(), path)

    def test_publication_ancestor_swap_is_detected_and_rolled_back(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            _log,
            _run,
            verifier,
        ):
            payloads = (
                ("unittest_log", UNITTEST_LOG_PATH, b"log\n"),
                ("calibration_run_receipt", RUN_RECEIPT_PATH, b"{}\n"),
            )
            artifact_parent = repository / ARTIFACT_DIRECTORY.parent
            moved_parent = repository.parent / "moved-artifacts"
            escaped_parent = repository.parent / "outside-artifacts"
            escaped_parent.mkdir()
            real_publish = verifier._publish_payload_at
            swapped = False

            def swap_after_first(
                parent_descriptor,
                name,
                payload,
                *,
                mode,
                context,
            ):  # type: ignore[no-untyped-def]
                nonlocal swapped
                result = real_publish(
                    parent_descriptor,
                    name,
                    payload,
                    mode=mode,
                    context=context,
                )
                if not swapped:
                    artifact_parent.rename(moved_parent)
                    artifact_parent.symlink_to(
                        escaped_parent,
                        target_is_directory=True,
                    )
                    swapped = True
                return result

            with mock.patch.object(
                verifier,
                "_publish_payload_at",
                side_effect=swap_after_first,
            ):
                errors = verifier._write_bundle(
                    execution_payload=b"{}\n",
                    acceptance_payload=b"{}\n",
                    artifact_payloads=payloads,
                )
            self.assertTrue(errors)
            self.assertTrue(
                any("ancestor identity changed" in error for error in errors),
                errors,
            )
            self.assertFalse((repository / EXECUTION_RECEIPT_PATH).exists())
            self.assertFalse((repository / ACCEPTANCE_PATH).exists())
            self.assertFalse(
                (moved_parent / ARTIFACT_DIRECTORY.name).exists()
            )
            self.assertFalse(
                (escaped_parent / ARTIFACT_DIRECTORY.name).exists()
            )

    def test_partial_checked_in_bundle_is_rejected(self) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            _log,
            _run,
            verifier,
        ):
            target = repository / EXECUTION_RECEIPT_PATH
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("{}\n", encoding="utf-8")
            self.assertEqual(
                verifier.check(),
                ["R10 generated acceptance evidence is only partially present"],
            )

    def test_cli_parser_enforces_explicit_modes_and_operational_inputs(
        self,
    ) -> None:
        script = REPOSITORY_ROOT / "Scripts/r10_phase_acceptance.py"
        help_result = subprocess.run(
            [sys.executable, str(script), "--help"],
            cwd=REPOSITORY_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertIn("--check", help_result.stdout)
        self.assertIn("--check-generated", help_result.stdout)
        self.assertIn("--write", help_result.stdout)
        self.assertIn("--test-log", help_result.stdout)
        self.assertIn("--run-root", help_result.stdout)
        missing = subprocess.run(
            [sys.executable, str(script), "--write", "1" * 40],
            cwd=REPOSITORY_ROOT,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn(
            "--write requires --test-log and --run-root",
            missing.stderr,
        )


if __name__ == "__main__":
    unittest.main()
