#!/usr/bin/env python3
"""Derive and validate R06 declared-software-function phase acceptance."""

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
from r06_contracts import (
    ABLATION_IDS,
    CHECK_IDS as FROZEN_CHECK_IDS,
    CONFORMANCE_OBSERVATION,
    CONFORMANCE_PATH,
    CONFORMANCE_PRODUCT_GATE_RESULT,
    CONFORMANCE_RESULT,
    CONFORMANCE_SCHEMA_PATH,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FIXTURE_CHECK_IDS,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    R06ContractVerifier,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r06/records/functional-phase-acceptance.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r06-functional-phase-acceptance-v1.json"
)
PHASE_EVIDENCE_JSON_PATH = Path("docs/roadmaps/evidence/r06/phase-evidence.json")
PHASE_EVIDENCE_MARKDOWN_PATH = Path(
    "docs/roadmaps/evidence/r06/phase-evidence.md"
)
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r06/records/artifacts/functional-phase-acceptance"
)
XCODEBUILD_LOG_PATH = ARTIFACT_DIRECTORY / "xcodebuild.log"
XCRESULT_SUMMARY_PATH = ARTIFACT_DIRECTORY / "xcresult-summary.json"

SOURCE_COMMIT = "6c4a6d3d5f8a59c553b10c23783c148ccb3388a5"
SOURCE_TREE = "beb0f8c666550c6c36dae5a2185cac58d2494132"
ACCEPTANCE_SCHEMA_SIZE_BYTES = 11890
ACCEPTANCE_SCHEMA_SHA256 = (
    "312ee8b85c0b362cf1ba975d8a7dfe0ab6c96538231941f8dac8cf0c900290ba"
)
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
    "-derivedDataPath /private/tmp/mirmir-r06-6c4a6d3d-derived "
    "-resultBundlePath /private/tmp/mirmir-r06-6c4a6d3d.xcresult "
    "-disableAutomaticPackageResolution test "
    "-only-testing:MirmirTests/R06ASHDecisionContextTests "
    "-only-testing:MirmirTests/R06ASHMasksAndAblationsTests "
    "-only-testing:MirmirTests/R06ASHOrchestratorTests "
    "-only-testing:MirmirTests/R06ASHPolicyCatalogTests "
    "-only-testing:MirmirTests/R06FunctionalPhaseAcceptanceTests "
    "-only-testing:MirmirTests/R07FunctionalCoordinatorTests "
    "-only-testing:MirmirTests/R07FunctionalCoordinatorTransactionTests "
    "'EXCLUDED_SOURCE_FILE_NAMES=*.metal' CODE_SIGNING_ALLOWED=NO"
)

EVIDENCE_PATHS = (
    ("r06_preregistration", PREREGISTRATION_PATH),
    ("r06_fixture_catalog", FIXTURE_CATALOG_PATH),
    ("r06_orchestration_conformance", CONFORMANCE_PATH),
    ("r06_phase_evidence_json", PHASE_EVIDENCE_JSON_PATH),
    ("r06_phase_evidence_markdown", PHASE_EVIDENCE_MARKDOWN_PATH),
    ("r06_preregistration_schema", PREREGISTRATION_SCHEMA_PATH),
    ("r06_fixture_catalog_schema", FIXTURE_CATALOG_SCHEMA_PATH),
    ("r06_orchestration_conformance_schema", CONFORMANCE_SCHEMA_PATH),
)

IMPLEMENTATION_PATHS = (
    (
        "ash_state_source",
        Path("Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift"),
    ),
    (
        "ash_code_source",
        Path("Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift"),
    ),
    (
        "r06_decision_context_source",
        Path("Mirmir/Modules/UpscalerEngine/R06ASHDecisionContext.swift"),
    ),
    (
        "r06_masks_and_ablations_source",
        Path("Mirmir/Modules/UpscalerEngine/R06ASHMasksAndAblations.swift"),
    ),
    (
        "r06_orchestrator_source",
        Path("Mirmir/Modules/UpscalerEngine/R06ASHOrchestrator.swift"),
    ),
    (
        "r06_policy_catalog_source",
        Path("Mirmir/Modules/UpscalerEngine/R06ASHPolicyCatalog.swift"),
    ),
    (
        "r07_functional_coordinator_source",
        Path("Mirmir/Modules/UpscalerEngine/R07FunctionalCoordinator.swift"),
    ),
    (
        "r07_functional_coordinator_analysis_source",
        Path(
            "Mirmir/Modules/UpscalerEngine/"
            "R07FunctionalCoordinatorAnalysis.swift"
        ),
    ),
    (
        "r07_functional_coordinator_runtime_source",
        Path(
            "Mirmir/Modules/UpscalerEngine/"
            "R07FunctionalCoordinatorRuntime.swift"
        ),
    ),
    (
        "r07_functional_coordinator_validation_source",
        Path(
            "Mirmir/Modules/UpscalerEngine/"
            "R07FunctionalCoordinatorValidation.swift"
        ),
    ),
    (
        "r06_decision_context_tests",
        Path("MirmirTests/UpscalerEngine/R06ASHDecisionContextTests.swift"),
    ),
    (
        "r06_masks_and_ablations_tests",
        Path("MirmirTests/UpscalerEngine/R06ASHMasksAndAblationsTests.swift"),
    ),
    (
        "r06_orchestrator_tests",
        Path("MirmirTests/UpscalerEngine/R06ASHOrchestratorTests.swift"),
    ),
    (
        "r06_policy_catalog_tests",
        Path("MirmirTests/UpscalerEngine/R06ASHPolicyCatalogTests.swift"),
    ),
    (
        "r06_functional_phase_acceptance_tests",
        Path("MirmirTests/R06FunctionalPhaseAcceptanceTests.swift"),
    ),
    (
        "r07_functional_coordinator_tests",
        Path("MirmirTests/UpscalerEngine/R07FunctionalCoordinatorTests.swift"),
    ),
    (
        "r07_functional_coordinator_transaction_tests",
        Path(
            "MirmirTests/UpscalerEngine/"
            "R07FunctionalCoordinatorTransactionTests.swift"
        ),
    ),
    (
        "r07_functional_test_support",
        Path("MirmirTests/UpscalerEngine/R07FunctionalTestSupport.swift"),
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
    ("r06_functional_xcodebuild_log", XCODEBUILD_LOG_PATH),
    ("r06_functional_xcresult_summary", XCRESULT_SUMMARY_PATH),
)

REQUIRED_TEST_SUITES = (
    "R06ASHDecisionContextTests",
    "R06ASHMasksAndAblationsTests",
    "R06ASHOrchestratorTests",
    "R06ASHPolicyCatalogTests",
    "R06FunctionalPhaseAcceptanceTests",
    "R07FunctionalCoordinatorTests",
    "R07FunctionalCoordinatorTransactionTests",
)

EXPECTED_SUITE_TESTS = (
    (
        "R06ASHDecisionContextTests",
        (
            "testDecisionContextPreservesAllThirtyEightFrozenFieldsAndAccessors()",
            "testIdentityAndScaleValidationRejectsEmptyTrimmedAndNonpositiveValues()",
            "testPostflightFallbackAndBackendIdentitiesAreTypedAndValidated()",
            "testQ16AndQ15DomainsAreCheckedWithoutClamping()",
            (
                "testStateContextRequiresEightFeaturesNonnegativeDwellAnd"
                "ExactTransition()"
            ),
            "testStateTransitionRejectsIntegrityFailureAndNoncodewordDelta()",
            "testStatusVocabulariesPreserveTheirTypedValues()",
        ),
    ),
    (
        "R06ASHMasksAndAblationsTests",
        (
            "testAblationMetadataMatchesPreregistrationAndFixtureCatalogExactly()",
            "testAblationModesMatchFrozenIDsAndOrderExactly()",
            "testMaskIDsMatchFrozenDeclarationOrderExactly()",
            "testMaskSampleCountMultiplicationFailsClosedOnOverflow()",
            "testMasksAcceptExactDimensionAndQ15SampleBoundaries()",
            "testMasksAndSetsHaveImmutableValueIdentity()",
            "testMasksRejectEveryDimensionBoundaryOutsideOneThrough64()",
            "testMasksRejectOutOfRangeSamplesWithoutClamping()",
            "testMasksRejectSampleCountMismatch()",
            "testTypedMaskSetMatchesExactFrozenFixtures()",
            "testTypedMaskSetRejectsCountDuplicatesAndWrongSlotIdentity()",
        ),
    ),
    (
        "R06ASHOrchestratorTests",
        (
            "testAblationsSeparateASHMessageSidecarAndTransitionCausality()",
            "testConstructorParametersRejectAnyDriftFromFrozenCatalog()",
            (
                "testEveryCandidatePermutationProducesIdenticalOrderedRecord"
                "AndSelection()"
            ),
            (
                "testFixedPointComponentsRejectOutOfRangeAndScoringFailsClosed"
                "OnOverflow()"
            ),
            "testFrozenCatalogMatchesExactDescriptorsComponentsAndScores()",
            "testFrozenTransitionFixturesProduceEveryTypedSelectionReason()",
            "testHysteresisSwitchesAtExactMarginAndHoldsOneStepBelow()",
            (
                "testPostflightAblationsZeroOnlyContextRiskAndRetainCandidate"
                "Component()"
            ),
            (
                "testProductGateRunsBeforeScoringAndPlanConstructionForEvery"
                "Ablation()"
            ),
            (
                "testTypedFailuresRejectDuplicateRoutesFatalMismatchAndEmpty"
                "FixtureSet()"
            ),
            "testWithoutHysteresisStillHonorsMinimumDwell()",
        ),
    ),
    (
        "R06ASHPolicyCatalogTests",
        (
            "testAllSixteenProfilesMapMSBFirstBitsToExactPolicyAxes()",
            "testCatalogIdentityOrderAndUniquenessAreFrozen()",
            "testEverySingleBitPerturbationChangesExactlyItsMappedPolicyAxis()",
        ),
    ),
    (
        "R06FunctionalPhaseAcceptanceTests",
        (
            (
                "testEligibilityFilterProducesOneTraceablePlanWithoutMutating"
                "Inputs()"
            ),
        ),
    ),
    (
        "R07FunctionalCoordinatorTests",
        (
            "testEmptyAndAllZeroProtectionAreExplicitlyNotApplicable()",
            "testEndToEndExecutesSupportAndCarriesFeedbackIntoNPlus1()",
            "testFailurePreservesHistoryAndPostflightState()",
            "testForgedExecutionIdentityAndPayloadFailClosedForEveryStage()",
            "testPreseededHigherRiskControlsEffectsScoresAndHistory()",
            "testProductGatePrecedesValidationAndSupportExecution()",
        ),
    ),
    (
        "R07FunctionalCoordinatorTransactionTests",
        (
            "testDuplicateAndStaleHistoryInsertionDoNotCommitState()",
            "testEmptyCandidatesFailsWithoutCommittingCoordinatorState()",
            "testShotAndTargetOrdinalMismatchDoNotCommitState()",
        ),
    ),
)

EXPECTED_SELECTED_TEST_COUNT = sum(
    len(test_ids) for _, test_ids in EXPECTED_SUITE_TESTS
)

FUNCTIONAL_CHECK_IDS = (
    "source_checkpoint_exact",
    "frozen_evidence_valid_and_unchanged",
    "historical_blocked_reason_preserved",
    "implementation_bindings_exact",
    "execution_artifacts_exact",
    "selected_test_set_exact",
    "decision_context_fields_and_validation",
    "fixed_point_domains_fail_closed",
    "bounded_masks_and_ablations",
    "policy_catalog_sixteen_profiles",
    "eligibility_filter_before_scoring",
    "candidate_order_invariance",
    "one_traceable_whole_frame_plan",
    "input_immutability",
    "hysteresis_dwell_and_transition",
    "typed_failures_and_no_silent_fallback",
    "product_gate_precedes_validation",
    "product_scope_rejected_unimplemented",
    "r07_coordinator_fixture_integration",
    "transaction_failure_preserves_state",
    "native_observation_boundary_truthful",
    "authorization_boundary_exact",
)

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "authorization_date": "2026-07-23",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "override_id": "r06.software-function-only-phase-acceptance.v1",
    "hardware_simulator_operator_observation": "waived_not_a_blocker",
    "comparative_requirement": "not_required_for_phase_acceptance",
    "historical_evidence_policy": (
        "preserve_r06_blocked_evidence_unchanged_non_authorizing"
    ),
}

RESULT = {
    "status": "passed",
    "phase_status_before": "in_progress",
    "phase_status_after": "passed",
    "acceptance": "accepted",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_integration",
}

AUTHORIZATIONS = {
    "r06_phase_acceptance": "authorized",
    "r06_phase_status": "passed",
    "phase_progression": "authorized",
    "deterministic_fixture_integration": "authorized",
    "historical_blocked_evidence": "preserved_non_authorizing",
    "product_scope_orchestration": "rejected_unimplemented",
    "product_qualification": "not_claimed",
    "product_routing": "not_authorized",
    "production_upscaling": "not_authorized",
    "production_default": "not_authorized",
    "auto_mode": "not_authorized",
    "holdout": "not_authorized",
    "native_framework_execution": "not_claimed",
    "hardware_observation": "not_claimed",
    "simulator_observation": "not_claimed",
    "operator_observation": "not_claimed",
    "quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "product_publication": "not_authorized",
    "release": "not_authorized",
}

LIMITATIONS = (
    "R06 acceptance is limited to checkpoint-bound deterministic fixture proof "
    "that the decision context, masks, policy catalog, scoring, eligibility, "
    "selection, transition, and coordinator transaction software performs its "
    "declared task.",
    "The historical no_product_qualified_primary_backend blocked conformance and "
    "phase evidence remain unchanged and non-authorizing; no product-scope rerun "
    "is claimed.",
    "R06 v1 product-scope orchestration intentionally rejects before scoring and "
    "plan construction and remains unsupported and unimplemented for product "
    "routing.",
    "R06 acceptance does not claim product qualification, production routing or "
    "default, Auto, holdout, native-framework or hardware observation, quality, "
    "performance, publication, or release.",
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
        "phase_id": "R06",
        "evidence_kind": "r06_functional_selected_test_summary_v1",
        "source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE},
        "execution_mode": "deterministic_fixture_integration",
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
    lines: list[str] = []
    for suite_id, test_ids in EXPECTED_SUITE_TESTS:
        noun = "test" if len(test_ids) == 1 else "tests"
        lines.extend(
            (
                f"Test Suite '{suite_id}' passed.",
                (
                    f"    Executed {len(test_ids)} {noun}, with 0 failures "
                    "(0 unexpected), 0 skipped."
                ),
            )
        )
    return "\n".join(
        (
            "R06 declared-software-function acceptance execution",
            "repository-safe transcript derived from the bound xcresult summary",
            f"source_commit: {SOURCE_COMMIT}",
            f"source_tree: {SOURCE_TREE}",
            "execution_mode: deterministic_fixture_integration",
            "platform: macos_host",
            "architecture: arm64",
            "",
            "Command line invocation:",
            f"    {XCODEBUILD_COMMAND}",
            "",
            *lines,
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


class R06PhaseAcceptanceVerifier:
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
        file_path = self.root / relative
        if file_path.is_symlink() or not file_path.is_file():
            raise OSError(f"not a regular non-symlink file: {relative}")
        payload = file_path.read_bytes()
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    def _checkpoint_file_binding(
        self, identifier: str, relative: Path
    ) -> dict[str, object]:
        tree_entry = self.git(
            "ls-tree", SOURCE_COMMIT, "--", relative.as_posix()
        )
        if tree_entry.returncode != 0 or not (
            tree_entry.stdout.startswith("100644 blob ")
            or tree_entry.stdout.startswith("100755 blob ")
        ):
            raise OSError(
                f"checkpoint path is not a regular file: {relative.as_posix()}"
            )
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

    def _schema_errors(self) -> list[str]:
        file_path = self.root / ACCEPTANCE_SCHEMA_PATH
        if file_path.is_symlink() or not file_path.is_file():
            return ["R06 acceptance schema must be a regular non-symlink file"]
        payload = file_path.read_bytes()
        errors: list[str] = []
        if len(payload) != ACCEPTANCE_SCHEMA_SIZE_BYTES:
            errors.append("R06 acceptance schema size differs")
        if _sha256(payload) != ACCEPTANCE_SCHEMA_SHA256:
            errors.append("R06 acceptance schema hash differs")
        return errors

    def _source_errors(self) -> list[str]:
        errors: list[str] = []
        if self.git("cat-file", "-e", f"{SOURCE_COMMIT}^{{commit}}").returncode:
            return ["R06 acceptance source commit is unavailable"]
        tree = self.git("rev-parse", f"{SOURCE_COMMIT}^{{tree}}")
        if tree.returncode != 0 or tree.stdout.strip() != SOURCE_TREE:
            errors.append("R06 acceptance source tree differs")
        if self.git(
            "merge-base", "--is-ancestor", SOURCE_COMMIT, "HEAD"
        ).returncode:
            errors.append("R06 acceptance source commit is not an ancestor of HEAD")
        for relative in SOURCE_BUILD_PATHS:
            if self.git(
                "cat-file", "-e", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            ).returncode:
                errors.append(
                    "R06 checkpoint build input is unavailable: "
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
                errors.append(f"R06 frozen evidence differs: {identifier}")
        for identifier, relative in IMPLEMENTATION_PATHS:
            try:
                self._checkpoint_file_binding(identifier, relative)
            except OSError:
                errors.append(
                    "R06 checkpoint implementation is unavailable or non-regular: "
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
                    R06PhaseAcceptanceVerifier._privacy_errors(
                        item, f"{context}.{key}"
                    )
                )
        elif isinstance(value, list):
            for index, item in enumerate(value):
                errors.extend(
                    R06PhaseAcceptanceVerifier._privacy_errors(
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
        frozen = R06ContractVerifier(self.root)
        errors.extend(frozen.check_preregistration())
        errors.extend(frozen.check_fixtures())
        conformance = self._read_json(
            CONFORMANCE_PATH, "R06 frozen orchestration conformance", errors
        )
        conformance_schema = self._read_json(
            CONFORMANCE_SCHEMA_PATH,
            "R06 frozen orchestration conformance schema",
            errors,
        )
        if conformance is not None and conformance_schema is not None:
            errors.extend(
                f"R06 frozen orchestration conformance schema: {error}"
                for error in validate_json_schema_instance(
                    conformance_schema, conformance
                )
            )
        if conformance is not None:
            if conformance.get("observation_status") != CONFORMANCE_OBSERVATION:
                errors.append("R06 frozen observation boundary differs")
            if (
                conformance.get("product_gate_result")
                != CONFORMANCE_PRODUCT_GATE_RESULT
            ):
                errors.append("R06 frozen product gate differs")
            if conformance.get("result") != CONFORMANCE_RESULT:
                errors.append("R06 frozen blocked result differs")
            expected_fixture_checks = [
                {"id": identifier, "status": "passed"}
                for identifier in FIXTURE_CHECK_IDS
            ]
            if conformance.get("fixture_checks") != expected_fixture_checks:
                errors.append("R06 frozen fixture checks differ")
            expected_ablations = [
                {
                    "id": identifier,
                    "status": "not_observed",
                    "reason": "no_product_qualified_primary_backend",
                }
                for identifier in ABLATION_IDS
            ]
            if conformance.get("product_ablations") != expected_ablations:
                errors.append("R06 frozen product ablations differ")
            expected_checks = [
                {"id": identifier, "status": "passed"}
                for identifier in FROZEN_CHECK_IDS
            ]
            if conformance.get("checks") != expected_checks:
                errors.append("R06 frozen conformance checks differ")

        phase_evidence = self._read_json(
            PHASE_EVIDENCE_JSON_PATH, "R06 frozen phase evidence", errors
        )
        if phase_evidence is not None:
            result = phase_evidence.get("result")
            dispositions = result.get("dispositions") if isinstance(result, dict) else None
            if not isinstance(result, dict) or (
                result.get("status") != "blocked"
                or result.get("disposition") != "blocked"
                or result.get("phase_status_after") != "in_progress"
            ):
                errors.append("R06 frozen phase-evidence result differs")
            if (
                not isinstance(dispositions, list)
                or len(dispositions) != len(ABLATION_IDS)
                or any(
                    not isinstance(item, dict)
                    or item.get("value") != "not_observed"
                    or item.get("reason")
                    != "no_product_qualified_primary_backend"
                    for item in dispositions
                )
            ):
                errors.append("R06 frozen phase-evidence dispositions differ")
        return errors

    @staticmethod
    def _summary_errors(summary: dict[str, Any]) -> list[str]:
        if summary != _expected_summary():
            return ["R06 selected-test summary differs from exact evidence"]
        return []

    def _artifact_errors(
        self, summary: dict[str, Any] | None = None
    ) -> list[str]:
        errors: list[str] = []
        if summary is None:
            summary = self._read_json(
                XCRESULT_SUMMARY_PATH, "R06 xcresult summary", errors
            )
        if summary is not None:
            errors.extend(self._summary_errors(summary))
            errors.extend(self._privacy_errors(summary, "xcresult_summary"))
        log_path = self.root / XCODEBUILD_LOG_PATH
        if log_path.is_symlink() or not log_path.is_file():
            errors.append("R06 xcodebuild log must be a regular non-symlink file")
        else:
            try:
                log = log_path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as error:
                errors.append(f"R06 xcodebuild log is invalid: {error}")
            else:
                if log != _expected_log():
                    errors.append("R06 xcodebuild log differs from exact evidence")
                errors.extend(self._privacy_errors(log, "xcodebuild_log"))
        return errors

    def expected_record(self) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R06",
            "evidence_kind": "r06_operator_functional_phase_acceptance_v1",
            "source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE},
            "operator_override": dict(OPERATOR_OVERRIDE),
            "functional_gate": {
                "acceptance_scope": "declared_software_function_only",
                "execution_mode": "deterministic_fixture_integration",
                "required_test_suites": list(REQUIRED_TEST_SUITES),
                "required_selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "required_behavior_ids": list(FUNCTIONAL_CHECK_IDS),
                "historical_blocked_evidence_role": (
                    "preserved_non_authorizing_not_acceptance_basis"
                ),
                "historical_blocked_reason": (
                    "no_product_qualified_primary_backend"
                ),
                "product_scope_orchestration": (
                    "unsupported_rejected_unimplemented"
                ),
                "product_scope_rerun": "not_claimed",
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
                {"id": identifier, "status": "passed"}
                for identifier in FUNCTIONAL_CHECK_IDS
            ],
            "result": dict(RESULT),
            "authorizations": dict(AUTHORIZATIONS),
            "limitations": list(LIMITATIONS),
        }

    @staticmethod
    def _boundary_errors(record: dict[str, Any]) -> list[str]:
        errors: list[str] = []
        if record.get("result") != RESULT:
            errors.append("R06 functional acceptance result boundary differs")
        if record.get("authorizations") != AUTHORIZATIONS:
            errors.append("R06 functional acceptance authorization boundary differs")
        gate = record.get("functional_gate")
        if not isinstance(gate, dict) or (
            gate.get("historical_blocked_reason")
            != "no_product_qualified_primary_backend"
            or gate.get("historical_blocked_evidence_role")
            != "preserved_non_authorizing_not_acceptance_basis"
            or gate.get("product_scope_orchestration")
            != "unsupported_rejected_unimplemented"
            or gate.get("product_scope_rerun") != "not_claimed"
        ):
            errors.append("R06 product and historical evidence boundary differs")
        return errors

    def _record_binding_errors(self, record: dict[str, Any]) -> list[str]:
        errors: list[str] = []
        try:
            expected_evidence = [
                self._file_binding(identifier, relative)
                for identifier, relative in EVIDENCE_PATHS
            ]
            expected_implementation = [
                self._checkpoint_file_binding(identifier, relative)
                for identifier, relative in IMPLEMENTATION_PATHS
            ]
            expected_artifacts = [
                self._file_binding(identifier, relative)
                for identifier, relative in ARTIFACT_PATHS
            ]
        except OSError as error:
            return [f"R06 binding source is unavailable: {error}"]
        for key, expected in (
            ("evidence_bindings", expected_evidence),
            ("implementation_bindings", expected_implementation),
            ("artifact_bindings", expected_artifacts),
        ):
            if record.get(key) != expected:
                errors.append(f"R06 {key} differ from exact source bytes")
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
        if not isinstance(expected_count, int) or expected_count != 42:
            errors.append("R06 checked summary selected test count differs")
            expected_count = 42
        for key, expected in {
            "result": "Passed",
            "title": "Test - Mirmir",
            "totalTestCount": expected_count,
            "passedTests": expected_count,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
        }.items():
            if summary.get(key) != expected:
                errors.append(
                    f"R06 raw xcresult summary {key} differs: expected {expected!r}"
                )
        if summary.get("testFailures") != []:
            errors.append("R06 raw xcresult contains test failures")

        configurations = summary.get("devicesAndConfigurations")
        if not isinstance(configurations, list) or len(configurations) != 1:
            errors.append(
                "R06 raw xcresult must contain exactly one device configuration"
            )
        else:
            configuration = configurations[0]
            if not isinstance(configuration, dict):
                errors.append("R06 raw xcresult device configuration is invalid")
            else:
                for key, expected in {
                    "passedTests": expected_count,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                }.items():
                    if configuration.get(key) != expected:
                        errors.append(
                            "R06 raw xcresult device configuration "
                            f"{key} differs: expected {expected!r}"
                        )
                device = configuration.get("device")
                if not isinstance(device, dict) or (
                    device.get("platform") != "macOS"
                    or device.get("architecture") != "arm64"
                ):
                    errors.append("R06 raw xcresult device must be macOS arm64")

        raw_start = summary.get("startTime")
        raw_finish = summary.get("finishTime")
        if (
            not isinstance(raw_start, (int, float))
            or not isinstance(raw_finish, (int, float))
            or raw_finish < raw_start
        ):
            errors.append("R06 raw xcresult timestamps are invalid")
        for key, expected in {
            "actionTitle": "Testing project Mirmir with scheme Mirmir",
            "status": "succeeded",
            "errorCount": 0,
            "errors": [],
        }.items():
            if build_results.get(key) != expected:
                errors.append(
                    f"R06 raw xcresult build {key} differs: expected {expected!r}"
                )
        destination = build_results.get("destination")
        if not isinstance(destination, dict) or (
            destination.get("platform") != "macOS"
            or destination.get("architecture") != "arm64"
        ):
            errors.append("R06 raw xcresult build destination must be macOS arm64")
        if (
            build_results.get("startTime") != raw_start
            or build_results.get("endTime") != raw_finish
        ):
            errors.append(
                "R06 raw xcresult test and build timestamps must match exactly"
            )

        expected_identities = {
            (suite_id, test_id)
            for suite_id, test_ids in EXPECTED_SUITE_TESTS
            for test_id in test_ids
        }
        checked_identities: set[tuple[str, str]] = set()
        checked_suites = checked_summary.get("test_suites")
        if not isinstance(checked_suites, list):
            errors.append("R06 checked summary suites are invalid")
        else:
            for suite in checked_suites:
                if not isinstance(suite, dict) or not isinstance(
                    suite.get("id"), str
                ):
                    errors.append("R06 checked summary suite is invalid")
                    continue
                checked_tests = suite.get("tests")
                if not isinstance(checked_tests, list):
                    errors.append("R06 checked summary tests are invalid")
                    continue
                for test in checked_tests:
                    if not isinstance(test, dict) or not isinstance(
                        test.get("id"), str
                    ):
                        errors.append("R06 checked summary test is invalid")
                        continue
                    checked_identities.add((suite["id"], test["id"]))
        if checked_identities != expected_identities:
            errors.append("R06 checked summary identities differ from constants")

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
        observed: list[tuple[str, str]] = []
        for test_case in test_cases:
            identifier = test_case.get("nodeIdentifier")
            name = test_case.get("name")
            if not isinstance(identifier, str) or not isinstance(name, str):
                errors.append("R06 raw xcresult contains invalid test identity")
                continue
            suite_id, separator, identifier_test = identifier.partition("/")
            if not separator or identifier_test != name:
                errors.append(
                    f"R06 raw xcresult test identifier is malformed: {identifier!r}"
                )
                continue
            observed.append((suite_id, name))
            if test_case.get("result") != "Passed":
                errors.append(f"R06 raw xcresult test did not pass: {identifier}")
        if len(observed) != expected_count:
            errors.append(
                f"R06 raw xcresult found {len(observed)} tests, expected {expected_count}"
            )
        if len(observed) != len(set(observed)):
            errors.append("R06 raw xcresult contains duplicate test identities")
        if set(observed) != expected_identities:
            errors.append("R06 raw xcresult test identities differ")
        return errors

    def _read_xcresult_json(
        self, result_path: Path, section: str, errors: list[str]
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
                f"R06 raw xcresult {section} extraction failed: {error}"
            )
            return None
        if result.returncode != 0:
            detail = result.stderr.strip()
            errors.append(
                f"R06 raw xcresult {section} extraction failed"
                + (f": {detail}" if detail else "")
            )
            return None
        try:
            value = decode_json(result.stdout)
        except (ValueError, json.JSONDecodeError) as error:
            errors.append(
                f"R06 raw xcresult {section} output is invalid: {error}"
            )
            return None
        if not isinstance(value, dict):
            errors.append(f"R06 raw xcresult {section} output must be an object")
            return None
        return value

    def check_xcresult(self, result_path: Path) -> list[str]:
        result_bundle = (
            result_path if result_path.is_absolute() else self.root / result_path
        )
        if result_bundle.is_symlink() or not result_bundle.is_dir():
            return [
                "R06 raw xcresult must be an existing non-symlink result bundle"
            ]
        errors = self._schema_errors()
        checked_summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R06 checked xcresult summary", errors
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

    def check(self) -> list[str]:
        errors = self._schema_errors()
        errors.extend(self._source_errors())
        errors.extend(self._frozen_evidence_errors())
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R06 xcresult summary", errors
        )
        errors.extend(self._artifact_errors(summary))
        record = self._read_json(ACCEPTANCE_PATH, "R06 phase acceptance", errors)
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R06 phase acceptance schema", errors
        )
        if record is not None:
            errors.extend(self._privacy_errors(record, "acceptance"))
            errors.extend(self._boundary_errors(record))
            errors.extend(self._record_binding_errors(record))
        if record is not None and schema is not None:
            errors.extend(
                f"R06 phase acceptance schema: {error}"
                for error in validate_json_schema_instance(schema, record)
            )
        if record is not None:
            try:
                expected = self.expected_record()
            except OSError as error:
                errors.append(f"R06 record derivation failed: {error}")
            else:
                if record != expected:
                    errors.append(
                        "R06 phase acceptance is not exactly derived from "
                        "checkpoint and artifact bytes"
                    )
        return sorted(set(errors))

    def _write_output(self, output_path: Path, payload: bytes) -> list[str]:
        try:
            relative = output_path.relative_to(self.root)
        except ValueError:
            return ["R06 evidence output must remain inside the repository"]
        current = self.root
        for component in relative.parts[:-1]:
            current /= component
            if current.is_symlink():
                return [
                    "R06 evidence output parent must not be a symlink: "
                    f"{current}"
                ]
        if (
            output_path.is_symlink()
            or output_path.exists()
            and not output_path.is_file()
        ):
            return [
                "R06 evidence output must be absent or a regular non-symlink file"
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
            return [f"R06 evidence output write failed: {error}"]
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink(missing_ok=True)
                except OSError:
                    pass
        return []

    def write(self) -> list[str]:
        errors = self._schema_errors()
        errors.extend(self._source_errors())
        errors.extend(self._frozen_evidence_errors())
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R06 xcresult summary", errors
        )
        errors.extend(self._artifact_errors(summary))
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R06 phase acceptance schema", errors
        )
        if schema is None or errors:
            return sorted(set(errors))
        try:
            record = self.expected_record()
        except OSError as error:
            return [f"R06 record derivation failed: {error}"]
        errors.extend(
            f"R06 phase acceptance schema: {error}"
            for error in validate_json_schema_instance(schema, record)
        )
        errors.extend(self._privacy_errors(record, "acceptance"))
        errors.extend(self._boundary_errors(record))
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
    verifier = R06PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    if arguments.write:
        errors = verifier.write()
    elif arguments.check_xcresult is not None:
        errors = verifier.check_xcresult(arguments.check_xcresult)
    else:
        errors = verifier.check()
    if not errors:
        print("R06 declared-software-function phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
