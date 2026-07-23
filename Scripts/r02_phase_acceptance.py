#!/usr/bin/env python3
"""Derive and validate R02 declared-software-function phase acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable

from phase_evidence import (
    EMAIL_PATTERN,
    LABELED_PRIVATE_VALUE_PATTERN,
    PRIVATE_EVIDENCE_KEYS,
    PRIVATE_PATH_PATTERN,
    decode_json,
    validate_json_schema_instance,
)
from r02_contracts import (
    CONFORMANCE_CHECK_IDS,
    CONFORMANCE_PATH,
    EXPECTED_CONFORMANCE_METRIC_VALUES,
    EXPECTED_CONFORMANCE_OBSERVATION_STATUS,
    FIXTURE_BACKEND_IDS,
    FIXTURE_CATALOG_PATH,
    PREREGISTRATION_PATH,
    R02ContractVerifier,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r02/records/functional-phase-acceptance.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r02-functional-phase-acceptance-v1.json"
)
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r02/records/artifacts/functional-phase-acceptance"
)
XCODEBUILD_LOG_PATH = ARTIFACT_DIRECTORY / "xcodebuild.log"
XCRESULT_SUMMARY_PATH = ARTIFACT_DIRECTORY / "xcresult-summary.json"

SOURCE_COMMIT = "eeabc4224100bc8ed86ae1208189bee508844210"
SOURCE_TREE = "ac402f993805cca499d2f688c6186c4684ce8dba"
SOURCE_BUILD_PATHS = (
    Path("Mirmir"),
    Path("MirmirTests"),
    Path("Mirmir.xcodeproj"),
    Path("project.yml"),
    Path("validation/calibration_v2/native_adapter/ASHCalibrationCLISupport.swift"),
    Path("validation/calibration_v2/native_adapter/ASHCalibrationCLIProtocol.swift"),
)
XCODEBUILD_COMMAND = (
    "xcodebuild -quiet -project Mirmir.xcodeproj -scheme Mirmir "
    "-configuration Debug -destination platform=macOS,arch=arm64 "
    "-derivedDataPath /private/tmp/mirmir-r02-eeabc422-v2-derived "
    "-resultBundlePath /private/tmp/mirmir-r02-eeabc422-v2.xcresult "
    "-disableAutomaticPackageResolution test "
    "-only-testing:MirmirTests/AppleUpscaleContractsTests "
    "-only-testing:MirmirTests/EnhancementPipelineContractsTests "
    "-only-testing:MirmirTests/AppleUpscaleFIFOSessionTests "
    "-only-testing:MirmirTests/R02FixtureConformanceTests "
    "-only-testing:MirmirTests/ArchitectureGuardrailTests/"
    "test_productionCompositionUsesNoRetainedReferenceBackendOrVTStager "
    "-only-testing:MirmirTests/UpscalerEngineAvailabilityTests/"
    "test_unavailableServiceRejectsSubmissionWithTypedReason "
    "CODE_SIGNING_ALLOWED=NO"
)

EVIDENCE_PATHS = (
    ("r02_preregistration", PREREGISTRATION_PATH),
    ("r02_fixture_catalog", FIXTURE_CATALOG_PATH),
    ("r02_deterministic_conformance", CONFORMANCE_PATH),
)

IMPLEMENTATION_PATHS = (
    (
        "apple_upscale_contracts_source",
        Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleContracts.swift"),
    ),
    (
        "enhancement_pipeline_contracts_source",
        Path("Mirmir/Modules/UpscalerEngine/EnhancementPipelineContracts.swift"),
    ),
    (
        "apple_upscale_fifo_session_source",
        Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleFIFOSession.swift"),
    ),
    (
        "production_bootstrap_source",
        Path("Mirmir/App/MirmirAppBootstrap.swift"),
    ),
    (
        "unavailable_upscaler_service_source",
        Path(
            "Mirmir/Modules/UpscalerEngine/"
            "UnavailableUpscalerEngineService.swift"
        ),
    ),
    (
        "avfoundation_media_pipeline_source",
        Path("Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift"),
    ),
    (
        "avfoundation_media_session_configuration_source",
        Path(
            "Mirmir/Modules/MediaPipeline/"
            "AVFoundationMediaSessionConfiguration.swift"
        ),
    ),
    (
        "avfoundation_media_session_finalization_source",
        Path(
            "Mirmir/Modules/MediaPipeline/"
            "AVFoundationMediaSessionFinalization.swift"
        ),
    ),
    (
        "output_media_aac_identity_reader_source",
        Path("Mirmir/Modules/MediaPipeline/OutputMediaAACIdentityReader.swift"),
    ),
    (
        "output_media_identity_verification_source",
        Path(
            "Mirmir/Modules/MediaPipeline/OutputMediaIdentityVerification.swift"
        ),
    ),
    (
        "output_media_verification_types_source",
        Path("Mirmir/Modules/MediaPipeline/OutputMediaVerificationTypes.swift"),
    ),
    (
        "output_media_verifier_source",
        Path("Mirmir/Modules/MediaPipeline/OutputMediaVerifier.swift"),
    ),
    (
        "apple_upscale_contracts_tests",
        Path("MirmirTests/AppleUpscaleContractsTests.swift"),
    ),
    (
        "enhancement_pipeline_contracts_tests",
        Path("MirmirTests/EnhancementPipelineContractsTests.swift"),
    ),
    (
        "apple_upscale_fifo_session_tests",
        Path("MirmirTests/AppleUpscaleFIFOSessionTests.swift"),
    ),
    (
        "r02_fixture_conformance_tests",
        Path("MirmirTests/R02FixtureConformanceTests.swift"),
    ),
    (
        "r02_fixture_conformance_support",
        Path("MirmirTests/R02FixtureConformanceTestSupport.swift"),
    ),
    (
        "architecture_guardrail_tests",
        Path("MirmirTests/ArchitectureGuardrailTests.swift"),
    ),
    (
        "upscaler_engine_availability_tests",
        Path("MirmirTests/UpscalerEngineAvailabilityTests.swift"),
    ),
    ("project_manifest", Path("project.yml")),
    ("xcode_project", Path("Mirmir.xcodeproj/project.pbxproj")),
    (
        "xcode_scheme",
        Path("Mirmir.xcodeproj/xcshareddata/xcschemes/Mirmir.xcscheme"),
    ),
    (
        "ash_calibration_cli_support_source",
        Path(
            "validation/calibration_v2/native_adapter/"
            "ASHCalibrationCLISupport.swift"
        ),
    ),
    (
        "ash_calibration_cli_protocol_source",
        Path(
            "validation/calibration_v2/native_adapter/"
            "ASHCalibrationCLIProtocol.swift"
        ),
    ),
)

ARTIFACT_PATHS = (
    ("r02_functional_xcodebuild_log", XCODEBUILD_LOG_PATH),
    ("r02_functional_xcresult_summary", XCRESULT_SUMMARY_PATH),
)

REQUIRED_TEST_SUITES = (
    "AppleUpscaleContractsTests",
    "EnhancementPipelineContractsTests",
    "AppleUpscaleFIFOSessionTests",
    "R02FixtureConformanceTests",
    "ArchitectureGuardrailTests",
    "UpscalerEngineAvailabilityTests",
)

EXPECTED_SUITE_TESTS = (
    (
        "AppleUpscaleContractsTests",
        (
            "testAllFiveOrchestrationOutcomesCarryCompleteRouteIdentity()",
            "testBackendAndActorSessionCompileThroughCommonExistentials()",
            "testCapabilityRegistryPreservesOrderAndDoesNotInferEligibility()",
            "testCapabilityRegistryRejectsDuplicateAndFabricatedQualification()",
            "testFramePreservesEveryFrozenFieldAndTokenReleasesExactlyOnce()",
            "testInvalidFrameTimingAndDimensionsFailClosed()",
            "testProcessingIdentityRequiresContiguousVisibleFallback()",
        ),
    ),
    (
        "AppleUpscaleFIFOSessionTests",
        (
            "testCancelUnblocksActiveDriverRejectsQueueAndDiscardsLateSuccess()",
            "testConcurrentSubmissionsRemainFIFOAcrossDriverSuspension()",
            "testDriverRouteAndFallbackIdentityMismatchFailClosed()",
            "testFailureAndRejectionReleaseInputOwnershipExactlyOnce()",
            "testFinishFencesAdmissionDrainsAndCachesOneFinalization()",
            "testResetOrdersBetweenSubmissionsAndAdvancesOnlyHistoryGeneration()",
            "testSequenceAndTimingValidationRejectBeforeDriverInvocation()",
        ),
    ),
    (
        "ArchitectureGuardrailTests",
        (
            (
                "test_productionCompositionUsesNoRetainedReferenceBackendOr"
                "VTStager()"
            ),
        ),
    ),
    (
        "EnhancementPipelineContractsTests",
        (
            "testFiveStageProtocolsInvokeDistinctTypedOperations()",
            "testPlanCreatesOnlyContiguousVisibleFallbackLinks()",
            "testPlannerPreservesSuppliedNonalphabeticOrderAndExactlyOnePrimary()",
            "testPlannerRejectsDuplicateStageIDsAcrossPrimaryAndFallbackRoles()",
            "testPlannerRejectsMissingAndMultiplePrimaryStages()",
            "testPlannerRejectsPrimaryAndDuplicateFallbackRoutes()",
            "testPlanSnapshotsIdentityBeforeMutableStageConformersChange()",
        ),
    ),
    (
        "R02FixtureConformanceTests",
        (
            "testBackendRejectsInvalidCapabilityConfigurationAndContextBeforeCreation()",
            "testBothFixtureBackendsProcessEveryFixtureThroughCommonSession()",
            "testFrozenMP4AACTransactionVerifiesBeforeAtomicPublicationForBothBackends()",
            "testFrozenSwiftGeneratorsMatchCatalogAndMaterializeRowAwareNV12()",
        ),
    ),
    (
        "UpscalerEngineAvailabilityTests",
        ("test_unavailableServiceRejectsSubmissionWithTypedReason()",),
    ),
)

EXPECTED_SELECTED_TEST_COUNT = sum(
    len(test_ids) for _, test_ids in EXPECTED_SUITE_TESTS
)

FUNCTIONAL_CHECK_IDS = (
    "source_checkpoint_exact",
    "frozen_evidence_valid_and_unchanged",
    "implementation_bindings_exact",
    "execution_artifacts_exact",
    "selected_test_set_exact",
    "capability_registry_and_common_protocols",
    "stage_protocols_and_immutable_plan",
    "planner_single_primary_and_visible_fallback",
    "fifo_order_and_actor_reentrancy",
    "reset_finish_cancel_lifecycle",
    "typed_outcomes_and_complete_identity",
    "resource_lifetime_exactly_once",
    "multiple_backends_common_session",
    "media_contract_preservation",
    "reopen_verification_and_atomic_publication",
    "production_unavailable",
    "native_observation_boundary_truthful",
    "authorization_boundary_exact",
)

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "authorization_date": "2026-07-23",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "override_id": "r02.software-function-only-phase-acceptance.v1",
    "hardware_simulator_operator_observation": "waived_not_a_blocker",
    "comparative_requirement": "not_required_for_phase_acceptance",
    "historical_evidence_policy": (
        "preserve_r02_preregistration_and_conformance_unchanged"
    ),
}

COMPARISON_POLICY = {
    "comparative_quality_testing": "not_run_not_required",
    "a_b_testing": "not_run_not_required",
    "blinded_testing": "not_run_not_required",
    "superiority_requirement": "not_applicable",
    "acceptance_dependency": "none",
    "common_session_multiple_backend_test": (
        "required_noncomparative_interface_conformance"
    ),
}

RESULT = {
    "status": "passed",
    "phase_status_before": "in_progress",
    "phase_status_after": "passed",
    "acceptance": "accepted",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_execution",
}

AUTHORIZATIONS = {
    "r02_phase_acceptance": "authorized",
    "r02_phase_status": "passed",
    "phase_progression": "authorized",
    "product_qualification": "not_claimed",
    "production_upscaling": "not_authorized",
    "production_default": "not_authorized",
    "auto_mode": "not_authorized",
    "holdout": "not_authorized",
    "quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "product_publication": "not_authorized",
    "release": "not_authorized",
    "native_framework_claims": "not_authorized",
}

LIMITATIONS = (
    "R02 acceptance is limited to checkpoint-bound proof that the unified "
    "backend, session, stage, planner, lifecycle, identity, and media-transaction "
    "software performs its declared deterministic task.",
    "The two fixture backends verify common-interface interchangeability; they "
    "are not a comparative-quality or A/B experiment.",
    "Hardware, simulator, operator-observed, native-framework, quality, and "
    "performance observations remain truthfully unclaimed and are not blockers.",
    "R02 acceptance does not authorize product qualification, production "
    "upscaling, a production default, Auto, holdout, claims, publication, or "
    "release.",
)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _expected_summary() -> dict[str, object]:
    suites = []
    for suite_id, test_ids in EXPECTED_SUITE_TESTS:
        suites.append(
            {
                "id": suite_id,
                "expected_test_count": len(test_ids),
                "passed_test_count": len(test_ids),
                "failed_test_count": 0,
                "skipped_test_count": 0,
                "tests": [
                    {"id": test_id, "status": "passed"} for test_id in test_ids
                ],
            }
        )
    return {
        "schema_version": "1.0.0",
        "phase_id": "R02",
        "evidence_kind": "r02_functional_selected_test_summary_v1",
        "source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE},
        "execution_mode": "deterministic_fixture_execution",
        "expected_selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
        "selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
        "passed_test_count": EXPECTED_SELECTED_TEST_COUNT,
        "failed_test_count": 0,
        "skipped_test_count": 0,
        "test_suites": suites,
        "toolchain": {
            "platform": "macos_host",
            "architecture": "arm64",
            "command": XCODEBUILD_COMMAND,
        },
    }


def _expected_log() -> str:
    suite_lines = []
    for suite_id, test_ids in EXPECTED_SUITE_TESTS:
        suite_lines.extend(
            (
                f"Test Suite '{suite_id}' passed.",
                (
                    f"    Executed {len(test_ids)} tests, with 0 failures "
                    "(0 unexpected), 0 skipped."
                ),
            )
        )
    return "\n".join(
        (
            "R02 declared-software-function acceptance execution",
            "repository-safe transcript derived from the bound xcresult summary",
            f"source_commit: {SOURCE_COMMIT}",
            f"source_tree: {SOURCE_TREE}",
            "execution_mode: deterministic_fixture_execution",
            "platform: macos_host",
            "architecture: arm64",
            "",
            "Command line invocation:",
            f"    {XCODEBUILD_COMMAND}",
            "",
            *suite_lines,
            "",
            "Test Suite 'Selected tests' passed.",
            (
                f"    Executed {EXPECTED_SELECTED_TEST_COUNT} tests, with "
                "0 failures (0 unexpected), 0 skipped."
            ),
            "",
            "** TEST SUCCEEDED **",
            "",
        )
    )


class R02PhaseAcceptanceVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
        )

    def _read_json(
        self, relative: Path, context: str, errors: list[str]
    ) -> dict[str, Any] | None:
        path = self.root / relative
        if path.is_symlink() or not path.is_file():
            errors.append(f"{context} must be a regular non-symlink file")
            return None
        try:
            value = decode_json(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{context} is invalid: {error}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return None
        return value

    def _file_binding(self, identifier: str, relative: Path) -> dict[str, object]:
        payload = (self.root / relative).read_bytes()
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    def _checkpoint_file_binding(
        self,
        identifier: str,
        relative: Path,
    ) -> dict[str, object]:
        historical = self.git_bytes(
            "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
        )
        if historical.returncode != 0:
            raise OSError(
                "checkpoint path is unavailable: "
                f"{relative.as_posix()}"
            )
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(historical.stdout),
            "sha256": _sha256(historical.stdout),
        }

    def _source_errors(self) -> list[str]:
        errors: list[str] = []
        commit = self.git("cat-file", "-e", f"{SOURCE_COMMIT}^{{commit}}")
        if commit.returncode != 0:
            return ["R02 acceptance source commit is unavailable"]
        tree = self.git("rev-parse", f"{SOURCE_COMMIT}^{{tree}}")
        if tree.returncode != 0 or tree.stdout.strip() != SOURCE_TREE:
            errors.append("R02 acceptance source tree differs")
        ancestor = self.git("merge-base", "--is-ancestor", SOURCE_COMMIT, "HEAD")
        if ancestor.returncode != 0:
            errors.append("R02 acceptance source commit is not an ancestor of HEAD")

        for relative in SOURCE_BUILD_PATHS:
            checkpoint_entry = self.git(
                "cat-file",
                "-e",
                f"{SOURCE_COMMIT}:{relative.as_posix()}",
            )
            if checkpoint_entry.returncode != 0:
                errors.append(
                    "R02 acceptance checkpoint build input is unavailable: "
                    f"{relative.as_posix()}"
                )

        for identifier, relative in EVIDENCE_PATHS:
            path = self.root / relative
            if path.is_symlink() or not path.is_file():
                errors.append(f"R02 acceptance source is absent: {identifier}")
                continue
            historical = self.git_bytes(
                "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            )
            if historical.returncode != 0 or historical.stdout != path.read_bytes():
                errors.append(f"R02 acceptance source differs: {identifier}")
        for identifier, relative in IMPLEMENTATION_PATHS:
            historical = self.git_bytes(
                "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            )
            if historical.returncode != 0:
                errors.append(
                    "R02 acceptance checkpoint source is unavailable: "
                    f"{identifier}"
                )
        return errors

    @staticmethod
    def _privacy_errors(value: object, context: str = "$") -> list[str]:
        errors: list[str] = []
        if isinstance(value, dict):
            for key, item in value.items():
                normalized = re.sub(r"[^a-z0-9]+", "_", key.lower()).strip("_")
                if normalized in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"private evidence key is forbidden: {context}.{key}")
                errors.extend(
                    R02PhaseAcceptanceVerifier._privacy_errors(
                        item, f"{context}.{key}"
                    )
                )
        elif isinstance(value, list):
            for index, item in enumerate(value):
                errors.extend(
                    R02PhaseAcceptanceVerifier._privacy_errors(
                        item, f"{context}[{index}]"
                    )
                )
        elif isinstance(value, str):
            if EMAIL_PATTERN.search(value):
                errors.append(f"email address is forbidden: {context}")
            if PRIVATE_PATH_PATTERN.search(value):
                errors.append(f"private path is forbidden: {context}")
            if LABELED_PRIVATE_VALUE_PATTERN.search(value):
                errors.append(f"labeled private value is forbidden: {context}")
        return errors

    @staticmethod
    def _functional_evidence_errors(
        conformance: dict[str, Any],
    ) -> list[str]:
        errors: list[str] = []
        result = conformance.get("result")
        if not isinstance(result, dict) or result.get("status") != "passed":
            errors.append("R02 deterministic software conformance did not pass")

        checks = conformance.get("checks")
        expected_checks = [
            {"id": check_id, "status": "passed"}
            for check_id in CONFORMANCE_CHECK_IDS
        ]
        if checks != expected_checks:
            errors.append("R02 functional conformance checks are not exactly passed")

        metrics = result.get("metrics") if isinstance(result, dict) else None
        metric_by_id = (
            {
                metric.get("id"): metric
                for metric in metrics
                if isinstance(metric, dict)
            }
            if isinstance(metrics, list)
            else {}
        )
        if set(metric_by_id) != set(EXPECTED_CONFORMANCE_METRIC_VALUES):
            errors.append("R02 functional metric coverage differs")
        else:
            for metric_id, expected_value in EXPECTED_CONFORMANCE_METRIC_VALUES.items():
                metric = metric_by_id[metric_id]
                if (
                    metric.get("value") != expected_value
                    or metric.get("passed") is not True
                ):
                    errors.append(f"R02 functional metric did not pass: {metric_id}")

        runs = conformance.get("backend_runs")
        if (
            not isinstance(runs, list)
            or [
                run.get("identity", {}).get("backend_id")
                for run in runs
                if isinstance(run, dict)
            ]
            != list(FIXTURE_BACKEND_IDS)
            or any(
                not isinstance(run, dict) or run.get("result") != "passed"
                for run in runs
            )
        ):
            errors.append("R02 common-session backend coverage differs")

        observation = conformance.get("observation_status")
        if observation != EXPECTED_CONFORMANCE_OBSERVATION_STATUS:
            errors.append("R02 observation boundary differs")

        authorization = result.get("authorization") if isinstance(result, dict) else None
        if not isinstance(authorization, dict) or (
            authorization.get("phase_acceptance") != "not_claimed"
            or authorization.get("product_eligibility") != "not_authorized"
            or authorization.get("production_enablement") != "not_authorized"
            or authorization.get("auto_mode") != "blocked"
            or authorization.get("holdout") != "blocked"
            or authorization.get("performance_claims") != "forbidden"
        ):
            errors.append("R02 frozen conformance authorization boundary differs")

        production = (
            result.get("production_composition") if isinstance(result, dict) else None
        )
        if not isinstance(production, dict) or (
            production.get("status") != "unavailable"
            or production.get("fixture_backend_reachable") is not False
        ):
            errors.append("R02 production-unavailable boundary differs")
        return errors

    @staticmethod
    def _summary_errors(summary: dict[str, Any]) -> list[str]:
        errors: list[str] = []
        expected = _expected_summary()
        if summary != expected:
            errors.append(
                "R02 selected-test summary differs from the exact xcresult extraction"
            )
        return errors

    @staticmethod
    def _raw_xcresult_errors(
        summary: dict[str, Any],
        tests: dict[str, Any],
        build_results: dict[str, Any],
        checked_summary: dict[str, Any],
    ) -> list[str]:
        errors: list[str] = []
        expected_count = checked_summary.get("expected_selected_test_count")
        if not isinstance(expected_count, int) or expected_count < 1:
            errors.append("R02 checked summary selected test count is invalid")
            expected_count = EXPECTED_SELECTED_TEST_COUNT
        expected_summary_values = {
            "result": "Passed",
            "totalTestCount": expected_count,
            "passedTests": expected_count,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
        }
        for key, expected in expected_summary_values.items():
            if summary.get(key) != expected:
                errors.append(
                    f"R02 raw xcresult summary {key} differs: "
                    f"expected {expected!r}"
                )
        if summary.get("testFailures") != []:
            errors.append("R02 raw xcresult contains test failures")

        checked_toolchain = checked_summary.get("toolchain")
        expected_platform = (
            checked_toolchain.get("platform")
            if isinstance(checked_toolchain, dict)
            else None
        )
        expected_architecture = (
            checked_toolchain.get("architecture")
            if isinstance(checked_toolchain, dict)
            else None
        )
        configurations = summary.get("devicesAndConfigurations")
        if not isinstance(configurations, list) or len(configurations) != 1:
            errors.append(
                "R02 raw xcresult must contain exactly one device configuration"
            )
        else:
            configuration = configurations[0]
            if not isinstance(configuration, dict):
                errors.append("R02 raw xcresult device configuration is invalid")
            else:
                for key, expected in {
                    "passedTests": expected_count,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                }.items():
                    if configuration.get(key) != expected:
                        errors.append(
                            "R02 raw xcresult device configuration "
                            f"{key} differs: expected {expected!r}"
                        )
                device = configuration.get("device")
                if not isinstance(device, dict) or (
                    expected_platform != "macos_host"
                    or device.get("platform") != "macOS"
                    or device.get("architecture") != expected_architecture
                ):
                    errors.append(
                        "R02 raw xcresult device must be macOS arm64"
                    )

        raw_start = summary.get("startTime")
        raw_finish = summary.get("finishTime")
        if (
            not isinstance(raw_start, (int, float))
            or not isinstance(raw_finish, (int, float))
            or raw_finish < raw_start
        ):
            errors.append("R02 raw xcresult timestamps are invalid")

        expected_build = {
            "actionTitle": "Testing project Mirmir with scheme Mirmir",
            "status": "succeeded",
            "errorCount": 0,
            "errors": [],
        }
        for key, expected in expected_build.items():
            if build_results.get(key) != expected:
                errors.append(
                    f"R02 raw xcresult build {key} differs: expected {expected!r}"
                )
        destination = build_results.get("destination")
        if not isinstance(destination, dict) or (
            destination.get("platform") != "macOS"
            or destination.get("architecture") != expected_architecture
        ):
            errors.append("R02 raw xcresult build destination must be macOS arm64")
        if (
            build_results.get("startTime") != raw_start
            or build_results.get("endTime") != raw_finish
        ):
            errors.append(
                "R02 raw xcresult test and build timestamps must match exactly"
            )

        test_cases: list[dict[str, Any]] = []

        def collect(value: object) -> None:
            if isinstance(value, dict):
                if value.get("nodeType") == "Test Case":
                    test_cases.append(value)
                for item in value.values():
                    collect(item)
            elif isinstance(value, list):
                for item in value:
                    collect(item)

        collect(tests)
        expected_identities: set[tuple[str, str]] = set()
        checked_suites = checked_summary.get("test_suites")
        if not isinstance(checked_suites, list):
            errors.append("R02 checked summary test suites are invalid")
        else:
            for suite in checked_suites:
                if not isinstance(suite, dict) or not isinstance(
                    suite.get("id"), str
                ):
                    errors.append("R02 checked summary suite identity is invalid")
                    continue
                suite_id = suite["id"]
                checked_tests = suite.get("tests")
                if not isinstance(checked_tests, list):
                    errors.append(
                        f"R02 checked summary tests are invalid: {suite_id}"
                    )
                    continue
                for test in checked_tests:
                    if not isinstance(test, dict) or not isinstance(
                        test.get("id"), str
                    ):
                        errors.append(
                            f"R02 checked summary test identity is invalid: {suite_id}"
                        )
                        continue
                    expected_identities.add((suite_id, test["id"]))
        observed_identities: list[tuple[str, str]] = []
        for test_case in test_cases:
            identifier = test_case.get("nodeIdentifier")
            name = test_case.get("name")
            result = test_case.get("result")
            if not isinstance(identifier, str) or not isinstance(name, str):
                errors.append("R02 raw xcresult contains an invalid test identity")
                continue
            suite_id, separator, identifier_test = identifier.partition("/")
            if not separator or identifier_test != name:
                errors.append(
                    f"R02 raw xcresult test identifier is malformed: {identifier!r}"
                )
                continue
            observed_identities.append((suite_id, name))
            if result != "Passed":
                errors.append(
                    f"R02 raw xcresult test did not pass: {identifier}"
                )

        if len(observed_identities) != expected_count:
            errors.append(
                "R02 raw xcresult selected test count differs: "
                f"expected {expected_count}, found {len(observed_identities)}"
            )
        if len(observed_identities) != len(set(observed_identities)):
            errors.append("R02 raw xcresult contains duplicate test identities")
        if set(observed_identities) != expected_identities:
            missing = sorted(expected_identities - set(observed_identities))
            unexpected = sorted(set(observed_identities) - expected_identities)
            errors.append(
                "R02 raw xcresult suite/test identities differ: "
                f"missing={missing!r}, unexpected={unexpected!r}"
            )
        return errors

    def _read_xcresult_section(
        self,
        result_path: Path,
        section: str,
        errors: list[str],
    ) -> dict[str, Any] | None:
        command = [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            section,
            "--path",
            str(result_path),
            "--compact",
        ]
        try:
            result = subprocess.run(
                command,
                cwd=self.root,
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            errors.append(
                f"R02 raw xcresult {section} extraction failed: {error}"
            )
            return None
        if result.returncode != 0:
            detail = result.stderr.strip()
            errors.append(
                f"R02 raw xcresult {section} extraction failed"
                + (f": {detail}" if detail else "")
            )
            return None
        try:
            value = decode_json(result.stdout)
        except (ValueError, json.JSONDecodeError) as error:
            errors.append(
                f"R02 raw xcresult {section} output is invalid: {error}"
            )
            return None
        if not isinstance(value, dict):
            errors.append(f"R02 raw xcresult {section} output must be an object")
            return None
        return value

    def _read_xcresult_build_results(
        self,
        result_path: Path,
        errors: list[str],
    ) -> dict[str, Any] | None:
        command = [
            "xcrun",
            "xcresulttool",
            "get",
            "build-results",
            "--path",
            str(result_path),
            "--compact",
        ]
        try:
            result = subprocess.run(
                command,
                cwd=self.root,
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            errors.append(
                f"R02 raw xcresult build-results extraction failed: {error}"
            )
            return None
        if result.returncode != 0:
            detail = result.stderr.strip()
            errors.append(
                "R02 raw xcresult build-results extraction failed"
                + (f": {detail}" if detail else "")
            )
            return None
        try:
            value = decode_json(result.stdout)
        except (ValueError, json.JSONDecodeError) as error:
            errors.append(
                f"R02 raw xcresult build-results output is invalid: {error}"
            )
            return None
        if not isinstance(value, dict):
            errors.append(
                "R02 raw xcresult build-results output must be an object"
            )
            return None
        return value

    def check_xcresult(self, result_path: Path) -> list[str]:
        path = result_path if result_path.is_absolute() else self.root / result_path
        errors: list[str] = []
        if path.is_symlink() or not path.is_dir():
            return [
                "R02 raw xcresult must be an existing non-symlink result bundle"
            ]
        checked_summary = self._read_json(
            XCRESULT_SUMMARY_PATH,
            "R02 checked xcresult summary",
            errors,
        )
        if checked_summary is not None:
            errors.extend(self._summary_errors(checked_summary))
        errors.extend(self._source_errors())
        summary = self._read_xcresult_section(path, "summary", errors)
        tests = self._read_xcresult_section(path, "tests", errors)
        build_results = self._read_xcresult_build_results(path, errors)
        if (
            summary is not None
            and tests is not None
            and build_results is not None
            and checked_summary is not None
        ):
            errors.extend(
                self._raw_xcresult_errors(
                    summary,
                    tests,
                    build_results,
                    checked_summary,
                )
            )
        return sorted(set(errors))

    def _artifact_errors(
        self, summary: dict[str, Any] | None = None
    ) -> list[str]:
        errors: list[str] = []
        if summary is None:
            summary = self._read_json(
                XCRESULT_SUMMARY_PATH, "R02 xcresult summary", errors
            )
        if summary is not None:
            errors.extend(self._summary_errors(summary))
            errors.extend(self._privacy_errors(summary, "xcresult_summary"))

        log_path = self.root / XCODEBUILD_LOG_PATH
        if log_path.is_symlink() or not log_path.is_file():
            errors.append("R02 xcodebuild log must be a regular non-symlink file")
        else:
            try:
                log = log_path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as error:
                errors.append(f"R02 xcodebuild log is invalid: {error}")
            else:
                if log != _expected_log():
                    errors.append("R02 xcodebuild log differs from the exact transcript")
                errors.extend(self._privacy_errors(log, "xcodebuild_log"))
        return errors

    def expected_record(self) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R02",
            "evidence_kind": "r02_operator_functional_phase_acceptance_v1",
            "source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE},
            "operator_override": dict(OPERATOR_OVERRIDE),
            "functional_gate": {
                "acceptance_scope": "declared_software_function_only",
                "execution_mode": "deterministic_fixture_execution",
                "required_test_suites": list(REQUIRED_TEST_SUITES),
                "required_selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "required_conformance_check_ids": list(CONFORMANCE_CHECK_IDS),
                "required_metric_ids": list(EXPECTED_CONFORMANCE_METRIC_VALUES),
                "hardware_simulator_operator_observation": (
                    "not_required_not_observed"
                ),
                "raw_xcresult_ci_validation": "required",
            },
            "comparison_policy": dict(COMPARISON_POLICY),
            "evidence_bindings": [
                self._file_binding(identifier, relative)
                for identifier, relative in EVIDENCE_PATHS
            ],
            "implementation_bindings": [
                self._checkpoint_file_binding(identifier, relative)
                for identifier, relative in IMPLEMENTATION_PATHS
            ],
            "artifact_bindings": [
                self._file_binding(identifier, relative)
                for identifier, relative in ARTIFACT_PATHS
            ],
            "derived_checks": [
                {"id": check_id, "status": "passed"}
                for check_id in FUNCTIONAL_CHECK_IDS
            ],
            "result": dict(RESULT),
            "authorizations": dict(AUTHORIZATIONS),
            "limitations": list(LIMITATIONS),
        }

    def check(self) -> list[str]:
        errors = self._source_errors()
        errors.extend(R02ContractVerifier(self.root).check_conformance())

        conformance = self._read_json(
            CONFORMANCE_PATH, "R02 deterministic conformance", errors
        )
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R02 xcresult summary", errors
        )
        record = self._read_json(ACCEPTANCE_PATH, "R02 phase acceptance", errors)
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R02 phase acceptance schema", errors
        )

        if conformance is not None:
            errors.extend(self._functional_evidence_errors(conformance))
        errors.extend(self._artifact_errors(summary))

        if record is not None:
            errors.extend(self._privacy_errors(record, "acceptance"))
        if record is not None and schema is not None:
            errors.extend(
                f"R02 phase acceptance schema: {error}"
                for error in validate_json_schema_instance(schema, record)
            )
        if record is not None:
            try:
                expected = self.expected_record()
            except OSError as error:
                errors.append(f"R02 acceptance binding source is unavailable: {error}")
            else:
                if record != expected:
                    errors.append(
                        "R02 phase acceptance is not exactly derived from bound "
                        "software evidence"
                    )
        return sorted(set(errors))

    def _write_output(self, path: Path, payload: bytes) -> list[str]:
        try:
            relative = path.relative_to(self.root)
        except ValueError:
            return ["R02 evidence output must remain inside the repository"]

        current = self.root
        for component in relative.parts[:-1]:
            current /= component
            if current.is_symlink():
                return [
                    "R02 evidence output parent must not be a symlink: "
                    f"{current}"
                ]
        if path.is_symlink() or path.exists() and not path.is_file():
            return [
                "R02 evidence output must be absent or a regular non-symlink file"
            ]

        temporary_path: Path | None = None
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                dir=path.parent,
                prefix=f".{path.name}.",
                suffix=".tmp",
                delete=False,
            ) as temporary:
                temporary.write(payload)
                temporary.flush()
                os.fsync(temporary.fileno())
                temporary_path = Path(temporary.name)
            os.replace(temporary_path, path)
        except OSError as error:
            return [f"R02 evidence output write failed: {error}"]
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink(missing_ok=True)
                except OSError:
                    pass
        return []

    def write(self) -> list[str]:
        errors = self._source_errors()
        errors.extend(R02ContractVerifier(self.root).check_conformance())
        conformance = self._read_json(
            CONFORMANCE_PATH, "R02 deterministic conformance", errors
        )
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R02 xcresult summary", errors
        )
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R02 phase acceptance schema", errors
        )
        if conformance is not None:
            errors.extend(self._functional_evidence_errors(conformance))
        errors.extend(self._artifact_errors(summary))
        if schema is None or errors:
            return sorted(set(errors))

        record = self.expected_record()
        errors.extend(
            f"R02 phase acceptance schema: {error}"
            for error in validate_json_schema_instance(schema, record)
        )
        errors.extend(self._privacy_errors(record, "acceptance"))
        if errors:
            return sorted(set(errors))

        payload = (
            json.dumps(record, indent=2, ensure_ascii=False) + "\n"
        ).encode("utf-8")
        errors.extend(
            self._write_output(
                self.root / ACCEPTANCE_PATH,
                payload,
            )
        )
        if errors:
            return sorted(set(errors))
        return self.check()


def emit_errors(errors: Iterable[str]) -> int:
    observed = list(errors)
    if not observed:
        return 0
    for error in observed:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--write", action="store_true")
    group.add_argument(
        "--check-xcresult",
        type=Path,
        metavar="PATH",
        help="validate an independently produced raw Xcode result bundle",
    )
    arguments = parser.parse_args(argv)
    verifier = R02PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    if arguments.write:
        errors = verifier.write()
    elif arguments.check_xcresult is not None:
        errors = verifier.check_xcresult(arguments.check_xcresult)
    else:
        errors = verifier.check()
    if not errors:
        print("R02 declared-software-function phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
