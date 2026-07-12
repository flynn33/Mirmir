from __future__ import annotations

import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.release_orchestrator import (
    REQUIRED_G06_TEST_EVIDENCE_IDS,
)
from validation.calibration_v2.tools import run_g06_verification as g06
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class G06ParserTests(unittest.TestCase):
    def test_unittest_parser_requires_terminal_arithmetic(self) -> None:
        counts = g06.parse_unittest_output(
            "................................................................\n"
            "----------------------------------------------------------------------\n"
            "Ran 150 tests in 41.901s\n\nOK\n"
        )
        self.assertEqual(counts["test_count"], 150)
        self.assertEqual(counts["passed"], 150)
        self.assertTrue(g06._test_counts_pass(counts))

        skipped = g06.parse_unittest_output(
            "Ran 3 tests in 0.1s\n\nOK (skipped=1)\n"
        )
        self.assertEqual(skipped["passed"], 2)
        self.assertFalse(g06._test_counts_pass(skipped))

        exceptional = g06.parse_unittest_output(
            "Ran 5 tests in 0.1s\n\n"
            "OK (skipped=1, expected failures=1, unexpected successes=1)\n"
        )
        self.assertEqual(exceptional["passed"], 2)
        self.assertEqual(exceptional["expected_failures"], 1)
        self.assertEqual(exceptional["unexpected_successes"], 1)
        self.assertFalse(g06._test_counts_pass(exceptional))
        with self.assertRaisesRegex(g06.G06VerificationError, "terminal status"):
            g06.parse_unittest_output("Ran 1 test in 0.1s\n")

    def test_pytest_parser_counts_function_style_tests_and_rejects_skips(self) -> None:
        counts = g06.parse_pytest_output(
            "................................ [100%]\n165 passed in 77.92s\n"
        )
        self.assertEqual(counts["test_count"], 165)
        self.assertTrue(g06._test_counts_pass(counts))

        skipped = g06.parse_pytest_output("4 passed, 1 skipped in 0.4s\n")
        self.assertEqual(skipped["test_count"], 5)
        self.assertFalse(g06._test_counts_pass(skipped))

    def test_xcresult_and_diagnostic_parsers_are_fail_closed(self) -> None:
        counts = g06.parse_xcresult_summary(
            {
                "totalTestCount": 8,
                "passedTests": 8,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "result": "Passed",
            }
        )
        self.assertTrue(g06._test_counts_pass(counts))
        with self.assertRaisesRegex(g06.G06VerificationError, "arithmetic"):
            g06.parse_xcresult_summary(
                {
                    "totalTestCount": 8,
                    "passedTests": 7,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "result": "Passed",
                }
            )
        self.assertEqual(
            g06.parse_diagnostic_counts(
                "file.swift:1: warning: warning text\n"
                "file.swift:2: error: error text\n"
                "2026-07-11 appintentsmetadataprocessor[1:2] warning: "
                "no AppIntents dependency\n"
                "2026-07-11 Mirmir[1:2] connection error: unavailable\n"
            ),
            {"warning_count": 1, "error_count": 1},
        )
        self.assertTrue(
            g06._diagnostics_are_clean(
                {"warning_count": 0, "error_count": 0}
            )
        )
        self.assertFalse(
            g06._diagnostics_are_clean(
                {"warning_count": 1, "error_count": 0}
            )
        )


class G06AtomicPublicationTests(unittest.TestCase):
    @staticmethod
    def _mock_passed_executor(
        identifier: str,
    ) -> object:
        def execute(run_root: Path) -> g06.GroupResult:
            artifact_id = f"logs/{identifier}.log"
            path = g06._safe_child(run_root, artifact_id)
            g06._write_new(path, f"{identifier}: passed\n".encode("utf-8"))
            binding = g06._file_binding(
                path,
                run_root=run_root,
                artifact_kind="command_log",
            )
            command = {
                "command_index": 1,
                "argv": ["mock-command", identifier],
                "command_text": f"mock-command {identifier}",
                "working_directory": ".",
                "exit_code": 0,
                "timed_out": False,
                "duration_seconds": 0.0,
                "status": "passed",
                "log_binding": binding,
            }
            return g06.GroupResult(
                status="passed",
                started_utc="2026-07-11T00:00:00.000000Z",
                finished_utc="2026-07-11T00:00:01.000000Z",
                commands=(command,),
                artifacts=(binding,),
                summary={"mocked": True},
                failure_reason=None,
            )

        return execute

    def _runner(
        self,
        *,
        output_root: Path,
        run_id: str,
        executors: dict[str, object],
    ) -> g06.G06VerificationRunner:
        return g06.G06VerificationRunner(
            repository_root=REPOSITORY_ROOT,
            output_root=output_root,
            run_id=run_id,
            group_executors=executors,
        )

    def test_success_publishes_exact_five_ordered_self_hashed_files_atomically(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-publication-") as value:
            output = Path(value)
            executors = {
                identifier: self._mock_passed_executor(identifier)
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            runner = self._runner(
                output_root=output,
                run_id="g06-pass",
                executors=executors,
            )
            result = runner.run()
            self.assertEqual(result.status, "passed")
            self.assertEqual(result.path, output / "g06-pass")
            self.assertFalse((output / ".g06-pass.partial").exists())
            self.assertEqual(
                [identifier for identifier, _ in result.evidence_paths],
                list(REQUIRED_G06_TEST_EVIDENCE_IDS),
            )
            self.assertEqual(
                sorted(path.name for path in result.path.glob("*.json")),
                sorted(
                    f"{identifier}.json"
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                ),
            )
            for ordinal, (identifier, path) in enumerate(result.evidence_paths, 1):
                document = g06._read_json(path)
                unhashed = dict(document)
                declared = unhashed.pop("evidence_sha256")
                self.assertEqual(document["evidence_id"], identifier)
                self.assertEqual(document["evidence_ordinal"], ordinal)
                self.assertEqual(declared, canonical_sha256(unhashed))

            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "already exists",
            ):
                runner.run()

    def test_failure_is_preserved_and_remaining_evidence_is_not_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-failure-") as value:
            output = Path(value)
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]
            calls: list[str] = []

            def fail(_run_root: Path) -> g06.GroupResult:
                calls.append(first)
                return g06.GroupResult(
                    status="failed",
                    started_utc="2026-07-11T00:00:00.000000Z",
                    finished_utc="2026-07-11T00:00:01.000000Z",
                    commands=(),
                    artifacts=(),
                    summary={"mocked": True},
                    failure_reason="mocked failure",
                )

            def must_not_run(_run_root: Path) -> g06.GroupResult:
                raise AssertionError("later evidence group must not run")

            executors = {
                identifier: (fail if identifier == first else must_not_run)
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            result = self._runner(
                output_root=output,
                run_id="g06-fail",
                executors=executors,
            ).run()
            self.assertEqual(calls, [first])
            self.assertEqual(result.status, "failed")
            self.assertEqual(result.path, output / "g06-fail.failed")
            statuses = [
                g06._read_json(path)["status"]
                for _, path in result.evidence_paths
            ]
            self.assertEqual(statuses, ["failed", "not_run", "not_run", "not_run", "not_run"])

    def test_mutated_artifact_blocks_final_publication_and_preserves_partial(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-mutation-") as value:
            output = Path(value)
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]

            def mutate(run_root: Path) -> g06.GroupResult:
                executor = self._mock_passed_executor(first)
                result = executor(run_root)
                artifact_id = str(result.artifacts[0]["artifact_id"])
                g06._safe_child(run_root, artifact_id).write_bytes(b"mutated\n")
                return result

            executors = {
                identifier: (
                    mutate
                    if identifier == first
                    else self._mock_passed_executor(identifier)
                )
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            runner = self._runner(
                output_root=output,
                run_id="g06-mutation",
                executors=executors,
            )
            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "artifact binding changed",
            ):
                runner.run()
            self.assertTrue((output / ".g06-mutation.partial").is_dir())
            self.assertFalse((output / "g06-mutation").exists())
            self.assertFalse((output / "g06-mutation.failed").exists())

    def test_xcode_commands_are_explicit_and_do_not_reference_holdout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-command-") as value:
            runner = self._runner(
                output_root=Path(value),
                run_id="g06-command",
                executors={},
            )
            command = runner._xcode_test_command(
                configuration="Debug",
                derived_data=Path(value) / "derived",
                result_bundle=Path(value) / "result.xcresult",
                tests=g06.NATIVE_INTEGRATION_TESTS,
                clean=True,
            )
            self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
            self.assertNotIn("ENABLE_TESTABILITY=YES", command)
            self.assertIn("-enableCodeCoverage", command)
            self.assertEqual(
                [value for value in command if value.startswith("-only-testing:")],
                [
                    f"-only-testing:MirmirTests/{name}"
                    for name in g06.NATIVE_INTEGRATION_TESTS
                ],
            )
            self.assertEqual(command[-2:], ("clean", "test"))

            release_command = runner._xcode_test_command(
                configuration="Release",
                derived_data=Path(value) / "release-derived",
                result_bundle=Path(value) / "release-result.xcresult",
                tests=g06.RELEASE_RUNTIME_TESTS,
                clean=False,
            )
            self.assertEqual(release_command[-1], "test")
            self.assertNotIn("clean", release_command)
            self.assertIn("ENABLE_TESTABILITY=YES", release_command)
            self.assertNotIn("holdout", " ".join(command).lower())
            self.assertNotIn("holdout", " ".join(release_command).lower())

    def test_xcresult_is_bound_after_summary_tool_materializes_lazy_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-xcresult-") as value:
            run_root = Path(value)
            runner = self._runner(
                output_root=run_root / "publication",
                run_id="g06-xcresult",
                executors={},
            )
            result_bundle = run_root / "artifacts/native-integration.xcresult"

            def command(**arguments: object) -> dict[str, object]:
                command_index = int(arguments["command_index"])
                artifact_id = str(arguments["log_artifact_id"])
                log_path = g06._safe_child(run_root, artifact_id)
                log_path.parent.mkdir(parents=True, exist_ok=True)
                argv = list(arguments["argv"])
                if command_index == 1:
                    result_bundle.mkdir(parents=True)
                    (result_bundle / "Info.plist").write_bytes(b"initial")
                    payload = b"** TEST SUCCEEDED **\n"
                else:
                    (result_bundle / "database.sqlite3").write_bytes(b"lazy")
                    payload = g06.canonical_json_bytes(
                        {
                            "totalTestCount": 1,
                            "passedTests": 1,
                            "failedTests": 0,
                            "skippedTests": 0,
                            "expectedFailures": 0,
                            "result": "Passed",
                        }
                    ) + b"\n"
                g06._write_new(log_path, payload)
                binding = g06._file_binding(
                    log_path,
                    run_root=run_root,
                    artifact_kind=str(arguments.get("artifact_kind", "command_log")),
                )
                return {
                    "command_index": command_index,
                    "argv": argv,
                    "command_text": " ".join(argv),
                    "working_directory": ".",
                    "exit_code": 0,
                    "timed_out": False,
                    "duration_seconds": 0.0,
                    "status": "passed",
                    "log_binding": binding,
                }

            with mock.patch.object(runner, "_execute_command", side_effect=command):
                result = runner._xcode_native_integration(run_root)
            self.assertEqual(result.status, "passed")
            xcresult = next(
                binding
                for binding in result.artifacts
                if binding["artifact_id"]
                == "artifacts/native-integration.xcresult"
            )
            self.assertEqual(xcresult["file_count"], 2)
            self.assertEqual(
                xcresult,
                g06._tree_binding(
                    result_bundle,
                    run_root=run_root,
                    artifact_kind="xcresult",
                ),
            )


if __name__ == "__main__":
    unittest.main()
