from __future__ import annotations

import ast
from contextlib import contextmanager
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from r11_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ARTIFACT_DIRECTORY,
    CONTRACT_PATHS,
    EXECUTION_RECEIPT_PATH,
    EXPECTED_SELECTED_TEST_COUNT,
    IMPLEMENTATION_PATHS,
    ROADMAP_PATH,
    RUN_RECEIPT_ARTIFACT_PATH,
    RUN_RECEIPT_PATH,
    R11PhaseAcceptanceVerifier,
    TEST_SUITES,
    UNITTEST_COMMAND,
    UNITTEST_LOG_PATH,
    _MAX_JSON_BYTES,
    _MAX_LOG_BYTES,
    _safe_relative_path,
)
from validation.calibration_v2.tools.run_r11_fixture_traceability import (  # noqa: E402
    run_fixture_traceability,
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


def _read_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected JSON object: {path}")
    return value


def _write_json(path: Path, value: object, *, mode: int | None = None) -> None:
    prior_mode = stat.S_IMODE(path.stat().st_mode)
    path.chmod(0o600)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    path.chmod(prior_mode if mode is None else mode)


def _replace_bytes(path: Path, payload: bytes, mode: int) -> None:
    if path.exists() and not path.is_symlink():
        path.chmod(0o600)
    path.write_bytes(payload)
    path.chmod(mode)


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
            "Ran 76 tests in 0.001s",
            "",
            "OK",
            "",
        ]
    )
    return "\n".join(lines).encode("utf-8")


@contextmanager
def acceptance_fixture():
    with tempfile.TemporaryDirectory(
        prefix="mirmir-r11-acceptance-"
    ) as value:
        base = Path(value).resolve()
        repository = base / "repository"
        subprocess.run(
            [
                "git",
                "clone",
                "-q",
                "--no-hardlinks",
                os.fspath(REPOSITORY_ROOT),
                os.fspath(repository),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        _git(repository, "config", "user.email", "r11@example.invalid")
        _git(repository, "config", "user.name", "R11 Acceptance Tests")
        for relative in (
            Path("Scripts/r11_phase_acceptance.py"),
            Path("Scripts/tests/test_r11_phase_acceptance.py"),
        ):
            target = repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((REPOSITORY_ROOT / relative).read_bytes())
        _git(repository, "add", "Scripts/r11_phase_acceptance.py")
        _git(repository, "add", "Scripts/tests/test_r11_phase_acceptance.py")
        _git(repository, "commit", "-qm", "R11 acceptance harness fixture")
        commit = _git(repository, "rev-parse", "HEAD")
        verifier = R11PhaseAcceptanceVerifier(repository)
        source = verifier.resolve_source(commit)
        identifiers, errors = verifier._checkpoint_test_inventory(source)
        if errors:
            raise AssertionError(errors)
        log = base / "unittest.log"
        log.write_bytes(_unittest_log(identifiers))
        run_root = base / "traceability-run"
        run_fixture_traceability(
            source_commit=commit,
            output_root=run_root,
            repository_root=repository,
        )
        yield repository, commit, log, run_root, verifier


class R11PhaseAcceptanceTests(unittest.TestCase):
    maxDiff = None

    def test_exact_76_inventory_and_real_log_parser_contract(self) -> None:
        self.assertEqual(
            tuple(len(suite.methods) for suite in TEST_SUITES),
            (32, 21, 23),
        )
        self.assertEqual(
            sum(len(suite.methods) for suite in TEST_SUITES),
            EXPECTED_SELECTED_TEST_COUNT,
        )
        identifiers = tuple(
            identifier
            for suite in TEST_SUITES
            for identifier in suite.identifiers
        )
        self.assertEqual(len(identifiers), 76)
        self.assertEqual(len(set(identifiers)), 76)
        self.assertEqual(
            R11PhaseAcceptanceVerifier._test_log_errors(
                _unittest_log(identifiers), identifiers
            ),
            [],
        )
        for suite in TEST_SUITES:
            payload = (REPOSITORY_ROOT / suite.path).read_bytes()
            methods, errors = R11PhaseAcceptanceVerifier._suite_methods(
                payload, suite
            )
            self.assertEqual(errors, [])
            self.assertEqual(methods, suite.methods)
            module = ast.parse(payload.decode("utf-8"))
            self.assertTrue(
                any(
                    isinstance(node, ast.ClassDef)
                    and node.name == suite.class_name
                    for node in module.body
                )
            )

    def test_parser_rejects_false_positive_failure_skip_and_forgery(
        self,
    ) -> None:
        identifiers = tuple(
            identifier
            for suite in TEST_SUITES
            for identifier in suite.identifiers
        )
        valid = _unittest_log(identifiers)
        malformed = (
            valid.replace(b" ... ok", b" ... FAIL", 1),
            valid.replace(b" ... ok", b" ... skipped 'unavailable'", 1),
            valid.replace(b"Ran 76 tests", b"Ran 75 tests"),
            valid.replace(b"\nOK\n", b"\nFAILED (failures=1)\n"),
            valid.replace(
                identifiers[0].rsplit(".", 1)[0].encode("utf-8"),
                b"forged.module.Test",
                1,
            ),
            valid + valid,
            b"prefix " + valid,
        )
        for payload in malformed:
            with self.subTest(payload=payload[-120:]):
                self.assertTrue(
                    R11PhaseAcceptanceVerifier._test_log_errors(
                        payload, identifiers
                    )
                )

    def test_writer_imports_dual_receipts_and_deeply_validates_bundle(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run_root,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run_root),
                [],
            )
            self.assertEqual(verifier.check_generated(), [])
            self.assertEqual(verifier.check(), [])
            canonical = repository / RUN_RECEIPT_PATH
            artifact = repository / RUN_RECEIPT_ARTIFACT_PATH
            self.assertEqual(canonical.read_bytes(), artifact.read_bytes())
            self.assertEqual(stat.S_IMODE(canonical.stat().st_mode), 0o400)
            self.assertEqual(stat.S_IMODE(artifact.stat().st_mode), 0o400)
            self.assertEqual(
                stat.S_IMODE((repository / UNITTEST_LOG_PATH).stat().st_mode),
                0o400,
            )
            execution = _read_json(repository / EXECUTION_RECEIPT_PATH)
            acceptance = _read_json(repository / ACCEPTANCE_PATH)
            source = verifier.resolve_source(commit)
            self.assertEqual(execution["source"], source)
            self.assertEqual(acceptance["source"], source)
            implementation_ids = {
                item["id"] for item in execution["implementation_bindings"]
            }
            self.assertIn(
                "r11_phase_acceptance_validator", implementation_ids
            )
            self.assertIn(
                "r11_phase_acceptance_validator_tests", implementation_ids
            )
            artifacts = {
                item["id"]: item
                for item in execution["artifact_bindings"]
            }
            self.assertEqual(
                artifacts["canonical_traceability_run_receipt"]["sha256"],
                artifacts["traceability_run_receipt_artifact"]["sha256"],
            )
            self.assertEqual(
                execution["test_execution"],
                {
                    "selected_test_count": 76,
                    "passed_test_count": 76,
                    "failed_test_count": 0,
                    "skipped_test_count": 0,
                },
            )
            self.assertEqual(
                execution["run_summary"],
                {
                    "record_count": 5,
                    "counts": {
                        "observed": 1,
                        "not_applicable": 1,
                        "not_observed": 1,
                        "failed": 1,
                        "absent": 1,
                    },
                    "aggregate_state": "mixed",
                },
            )
            self.assertEqual(
                acceptance["functional_gate"],
                {
                    "status": "passed",
                    "acceptance_basis": "software_does_what_it_says_it_does",
                    "acceptance_scope": "declared_software_function_only",
                    "phase_status_before": "in_progress",
                    "phase_status_after": "passed",
                },
            )
            self.assertEqual(
                acceptance["claim_boundary"]["market_disposition"],
                "no_market_claim",
            )
            self.assertTrue(
                any(
                    "release remain blocked or unauthorized" in limitation
                    for limitation in acceptance["limitations"]
                )
            )

    def test_in_progress_absence_passes_and_passed_absence_fails(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            _log,
            _run_root,
            verifier,
        ):
            self.assertEqual(verifier.check(), [])
            roadmap_path = repository / ROADMAP_PATH
            roadmap = _read_json(roadmap_path)
            phases = roadmap["phases"]
            assert isinstance(phases, list)
            phase = next(
                item
                for item in phases
                if isinstance(item, dict) and item.get("id") == "R11"
            )
            phase["status"] = "passed"
            _write_json(roadmap_path, roadmap)
            self.assertEqual(
                verifier.check(),
                [
                    "R11 generated acceptance evidence is absent while "
                    "canonical phase status is 'passed'"
                ],
            )

    def test_deep_verifier_rejects_tamper_missing_stale_source_and_forgery(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run_root,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run_root),
                [],
            )
            paths = (
                repository / RUN_RECEIPT_PATH,
                repository / RUN_RECEIPT_ARTIFACT_PATH,
                repository / UNITTEST_LOG_PATH,
                repository / EXECUTION_RECEIPT_PATH,
                repository / ACCEPTANCE_PATH,
            )
            originals = {
                path: (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
                for path in paths
            }

            def restore() -> None:
                for path, (payload, mode) in originals.items():
                    if path.is_symlink():
                        path.unlink()
                    _replace_bytes(path, payload, mode)

            mutations = []

            def forged_count() -> None:
                value = _read_json(repository / EXECUTION_RECEIPT_PATH)
                value["test_execution"]["selected_test_count"] = 75
                _write_json(repository / EXECUTION_RECEIPT_PATH, value)

            mutations.append(("forged_count", forged_count))

            def forged_claim() -> None:
                value = _read_json(repository / ACCEPTANCE_PATH)
                value["claim_boundary"]["market_disposition"] = "market_claim"
                _write_json(repository / ACCEPTANCE_PATH, value)

            mutations.append(("forged_claim", forged_claim))

            def forged_authority() -> None:
                value = _read_json(repository / ACCEPTANCE_PATH)
                value["authorization_boundary"] = {
                    "production_auto_mode": "authorized",
                    "release": "authorized",
                }
                _write_json(repository / ACCEPTANCE_PATH, value)

            mutations.append(("forged_authority", forged_authority))

            def stale_source() -> None:
                value = _read_json(repository / EXECUTION_RECEIPT_PATH)
                value["source"] = {
                    "commit": "3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b",
                    "tree": "37951da694ab4fbca6f8c663bb2883e5084b861c",
                }
                _write_json(repository / EXECUTION_RECEIPT_PATH, value)

            mutations.append(("stale_source", stale_source))

            def missing_artifact() -> None:
                (repository / RUN_RECEIPT_ARTIFACT_PATH).unlink()

            mutations.append(("missing_artifact", missing_artifact))

            def drifted_artifact_copy() -> None:
                path = repository / RUN_RECEIPT_ARTIFACT_PATH
                payload, _mode = originals[path]
                mutated = payload.replace(
                    b'"result_status":"succeeded"',
                    b'"result_status":"failed___"',
                    1,
                )
                _replace_bytes(path, mutated, 0o400)

            mutations.append(("drifted_artifact_copy", drifted_artifact_copy))

            try:
                for label, mutate in mutations:
                    with self.subTest(label=label):
                        restore()
                        self.assertEqual(verifier.check_generated(), [])
                        mutate()
                        self.assertTrue(verifier.check_generated())
            finally:
                restore()
            self.assertEqual(verifier.check_generated(), [])

    def test_run_receipt_rejects_duplicate_nonfinite_and_noncanonical_json(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run_root,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run_root),
                [],
            )
            canonical = repository / RUN_RECEIPT_PATH
            artifact = repository / RUN_RECEIPT_ARTIFACT_PATH
            original = canonical.read_bytes()
            variants = (
                original.replace(
                    b'{"artifact_kind":',
                    (
                        b'{"artifact_kind":"r11_traceability_run_receipt",'
                        b'"artifact_kind":'
                    ),
                    1,
                ),
                original.replace(
                    b'"result_status":"succeeded"',
                    b'"nonfinite":NaN,"result_status":"succeeded"',
                    1,
                ),
                (
                    json.dumps(
                        json.loads(original),
                        indent=2,
                        ensure_ascii=False,
                    )
                    + "\n"
                ).encode("utf-8"),
            )
            try:
                for payload in variants:
                    with self.subTest(payload=payload[:100]):
                        _replace_bytes(canonical, payload, 0o400)
                        _replace_bytes(artifact, payload, 0o400)
                        self.assertTrue(verifier.check_generated())
            finally:
                _replace_bytes(canonical, original, 0o400)
                _replace_bytes(artifact, original, 0o400)
            self.assertEqual(verifier.check_generated(), [])

    def test_writer_rejects_stale_unsafe_and_oversize_inputs_without_output(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run_root,
            verifier,
        ):
            outputs = (
                repository / RUN_RECEIPT_PATH,
                repository / EXECUTION_RECEIPT_PATH,
                repository / ACCEPTANCE_PATH,
                repository / ARTIFACT_DIRECTORY,
            )

            stale = _git(repository, "rev-parse", f"{commit}^")
            self.assertTrue(
                verifier.write(stale, test_log=log, run_root=run_root)
            )
            self.assertFalse(any(path.exists() for path in outputs))

            symlinked_log = log.parent / "symlinked-unittest.log"
            symlinked_log.symlink_to(log)
            self.assertTrue(
                verifier.write(
                    commit, test_log=symlinked_log, run_root=run_root
                )
            )
            self.assertFalse(any(path.exists() for path in outputs))

            symlinked_run = run_root.parent / "symlinked-run"
            symlinked_run.symlink_to(run_root, target_is_directory=True)
            self.assertTrue(
                verifier.write(
                    commit, test_log=log, run_root=symlinked_run
                )
            )
            self.assertFalse(any(path.exists() for path in outputs))

            receipt = run_root / "traceability-run-receipt.json"
            hardlink = run_root.parent / "run-receipt-hardlink.json"
            os.link(receipt, hardlink)
            try:
                self.assertTrue(
                    verifier.write(
                        commit, test_log=log, run_root=run_root
                    )
                )
                self.assertFalse(any(path.exists() for path in outputs))
            finally:
                hardlink.unlink()

            oversized = log.parent / "oversized-unittest.log"
            oversized.write_bytes(b"x")
            os.truncate(oversized, _MAX_LOG_BYTES + 1)
            self.assertTrue(
                verifier.write(
                    commit, test_log=oversized, run_root=run_root
                )
            )
            self.assertFalse(any(path.exists() for path in outputs))

    def test_publication_failure_rolls_back_and_retry_succeeds(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run_root,
            verifier,
        ):
            original_publish = verifier._publish_payload_at
            calls = 0

            def fail_fourth(*args, **kwargs):
                nonlocal calls
                calls += 1
                if calls == 4:
                    raise ValueError("injected_publication_failure")
                return original_publish(*args, **kwargs)

            with mock.patch.object(
                verifier,
                "_publish_payload_at",
                side_effect=fail_fourth,
            ):
                errors = verifier.write(
                    commit, test_log=log, run_root=run_root
                )
            self.assertTrue(
                any("injected_publication_failure" in error for error in errors)
            )
            self.assertFalse((repository / RUN_RECEIPT_PATH).exists())
            self.assertFalse((repository / EXECUTION_RECEIPT_PATH).exists())
            self.assertFalse((repository / ACCEPTANCE_PATH).exists())
            self.assertFalse((repository / ARTIFACT_DIRECTORY).exists())
            self.assertFalse(
                (repository / ARTIFACT_DIRECTORY.parent).exists()
            )
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run_root),
                [],
            )
            self.assertEqual(verifier.check_generated(), [])

    def test_git_materialized_artifacts_validate_after_fresh_clone(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run_root,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run_root),
                [],
            )
            _git(repository, "add", "docs/roadmaps/evidence/r11/records")
            _git(repository, "commit", "-qm", "Add R11 acceptance fixture")
            fresh = repository.parent / "fresh-checkout"
            subprocess.run(
                [
                    "git",
                    "clone",
                    "-q",
                    "--no-hardlinks",
                    os.fspath(repository),
                    os.fspath(fresh),
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for relative in (
                RUN_RECEIPT_PATH,
                RUN_RECEIPT_ARTIFACT_PATH,
                UNITTEST_LOG_PATH,
            ):
                self.assertEqual(
                    stat.S_IMODE((fresh / relative).stat().st_mode),
                    0o644,
                )
            fresh_verifier = R11PhaseAcceptanceVerifier(fresh)
            self.assertEqual(fresh_verifier.check_generated(), [])
            self.assertEqual(fresh_verifier.check(), [])

    def test_path_escape_and_generated_symlink_hardlink_oversize_reject(
        self,
    ) -> None:
        for value in ("../escape", "nested/../../escape", "/absolute/path"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    _safe_relative_path(value, "test path")

        with acceptance_fixture() as (
            repository,
            commit,
            log,
            run_root,
            verifier,
        ):
            self.assertEqual(
                verifier.write(commit, test_log=log, run_root=run_root),
                [],
            )
            artifact = repository / RUN_RECEIPT_ARTIFACT_PATH
            original = artifact.read_bytes()

            artifact.chmod(0o600)
            artifact.unlink()
            artifact.symlink_to(repository / RUN_RECEIPT_PATH)
            self.assertTrue(verifier.check_generated())
            artifact.unlink()
            _replace_bytes(artifact, original, 0o400)

            hardlink = repository.parent / "artifact-hardlink.json"
            os.link(artifact, hardlink)
            try:
                self.assertTrue(verifier.check_generated())
            finally:
                hardlink.unlink()
            self.assertEqual(verifier.check_generated(), [])

            artifact.chmod(0o600)
            os.truncate(artifact, _MAX_JSON_BYTES + 1)
            artifact.chmod(0o400)
            self.assertTrue(verifier.check_generated())
            _replace_bytes(artifact, original, 0o400)
            self.assertEqual(verifier.check_generated(), [])

    def test_real_76_unittest_execution_log_parses(self) -> None:
        self.assertEqual(
            UNITTEST_COMMAND,
            (
                "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v "
                "validation.calibration_v2.tests.test_r11_traceability "
                "validation.calibration_v2.tests."
                "test_run_r11_fixture_traceability "
                "Scripts.tests.test_r11_contracts"
            ),
        )
        environment = dict(os.environ)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "unittest",
                "-v",
                "validation.calibration_v2.tests.test_r11_traceability",
                (
                    "validation.calibration_v2.tests."
                    "test_run_r11_fixture_traceability"
                ),
                "Scripts.tests.test_r11_contracts",
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8"))
        self.assertEqual(result.stdout, b"")
        identifiers = tuple(
            identifier
            for suite in TEST_SUITES
            for identifier in suite.identifiers
        )
        self.assertEqual(
            R11PhaseAcceptanceVerifier._test_log_errors(
                result.stderr, identifiers
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
