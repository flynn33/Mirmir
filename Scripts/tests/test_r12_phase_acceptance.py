from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any, Callable
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from r12_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ACCEPTANCE_SCHEMA_PATH,
    ARTIFACT_DIRECTORY,
    BUILD_COMMAND,
    BUILD_LOG_PATH,
    CapturedExecution,
    EXECUTION_RECEIPT_PATH,
    EXECUTION_SCHEMA_PATH,
    FORMAT_SOURCE_PATH,
    FORMAT_TEST_PATH,
    LINT_LOG_PATH,
    LINT_COMMAND,
    PREDECESSOR_ACCEPTANCE_PATH,
    PROJECT_PATH,
    RECORDS_DIRECTORY,
    ROADMAP_PATH,
    R12PhaseAcceptanceVerifier,
    SOURCE_BINDING_PATHS,
    TEST_LOG_PATH,
    TEST_COMMAND,
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


def _fixture_tool_identity(tool_name: str) -> dict[str, str]:
    return {
        "executable_path": f"/fixture-tools/{tool_name}",
        "executable_sha256": hashlib.sha256(
            f"fixture-{tool_name}".encode("utf-8")
        ).hexdigest(),
        "name": tool_name,
        "version": f"{tool_name} fixture version",
    }


def _rewrite_execution_identity(
    payload: bytes,
    mutate: Callable[[dict[str, Any]], None],
) -> bytes:
    header, separator, output = payload.partition(b"\n")
    if not separator:
        raise ValueError("fixture execution identity line is absent")
    prefix = b"R12_EXECUTION_IDENTITY="
    if not header.startswith(prefix):
        raise ValueError("fixture execution identity prefix differs")
    identity = json.loads(header[len(prefix) :].decode("utf-8"))
    if not isinstance(identity, dict):
        raise TypeError("fixture execution identity is not an object")
    mutate(identity)
    rewritten = R12PhaseAcceptanceVerifier._execution_identity_header(
        identity
    ).encode("utf-8")
    return rewritten + separator + output


def _execution_identity_line(
    source: dict[str, str],
    *,
    command_id: str,
    command: str,
    tool_name: str,
) -> str:
    tool = _fixture_tool_identity(tool_name)
    if command_id == "build_for_testing":
        argv = R12PhaseAcceptanceVerifier._build_command_arguments(
            tool["executable_path"],
            source,
            "/private/tmp/r12/DerivedData",
        )
    elif command_id == "targeted_tests":
        argv = R12PhaseAcceptanceVerifier._test_command_arguments(
            tool["executable_path"],
            source,
            (
                "/private/tmp/r12/DerivedData/Build/Products/"
                "Mirmir_macosx.xctestrun"
            ),
        )
    elif command_id == "swiftlint":
        argv = R12PhaseAcceptanceVerifier._lint_command_arguments(
            tool["executable_path"]
        )
    else:
        raise ValueError(f"unknown fixture command: {command_id}")
    identity = {
        "argv": argv,
        "checkpoint": {
            "clean_after": True,
            "clean_before": True,
            "commit_after": source["commit"],
            "commit_before": source["commit"],
            "kind": "detached_clean_exact_git_checkpoint",
            "tree_after": source["tree"],
            "tree_before": source["tree"],
        },
        "command": command,
        "command_id": command_id,
        "exit_code": 0,
        "source": source,
        "tool": tool,
    }
    return R12PhaseAcceptanceVerifier._execution_identity_header(identity)


def _build_log(source: dict[str, str]) -> bytes:
    return (
        _execution_identity_line(
            source,
            command_id="build_for_testing",
            command=BUILD_COMMAND,
            tool_name="xcodebuild",
        )
        + "\n"
        "Command line invocation:\n"
        "    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "
        "build-for-testing -project Mirmir.xcodeproj -scheme Mirmir "
        "-configuration Debug -destination platform=macOS,arch=arm64 "
        "-derivedDataPath /private/tmp/r12/DerivedData "
        "-disableAutomaticPackageResolution "
        f"R12_ACCEPTANCE_SOURCE_COMMIT={source['commit']} "
        f"R12_ACCEPTANCE_SOURCE_TREE={source['tree']} "
        "EXCLUDED_SOURCE_FILE_NAMES=*.metal\n"
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
        _execution_identity_line(
            source,
            command_id="targeted_tests",
            command=TEST_COMMAND,
            tool_name="xcodebuild",
        ),
        "Command line invocation:",
        (
            "    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "
            "test-without-building -xctestrun "
            "/private/tmp/r12/DerivedData/Build/Products/"
            "Mirmir_macosx.xctestrun "
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


def _lint_log(
    source: dict[str, str],
    file_count: int = 3,
    *,
    file_records: tuple[tuple[int, int], ...] | None = None,
) -> bytes:
    lines = [
        _execution_identity_line(
            source,
            command_id="swiftlint",
            command=LINT_COMMAND,
            tool_name="swiftlint",
        ),
        "Linting Swift files in current working directory",
    ]
    records = (
        file_records
        if file_records is not None
        else tuple(
            (index, file_count) for index in range(1, file_count + 1)
        )
    )
    lines.extend(
        f"Linting 'Fixture{position}.swift' ({ordinal}/{total})"
        for position, (ordinal, total) in enumerate(records, start=1)
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
        lint_log.write_bytes(_lint_log(source))
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
    source = verifier.resolve_source(commit)
    expected_tools = {
        name: _fixture_tool_identity(name)
        for name in ("xcodebuild", "swiftlint")
    }
    captured = CapturedExecution(
        build_log_payload=build_log.read_bytes(),
        test_log_payload=test_log.read_bytes(),
        lint_log_payload=lint_log.read_bytes(),
    )
    with (
        mock.patch.object(
            verifier,
            "_tool_identity",
            side_effect=lambda name: expected_tools[name],
        ) as tool_lookup,
        mock.patch.object(
            verifier,
            "_run_checkpoint_commands",
            return_value=captured,
        ) as runner,
    ):
        errors = verifier.write(commit)
    expected_calls = [mock.call("xcodebuild"), mock.call("swiftlint")]
    if tool_lookup.call_args_list != expected_calls:
        raise AssertionError(tool_lookup.call_args_list)
    runner.assert_called_once_with(source, expected_tools)
    return errors


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
            self.assertTrue(all(count > 0 for count in source_counts))
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
            lint, lint_errors = verifier._lint_log(
                lint_log.read_bytes(), source
            )
            self.assertEqual(lint_errors, [])
            self.assertIsNotNone(lint)
            shuffled_lint = _lint_log(
                source,
                file_records=((3, 3), (1, 3), (2, 3)),
            )
            shuffled, shuffled_errors = verifier._lint_log(
                shuffled_lint,
                source,
            )
            self.assertEqual(shuffled_errors, [])
            self.assertIsNotNone(shuffled)
            self.assertEqual(shuffled.linted_file_count, 3)

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
                    b"Test Suite 'Selected tests' started.\n",
                    (
                        b"Test Suite 'Selected tests' started.\n"
                        b"Executed 1 test, with 1 failure (1 unexpected) "
                        b"in 0.001 seconds\n"
                    ),
                    1,
                ),
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
            )
            for payload in invalid_lints:
                _parsed, errors = verifier._lint_log(payload, source)
                self.assertTrue(errors)
            invalid_file_inventories = {
                "duplicate": ((1, 3), (1, 3), (3, 3)),
                "missing": ((1, 3), (3, 3)),
                "out_of_range": ((1, 3), (2, 3), (4, 3)),
                "mixed_totals": ((1, 3), (2, 4), (3, 3)),
            }
            for name, records in invalid_file_inventories.items():
                with self.subTest(swiftlint_inventory=name):
                    parsed, errors = verifier._lint_log(
                        _lint_log(source, file_records=records),
                        source,
                    )
                    self.assertIsNone(parsed)
                    self.assertEqual(
                        errors,
                        ["R12 SwiftLint per-file inventory differs"],
                    )

    def test_mandatory_test_contract_inventory_allows_only_dynamic_extras(
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
            source_path = repository / FORMAT_TEST_PATH
            original = source_path.read_text(encoding="utf-8")
            declaration = (
                "final class R12MediaFormatContractV2Tests: XCTestCase {\n"
            )
            self.assertIn(declaration, original)
            with_extra = original.replace(
                declaration,
                declaration
                + "    func testFutureDynamicFormatContract() {}\n",
                1,
            )
            source_path.write_text(with_extra, encoding="utf-8")
            _git(repository, "add", FORMAT_TEST_PATH.as_posix())
            _git(repository, "commit", "-qm", "Add dynamic R12 fixture test")
            extra_source = verifier.resolve_source(
                _git(repository, "rev-parse", "HEAD")
            )
            inventory, errors = verifier._checkpoint_test_inventory(
                extra_source
            )
            self.assertEqual(errors, [])
            self.assertIsNotNone(inventory)
            self.assertIn(
                (
                    "MirmirTests.R12MediaFormatContractV2Tests."
                    "testFutureDynamicFormatContract"
                ),
                inventory.identifiers,
            )

            renamed = with_extra.replace(
                "testMetadataAndStructuralQualityContractsAreExplicit",
                "testRenamedMetadataContract",
                1,
            )
            source_path.write_text(renamed, encoding="utf-8")
            _git(repository, "add", FORMAT_TEST_PATH.as_posix())
            _git(repository, "commit", "-qm", "Rename mandatory R12 test")
            renamed_source = verifier.resolve_source(
                _git(repository, "rev-parse", "HEAD")
            )
            inventory, errors = verifier._checkpoint_test_inventory(
                renamed_source
            )
            self.assertIsNone(inventory)
            self.assertTrue(
                any(
                    "R12 mandatory format test contract inventory differs"
                    in error
                    and (
                        "testMetadataAndStructuralQualityContractsAreExplicit"
                        in error
                    )
                    for error in errors
                )
            )

            source_path.write_text(
                "import XCTest\n"
                "final class R12MediaFormatContractV2Tests: XCTestCase {\n"
                "    func testNoOpFormatContract() {}\n"
                "}\n",
                encoding="utf-8",
            )
            _git(repository, "add", FORMAT_TEST_PATH.as_posix())
            _git(repository, "commit", "-qm", "Minimize R12 test inventory")
            minimal_source = verifier.resolve_source(
                _git(repository, "rev-parse", "HEAD")
            )
            inventory, errors = verifier._checkpoint_test_inventory(
                minimal_source
            )
            self.assertIsNone(inventory)
            self.assertTrue(
                any(
                    "R12 mandatory format test contract inventory differs"
                    in error
                    for error in errors
                )
            )
            self.assertTrue(
                any(
                    "R12 mandatory backend test contract inventory differs"
                    in error
                    for error in errors
                )
            )

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
                set(execution["execution_identities"]),
                {"build_for_testing", "targeted_tests", "swiftlint"},
            )
            for command_id, identity in execution[
                "execution_identities"
            ].items():
                self.assertEqual(identity["source"], source)
                self.assertEqual(identity["command_id"], command_id)
                self.assertEqual(identity["exit_code"], 0)
                self.assertEqual(
                    identity["checkpoint"],
                    {
                        "clean_after": True,
                        "clean_before": True,
                        "commit_after": source["commit"],
                        "commit_before": source["commit"],
                        "kind": "detached_clean_exact_git_checkpoint",
                        "tree_after": source["tree"],
                        "tree_before": source["tree"],
                    },
                )
                self.assertIsInstance(identity["argv"], list)
                self.assertEqual(
                    identity["argv"][0],
                    identity["tool"]["executable_path"],
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
            self.assertTrue(
                any(
                    "contract-only" in limitation
                    and "production decode" in limitation
                    for limitation in acceptance["limitations"]
                )
            )
            self.assertTrue(
                any(
                    "deterministic contract simulations" in limitation
                    and "A11 backend" in limitation
                    for limitation in execution["limitations"]
                )
            )

    def test_writer_rejects_unowned_synthetic_tool_identities(self) -> None:
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
            self.assertFalse(Path("/fixture-tools/xcodebuild").exists())
            self.assertFalse(Path("/fixture-tools/swiftlint").exists())
            captured = CapturedExecution(
                build_log_payload=build_log.read_bytes(),
                test_log_payload=test_log.read_bytes(),
                lint_log_payload=lint_log.read_bytes(),
            )
            with mock.patch.object(
                verifier,
                "_run_checkpoint_commands",
                return_value=captured,
            ) as runner:
                errors = verifier.write(commit)
            runner.assert_called_once()
            self.assertTrue(
                any(
                    "owned tool identity differs" in error
                    for error in errors
                ),
                errors,
            )
            self.assertFalse((repository / RECORDS_DIRECTORY).exists())

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
            self.assertEqual(
                verifier.check(),
                [
                    "INCOMPLETE: R12 generated acceptance evidence is absent "
                    "while canonical phase status is 'in_progress'"
                ],
            )
            _set_r12_status(repository / ROADMAP_PATH, "evidence_ready")
            self.assertEqual(
                verifier.check(),
                [
                    "INCOMPLETE: R12 generated acceptance evidence is absent "
                    "while canonical phase status is 'evidence_ready'"
                ],
            )
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
            with self.assertRaises(ValueError):
                verifier._read_input_file(
                    symlink_log,
                    context="R12 test fixture symlink",
                    maximum=_MAX_LINT_LOG_BYTES,
                )
            hardlink_log = build_log.parent / "build-hardlink.log"
            os.link(build_log, hardlink_log)
            with self.assertRaises(ValueError):
                verifier._read_input_file(
                    hardlink_log,
                    context="R12 test fixture hardlink",
                    maximum=_MAX_LINT_LOG_BYTES,
                )
            hardlink_log.unlink()
            oversized = build_log.parent / "oversized-lint.log"
            with oversized.open("wb") as stream:
                stream.truncate(_MAX_LINT_LOG_BYTES + 1)
            with self.assertRaises(ValueError):
                verifier._read_input_file(
                    oversized,
                    context="R12 test fixture oversized input",
                    maximum=_MAX_LINT_LOG_BYTES,
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

    def test_owned_command_rejects_clean_different_head_before_and_after(
        self,
    ) -> None:
        with acceptance_fixture() as (
            repository,
            _commit,
            source,
            _inventory,
            _build_log,
            _test_log,
            _lint_log,
            verifier,
        ):
            marker = repository / "different-head.txt"
            marker.write_text("different clean checkpoint\n", encoding="utf-8")
            _git(repository, "add", marker.name)
            _git(repository, "commit", "-qm", "Different clean checkpoint")
            different_commit = _git(repository, "rev-parse", "HEAD")
            self.assertNotEqual(different_commit, source["commit"])
            self.assertEqual(
                _git(repository, "status", "--porcelain=v1"),
                "",
            )

            _git(repository, "checkout", "-q", "--detach", source["commit"])

            def change_head_after_start(*_args, **_kwargs) -> bytes:
                _git(
                    repository,
                    "checkout",
                    "-q",
                    "--detach",
                    different_commit,
                )
                return b"fixture output\n"

            with mock.patch.object(
                R12PhaseAcceptanceVerifier,
                "_run_bounded_command",
                side_effect=change_head_after_start,
            ):
                with self.assertRaisesRegex(
                    ValueError,
                    "exact checkpoint identity differs after execution",
                ):
                    verifier._captured_command_log(
                        arguments=[
                            _fixture_tool_identity("swiftlint")[
                                "executable_path"
                            ],
                            "lint",
                            "--strict",
                            "--no-cache",
                        ],
                        cwd=repository,
                        source=source,
                        command_id="swiftlint",
                        command=LINT_COMMAND,
                        tool=_fixture_tool_identity("swiftlint"),
                        context="R12 clean-different-HEAD fixture",
                        maximum=_MAX_LINT_LOG_BYTES,
                    )

            with mock.patch.object(
                R12PhaseAcceptanceVerifier,
                "_run_bounded_command",
                return_value=b"must not execute\n",
            ) as command:
                with self.assertRaisesRegex(
                    ValueError,
                    "exact checkpoint identity differs before execution",
                ):
                    verifier._captured_command_log(
                        arguments=[
                            _fixture_tool_identity("swiftlint")[
                                "executable_path"
                            ],
                            "lint",
                            "--strict",
                            "--no-cache",
                        ],
                        cwd=repository,
                        source=source,
                        command_id="swiftlint",
                        command=LINT_COMMAND,
                        tool=_fixture_tool_identity("swiftlint"),
                        context="R12 clean-different-HEAD fixture",
                        maximum=_MAX_LINT_LOG_BYTES,
                    )
            command.assert_not_called()

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

    def test_created_directory_is_removed_when_parent_fsync_fails(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-r12-directory-sync-"
        ) as value:
            parent = Path(value)
            parent_descriptor = os.open(
                parent,
                os.O_RDONLY | os.O_DIRECTORY,
            )
            original_fsync = os.fsync
            calls = 0

            def fail_first_parent_sync(descriptor: int) -> None:
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise OSError("injected parent fsync failure")
                original_fsync(descriptor)

            try:
                with mock.patch(
                    "r12_phase_acceptance.os.fsync",
                    side_effect=fail_first_parent_sync,
                ):
                    with self.assertRaisesRegex(
                        ValueError,
                        "directory cannot be synchronized",
                    ):
                        R12PhaseAcceptanceVerifier._ensure_directory_at(
                            parent_descriptor,
                            "created",
                            context="R12 injected directory",
                        )
                self.assertGreaterEqual(calls, 2)
                self.assertFalse((parent / "created").exists())

                descriptor, created = (
                    R12PhaseAcceptanceVerifier._ensure_directory_at(
                        parent_descriptor,
                        "created",
                        context="R12 retry directory",
                    )
                )
                os.close(descriptor)
                self.assertTrue(created)
                self.assertTrue((parent / "created").is_dir())
                (parent / "created").rmdir()
            finally:
                os.close(parent_descriptor)

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

    def test_canonical_r11_bundle_and_roadmap_contract_are_required(
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
            r11_log = (
                repository
                / "docs/roadmaps/evidence/r11/records/artifacts/"
                "functional-phase-acceptance/unittest.log"
            )
            original_log = r11_log.read_bytes()
            original_mode = stat.S_IMODE(r11_log.stat().st_mode)
            r11_log.chmod(0o600)
            r11_log.write_bytes(original_log + b"tamper\n")
            r11_log.chmod(original_mode)
            self.assertTrue(
                any(
                    "canonical R11 generated-evidence validation failed"
                    in error
                    for error in verifier.check_generated()
                )
            )
            _replace_bytes(r11_log, original_log, original_mode)
            self.assertEqual(verifier.check_generated(), [])

            roadmap_path = repository / ROADMAP_PATH
            original_roadmap = roadmap_path.read_bytes()
            roadmap = _read_json(roadmap_path)
            roadmap["roadmap_version"] = "forged"
            _write_json(roadmap_path, roadmap)
            self.assertIn(
                "R12 canonical roadmap version must be 1.0.1",
                verifier.check_generated(),
            )
            _replace_bytes(roadmap_path, original_roadmap, 0o644)

            for phase_id in ("R11", "R12", "R13"):
                for field, forged in (
                    ("id", f"{phase_id}-forged"),
                    ("name", "forged phase name"),
                    ("exit", "forged phase exit"),
                    ("depends_on", ["forged"]),
                ):
                    with self.subTest(
                        roadmap_phase=phase_id,
                        roadmap_field=field,
                    ):
                        roadmap = _read_json(roadmap_path)
                        phases = roadmap["phases"]
                        assert isinstance(phases, list)
                        phase = next(
                            item
                            for item in phases
                            if isinstance(item, dict)
                            and item.get("id") == phase_id
                        )
                        phase[field] = forged
                        _write_json(roadmap_path, roadmap)
                        expected = (
                            f"R12 canonical roadmap {phase_id} entry differs"
                            if field == "id"
                            else (
                                "R12 canonical roadmap "
                                f"{phase_id} {field} contract differs"
                            )
                        )
                        self.assertIn(
                            expected,
                            verifier.check_generated(),
                        )
                        _replace_bytes(
                            roadmap_path,
                            original_roadmap,
                            0o644,
                        )

            _set_r12_status(roadmap_path, "planned")
            self.assertIn(
                "R12 canonical roadmap R12 status transition differs",
                verifier.check_generated(),
            )
            _replace_bytes(roadmap_path, original_roadmap, 0o644)

            roadmap = _read_json(roadmap_path)
            phases = roadmap["phases"]
            assert isinstance(phases, list)
            r13 = next(
                item
                for item in phases
                if isinstance(item, dict) and item.get("id") == "R13"
            )
            r13["status"] = "forged"
            _write_json(roadmap_path, roadmap)
            self.assertIn(
                "R12 canonical roadmap R13 status transition differs",
                verifier.check_generated(),
            )
            _replace_bytes(roadmap_path, original_roadmap, 0o644)

            roadmap = _read_json(roadmap_path)
            phases = roadmap["phases"]
            assert isinstance(phases, list)
            r13 = next(
                item
                for item in phases
                if isinstance(item, dict) and item.get("id") == "R13"
            )
            r13["status"] = "in_progress"
            _write_json(roadmap_path, roadmap)
            self.assertIn(
                "R12 canonical roadmap successor advanced before R12 passed",
                verifier.check_generated(),
            )
            _replace_bytes(roadmap_path, original_roadmap, 0o644)

            _set_r12_status(roadmap_path, "passed")
            self.assertEqual(verifier.check_generated(), [])
            roadmap = _read_json(roadmap_path)
            phases = roadmap["phases"]
            assert isinstance(phases, list)
            r13 = next(
                item
                for item in phases
                if isinstance(item, dict) and item.get("id") == "R13"
            )
            r13["status"] = "in_progress"
            _write_json(roadmap_path, roadmap)
            self.assertEqual(verifier.check_generated(), [])

            roadmap = _read_json(roadmap_path)
            phases = roadmap["phases"]
            assert isinstance(phases, list)
            r11 = next(
                item
                for item in phases
                if isinstance(item, dict) and item.get("id") == "R11"
            )
            r11["status"] = "planned"
            _write_json(roadmap_path, roadmap)
            self.assertIn(
                "R12 canonical roadmap predecessor R11 is not passed",
                verifier.check_generated(),
            )

    def test_execution_identity_header_is_exact_and_fail_closed(self) -> None:
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
            valid_build = build_log.read_bytes()
            valid_test = test_log.read_bytes()
            valid_lint = lint_log.read_bytes()
            self.assertNotIn("CODE_SIGNING_ALLOWED", BUILD_COMMAND)
            self.assertEqual(
                verifier._build_log_errors(valid_build, source), []
            )
            self.assertEqual(
                verifier._test_log_errors(
                    valid_test, source, inventory, TEST_SUITES
                ),
                [],
            )
            _lint, lint_errors = verifier._lint_log(valid_lint, source)
            self.assertEqual(lint_errors, [])

            def append_build_argument(value: str) -> bytes:
                def mutate(identity: dict[str, Any]) -> None:
                    argv = identity["argv"]
                    assert isinstance(argv, list)
                    argv.append(value)

                return _rewrite_execution_identity(valid_build, mutate)

            for forged_argv in (
                append_build_argument("CODE_SIGNING_ALLOWED=NO"),
                append_build_argument(
                    "EXCLUDED_SOURCE_FILE_NAMES=not-metal"
                ),
                append_build_argument("-quiet"),
            ):
                self.assertIn(
                    "R12 build-for-testing log structured command argv differs",
                    verifier._build_log_errors(forged_argv, source),
                )

            def append_argument(
                payload: bytes,
                value: str,
            ) -> bytes:
                def mutate(identity: dict[str, Any]) -> None:
                    argv = identity["argv"]
                    assert isinstance(argv, list)
                    argv.append(value)

                return _rewrite_execution_identity(payload, mutate)

            self.assertIn(
                "R12 targeted XCTest log structured command argv differs",
                verifier._test_log_errors(
                    append_argument(valid_test, "-parallel-testing-enabled"),
                    source,
                    inventory,
                    TEST_SUITES,
                ),
            )
            _parsed, forged_lint_errors = verifier._lint_log(
                append_argument(valid_lint, "--fix"),
                source,
            )
            self.assertIn(
                "R12 SwiftLint log structured command argv differs",
                forged_lint_errors,
            )
            for forged in (
                valid_build.replace(
                    b'"clean_after":true',
                    b'"clean_after":false',
                    1,
                ),
                valid_build.replace(
                    b'"command_id":"build_for_testing"',
                    b'"command_id":"targeted_tests"',
                    1,
                ),
                valid_build.replace(
                    b'"exit_code":0',
                    b'"exit_code":1',
                    1,
                ),
                valid_build.replace(
                    b"R12_EXECUTION_IDENTITY={",
                    b"R12_EXECUTION_IDENTITY={ ",
                    1,
                ),
            ):
                self.assertTrue(verifier._build_log_errors(forged, source))

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
            "implementation commit must be one exact nonzero",
            invalid.stderr,
        )
        caller_log = subprocess.run(
            [
                sys.executable,
                os.fspath(script),
                "--write",
                "0" * 40,
                "--build-log",
                "/private/tmp/caller.log",
            ],
            cwd=REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertNotEqual(caller_log.returncode, 0)
        self.assertIn("unrecognized arguments: --build-log", caller_log.stderr)


if __name__ == "__main__":
    unittest.main()
