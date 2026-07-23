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
from r02_contracts import CONFORMANCE_PATH  # noqa: E402
from r02_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ACCEPTANCE_SCHEMA_PATH,
    ARTIFACT_PATHS,
    EVIDENCE_PATHS,
    EXPECTED_SELECTED_TEST_COUNT,
    IMPLEMENTATION_PATHS,
    REQUIRED_TEST_SUITES,
    SOURCE_BUILD_PATHS,
    SOURCE_COMMIT,
    SOURCE_TREE,
    XCRESULT_SUMMARY_PATH,
    XCODEBUILD_COMMAND,
    XCODEBUILD_LOG_PATH,
    R02PhaseAcceptanceVerifier,
    _expected_log,
    _expected_summary,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected object: {relative}")
    return value


def raw_xcresult_payloads() -> tuple[
    dict[str, object],
    dict[str, object],
    dict[str, object],
]:
    summary: dict[str, object] = {
        "result": "Passed",
        "totalTestCount": EXPECTED_SELECTED_TEST_COUNT,
        "passedTests": EXPECTED_SELECTED_TEST_COUNT,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
        "testFailures": [],
        "startTime": 1_784_801_776.894,
        "finishTime": 1_784_801_795.357,
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
    for suite_id, test_ids in _expected_summary_suite_tests():
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


def _expected_summary_suite_tests() -> tuple[tuple[str, tuple[str, ...]], ...]:
    summary = _expected_summary()
    return tuple(
        (
            suite["id"],
            tuple(test["id"] for test in suite["tests"]),
        )
        for suite in summary["test_suites"]
    )


class R02PhaseAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R02PhaseAcceptanceVerifier(REPOSITORY_ROOT)
        self.schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.record = read_json(ACCEPTANCE_PATH)
        self.conformance = read_json(CONFORMANCE_PATH)
        self.summary = read_json(XCRESULT_SUMMARY_PATH)

    def test_repository_acceptance_is_valid_and_exactly_derived(self) -> None:
        self.assertEqual(self.verifier.check(), [])
        self.assertEqual(self.record, self.verifier.expected_record())

    def test_acceptance_schema_is_closed(self) -> None:
        self.assertEqual(
            validate_json_schema_instance(self.schema, self.record),
            [],
        )
        fabricated = copy.deepcopy(self.record)
        fabricated["unreviewed_authority"] = True
        self.assertTrue(validate_json_schema_instance(self.schema, fabricated))

    def test_source_checkpoint_and_source_bound_files_are_exact(self) -> None:
        self.assertEqual(self.record["source"]["commit"], SOURCE_COMMIT)
        self.assertEqual(self.record["source"]["tree"], SOURCE_TREE)
        self.assertEqual(self.verifier._source_errors(), [])
        self.assertEqual(
            [binding["id"] for binding in self.record["evidence_bindings"]],
            [identifier for identifier, _ in EVIDENCE_PATHS],
        )
        self.assertEqual(
            [binding["id"] for binding in self.record["implementation_bindings"]],
            [identifier for identifier, _ in IMPLEMENTATION_PATHS],
        )
        self.assertEqual(
            tuple(path.as_posix() for path in SOURCE_BUILD_PATHS),
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
        bindings = {
            binding["id"]: binding
            for binding in self.record["implementation_bindings"]
        }
        self.assertEqual(
            {
                identifier: bindings[identifier]["path"]
                for identifier in (
                    "production_bootstrap_source",
                    "unavailable_upscaler_service_source",
                    "architecture_guardrail_tests",
                    "upscaler_engine_availability_tests",
                    "ash_calibration_cli_support_source",
                    "ash_calibration_cli_protocol_source",
                )
            },
            {
                "production_bootstrap_source": "Mirmir/App/MirmirAppBootstrap.swift",
                "unavailable_upscaler_service_source": (
                    "Mirmir/Modules/UpscalerEngine/"
                    "UnavailableUpscalerEngineService.swift"
                ),
                "architecture_guardrail_tests": (
                    "MirmirTests/ArchitectureGuardrailTests.swift"
                ),
                "upscaler_engine_availability_tests": (
                    "MirmirTests/UpscalerEngineAvailabilityTests.swift"
                ),
                "ash_calibration_cli_support_source": (
                    "validation/calibration_v2/native_adapter/"
                    "ASHCalibrationCLISupport.swift"
                ),
                "ash_calibration_cli_protocol_source": (
                    "validation/calibration_v2/native_adapter/"
                    "ASHCalibrationCLIProtocol.swift"
                ),
            },
        )
        self.assertEqual(
            bindings["xcode_scheme"]["path"],
            "Mirmir.xcodeproj/xcshareddata/xcschemes/Mirmir.xcscheme",
        )

    def test_source_build_surface_mutation_fails_closed(self) -> None:
        original_git = self.verifier.git

        def git_with_mutated_build_surface(
            *arguments: str,
        ) -> subprocess.CompletedProcess[str]:
            if arguments[:2] == ("diff", "--quiet"):
                return subprocess.CompletedProcess(
                    args=["git", *arguments],
                    returncode=1,
                    stdout="",
                    stderr="",
                )
            return original_git(*arguments)

        with mock.patch.object(
            self.verifier,
            "git",
            side_effect=git_with_mutated_build_surface,
        ):
            errors = self.verifier._source_errors()
        self.assertIn(
            "R02 acceptance build surface differs from the source checkpoint",
            errors,
        )

    def test_write_output_rejects_symlink_target_and_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verifier = R02PhaseAcceptanceVerifier(root)
            output = root / ACCEPTANCE_PATH
            output.parent.mkdir(parents=True)
            target = root / "target.json"
            target.write_text("preserve\n", encoding="utf-8")
            output.symlink_to(target)

            self.assertTrue(verifier._write_output(output, b"replace\n"))
            self.assertEqual(target.read_text(encoding="utf-8"), "preserve\n")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            verifier = R02PhaseAcceptanceVerifier(root)
            real_docs = root / "real-docs"
            real_docs.mkdir()
            (root / "docs").symlink_to(real_docs, target_is_directory=True)
            output = root / ACCEPTANCE_PATH

            self.assertTrue(verifier._write_output(output, b"replace\n"))
            self.assertFalse(
                (real_docs / Path(*ACCEPTANCE_PATH.parts[1:])).exists()
            )

    def test_frozen_r02_evidence_is_bound_without_rewriting_it(self) -> None:
        bindings = {
            binding["id"]: binding for binding in self.record["evidence_bindings"]
        }
        self.assertEqual(
            bindings["r02_deterministic_conformance"],
            {
                "id": "r02_deterministic_conformance",
                "path": (
                    "docs/roadmaps/evidence/r02/records/conformance.json"
                ),
                "size_bytes": 13488,
                "sha256": (
                    "8eaccc72d82beb4bbe26dfa7af52809743e017e3ad9ba09d3"
                    "cc4febc7f8187b1"
                ),
            },
        )
        self.assertEqual(
            self.conformance["result"]["authorization"]["phase_acceptance"],
            "not_claimed",
        )

    def test_failed_or_incomplete_conformance_cannot_accept(self) -> None:
        mutations: list[dict[str, object]] = []

        conformance = copy.deepcopy(self.conformance)
        conformance["result"]["status"] = "blocked"
        mutations.append(conformance)

        conformance = copy.deepcopy(self.conformance)
        conformance["checks"][0]["status"] = "failed"
        mutations.append(conformance)

        conformance = copy.deepcopy(self.conformance)
        conformance["result"]["metrics"][0]["value"] = 1
        conformance["result"]["metrics"][0]["passed"] = False
        mutations.append(conformance)

        conformance = copy.deepcopy(self.conformance)
        conformance["backend_runs"].pop()
        mutations.append(conformance)

        conformance = copy.deepcopy(self.conformance)
        conformance["observation_status"]["simulator_execution"] = "observed"
        mutations.append(conformance)

        conformance = copy.deepcopy(self.conformance)
        conformance["result"]["production_composition"][
            "fixture_backend_reachable"
        ] = True
        mutations.append(conformance)

        conformance = copy.deepcopy(self.conformance)
        conformance["result"]["authorization"][
            "production_enablement"
        ] = "authorized"
        mutations.append(conformance)

        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertTrue(
                    self.verifier._functional_evidence_errors(mutation)
                )

    def test_xcresult_summary_is_exact_and_complete(self) -> None:
        self.assertEqual(self.summary, _expected_summary())
        self.assertEqual(self.verifier._summary_errors(self.summary), [])
        self.assertEqual(
            [suite["id"] for suite in self.summary["test_suites"]],
            [
                "AppleUpscaleContractsTests",
                "AppleUpscaleFIFOSessionTests",
                "ArchitectureGuardrailTests",
                "EnhancementPipelineContractsTests",
                "R02FixtureConformanceTests",
                "UpscalerEngineAvailabilityTests",
            ],
        )
        self.assertEqual(
            set(REQUIRED_TEST_SUITES),
            {suite["id"] for suite in self.summary["test_suites"]},
        )
        self.assertEqual(
            self.summary["passed_test_count"],
            EXPECTED_SELECTED_TEST_COUNT,
        )
        self.assertEqual(self.summary["failed_test_count"], 0)
        self.assertEqual(self.summary["skipped_test_count"], 0)

    def test_test_result_or_toolchain_mutation_fails_closed(self) -> None:
        mutations: list[dict[str, object]] = []

        summary = copy.deepcopy(self.summary)
        summary["passed_test_count"] = 24
        summary["failed_test_count"] = 1
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["skipped_test_count"] = 1
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["test_suites"].pop()
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["test_suites"][0]["tests"][0]["status"] = "failed"
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["test_suites"][0]["tests"].pop()
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["toolchain"]["command"] = "xcodebuild test"
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["source"]["commit"] = "1" * 40
        mutations.append(summary)

        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertTrue(self.verifier._summary_errors(mutation))

    def test_exact_command_and_repository_safe_transcript_are_bound(self) -> None:
        self.assertEqual(self.summary["toolchain"]["command"], XCODEBUILD_COMMAND)
        self.assertEqual(
            (REPOSITORY_ROOT / XCODEBUILD_LOG_PATH).read_text(encoding="utf-8"),
            _expected_log(),
        )
        self.assertEqual(self.verifier._artifact_errors(self.summary), [])
        self.assertEqual(
            [binding["id"] for binding in self.record["artifact_bindings"]],
            [identifier for identifier, _ in ARTIFACT_PATHS],
        )

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
                "r02_phase_acceptance.subprocess.run",
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
            for call in run.call_args_list[:2]:
                self.assertEqual(
                    call.args[0][:4],
                    ["xcrun", "xcresulttool", "get", "test-results"],
                )
                self.assertIn(str(result_path), call.args[0])
                self.assertIn("--compact", call.args[0])
            self.assertEqual(
                run.call_args_list[2].args[0][:4],
                ["xcrun", "xcresulttool", "get", "build-results"],
            )
            self.assertIn(str(result_path), run.call_args_list[2].args[0])
            self.assertIn("--compact", run.call_args_list[2].args[0])

    def test_raw_xcresult_summary_and_test_mutations_fail_closed(self) -> None:
        summary, tests, build_results = raw_xcresult_payloads()
        mutations: list[
            tuple[
                dict[str, object],
                dict[str, object],
                dict[str, object],
            ]
        ] = []

        changed_summary = copy.deepcopy(summary)
        changed_summary["passedTests"] = EXPECTED_SELECTED_TEST_COUNT - 1
        changed_summary["failedTests"] = 1
        mutations.append(
            (
                changed_summary,
                copy.deepcopy(tests),
                copy.deepcopy(build_results),
            )
        )

        changed_summary = copy.deepcopy(summary)
        changed_summary["skippedTests"] = 1
        mutations.append(
            (
                changed_summary,
                copy.deepcopy(tests),
                copy.deepcopy(build_results),
            )
        )

        changed_tests = copy.deepcopy(tests)
        changed_tests["testNodes"][0]["children"][0]["children"].pop()
        mutations.append(
            (
                copy.deepcopy(summary),
                changed_tests,
                copy.deepcopy(build_results),
            )
        )

        changed_tests = copy.deepcopy(tests)
        changed_tests["testNodes"][0]["children"][0]["children"][0][
            "result"
        ] = "Failed"
        mutations.append(
            (
                copy.deepcopy(summary),
                changed_tests,
                copy.deepcopy(build_results),
            )
        )

        changed_tests = copy.deepcopy(tests)
        case = changed_tests["testNodes"][0]["children"][0]["children"][0]
        case["nodeIdentifier"] = "UnexpectedSuite/" + case["name"]
        mutations.append(
            (
                copy.deepcopy(summary),
                changed_tests,
                copy.deepcopy(build_results),
            )
        )

        changed_tests = copy.deepcopy(tests)
        duplicate = copy.deepcopy(
            changed_tests["testNodes"][0]["children"][0]["children"][0]
        )
        changed_tests["testNodes"][0]["children"][0]["children"].append(
            duplicate
        )
        mutations.append(
            (
                copy.deepcopy(summary),
                changed_tests,
                copy.deepcopy(build_results),
            )
        )

        changed_build = copy.deepcopy(build_results)
        changed_build["actionTitle"] = "Testing another project"
        mutations.append(
            (
                copy.deepcopy(summary),
                copy.deepcopy(tests),
                changed_build,
            )
        )

        for changed_summary, changed_tests, changed_build in mutations:
            with self.subTest(
                summary=changed_summary,
                tests=changed_tests,
                build=changed_build,
            ):
                self.assertTrue(
                    self.verifier._raw_xcresult_errors(
                        changed_summary,
                        changed_tests,
                        changed_build,
                        self.summary,
                    )
                )

    def test_raw_xcresult_path_and_tool_failures_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = root / "missing.xcresult"
            self.assertTrue(self.verifier.check_xcresult(missing))

            target = root / "target.xcresult"
            target.mkdir()
            symlink = root / "symlink.xcresult"
            symlink.symlink_to(target)
            self.assertTrue(self.verifier.check_xcresult(symlink))

            failure = subprocess.CompletedProcess(
                args=[],
                returncode=1,
                stdout="",
                stderr="result bundle invalid",
            )
            success = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps(raw_xcresult_payloads()[1]),
                stderr="",
            )
            build_success = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps(raw_xcresult_payloads()[2]),
                stderr="",
            )
            with mock.patch(
                "r02_phase_acceptance.subprocess.run",
                side_effect=(failure, success, build_success),
            ), mock.patch.object(
                self.verifier,
                "_source_errors",
                return_value=[],
            ):
                errors = self.verifier.check_xcresult(target)
            self.assertTrue(
                any("summary extraction failed" in error for error in errors)
            )

            invalid = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout="{",
                stderr="",
            )
            with mock.patch(
                "r02_phase_acceptance.subprocess.run",
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

            with mock.patch(
                "r02_phase_acceptance.subprocess.run",
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

    def test_artifact_content_and_symlink_mutations_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary_path = root / XCRESULT_SUMMARY_PATH
            log_path = root / XCODEBUILD_LOG_PATH
            summary_path.parent.mkdir(parents=True)
            shutil.copy2(REPOSITORY_ROOT / XCRESULT_SUMMARY_PATH, summary_path)
            shutil.copy2(REPOSITORY_ROOT / XCODEBUILD_LOG_PATH, log_path)
            verifier = R02PhaseAcceptanceVerifier(root)
            self.assertEqual(verifier._artifact_errors(), [])

            mutated = copy.deepcopy(self.summary)
            mutated["failed_test_count"] = 1
            summary_path.write_text(
                json.dumps(mutated, indent=2) + "\n",
                encoding="utf-8",
            )
            self.assertTrue(verifier._artifact_errors())

            summary_path.unlink()
            summary_path.symlink_to(REPOSITORY_ROOT / XCRESULT_SUMMARY_PATH)
            self.assertTrue(verifier._artifact_errors())

    def test_plausible_binding_hash_mutation_is_rejected_by_derivation(self) -> None:
        fabricated = copy.deepcopy(self.record)
        fabricated["artifact_bindings"][0]["sha256"] = "1" * 64
        self.assertEqual(
            validate_json_schema_instance(self.schema, fabricated),
            [],
        )
        self.assertNotEqual(fabricated, self.verifier.expected_record())

    def test_acceptance_cannot_expand_product_or_claim_authority(self) -> None:
        forbidden_authorizations = (
            "production_upscaling",
            "production_default",
            "auto_mode",
            "holdout",
            "quality_claims",
            "performance_claims",
            "product_publication",
            "release",
            "native_framework_claims",
        )
        for key in forbidden_authorizations:
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.record)
                fabricated["authorizations"][key] = "authorized"
                self.assertTrue(
                    validate_json_schema_instance(self.schema, fabricated)
                )
                self.assertNotEqual(fabricated, self.verifier.expected_record())

    def test_comparison_policy_does_not_replace_common_session_proof(self) -> None:
        comparison = self.record["comparison_policy"]
        self.assertEqual(
            comparison["common_session_multiple_backend_test"],
            "required_noncomparative_interface_conformance",
        )
        self.assertEqual(comparison["a_b_testing"], "not_run_not_required")
        fabricated = copy.deepcopy(self.record)
        fabricated["comparison_policy"][
            "common_session_multiple_backend_test"
        ] = "not_required"
        self.assertTrue(validate_json_schema_instance(self.schema, fabricated))

    def test_private_or_unreviewed_evidence_is_rejected(self) -> None:
        private_values = (
            {"username": "operator"},
            {"note": "operator@example.com"},
            {"note": "/Users/operator/private/result.xcresult"},
            {"note": "hardware uuid: 00000000-0000-0000-0000-000000000000"},
        )
        for value in private_values:
            with self.subTest(value=value):
                self.assertTrue(self.verifier._privacy_errors(value))


if __name__ == "__main__":
    unittest.main()
