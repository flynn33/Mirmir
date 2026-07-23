from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from r12_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ACCEPTANCE_SCHEMA_PATH,
    ARTIFACT_DIRECTORY,
    BUILD_LOG_PATH,
    EXECUTION_RECEIPT_PATH,
    EXECUTION_SCHEMA_PATH,
    FORMAT_SOURCE_PATH,
    LINT_LOG_PATH,
    PREDECESSOR_ACCEPTANCE_PATH,
    PROJECT_PATH,
    RECORDS_DIRECTORY,
    ROADMAP_PATH,
    R12PhaseAcceptanceVerifier,
    SOURCE_BINDING_PATHS,
    TEST_LOG_PATH,
    TEST_SUITES,
    _MAX_LINT_LOG_BYTES,
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
    prior_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    if path.exists() and not path.is_symlink():
        path.chmod(0o600)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    path.chmod(prior_mode if mode is None else mode)


def _replace_bytes(path: Path, payload: bytes, mode: int) -> None:
    if path.is_symlink():
        path.unlink()
    elif path.exists():
        path.chmod(0o600)
        path.unlink()
    path.write_bytes(payload)
    path.chmod(mode)


def _build_log(source: dict[str, str]) -> bytes:
    return (
        "Command line invocation:\n"
        "    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "
        "build-for-testing -project Mirmir.xcodeproj -scheme Mirmir "
        "-configuration Debug -destination platform=macOS,arch=arm64 "
        "-derivedDataPath /private/tmp/r12/DerivedData "
        f"R12_ACCEPTANCE_SOURCE_COMMIT={source['commit']} "
        f"R12_ACCEPTANCE_SOURCE_TREE={source['tree']}\n"
        "\n"
        "Build settings from command line:\n"
        f"    R12_ACCEPTANCE_SOURCE_COMMIT = {source['commit']}\n"
        f"    R12_ACCEPTANCE_SOURCE_TREE = {source['tree']}\n"
        "\n"
        "note: Building targets in dependency order\n"
        "** TEST BUILD SUCCEEDED **\n"
    ).encode("utf-8")


def _test_log(source: dict[str, str], identifiers: tuple[str, ...]) -> bytes:
    selections = " ".join(
        f'"-only-testing:{suite.only_testing}"' for suite in TEST_SUITES
    )
    lines = [
        "Command line invocation:",
        (
            "    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "
            "test-without-building -xctestrun "
            "/private/tmp/r12/Mirmir_macosx.xctestrun "
            "-destination platform=macOS,arch=arm64 "
            f"{selections} "
            f"R12_ACCEPTANCE_SOURCE_COMMIT={source['commit']} "
            f"R12_ACCEPTANCE_SOURCE_TREE={source['tree']}"
        ),
        "",
        "Test Suite 'Selected tests' started.",
    ]
    for identifier in identifiers:
        _module, suite, method = identifier.split(".")
        lines.extend(
            [
                (
                    f"Test Case '-[MirmirTests.{suite} {method}]' "
                    "started."
                ),
                (
                    f"Test Case '-[MirmirTests.{suite} {method}]' "
                    "passed (0.001 seconds)."
                ),
            ]
        )
    lines.extend(
        [
            "Test Suite 'Selected tests' passed.",
            (
                f"\t Executed {len(identifiers)} tests, with 0 failures "
                "(0 unexpected) in 0.100 (0.101) seconds"
            ),
            "",
            "** TEST EXECUTE SUCCEEDED **",
            "",
        ]
    )
    return "\n".join(lines).encode("utf-8")


def _lint_log(file_count: int = 3) -> bytes:
    lines = ["Linting Swift files in current working directory"]
    lines.extend(
        f"Linting 'Fixture{index}.swift' ({index}/{file_count})"
        for index in range(1, file_count + 1)
    )
    lines.append(
        f"Done linting! Found 0 violations, 0 serious in {file_count} files."
    )
    return ("\n".join(lines) + "\n").encode("utf-8")


def _set_r12_status(path: Path, status: str) -> None:
    roadmap = _read_json(path)
    phases = roadmap["phases"]
    assert isinstance(phases, list)
    phase = next(
        item
        for item in phases
        if isinstance(item, dict) and item.get("id") == "R12"
    )
    phase["status"] = status
    _write_json(path, roadmap)


@contextmanager
def acceptance_fixture():
    with tempfile.TemporaryDirectory(
        prefix="mirmir-r12-acceptance-"
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
        _git(repository, "config", "user.email", "r12@example.invalid")
        _git(repository, "config", "user.name", "R12 Acceptance Tests")

        # Copy the live bounded implementation into a private pre-evidence
        # checkpoint. This remains valid after repository closure because any
        # checked-in generated outputs are removed before the fixture commit.
        for _identifier, relative in SOURCE_BINDING_PATHS:
            source = REPOSITORY_ROOT / relative
            target = repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        for relative in (PREDECESSOR_ACCEPTANCE_PATH, ROADMAP_PATH):
            source = REPOSITORY_ROOT / relative
            target = repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.rmtree(repository / RECORDS_DIRECTORY, ignore_errors=True)
        _set_r12_status(repository / ROADMAP_PATH, "in_progress")
        _git(repository, "add", "-A")
        _git(
            repository,
            "commit",
            "--allow-empty",
            "-qm",
            "R12 acceptance pre-evidence fixture",
        )
        commit = _git(repository, "rev-parse", "HEAD")
        verifier = R12PhaseAcceptanceVerifier(repository)
        source = verifier.resolve_source(commit)
        inventory, errors = verifier._checkpoint_test_inventory(source)
        if errors or inventory is None:
            raise AssertionError(errors)
        build_log = base / "build-for-testing.log"
        test_log = base / "targeted-xctest.log"
        lint_log = base / "swiftlint.log"
        build_log.write_bytes(_build_log(source))
        test_log.write_bytes(_test_log(source, inventory.identifiers))
        lint_log.write_bytes(_lint_log())
        yield (
            repository,
            commit,
            source,
            inventory,
            build_log,
            test_log,
            lint_log,
            verifier,
        )


def _write_fixture(
    verifier: R12PhaseAcceptanceVerifier,
    commit: str,
    build_log: Path,
    test_log: Path,
    lint_log: Path,
) -> list[str]:
    return verifier.write(
        commit,
        build_log=build_log,
        test_log=test_log,
        lint_log=lint_log,
    )


class R12PhaseAcceptanceTests(unittest.TestCase):
    maxDiff = None

    def test_dynamic_inventory_coverage_and_strict_log_parsers(self) -> None:
        with acceptance_fixture() as (
            _repository,
            _commit,
            source,
            inventory,
            build_log,
            test_log,
            lint_log,
            verifier,
        ):
            source_counts = []
            for suite in TEST_SUITES:
                payload = (REPOSITORY_ROOT / suite.path).read_bytes()
                methods, errors = verifier._swift_test_methods(payload, suite)
                self.assertEqual(errors, [])
                source_counts.append(len(methods))
            self.assertEqual(
                tuple(count for _suite, count in inventory.suite_counts),
                tuple(source_counts),
            )
            self.assertEqual(source_counts[:2], [13, 14])
            self.assertGreater(source_counts[2], 0)
            coverage = verifier.contract_coverage(inventory)
            self.assertEqual(len(coverage), len(inventory.identifiers))
            self.assertEqual(
                {item["test_identifier"] for item in coverage},
                set(inventory.identifiers),
            )
            self.assertEqual(
                {
                    area
                    for item in coverage
                    for area in item["contract_areas"]
                },
                {"format", "route", "backend", "resume"},
            )
            self.assertEqual(
                verifier._build_log_errors(build_log.read_bytes(), source),
                [],
            )
            self.assertEqual(
                verifier._test_log_errors(
                    test_log.read_bytes(),
                    source,
                    inventory,
                    TEST_SUITES,
                ),
                [],
            )
            lint, lint_errors = verifier._lint_log(lint_log.read_bytes())
            self.assertEqual(lint_errors, [])
            self.assertIsNotNone(lint)

            invalid_builds = (
                build_log.read_bytes().replace(
                    b"TEST BUILD SUCCEEDED", b"TEST BUILD FAILED"
                ),
                build_log.read_bytes().replace(
                    source["commit"].encode(), b"0" * 40
                ),
                build_log.read_bytes() + b"error: forged\n",
            )
            for payload in invalid_builds:
                self.assertTrue(verifier._build_log_errors(payload, source))
            valid_tests = test_log.read_bytes()
            invalid_tests = (
                valid_tests.replace(b" passed (", b" failed (", 1),
                valid_tests.replace(b" passed (", b" skipped (", 1),
                valid_tests.replace(b"with 0 failures", b"with 1 failures"),
                valid_tests.replace(
                    inventory.identifiers[0].rsplit(".", 1)[-1].encode(),
                    b"testForgedCase",
                    1,
                ),
                valid_tests.replace(
                    b"** TEST EXECUTE SUCCEEDED **",
                    b"** TEST EXECUTE FAILED **",
                ),
            )
            for payload in invalid_tests:
                self.assertTrue(
                    verifier._test_log_errors(
                        payload, source, inventory, TEST_SUITES
                    )
                )
            invalid_lints = (
                lint_log.read_bytes().replace(
                    b"Found 0 violations, 0 serious",
                    b"Found 1 violations, 1 serious",
                ),
                lint_log.read_bytes()
                + b"Fixture.swift:1:1: error: violation\n",
                lint_log.read_bytes().replace(b"(2/3)", b"(3/3)"),
            )
            for payload in invalid_lints:
                _parsed, errors = verifier._lint_log(payload)
                self.assertTrue(errors)

    def test_writer_publishes_sealed_closed_deeply_validated_bundle(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            source,
            inventory,
            build_log,
            test_log,
            lint_log,
            verifier,
        ):
            self.assertEqual(
                _write_fixture(
                    verifier, commit, build_log, test_log, lint_log
                ),
                [],
            )
            self.assertEqual(verifier.check_generated(), [])
            self.assertEqual(verifier.check(), [])
            for relative in (BUILD_LOG_PATH, TEST_LOG_PATH, LINT_LOG_PATH):
                self.assertEqual(
                    stat.S_IMODE((repository / relative).stat().st_mode),
                    0o400,
                )
            execution = _read_json(repository / EXECUTION_RECEIPT_PATH)
            acceptance = _read_json(repository / ACCEPTANCE_PATH)
            self.assertEqual(execution["source"], source)
            self.assertEqual(acceptance["source"], source)
            self.assertEqual(
                len(execution["source_bindings"]),
                len(SOURCE_BINDING_PATHS),
            )
            self.assertEqual(
                execution["verification"]["targeted_tests"],
                {
                    "selected_test_count": len(inventory.identifiers),
                    "passed_test_count": len(inventory.identifiers),
                    "failed_test_count": 0,
                    "skipped_test_count": 0,
                    "suite_counts": [
                        {"suite": suite, "passed_test_count": count}
                        for suite, count in inventory.suite_counts
                    ],
                },
            )
            self.assertEqual(
                acceptance["functional_gate"]["acceptance_basis"],
                "software_does_what_it_says_it_does",
            )
            self.assertEqual(
                acceptance["observations"],
                {
                    "native_hardware": "not_observed",
                    "simulator": "not_observed",
                    "operator": "not_observed",
                    "nonblocking_for_software_function_acceptance": True,
                },
            )
            self.assertEqual(
                acceptance["claim_boundary"]["market_disposition"],
                "no_market_claim",
            )
            for authority in (
                "product_qualification",
                "production_auto_mode",
                "release_publication",
            ):
                self.assertEqual(
                    acceptance["claim_boundary"][authority],
                    "not_authorized",
                )
            self.assertEqual(
                acceptance["comparison_policy"]["acceptance_dependency"],
                "none",
            )

    def test_absence_is_permitted_only_preclosure_and_partial_rejects(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            _source,
            _inventory,
            _build_log,
            _test_log,
            _lint_log,
            verifier,
        ):
            self.assertEqual(verifier.check(), [])
            _set_r12_status(repository / ROADMAP_PATH, "evidence_ready")
            self.assertEqual(verifier.check(), [])
            _set_r12_status(repository / ROADMAP_PATH, "passed")
            self.assertEqual(
                verifier.check(),
                [
                    "R12 generated acceptance evidence is absent while "
                    "canonical phase status is 'passed'"
                ],
            )
            _set_r12_status(repository / ROADMAP_PATH, "planned")
            self.assertTrue(verifier.check())
            _set_r12_status(repository / ROADMAP_PATH, "in_progress")
            target = repository / EXECUTION_RECEIPT_PATH
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("{}\n", encoding="utf-8")
            self.assertEqual(
                verifier.check(),
                [
                    "R12 generated acceptance evidence is only partially "
                    "present"
                ],
            )

    def test_deep_check_rejects_generated_tamper_and_source_drift(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            _source,
            _inventory,
            build_log,
            test_log,
            lint_log,
            verifier,
        ):
            self.assertEqual(
                _write_fixture(
                    verifier, commit, build_log, test_log, lint_log
                ),
                [],
            )
            execution_path = repository / EXECUTION_RECEIPT_PATH
            execution_payload = execution_path.read_bytes()
            execution_mode = stat.S_IMODE(execution_path.stat().st_mode)
            execution = _read_json(execution_path)
            execution["acceptance_basis"] = "forged"
            _write_json(execution_path, execution)
            self.assertTrue(verifier.check_generated())
            _replace_bytes(
                execution_path, execution_payload, execution_mode
            )
            self.assertEqual(verifier.check_generated(), [])

            source_path = repository / FORMAT_SOURCE_PATH
            source_payload = source_path.read_bytes()
            source_mode = stat.S_IMODE(source_path.stat().st_mode)
            source_path.write_bytes(source_payload + b"\n")
            self.assertIn(
                (
                    "R12 current source differs from implementation commit: "
                    f"{FORMAT_SOURCE_PATH.as_posix()}"
                ),
                verifier.check_generated(),
            )
            _replace_bytes(source_path, source_payload, source_mode)
            self.assertEqual(verifier.check_generated(), [])

            log_path = repository / TEST_LOG_PATH
            log_payload = log_path.read_bytes()
            log_path.chmod(0o600)
            log_path.write_bytes(log_payload.replace(b"passed (", b"failed (", 1))
            log_path.chmod(0o400)
            self.assertTrue(verifier.check_generated())
            _replace_bytes(log_path, log_payload, 0o400)
            self.assertEqual(verifier.check_generated(), [])

    def test_input_and_generated_symlink_hardlink_and_oversize_reject(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            _source,
            _inventory,
            build_log,
            test_log,
            lint_log,
            verifier,
        ):
            symlink_log = build_log.parent / "build-symlink.log"
            symlink_log.symlink_to(build_log)
            self.assertTrue(
                verifier.write(
                    commit,
                    build_log=symlink_log,
                    test_log=test_log,
                    lint_log=lint_log,
                )
            )
            hardlink_log = build_log.parent / "build-hardlink.log"
            os.link(build_log, hardlink_log)
            self.assertTrue(
                verifier.write(
                    commit,
                    build_log=hardlink_log,
                    test_log=test_log,
                    lint_log=lint_log,
                )
            )
            hardlink_log.unlink()
            oversized = build_log.parent / "oversized-lint.log"
            with oversized.open("wb") as stream:
                stream.truncate(_MAX_LINT_LOG_BYTES + 1)
            self.assertTrue(
                verifier.write(
                    commit,
                    build_log=build_log,
                    test_log=test_log,
                    lint_log=oversized,
                )
            )
            self.assertFalse((repository / RECORDS_DIRECTORY).exists())

            self.assertEqual(
                _write_fixture(
                    verifier, commit, build_log, test_log, lint_log
                ),
                [],
            )
            generated = repository / BUILD_LOG_PATH
            original = generated.read_bytes()
            generated.chmod(0o600)
            generated.unlink()
            generated.symlink_to(build_log)
            self.assertTrue(verifier.check_generated())
            generated.unlink()
            generated.write_bytes(original)
            generated.chmod(0o400)
            self.assertEqual(verifier.check_generated(), [])

            external = build_log.parent / "generated-hardlink-target.log"
            external.write_bytes(original)
            generated.chmod(0o600)
            generated.unlink()
            os.link(external, generated)
            generated.chmod(0o400)
            self.assertTrue(verifier.check_generated())
            generated.unlink()
            external.unlink()
            generated.write_bytes(original)
            generated.chmod(0o400)
            self.assertEqual(verifier.check_generated(), [])

    def test_publication_failure_rolls_back_and_retry_succeeds(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            _source,
            _inventory,
            build_log,
            test_log,
            lint_log,
            verifier,
        ):
            original = verifier._publish_payload_at
            calls = 0

            def fail_third(*args, **kwargs):
                nonlocal calls
                calls += 1
                if calls == 3:
                    raise ValueError("injected publication failure")
                return original(*args, **kwargs)

            with mock.patch.object(
                verifier,
                "_publish_payload_at",
                side_effect=fail_third,
            ):
                errors = _write_fixture(
                    verifier, commit, build_log, test_log, lint_log
                )
            self.assertTrue(
                any("output transaction failed" in error for error in errors)
            )
            self.assertFalse((repository / RECORDS_DIRECTORY).exists())
            self.assertEqual(
                _write_fixture(
                    verifier, commit, build_log, test_log, lint_log
                ),
                [],
            )

    def test_git_materialized_artifacts_validate_in_fresh_clone(self) -> None:
        with acceptance_fixture() as (
            repository,
            commit,
            _source,
            _inventory,
            build_log,
            test_log,
            lint_log,
            verifier,
        ):
            self.assertEqual(
                _write_fixture(
                    verifier, commit, build_log, test_log, lint_log
                ),
                [],
            )
            _git(repository, "add", RECORDS_DIRECTORY.as_posix())
            _git(repository, "commit", "-qm", "R12 evidence fixture")
            with tempfile.TemporaryDirectory(
                prefix="mirmir-r12-fresh-clone-"
            ) as value:
                fresh = Path(value) / "repository"
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
                    BUILD_LOG_PATH,
                    TEST_LOG_PATH,
                    LINT_LOG_PATH,
                ):
                    self.assertEqual(
                        stat.S_IMODE((fresh / relative).stat().st_mode),
                        0o644,
                    )
                fresh_verifier = R12PhaseAcceptanceVerifier(fresh)
                self.assertEqual(fresh_verifier.check_generated(), [])
                self.assertEqual(fresh_verifier.check(), [])

    def test_schemas_are_closed_and_cli_argument_contract_is_bounded(
        self,
    ) -> None:
        for relative in (EXECUTION_SCHEMA_PATH, ACCEPTANCE_SCHEMA_PATH):
            schema = _read_json(REPOSITORY_ROOT / relative)
            self.assertEqual(
                schema["$schema"],
                "https://json-schema.org/draft/2020-12/schema",
            )
            pending = [schema]
            while pending:
                value = pending.pop()
                if isinstance(value, dict):
                    if value.get("type") == "object":
                        self.assertIs(
                            value.get("additionalProperties"),
                            False,
                            msg=f"open object schema in {relative}",
                        )
                    pending.extend(value.values())
                elif isinstance(value, list):
                    pending.extend(value)
        script = REPOSITORY_ROOT / "Scripts/r12_phase_acceptance.py"
        result = subprocess.run(
            [sys.executable, os.fspath(script), "--check"],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        invalid = subprocess.run(
            [
                sys.executable,
                os.fspath(script),
                "--write",
                "0" * 40,
            ],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn(
            "--write requires --build-log, --test-log, and --lint-log",
            invalid.stderr,
        )


if __name__ == "__main__":
    unittest.main()
