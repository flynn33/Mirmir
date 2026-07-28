#!/usr/bin/env python3
"""Derive and validate R05 declared-software-function phase acceptance."""

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
from r05_contracts import (
    CHECK_IDS as FROZEN_CHECK_IDS,
    CONFORMANCE_PATH,
    CONFORMANCE_RESULT as FROZEN_CONFORMANCE_RESULT,
    CONFORMANCE_SCHEMA_PATH,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    NOT_OBSERVED_CHECK_IDS,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    R05ContractVerifier,
    SUBJECT_IDENTITIES as FROZEN_SUBJECT_IDENTITIES,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r05/records/functional-phase-acceptance.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r05-functional-phase-acceptance-v1.json"
)
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r05/records/artifacts/functional-phase-acceptance"
)
XCODEBUILD_LOG_PATH = ARTIFACT_DIRECTORY / "xcodebuild.log"
XCRESULT_SUMMARY_PATH = ARTIFACT_DIRECTORY / "xcresult-summary.json"

SOURCE_COMMIT = "7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8"
SOURCE_TREE = "adce5b65fd3d752a1467925232847e086d0b3e7a"
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
    "-derivedDataPath /private/tmp/mirmir-r05-7e1ab673-derived "
    "-resultBundlePath /private/tmp/mirmir-r05-7e1ab673.xcresult "
    "-disableAutomaticPackageResolution test "
    "-only-testing:MirmirTests/R05MetalFXContractsTests "
    "-only-testing:MirmirTests/R05MetalFXColorBridgeTests "
    "-only-testing:MirmirTests/R05MetalFXSpatialDriverTests "
    "-only-testing:MirmirTests/R05MetalFXSpatialBackendTests "
    "-only-testing:MirmirTests/R05FunctionalPhaseAcceptanceTests "
    "'EXCLUDED_SOURCE_FILE_NAMES=*.metal' CODE_SIGNING_ALLOWED=NO"
)

EVIDENCE_PATHS = (
    ("r05_preregistration", PREREGISTRATION_PATH),
    ("r05_fixture_catalog", FIXTURE_CATALOG_PATH),
    ("r05_suitability_conformance", CONFORMANCE_PATH),
    ("r05_preregistration_schema", PREREGISTRATION_SCHEMA_PATH),
    ("r05_fixture_catalog_schema", FIXTURE_CATALOG_SCHEMA_PATH),
    ("r05_suitability_conformance_schema", CONFORMANCE_SCHEMA_PATH),
)

IMPLEMENTATION_PATHS = (
    (
        "apple_upscale_contracts_source",
        Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleContracts.swift"),
    ),
    (
        "apple_upscale_fifo_session_source",
        Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleFIFOSession.swift"),
    ),
    (
        "r05_metalfx_contracts_source",
        Path("Mirmir/Modules/UpscalerEngine/R05MetalFXContracts.swift"),
    ),
    (
        "r05_metalfx_color_bridge_source",
        Path("Mirmir/Modules/UpscalerEngine/R05MetalFXColorBridge.swift"),
    ),
    (
        "r05_metalfx_spatial_driver_source",
        Path("Mirmir/Modules/UpscalerEngine/R05MetalFXSpatialDriver.swift"),
    ),
    (
        "r05_metalfx_spatial_backend_source",
        Path("Mirmir/Modules/UpscalerEngine/R05MetalFXSpatialBackend.swift"),
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
        "atomic_media_output_source",
        Path("Mirmir/Modules/MediaPipeline/AtomicMediaOutput.swift"),
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
        "r03_nv12_scaling_source",
        Path("Mirmir/Modules/UpscalerEngine/R03NV12Scaling.swift"),
    ),
    (
        "r05_metalfx_contracts_tests",
        Path("MirmirTests/R05MetalFXContractsTests.swift"),
    ),
    (
        "r05_metalfx_color_bridge_tests",
        Path("MirmirTests/R05MetalFXColorBridgeTests.swift"),
    ),
    (
        "r05_metalfx_spatial_driver_tests",
        Path("MirmirTests/R05MetalFXSpatialDriverTests.swift"),
    ),
    (
        "r05_metalfx_spatial_backend_tests",
        Path("MirmirTests/R05MetalFXSpatialBackendTests.swift"),
    ),
    (
        "r05_functional_phase_acceptance_tests",
        Path("MirmirTests/R05FunctionalPhaseAcceptanceTests.swift"),
    ),
    (
        "r02_fixture_conformance_test_support",
        Path("MirmirTests/R02FixtureConformanceTestSupport.swift"),
    ),
    (
        "r03_product_qualification_media_test_support",
        Path("MirmirTests/R03ProductQualificationMediaTestSupport.swift"),
    ),
    ("noop_services_tests", Path("MirmirTests/NoopServices.swift")),
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
    ("r05_functional_xcodebuild_log", XCODEBUILD_LOG_PATH),
    ("r05_functional_xcresult_summary", XCRESULT_SUMMARY_PATH),
)

REQUIRED_TEST_SUITES = (
    "R05MetalFXContractsTests",
    "R05MetalFXColorBridgeTests",
    "R05MetalFXSpatialDriverTests",
    "R05MetalFXSpatialBackendTests",
    "R05FunctionalPhaseAcceptanceTests",
)

EXPECTED_SUITE_TESTS = (
    (
        "R05MetalFXContractsTests",
        (
            "testCatalogMatchesFrozenSevenSubjectRouteMatrixExactly()",
            "testDecodedVideoRejectionsRemainFirstEvenForProductAdmission()",
            "testDescriptorRejectsSpatialOrDecodedVideoContractDrift()",
            "testEveryA08A09AndA10RouteRejectsBeforeSupportOrFactoryProbe()",
            "testEveryRouteForbidsProductScopeFallbackAndQualificationClaims()",
            "testFrozenColorBridgeMatchesCatalogExactly()",
            (
                "testNotObservedCapabilityRegistryPreservesFrozenRolesAnd"
                "ProductIneligibility()"
            ),
            "testScaleFactorsNormalizeAndRejectInvalidOrMismatchedRoutes()",
            "testSpatialNilConstructionIsTypedUnavailabilityWithoutFallback()",
            "testSpatialProductAdmissionRejectsBeforeSupportOrFactoryProbe()",
            "testSpatialSupportQueryPrecedesConstruction()",
            "testSpatialUnavailableSupportNeverCallsFactory()",
            "testStableRouteAndProcessingIdentitiesContainNoFallback()",
        ),
    ),
    (
        "R05MetalFXColorBridgeTests",
        (
            "testBT709TransferFunctionsAreInverseAcrossLegalLumaCodes()",
            "testDecodeInterpolatesCenteredChromaVertically()",
            "testDecodeInterpolatesLeftSitedChromaHorizontally()",
            "testDecodeMapsLegalBlackAndWhiteToLinearEndpoints()",
            "testEncodeAveragesVerticallyForCenteredChroma()",
            "testEncodeRejectsNonFiniteOutOfRangeAndNonOpaqueComponents()",
            "testEncodeSamplesEvenColumnsForLeftSitedChroma()",
            "testEncodeUsesBT709VideoRangeCodesForPrimaryColors()",
            "testFrameInitializersRejectInsufficientStorage()",
            "testFrameInitializersRejectOddDimensionsAndInvalidRows()",
            "testPixelBufferEncodeRejectsDimensionMismatch()",
            "testPixelBufferWrapperRejectsMissingAttachment()",
            "testPixelBufferWrapperRejectsWrongFormat()",
            "testPixelBufferWrappersRequireExactContractAndCopyActiveRows()",
        ),
    ),
    (
        "R05MetalFXSpatialDriverTests",
        (
            "testBothRoutesConfigureLinearRGBA16FloatAndOrderedPipeline()",
            "testCommandFailureDoesNotFinalizeOrPublish()",
            "testDeviceSupportGuardPrecedesDescriptorFactoryAndEncoding()",
            "testFinalizationFailureIsTypedAndPublicationIsSuppressed()",
            "testGeometryMismatchRejectsBeforeSupportQuery()",
            "testMutableScalerUseRemainsSerializedAcrossCommandCompletion()",
            "testNilScalerFactoryIsTypedUnavailableWithoutSilentFallback()",
            "testPostCommitCancellationSuppressesFinalizationAndPublication()",
            "testPrecommitCancellationDoesNotQuerySupportOrPublish()",
        ),
    ),
    (
        "R05MetalFXSpatialBackendTests",
        (
            "testBothSpatialRoutesPreserveIdentityAttachmentsAndLifetimes()",
            "testDecodedVideoRoutesRejectBeforeFactoryForFixtureAndProduct()",
            "testEveryClosedDriverOutcomeMapsCategoryReasonAndReleases()",
            "testInputContractMismatchRejectsBeforeDriverAndOutputAllocation()",
            "testMalformedProcessedResultsFailClosed()",
            "testNilNativeFactoryIsTypedUnavailableWithoutFallback()",
            "testSpatialProductAndNotObservedCapabilityNeverConstructDriver()",
            "testWrongConfigurationPolicyAndCapabilityRejectBeforeFactory()",
        ),
    ),
    (
        "R05FunctionalPhaseAcceptanceTests",
        (
            "testBothSpatialRoutesProcessSourceDerivedFramesThroughProductionFIFO()",
            (
                "testSpatial2xCompletesVerifiedMediaTransactionBeforeAtomic"
                "Publication()"
            ),
        ),
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
    "seven_subject_route_contract",
    "a07_spatial_exact_routes",
    "a08_a09_a10_typed_decoded_video_rejection",
    "product_admission_rejects_before_probe",
    "bt709_nv12_linear_rgba_color_bridge",
    "support_query_before_construction",
    "simulated_spatial_driver_ordering",
    "fifo_identity_timing_and_lifetime",
    "closed_failure_and_cancellation_outcomes",
    "media_identity_preserved",
    "reopen_verification_before_atomic_publication",
    "no_silent_fallback",
    "native_observation_boundary_truthful",
    "authorization_boundary_exact",
)

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "authorization_date": "2026-07-23",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "override_id": "r05.software-function-only-diagnostic-acceptance.v1",
    "hardware_simulator_operator_observation": "waived_not_a_blocker",
    "comparative_requirement": "not_required_for_phase_acceptance",
    "historical_evidence_policy": (
        "preserve_r05_preregistration_fixture_and_conformance_unchanged"
    ),
}

RESULT = {
    "status": "passed",
    "phase_status_before": "in_progress",
    "phase_status_after": "passed",
    "acceptance": "accepted",
    "exit_outcome": "diagnostic_only",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_simulated_runtime_integration",
}

AUTHORIZATIONS = {
    "r05_functional_disposition": "diagnostic_only",
    "r05_phase_status": "passed",
    "phase_progression": "authorized",
    "deterministic_simulated_runtime_integration": "authorized",
    "a08_a09_a10_decoded_video_rejection": "validated",
    "native_metalfx_execution": "not_claimed",
    "hardware_observation": "not_claimed",
    "simulator_observation": "not_claimed",
    "operator_observation": "not_claimed",
    "comparative_evaluation": "not_claimed",
    "product_qualification": "not_claimed",
    "production_upscaling": "not_authorized",
    "production_default": "not_authorized",
    "auto_mode": "not_authorized",
    "holdout": "not_authorized",
    "quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "product_publication": "not_authorized",
    "release": "not_authorized",
}

LIMITATIONS = (
    "R05 passed its declared-software-function phase gate with a diagnostic_only "
    "exit outcome: checkpoint-bound deterministic tests prove the declared route, "
    "rejection, color-bridge, driver, backend, FIFO, lifecycle, and "
    "media-transaction software behavior with simulated runtimes.",
    "Typed A08, A09, and A10 decoded-video rejection is the successful declared "
    "behavior because required renderer semantics are absent and never fabricated.",
    "A07 native MetalFX execution, hardware, simulator, operator observation, "
    "comparison, quality, and performance were not observed or claimed; the "
    "optional Metal shader source was excluded because the Metal Toolchain was "
    "unavailable.",
    "R05's diagnostic functional disposition does not authorize product "
    "qualification, production upscaling, a product default, Auto, holdout, "
    "publication, or release.",
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
        "phase_id": "R05",
        "evidence_kind": "r05_functional_selected_test_summary_v1",
        "source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE},
        "execution_mode": "deterministic_simulated_runtime_integration",
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
            "R05 declared-software-function diagnostic execution",
            "repository-safe transcript derived from the bound xcresult summary",
            f"source_commit: {SOURCE_COMMIT}",
            f"source_tree: {SOURCE_TREE}",
            "execution_mode: deterministic_simulated_runtime_integration",
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


class R05PhaseAcceptanceVerifier:
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
        file_path = self.root / relative
        if file_path.is_symlink() or not file_path.is_file():
            errors.append(f"{context} must be a regular non-symlink file")
            return None
        try:
            value = decode_json(file_path.read_text(encoding="utf-8"))
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
        self, identifier: str, relative: Path
    ) -> dict[str, object]:
        historical = self.git_bytes(
            "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
        )
        if historical.returncode != 0:
            raise OSError(
                f"checkpoint path is unavailable: {relative.as_posix()}"
            )
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(historical.stdout),
            "sha256": _sha256(historical.stdout),
        }

    def _source_errors(self) -> list[str]:
        errors: list[str] = []
        if self.git("cat-file", "-e", f"{SOURCE_COMMIT}^{{commit}}").returncode:
            return ["R05 acceptance source commit is unavailable"]
        tree = self.git("rev-parse", f"{SOURCE_COMMIT}^{{tree}}")
        if tree.returncode != 0 or tree.stdout.strip() != SOURCE_TREE:
            errors.append("R05 acceptance source tree differs")
        if self.git(
            "merge-base", "--is-ancestor", SOURCE_COMMIT, "HEAD"
        ).returncode:
            errors.append("R05 acceptance source commit is not an ancestor of HEAD")

        for relative in SOURCE_BUILD_PATHS:
            if self.git(
                "cat-file", "-e", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            ).returncode:
                errors.append(
                    "R05 acceptance checkpoint build input is unavailable: "
                    f"{relative.as_posix()}"
                )
        for identifier, relative in EVIDENCE_PATHS:
            file_path = self.root / relative
            historical = self.git_bytes(
                "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            )
            if (
                file_path.is_symlink()
                or not file_path.is_file()
                or historical.returncode != 0
                or historical.stdout != file_path.read_bytes()
            ):
                errors.append(f"R05 frozen evidence differs: {identifier}")
        for identifier, relative in IMPLEMENTATION_PATHS:
            historical = self.git_bytes(
                "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            )
            if historical.returncode != 0:
                errors.append(
                    "R05 acceptance checkpoint source is unavailable: "
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
                    R05PhaseAcceptanceVerifier._privacy_errors(
                        item, f"{context}.{key}"
                    )
                )
        elif isinstance(value, list):
            for index, item in enumerate(value):
                errors.extend(
                    R05PhaseAcceptanceVerifier._privacy_errors(
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

    def _frozen_evidence_errors(self) -> list[str]:
        errors: list[str] = []
        frozen_verifier = R05ContractVerifier(self.root)
        errors.extend(frozen_verifier.check_preregistration())
        errors.extend(frozen_verifier.check_fixtures())
        conformance = self._read_json(
            CONFORMANCE_PATH, "R05 frozen suitability conformance", errors
        )
        schema = self._read_json(
            CONFORMANCE_SCHEMA_PATH,
            "R05 frozen suitability conformance schema",
            errors,
        )
        if conformance is not None and schema is not None:
            errors.extend(
                f"R05 frozen suitability conformance schema: {error}"
                for error in validate_json_schema_instance(schema, conformance)
            )
        if conformance is None:
            return errors
        if conformance.get("result") != FROZEN_CONFORMANCE_RESULT:
            errors.append("R05 frozen diagnostic result boundary differs")
        expected_observation = {
            "hardware_capability_observation": "not_observed",
            "simulator_execution": "not_observed",
            "operator_observed_operation": "not_observed",
            "quality_claims": "forbidden",
            "performance_claims": "forbidden",
        }
        if conformance.get("observation_status") != expected_observation:
            errors.append("R05 frozen observation boundary differs")
        expected_checks = [
            {
                "id": check_id,
                "status": (
                    "not_observed"
                    if check_id in NOT_OBSERVED_CHECK_IDS
                    else "passed"
                ),
            }
            for check_id in FROZEN_CHECK_IDS
        ]
        if conformance.get("checks") != expected_checks:
            errors.append("R05 frozen diagnostic check boundary differs")
        expected_subjects = [
            {
                "subject_id": identity[0],
                "execution_status": identity[5],
                "disposition": identity[6],
                "reason": identity[7],
            }
            for identity in FROZEN_SUBJECT_IDENTITIES
        ]
        if conformance.get("subject_results") != expected_subjects:
            errors.append("R05 frozen subject boundary differs")
        return errors

    @staticmethod
    def _summary_errors(summary: dict[str, Any]) -> list[str]:
        if summary != _expected_summary():
            return [
                "R05 selected-test summary differs from the exact xcresult extraction"
            ]
        return []

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
            errors.append("R05 checked summary selected test count is invalid")
            expected_count = EXPECTED_SELECTED_TEST_COUNT
        for key, expected in {
            "result": "Passed",
            "totalTestCount": expected_count,
            "passedTests": expected_count,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
        }.items():
            if summary.get(key) != expected:
                errors.append(
                    f"R05 raw xcresult summary {key} differs: expected {expected!r}"
                )
        if summary.get("testFailures") != []:
            errors.append("R05 raw xcresult contains test failures")

        toolchain = checked_summary.get("toolchain")
        expected_platform = (
            toolchain.get("platform") if isinstance(toolchain, dict) else None
        )
        expected_architecture = (
            toolchain.get("architecture") if isinstance(toolchain, dict) else None
        )
        configurations = summary.get("devicesAndConfigurations")
        if not isinstance(configurations, list) or len(configurations) != 1:
            errors.append(
                "R05 raw xcresult must contain exactly one device configuration"
            )
        else:
            configuration = configurations[0]
            if not isinstance(configuration, dict):
                errors.append("R05 raw xcresult device configuration is invalid")
            else:
                for key, expected in {
                    "passedTests": expected_count,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                }.items():
                    if configuration.get(key) != expected:
                        errors.append(
                            "R05 raw xcresult device configuration "
                            f"{key} differs: expected {expected!r}"
                        )
                device = configuration.get("device")
                if not isinstance(device, dict) or (
                    expected_platform != "macos_host"
                    or device.get("platform") != "macOS"
                    or device.get("architecture") != expected_architecture
                ):
                    errors.append("R05 raw xcresult device must be macOS arm64")

        raw_start = summary.get("startTime")
        raw_finish = summary.get("finishTime")
        if (
            not isinstance(raw_start, (int, float))
            or not isinstance(raw_finish, (int, float))
            or raw_finish < raw_start
        ):
            errors.append("R05 raw xcresult timestamps are invalid")
        for key, expected in {
            "actionTitle": "Testing project Mirmir with scheme Mirmir",
            "status": "succeeded",
            "errorCount": 0,
            "errors": [],
        }.items():
            if build_results.get(key) != expected:
                errors.append(
                    f"R05 raw xcresult build {key} differs: expected {expected!r}"
                )
        destination = build_results.get("destination")
        if not isinstance(destination, dict) or (
            destination.get("platform") != "macOS"
            or destination.get("architecture") != expected_architecture
        ):
            errors.append("R05 raw xcresult build destination must be macOS arm64")
        if (
            build_results.get("startTime") != raw_start
            or build_results.get("endTime") != raw_finish
        ):
            errors.append(
                "R05 raw xcresult test and build timestamps must match exactly"
            )

        expected_identities: set[tuple[str, str]] = set()
        checked_suites = checked_summary.get("test_suites")
        if not isinstance(checked_suites, list):
            errors.append("R05 checked summary test suites are invalid")
        else:
            for suite in checked_suites:
                if not isinstance(suite, dict) or not isinstance(
                    suite.get("id"), str
                ):
                    errors.append("R05 checked summary suite identity is invalid")
                    continue
                checked_tests = suite.get("tests")
                if not isinstance(checked_tests, list):
                    errors.append("R05 checked summary tests are invalid")
                    continue
                for test in checked_tests:
                    if not isinstance(test, dict) or not isinstance(
                        test.get("id"), str
                    ):
                        errors.append("R05 checked summary test identity is invalid")
                        continue
                    expected_identities.add((suite["id"], test["id"]))

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
        observed_identities: list[tuple[str, str]] = []
        for test_case in test_cases:
            identifier = test_case.get("nodeIdentifier")
            name = test_case.get("name")
            if not isinstance(identifier, str) or not isinstance(name, str):
                errors.append("R05 raw xcresult contains an invalid test identity")
                continue
            suite_id, separator, identifier_test = identifier.partition("/")
            if not separator or identifier_test != name:
                errors.append(
                    f"R05 raw xcresult test identifier is malformed: {identifier!r}"
                )
                continue
            observed_identities.append((suite_id, name))
            if test_case.get("result") != "Passed":
                errors.append(f"R05 raw xcresult test did not pass: {identifier}")
        if len(observed_identities) != expected_count:
            errors.append(
                "R05 raw xcresult selected test count differs: "
                f"expected {expected_count}, found {len(observed_identities)}"
            )
        if len(observed_identities) != len(set(observed_identities)):
            errors.append("R05 raw xcresult contains duplicate test identities")
        if set(observed_identities) != expected_identities:
            missing = sorted(expected_identities - set(observed_identities))
            unexpected = sorted(set(observed_identities) - expected_identities)
            errors.append(
                "R05 raw xcresult suite/test identities differ: "
                f"missing={missing!r}, unexpected={unexpected!r}"
            )
        return errors

    def _read_xcresult_json(
        self,
        result_path: Path,
        section: str,
        errors: list[str],
    ) -> dict[str, Any] | None:
        if section == "build-results":
            command = [
                "xcrun", "xcresulttool", "get", "build-results",
                "--path", str(result_path), "--compact",
            ]
        else:
            command = [
                "xcrun", "xcresulttool", "get", "test-results", section,
                "--path", str(result_path), "--compact",
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
                f"R05 raw xcresult {section} extraction failed: {error}"
            )
            return None
        if result.returncode != 0:
            detail = result.stderr.strip()
            errors.append(
                f"R05 raw xcresult {section} extraction failed"
                + (f": {detail}" if detail else "")
            )
            return None
        try:
            value = decode_json(result.stdout)
        except (ValueError, json.JSONDecodeError) as error:
            errors.append(
                f"R05 raw xcresult {section} output is invalid: {error}"
            )
            return None
        if not isinstance(value, dict):
            errors.append(f"R05 raw xcresult {section} output must be an object")
            return None
        return value

    def check_xcresult(self, result_path: Path) -> list[str]:
        result_bundle = (
            result_path if result_path.is_absolute() else self.root / result_path
        )
        errors: list[str] = []
        if result_bundle.is_symlink() or not result_bundle.is_dir():
            return [
                "R05 raw xcresult must be an existing non-symlink result bundle"
            ]
        checked_summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R05 checked xcresult summary", errors
        )
        if checked_summary is not None:
            errors.extend(self._summary_errors(checked_summary))
        errors.extend(self._source_errors())
        summary = self._read_xcresult_json(result_bundle, "summary", errors)
        tests = self._read_xcresult_json(result_bundle, "tests", errors)
        build_results = self._read_xcresult_json(
            result_bundle, "build-results", errors
        )
        if (
            summary is not None
            and tests is not None
            and build_results is not None
            and checked_summary is not None
        ):
            errors.extend(
                self._raw_xcresult_errors(
                    summary, tests, build_results, checked_summary
                )
            )
        return sorted(set(errors))

    def _artifact_errors(
        self, summary: dict[str, Any] | None = None
    ) -> list[str]:
        errors: list[str] = []
        if summary is None:
            summary = self._read_json(
                XCRESULT_SUMMARY_PATH, "R05 xcresult summary", errors
            )
        if summary is not None:
            errors.extend(self._summary_errors(summary))
            errors.extend(self._privacy_errors(summary, "xcresult_summary"))
        log_path = self.root / XCODEBUILD_LOG_PATH
        if log_path.is_symlink() or not log_path.is_file():
            errors.append("R05 xcodebuild log must be a regular non-symlink file")
        else:
            try:
                log = log_path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as error:
                errors.append(f"R05 xcodebuild log is invalid: {error}")
            else:
                if log != _expected_log():
                    errors.append("R05 xcodebuild log differs from the exact transcript")
                errors.extend(self._privacy_errors(log, "xcodebuild_log"))
        return errors

    def expected_record(self) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R05",
            "evidence_kind": "r05_operator_functional_diagnostic_acceptance_v1",
            "source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE},
            "operator_override": dict(OPERATOR_OVERRIDE),
            "functional_gate": {
                "acceptance_scope": "declared_software_function_only",
                "execution_mode": "deterministic_simulated_runtime_integration",
                "required_test_suites": list(REQUIRED_TEST_SUITES),
                "required_selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "required_behavior_ids": list(FUNCTIONAL_CHECK_IDS),
                "successful_decoded_video_disposition": (
                    "a08_a09_a10_typed_rejection"
                ),
                "frozen_diagnostic_evidence_role": (
                    "preserved_boundary_only_not_acceptance_basis"
                ),
                "native_metalfx_execution": "not_required_not_observed",
                "hardware_simulator_operator_observation": (
                    "not_required_not_observed"
                ),
                "raw_xcresult_ci_validation": "required",
            },
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
        errors.extend(self._frozen_evidence_errors())
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R05 xcresult summary", errors
        )
        record = self._read_json(ACCEPTANCE_PATH, "R05 phase acceptance", errors)
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R05 phase acceptance schema", errors
        )
        errors.extend(self._artifact_errors(summary))
        if record is not None:
            errors.extend(self._privacy_errors(record, "acceptance"))
        if record is not None and schema is not None:
            errors.extend(
                f"R05 phase acceptance schema: {error}"
                for error in validate_json_schema_instance(schema, record)
            )
        if record is not None:
            try:
                expected = self.expected_record()
            except OSError as error:
                errors.append(f"R05 acceptance binding source is unavailable: {error}")
            else:
                if record != expected:
                    errors.append(
                        "R05 phase acceptance is not exactly derived from bound "
                        "software evidence"
                    )
        return sorted(set(errors))

    def _write_output(self, output_path: Path, payload: bytes) -> list[str]:
        try:
            relative = output_path.relative_to(self.root)
        except ValueError:
            return ["R05 evidence output must remain inside the repository"]
        current = self.root
        for component in relative.parts[:-1]:
            current /= component
            if current.is_symlink():
                return [
                    "R05 evidence output parent must not be a symlink: "
                    f"{current}"
                ]
        if (
            output_path.is_symlink()
            or output_path.exists()
            and not output_path.is_file()
        ):
            return [
                "R05 evidence output must be absent or a regular non-symlink file"
            ]
        temporary_path: Path | None = None
        try:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                dir=output_path.parent,
                prefix=f".{output_path.name}.",
                suffix=".tmp",
                delete=False,
            ) as temporary:
                temporary.write(payload)
                temporary.flush()
                os.fsync(temporary.fileno())
                temporary_path = Path(temporary.name)
            os.replace(temporary_path, output_path)
        except OSError as error:
            return [f"R05 evidence output write failed: {error}"]
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink(missing_ok=True)
                except OSError:
                    pass
        return []

    def write(self) -> list[str]:
        errors = self._source_errors()
        errors.extend(self._frozen_evidence_errors())
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R05 xcresult summary", errors
        )
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R05 phase acceptance schema", errors
        )
        errors.extend(self._artifact_errors(summary))
        if schema is None or errors:
            return sorted(set(errors))
        record = self.expected_record()
        errors.extend(
            f"R05 phase acceptance schema: {error}"
            for error in validate_json_schema_instance(schema, record)
        )
        errors.extend(self._privacy_errors(record, "acceptance"))
        if errors:
            return sorted(set(errors))
        payload = (
            json.dumps(record, indent=2, ensure_ascii=False) + "\n"
        ).encode("utf-8")
        errors.extend(self._write_output(self.root / ACCEPTANCE_PATH, payload))
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
    verifier = R05PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    if arguments.write:
        errors = verifier.write()
    elif arguments.check_xcresult is not None:
        errors = verifier.check_xcresult(arguments.check_xcresult)
    else:
        errors = verifier.check()
    if not errors:
        print("R05 declared-software-function phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
