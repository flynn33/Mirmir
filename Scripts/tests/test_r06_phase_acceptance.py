from __future__ import annotations

import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r06_contracts import CONFORMANCE_PATH  # noqa: E402
from r06_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ACCEPTANCE_SCHEMA_PATH,
    ARTIFACT_PATHS,
    EVIDENCE_PATHS,
    EXPECTED_SELECTED_TEST_COUNT,
    IMPLEMENTATION_PATHS,
    PHASE_EVIDENCE_JSON_PATH,
    REQUIRED_TEST_SUITES,
    SOURCE_BUILD_PATHS,
    SOURCE_COMMIT,
    SOURCE_TREE,
    XCRESULT_SUMMARY_PATH,
    XCODEBUILD_COMMAND,
    XCODEBUILD_LOG_PATH,
    R06PhaseAcceptanceVerifier,
    _expected_log,
    _expected_summary,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected object: {relative}")
    return value


def expected_summary_suite_tests() -> tuple[tuple[str, tuple[str, ...]], ...]:
    summary = _expected_summary()
    return tuple(
        (
            suite["id"],
            tuple(test["id"] for test in suite["tests"]),
        )
        for suite in summary["test_suites"]
    )


def raw_xcresult_payloads() -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
]:
    summary: dict[str, object] = {
        "result": "Passed",
        "title": "Test - Mirmir",
        "totalTestCount": EXPECTED_SELECTED_TEST_COUNT,
        "passedTests": EXPECTED_SELECTED_TEST_COUNT,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
        "testFailures": [],
        "startTime": 1_784_809_794.539,
        "finishTime": 1_784_809_812.044,
        "devicesAndConfigurations": [
            {
                "passedTests": EXPECTED_SELECTED_TEST_COUNT,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "device": {
                    "platform": "macOS",
                    "architecture": "arm64",
                },
            }
        ],
    }
    suites = []
    for suite_id, test_ids in expected_summary_suite_tests():
        suites.append(
            {
                "nodeType": "Test Suite",
                "name": suite_id,
                "children": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": f"{suite_id}/{test_id}",
                        "name": test_id,
                        "result": "Passed",
                    }
                    for test_id in test_ids
                ],
            }
        )
    build_results: dict[str, object] = {
        "actionTitle": "Testing project Mirmir with scheme Mirmir",
        "status": "succeeded",
        "errorCount": 0,
        "errors": [],
        "startTime": summary["startTime"],
        "endTime": summary["finishTime"],
        "destination": {
            "platform": "macOS",
            "architecture": "arm64",
        },
    }
    return summary, {"testNodes": [{"children": suites}]}, build_results


class R06PhaseAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R06PhaseAcceptanceVerifier(REPOSITORY_ROOT)
        self.schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.record = read_json(ACCEPTANCE_PATH)
        self.summary = read_json(XCRESULT_SUMMARY_PATH)
        self.conformance = read_json(CONFORMANCE_PATH)
        self.phase_evidence = read_json(PHASE_EVIDENCE_JSON_PATH)

    def test_repository_acceptance_is_valid_and_exactly_derived(self) -> None:
        self.assertEqual(self.verifier.check(), [])
        self.assertEqual(self.record, self.verifier.expected_record())
        self.assertEqual(
            validate_json_schema_instance(self.schema, self.record),
            [],
        )

    def test_schema_and_record_drift_fail_closed(self) -> None:
        fabricated = copy.deepcopy(self.record)
        fabricated["unreviewed_authority"] = True
        self.assertTrue(validate_json_schema_instance(self.schema, fabricated))

        fabricated = copy.deepcopy(self.record)
        fabricated["result"]["status"] = "blocked"
        self.assertTrue(validate_json_schema_instance(self.schema, fabricated))
        self.assertTrue(self.verifier._boundary_errors(fabricated))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schema_path = root / ACCEPTANCE_SCHEMA_PATH
            schema_path.parent.mkdir(parents=True)
            shutil.copy2(REPOSITORY_ROOT / ACCEPTANCE_SCHEMA_PATH, schema_path)
            verifier = R06PhaseAcceptanceVerifier(root)
            self.assertEqual(verifier._schema_errors(), [])
            schema_path.write_text(
                schema_path.read_text(encoding="utf-8") + " ",
                encoding="utf-8",
            )
            self.assertTrue(verifier._schema_errors())

    def test_binding_hash_and_size_drift_fail_closed(self) -> None:
        for binding_key in (
            "evidence_bindings",
            "implementation_bindings",
            "artifact_bindings",
        ):
            with self.subTest(binding_key=binding_key):
                fabricated = copy.deepcopy(self.record)
                fabricated[binding_key][0]["sha256"] = "1" * 64
                fabricated[binding_key][0]["size_bytes"] += 1
                self.assertTrue(self.verifier._record_binding_errors(fabricated))
                self.assertNotEqual(fabricated, self.verifier.expected_record())

    def test_source_checkpoint_tree_and_ancestor_are_exact(self) -> None:
        self.assertEqual(self.verifier._source_errors(), [])
        self.assertEqual(self.record["source"]["commit"], SOURCE_COMMIT)
        self.assertEqual(self.record["source"]["tree"], SOURCE_TREE)
        self.assertEqual(
            tuple(relative.as_posix() for relative in SOURCE_BUILD_PATHS),
            (
                "Mirmir",
                "MirmirTests",
                "Mirmir.xcodeproj",
                "project.yml",
                (
                    "validation/calibration_v2/native_adapter/"
                    "ASHCalibrationCLISupport.swift"
                ),
                (
                    "validation/calibration_v2/native_adapter/"
                    "ASHCalibrationCLIProtocol.swift"
                ),
            ),
        )
        with mock.patch(
            "r06_phase_acceptance.SOURCE_TREE",
            "0" * 40,
        ):
            self.assertIn(
                "R06 acceptance source tree differs",
                self.verifier._source_errors(),
            )

        original_git = self.verifier.git

        def git_without_ancestor(
            *arguments: str,
        ) -> subprocess.CompletedProcess[str]:
            if arguments == (
                "merge-base",
                "--is-ancestor",
                SOURCE_COMMIT,
                "HEAD",
            ):
                return subprocess.CompletedProcess(
                    args=["git", *arguments],
                    returncode=1,
                    stdout="",
                    stderr="not ancestor",
                )
            return original_git(*arguments)

        with mock.patch.object(
            self.verifier,
            "git",
            side_effect=git_without_ancestor,
        ):
            self.assertIn(
                "R06 acceptance source commit is not an ancestor of HEAD",
                self.verifier._source_errors(),
            )

    def test_checkpoint_bindings_use_exact_positional_git_show_bytes(self) -> None:
        identifier, relative = IMPLEMENTATION_PATHS[4]
        with mock.patch.object(
            self.verifier,
            "git_bytes",
            wraps=self.verifier.git_bytes,
        ) as git_bytes:
            binding = self.verifier._checkpoint_file_binding(
                identifier,
                relative,
            )
        git_bytes.assert_called_once_with(
            "show",
            f"{SOURCE_COMMIT}:{relative.as_posix()}",
        )
        self.assertEqual(binding["id"], identifier)
        self.assertEqual(binding["path"], relative.as_posix())

        current_payload = (REPOSITORY_ROOT / relative).read_bytes() + b"\nsubstitute"
        original_git_bytes = self.verifier.git_bytes

        def substituted_git_show(
            *arguments: str,
        ) -> subprocess.CompletedProcess[bytes]:
            if arguments == (
                "show",
                f"{SOURCE_COMMIT}:{relative.as_posix()}",
            ):
                return subprocess.CompletedProcess(
                    args=["git", *arguments],
                    returncode=0,
                    stdout=current_payload,
                    stderr=b"",
                )
            return original_git_bytes(*arguments)

        with mock.patch.object(
            self.verifier,
            "git_bytes",
            side_effect=substituted_git_show,
        ):
            self.assertTrue(self.verifier._record_binding_errors(self.record))

    def test_later_source_evolution_does_not_replace_checkpoint_bytes(self) -> None:
        with mock.patch.object(
            self.verifier,
            "git",
            wraps=self.verifier.git,
        ) as git:
            self.assertEqual(self.verifier._source_errors(), [])
        self.assertFalse(
            any(
                call.args[:2] == ("diff", "--quiet")
                for call in git.call_args_list
            )
        )
        self.assertEqual(
            [binding["id"] for binding in self.record["implementation_bindings"]],
            [identifier for identifier, _ in IMPLEMENTATION_PATHS],
        )

    def test_checkpoint_symlink_or_missing_blob_is_rejected(self) -> None:
        identifier, relative = IMPLEMENTATION_PATHS[0]
        symlink_entry = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                "120000 blob 0000000000000000000000000000000000000000\t"
                f"{relative.as_posix()}\n"
            ),
            stderr="",
        )
        with mock.patch.object(
            self.verifier,
            "git",
            return_value=symlink_entry,
        ):
            with self.assertRaises(OSError):
                self.verifier._checkpoint_file_binding(identifier, relative)

    def test_frozen_historical_block_is_preserved_and_non_authorizing(self) -> None:
        self.assertEqual(self.verifier._frozen_evidence_errors(), [])
        self.assertEqual(
            self.conformance["result"]["reason"],
            "no_product_qualified_primary_backend",
        )
        self.assertEqual(self.conformance["result"]["status"], "blocked")
        self.assertEqual(self.phase_evidence["result"]["status"], "blocked")
        self.assertEqual(
            self.record["functional_gate"]["historical_blocked_evidence_role"],
            "preserved_non_authorizing_not_acceptance_basis",
        )
        self.assertEqual(
            self.record["authorizations"]["historical_blocked_evidence"],
            "preserved_non_authorizing",
        )

    def test_frozen_historical_mutations_fail_closed(self) -> None:
        conformance = copy.deepcopy(self.conformance)
        conformance["result"]["reason"] = "hardware_unavailable"
        phase_evidence = copy.deepcopy(self.phase_evidence)
        phase_evidence["result"]["dispositions"][0]["reason"] = "rerun"

        def mutated_read(
            relative: Path,
            _context: str,
            _errors: list[str],
        ) -> dict[str, object]:
            if relative == CONFORMANCE_PATH:
                return conformance
            if relative == PHASE_EVIDENCE_JSON_PATH:
                return phase_evidence
            return read_json(relative)

        with mock.patch.object(
            self.verifier,
            "_read_json",
            side_effect=mutated_read,
        ), mock.patch(
            "r06_phase_acceptance.R06ContractVerifier.check_preregistration",
            return_value=[],
        ), mock.patch(
            "r06_phase_acceptance.R06ContractVerifier.check_fixtures",
            return_value=[],
        ):
            errors = self.verifier._frozen_evidence_errors()
        self.assertTrue(errors)

    def test_product_and_claim_boundaries_reject_expansion(self) -> None:
        self.assertEqual(
            self.record["functional_gate"]["product_scope_orchestration"],
            "unsupported_rejected_unimplemented",
        )
        self.assertEqual(
            self.record["functional_gate"]["product_scope_rerun"],
            "not_claimed",
        )
        forbidden = (
            "product_qualification",
            "product_routing",
            "production_upscaling",
            "production_default",
            "auto_mode",
            "holdout",
            "native_framework_execution",
            "hardware_observation",
            "simulator_observation",
            "operator_observation",
            "quality_claims",
            "performance_claims",
            "product_publication",
            "release",
        )
        for key in forbidden:
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.record)
                fabricated["authorizations"][key] = "authorized"
                self.assertTrue(
                    validate_json_schema_instance(self.schema, fabricated)
                )
                self.assertTrue(self.verifier._boundary_errors(fabricated))

    def test_current_files_and_json_readers_reject_symlinks(self) -> None:
        for binding_key in ("evidence_bindings", "artifact_bindings"):
            for binding in self.record[binding_key]:
                with self.subTest(binding=binding["id"]):
                    file_path = REPOSITORY_ROOT / binding["path"]
                    self.assertTrue(file_path.is_file())
                    self.assertFalse(file_path.is_symlink())

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verifier = R06PhaseAcceptanceVerifier(root)
            target = root / "target.json"
            target.write_text("{}\n", encoding="utf-8")
            linked = root / ACCEPTANCE_PATH
            linked.parent.mkdir(parents=True)
            linked.symlink_to(target)
            errors: list[str] = []
            self.assertIsNone(
                verifier._read_json(
                    ACCEPTANCE_PATH,
                    "linked acceptance",
                    errors,
                )
            )
            self.assertTrue(errors)
            with self.assertRaises(OSError):
                verifier._file_binding("linked", ACCEPTANCE_PATH)

    def test_write_rejects_symlink_target_and_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verifier = R06PhaseAcceptanceVerifier(root)
            root = verifier.root
            output = root / ACCEPTANCE_PATH
            output.parent.mkdir(parents=True)
            target = root / "target.json"
            target.write_text("preserve\n", encoding="utf-8")
            output.symlink_to(target)
            self.assertTrue(verifier._write_output(output, b"replace\n"))
            self.assertEqual(target.read_text(encoding="utf-8"), "preserve\n")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verifier = R06PhaseAcceptanceVerifier(root)
            root = verifier.root
            real_docs = root / "real-docs"
            real_docs.mkdir()
            (root / "docs").symlink_to(real_docs, target_is_directory=True)
            output = root / ACCEPTANCE_PATH
            self.assertTrue(verifier._write_output(output, b"replace\n"))
            self.assertFalse(
                (real_docs / Path(*ACCEPTANCE_PATH.parts[1:])).exists()
            )

    def test_safe_write_is_atomic_and_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verifier = R06PhaseAcceptanceVerifier(root)
            output = verifier.root / "nested" / "acceptance.json"
            first = b'{"value":1}\n'
            second = b'{"value":2}\n'
            self.assertEqual(verifier._write_output(output, first), [])
            self.assertEqual(output.read_bytes(), first)
            self.assertEqual(verifier._write_output(output, second), [])
            self.assertEqual(output.read_bytes(), second)
            self.assertEqual(
                list(output.parent.glob(f".{output.name}.*.tmp")),
                [],
            )

    def test_summary_command_suite_and_count_are_exact(self) -> None:
        self.assertEqual(self.summary, _expected_summary())
        self.assertEqual(self.verifier._summary_errors(self.summary), [])
        self.assertEqual(
            [suite["id"] for suite in self.summary["test_suites"]],
            list(REQUIRED_TEST_SUITES),
        )
        self.assertEqual(
            [suite["expected_test_count"] for suite in self.summary["test_suites"]],
            [7, 11, 11, 3, 1, 6, 3],
        )
        self.assertEqual(self.summary["toolchain"]["command"], XCODEBUILD_COMMAND)
        self.assertEqual(self.summary["passed_test_count"], 42)
        self.assertEqual(self.summary["failed_test_count"], 0)
        self.assertEqual(self.summary["skipped_test_count"], 0)
        self.assertEqual(
            (REPOSITORY_ROOT / XCODEBUILD_LOG_PATH).read_text(encoding="utf-8"),
            _expected_log(),
        )

    def test_summary_and_artifact_mutations_fail_closed(self) -> None:
        for mutation in ("count", "command", "suite", "test", "skip"):
            summary = copy.deepcopy(self.summary)
            if mutation == "count":
                summary["passed_test_count"] = 41
            elif mutation == "command":
                summary["toolchain"]["command"] = "xcodebuild test"
            elif mutation == "suite":
                summary["test_suites"].pop()
            elif mutation == "test":
                summary["test_suites"][0]["tests"][0]["status"] = "failed"
            else:
                summary["skipped_test_count"] = 1
            with self.subTest(mutation=mutation):
                self.assertTrue(self.verifier._summary_errors(summary))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary_path = root / XCRESULT_SUMMARY_PATH
            log_path = root / XCODEBUILD_LOG_PATH
            summary_path.parent.mkdir(parents=True)
            shutil.copy2(REPOSITORY_ROOT / XCRESULT_SUMMARY_PATH, summary_path)
            shutil.copy2(REPOSITORY_ROOT / XCODEBUILD_LOG_PATH, log_path)
            verifier = R06PhaseAcceptanceVerifier(root)
            self.assertEqual(verifier._artifact_errors(), [])
            log_path.write_text("fabricated\n", encoding="utf-8")
            self.assertTrue(verifier._artifact_errors())
            log_path.unlink()
            log_path.symlink_to(REPOSITORY_ROOT / XCODEBUILD_LOG_PATH)
            self.assertTrue(verifier._artifact_errors())

    def test_raw_xcresult_invocation_and_exact_result_pass(self) -> None:
        summary, tests, build_results = raw_xcresult_payloads()
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "selected.xcresult"
            result_path.mkdir()
            completed = [
                subprocess.CompletedProcess(
                    args=[],
                    returncode=0,
                    stdout=json.dumps(payload),
                    stderr="",
                )
                for payload in (summary, tests, build_results)
            ]
            with mock.patch(
                "r06_phase_acceptance.subprocess.run",
                side_effect=completed,
            ) as run, mock.patch.object(
                self.verifier,
                "_source_errors",
                return_value=[],
            ):
                self.assertEqual(
                    self.verifier.check_xcresult(result_path),
                    [],
                )
            self.assertEqual(run.call_count, 3)
            self.assertEqual(
                [call.args[0][4] for call in run.call_args_list[:2]],
                ["summary", "tests"],
            )
            self.assertEqual(
                run.call_args_list[2].args[0][:4],
                ["xcrun", "xcresulttool", "get", "build-results"],
            )
            for call in run.call_args_list:
                self.assertIn(str(result_path), call.args[0])
                self.assertIn("--compact", call.args[0])

    def test_raw_summary_count_skip_platform_and_title_fail_closed(self) -> None:
        base_summary, tests, build = raw_xcresult_payloads()
        mutations = []
        summary = copy.deepcopy(base_summary)
        summary["passedTests"] = 41
        summary["failedTests"] = 1
        mutations.append(summary)
        summary = copy.deepcopy(base_summary)
        summary["skippedTests"] = 1
        mutations.append(summary)
        summary = copy.deepcopy(base_summary)
        summary["title"] = "Build - Mirmir"
        mutations.append(summary)
        summary = copy.deepcopy(base_summary)
        summary["devicesAndConfigurations"][0]["device"]["platform"] = "iOS"
        mutations.append(summary)
        for summary in mutations:
            with self.subTest(summary=summary):
                self.assertTrue(
                    self.verifier._raw_xcresult_errors(
                        summary,
                        copy.deepcopy(tests),
                        copy.deepcopy(build),
                        self.summary,
                    )
                )

    def test_raw_missing_unexpected_duplicate_and_failing_tests_fail(self) -> None:
        summary, base_tests, build = raw_xcresult_payloads()
        mutations = []
        tests = copy.deepcopy(base_tests)
        tests["testNodes"][0]["children"][0]["children"].pop()
        mutations.append(tests)

        tests = copy.deepcopy(base_tests)
        test_case = tests["testNodes"][0]["children"][0]["children"][0]
        test_case["nodeIdentifier"] = "UnexpectedSuite/" + test_case["name"]
        mutations.append(tests)

        tests = copy.deepcopy(base_tests)
        duplicate = copy.deepcopy(
            tests["testNodes"][0]["children"][0]["children"][0]
        )
        tests["testNodes"][0]["children"][0]["children"].append(duplicate)
        mutations.append(tests)

        tests = copy.deepcopy(base_tests)
        tests["testNodes"][0]["children"][0]["children"][0][
            "result"
        ] = "Failed"
        mutations.append(tests)

        for tests in mutations:
            with self.subTest(tests=tests):
                self.assertTrue(
                    self.verifier._raw_xcresult_errors(
                        copy.deepcopy(summary),
                        tests,
                        copy.deepcopy(build),
                        self.summary,
                    )
                )

    def test_non_test_and_failing_build_results_fail_closed(self) -> None:
        summary, tests, build = raw_xcresult_payloads()
        self.assertTrue(
            self.verifier._raw_xcresult_errors(
                copy.deepcopy(summary),
                {"buildNodes": []},
                copy.deepcopy(build),
                self.summary,
            )
        )
        for mutation in ("action", "status", "errors", "platform"):
            changed = copy.deepcopy(build)
            if mutation == "action":
                changed["actionTitle"] = "Building project Mirmir"
            elif mutation == "status":
                changed["status"] = "failed"
            elif mutation == "errors":
                changed["errorCount"] = 1
                changed["errors"] = [{"message": "failed"}]
            else:
                changed["destination"]["platform"] = "iOS Simulator"
            with self.subTest(mutation=mutation):
                self.assertTrue(
                    self.verifier._raw_xcresult_errors(
                        copy.deepcopy(summary),
                        copy.deepcopy(tests),
                        changed,
                        self.summary,
                    )
                )

    def test_raw_path_symlink_tool_and_invalid_output_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = root / "missing.xcresult"
            self.assertTrue(self.verifier.check_xcresult(missing))

            target = root / "target.xcresult"
            target.mkdir()
            linked = root / "linked.xcresult"
            linked.symlink_to(target)
            self.assertTrue(self.verifier.check_xcresult(linked))

            invalid = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout="{",
                stderr="",
            )
            with mock.patch(
                "r06_phase_acceptance.subprocess.run",
                side_effect=(invalid, invalid, invalid),
            ), mock.patch.object(
                self.verifier,
                "_source_errors",
                return_value=[],
            ):
                errors = self.verifier.check_xcresult(target)
            self.assertTrue(
                any("output is invalid" in error for error in errors)
            )

            failure = subprocess.CompletedProcess(
                args=[],
                returncode=1,
                stdout="",
                stderr="not a test result",
            )
            with mock.patch(
                "r06_phase_acceptance.subprocess.run",
                side_effect=(failure, failure, failure),
            ), mock.patch.object(
                self.verifier,
                "_source_errors",
                return_value=[],
            ):
                errors = self.verifier.check_xcresult(target)
            self.assertTrue(
                any("extraction failed" in error for error in errors)
            )

            with mock.patch(
                "r06_phase_acceptance.subprocess.run",
                side_effect=OSError("xcrun unavailable"),
            ), mock.patch.object(
                self.verifier,
                "_source_errors",
                return_value=[],
            ):
                errors = self.verifier.check_xcresult(target)
            self.assertTrue(
                any("extraction failed" in error for error in errors)
            )

    def test_private_evidence_is_rejected(self) -> None:
        for value in (
            {"username": "operator"},
            {"note": "operator@example.com"},
            {"note": "/Users/operator/private/result.xcresult"},
            {"note": "hardware uuid: 00000000-0000-0000-0000-000000000000"},
        ):
            with self.subTest(value=value):
                self.assertTrue(self.verifier._privacy_errors(value))


if __name__ == "__main__":
    unittest.main()
