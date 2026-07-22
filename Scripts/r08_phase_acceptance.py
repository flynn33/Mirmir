#!/usr/bin/env python3
"""Derive and validate R08 software-function-only phase acceptance evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
from typing import Any, Iterable, Mapping, Sequence

from phase_evidence import (
    EMAIL_PATTERN,
    PRIVATE_EVIDENCE_KEYS,
    PRIVATE_PATH_PATTERN,
    decode_json,
    validate_json_schema_instance,
)
from r08_contracts import R08ContractVerifier


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
EXECUTION_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r08/records/functional-execution-receipt.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r08-functional-execution-receipt-v1.json"
)
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r08/records/functional-phase-acceptance.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r08-functional-phase-acceptance-v1.json"
)
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r08/records/artifacts/functional-phase-acceptance"
)
XCODEBUILD_LOG_PATH = ARTIFACT_DIRECTORY / "xcodebuild.log"
XCRESULT_SUMMARY_PATH = ARTIFACT_DIRECTORY / "xcresult-summary.json"

CONTRACT_PATHS = (
    ("r08_preregistration", Path(
        "docs/roadmaps/evidence/r08/records/preregistration.json"
    )),
    ("r08_fixture_catalog", Path(
        "docs/roadmaps/evidence/r08/records/fixtures/fixture-catalog.json"
    )),
    ("r08_preregistration_schema", Path(
        "docs/roadmaps/evidence/schema/r08-preregistration-v1.json"
    )),
    ("r08_fixture_catalog_schema", Path(
        "docs/roadmaps/evidence/schema/r08-fixture-catalog-v1.json"
    )),
    ("r08_contract_validator", Path("Scripts/r08_contracts.py")),
    ("r08_contract_validator_tests", Path(
        "Scripts/tests/test_r08_contracts.py"
    )),
    ("r08_phase_acceptance_validator", Path(
        "Scripts/r08_phase_acceptance.py"
    )),
    ("r08_phase_acceptance_validator_tests", Path(
        "Scripts/tests/test_r08_phase_acceptance.py"
    )),
    ("r08_functional_execution_receipt_schema", Path(
        "docs/roadmaps/evidence/schema/"
        "r08-functional-execution-receipt-v1.json"
    )),
    ("r08_functional_phase_acceptance_schema", Path(
        "docs/roadmaps/evidence/schema/"
        "r08-functional-phase-acceptance-v1.json"
    )),
)

IMPLEMENTATION_PATHS = (
    ("r08_analysis_contracts_source", Path(
        "Mirmir/Modules/ModelAssets/R08CoreAIAnalysisContracts.swift"
    )),
    ("r08_analysis_heads_source", Path(
        "Mirmir/Modules/ModelAssets/R08CoreAIAnalysisHeads.swift"
    )),
    ("r08_deterministic_service_source", Path(
        "Mirmir/Modules/ModelAssets/R08DeterministicAnalysisService.swift"
    )),
    ("r08_ash_bridge_source", Path(
        "Mirmir/Modules/UpscalerEngine/R08ASHAnalysisBridge.swift"
    )),
    ("r08_analysis_contracts_tests", Path(
        "MirmirTests/UpscalerEngine/R08CoreAIAnalysisContractsTests.swift"
    )),
    ("r08_analysis_output_decoder_tests", Path(
        "MirmirTests/UpscalerEngine/R08AnalysisOutputDecoderTests.swift"
    )),
    ("r08_deterministic_service_tests", Path(
        "MirmirTests/UpscalerEngine/R08DeterministicAnalysisServiceTests.swift"
    )),
    ("r08_ash_bridge_tests", Path(
        "MirmirTests/UpscalerEngine/R08ASHAnalysisBridgeTests.swift"
    )),
    ("r08_resource_and_authority_tests", Path(
        "MirmirTests/UpscalerEngine/R08AnalysisResourceAndAuthorityTests.swift"
    )),
    ("r08_test_support", Path(
        "MirmirTests/UpscalerEngine/R08TestSupport.swift"
    )),
    ("project_manifest", Path("project.yml")),
    ("xcode_project", Path("Mirmir.xcodeproj/project.pbxproj")),
)

TEST_SUITES = (
    (
        "R08CoreAIAnalysisContractsTests",
        Path("MirmirTests/UpscalerEngine/R08CoreAIAnalysisContractsTests.swift"),
    ),
    (
        "R08AnalysisBudgetContractTests",
        Path("MirmirTests/UpscalerEngine/R08CoreAIAnalysisContractsTests.swift"),
    ),
    (
        "R08AnalysisIdentityContractTests",
        Path("MirmirTests/UpscalerEngine/R08CoreAIAnalysisContractsTests.swift"),
    ),
    (
        "R08AnalysisOutputDecoderTests",
        Path("MirmirTests/UpscalerEngine/R08AnalysisOutputDecoderTests.swift"),
    ),
    (
        "R08DeterministicAnalysisServiceTests",
        Path("MirmirTests/UpscalerEngine/R08DeterministicAnalysisServiceTests.swift"),
    ),
    (
        "R08DeterministicAnalysisLifecycleTests",
        Path("MirmirTests/UpscalerEngine/R08DeterministicAnalysisServiceTests.swift"),
    ),
    (
        "R08AnalysisResourceBudgetTests",
        Path("MirmirTests/UpscalerEngine/R08AnalysisResourceAndAuthorityTests.swift"),
    ),
    (
        "R08ForbiddenOutputServiceTests",
        Path("MirmirTests/UpscalerEngine/R08AnalysisResourceAndAuthorityTests.swift"),
    ),
    (
        "R08InputTransferFallbackTests",
        Path("MirmirTests/UpscalerEngine/R08AnalysisResourceAndAuthorityTests.swift"),
    ),
    (
        "R08ASHAnalysisBridgeTests",
        Path("MirmirTests/UpscalerEngine/R08ASHAnalysisBridgeTests.swift"),
    ),
)


def _test_id(suite: str, method: str) -> str:
    return f"MirmirTests/{suite}/{method}"


FUNCTIONAL_TEST_METHODS = (
    (
        "optional_analysis_only_service",
        (_test_id(
            "R08DeterministicAnalysisServiceTests",
            "testAnalyzedResultIsCompleteBoundedAndAnalysisOnly",
        ),),
    ),
    (
        "exact_nine_analysis_outputs",
        (
            _test_id(
                "R08AnalysisOutputDecoderTests",
                "testDecoderAcceptsExactNineHeadInventoryAndRetainsClassification",
            ),
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testAnalysisHeadsRequireEightTwoByTwoMapsPlusOneScalar",
            ),
        ),
    ),
    (
        "calibrated_q15_geometry_and_bounds",
        (
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testQ15MapAcceptsBoundariesAndRejectsInvalidGeometryOrSamples",
            ),
            _test_id(
                "R08AnalysisOutputDecoderTests",
                "testDecoderRejectsKindAndSampleCountMismatches",
            ),
            _test_id(
                "R08AnalysisOutputDecoderTests",
                "testDecoderRejectsQ15UnderflowAndOverflowWithoutClamping",
            ),
        ),
    ),
    (
        "invalid_output_fail_closed",
        (
            _test_id(
                "R08AnalysisOutputDecoderTests",
                "testDecoderRejectsMissingDuplicateAndUnexpectedHeadIDs",
            ),
            _test_id(
                "R08DeterministicAnalysisServiceTests",
                "testInvalidOutputBypassesWithoutStateOrCacheMutation",
            ),
        ),
    ),
    (
        "schedule_precedence_cadence_and_order",
        (
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testScheduleResolverAppliesFrozenPrecedenceAndCadence",
            ),
            _test_id(
                "R08DeterministicAnalysisServiceTests",
                "testServiceUsesResolvedScheduleAndRejectsUnscheduledFrame",
            ),
            _test_id(
                "R08DeterministicAnalysisLifecycleTests",
                "testStreamShotAndOrdinalRejectionsDoNotMutateState",
            ),
        ),
    ),
    (
        "model_processing_and_result_identity",
        (
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testFrozenProxyAndSimulationIdentityAreExact",
            ),
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testResultRejectsCrossModeExecutionBinding",
            ),
            _test_id(
                "R08AnalysisIdentityContractTests",
                "testMissingCalibrationIdentityFailsBeforeARequestCanExist",
            ),
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testIdentityBudgetAndOrdinalValidationRejectInvalidValues",
            ),
            _test_id(
                "R08ASHAnalysisBridgeTests",
                "testFrameAndShotMismatchAreRejectedBeforeContextMutation",
            ),
        ),
    ),
    (
        "specialization_cache_key_and_lru",
        (
            _test_id(
                "R08DeterministicAnalysisServiceTests",
                "testBoundedSpecializationCacheUsesExactKeyAndLRUOrder",
            ),
            _test_id(
                "R08DeterministicAnalysisServiceTests",
                "testSpecializationKeyIncludesModelPlatformAndIOContract",
            ),
        ),
    ),
    (
        "aot_behavioral_equivalence",
        (_test_id(
            "R08DeterministicAnalysisServiceTests",
            "testOutputsAreRepeatableAndAOTBehaviorallyEquivalent",
        ),),
    ),
    (
        "zero_copy_with_deterministic_copy_fallback",
        (
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testInputTransferResolverPrefersZeroCopyAndExecutesCopyFallback",
            ),
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testInputTransferResolverRejectsContradictoryBindings",
            ),
            _test_id(
                "R08InputTransferFallbackTests",
                "testUnavailableZeroCopyCreatesOwnedCopyWithoutNativeExecutionClaim",
            ),
        ),
    ),
    (
        "state_scope_and_reset",
        (
            _test_id(
                "R08DeterministicAnalysisLifecycleTests",
                "testResetChangesGenerationClearsSequenceAndRetainsCache",
            ),
            _test_id(
                "R08DeterministicAnalysisLifecycleTests",
                "testStateResetDuringAwaitIsCaughtBeforeCommit",
            ),
            _test_id(
                "R08CoreAIAnalysisContractsTests",
                "testResultRejectsStateScheduleTransferAndAOTMismatch",
            ),
        ),
    ),
    (
        "cancellation_is_transactional",
        (_test_id(
            "R08DeterministicAnalysisLifecycleTests",
            "testCancellationResetsGenerationWithoutCommittingResultOrCache",
        ),),
    ),
    (
        "single_inflight_transaction",
        (_test_id(
            "R08DeterministicAnalysisLifecycleTests",
            "testConcurrentRequestBypassesBusyWithoutMutatingInFlightTransaction",
        ),),
    ),
    (
        "resource_budget_bypass",
        (
            _test_id(
                "R08AnalysisBudgetContractTests",
                "testFunctionalBudgetIsFixedAndCannotBeRaisedByRequest",
            ),
            _test_id(
                "R08AnalysisBudgetContractTests",
                "testResourceMeasurementRejectsNegativeValues",
            ),
            _test_id(
                "R08AnalysisResourceBudgetTests",
                "testExactMemoryAndLatencyBudgetBoundariesAreAccepted",
            ),
            _test_id(
                "R08AnalysisResourceBudgetTests",
                "testMemoryOneByteOverFrozenBudgetBypassesWithoutCommit",
            ),
            _test_id(
                "R08AnalysisResourceBudgetTests",
                "testLatencyOneMillisecondOverFrozenBudgetBypassesWithoutCommit",
            ),
        ),
    ),
    (
        "availability_and_identity_fallback",
        (
            _test_id(
                "R08DeterministicAnalysisServiceTests",
                "testAvailabilityFailuresUseTypedBypassWithoutMutation",
            ),
            _test_id(
                "R08DeterministicAnalysisServiceTests",
                "testInvalidSimulationIdentityBypassesWithoutMutation",
            ),
            _test_id(
                "R08ASHAnalysisBridgeTests",
                "testBypassPreservesBaseContextAndDeterministicRegionsExactly",
            ),
        ),
    ),
    (
        "ash_context_bounded_integration",
        (
            _test_id(
                "R08ASHAnalysisBridgeTests",
                "testAnalyzedSidecarStrengthensOnlyAnalysisFields",
            ),
            _test_id(
                "R08ASHAnalysisBridgeTests",
                "testRepeatedIntegrationNeverReducesConservativeContributions",
            ),
        ),
    ),
    (
        "protected_mask_composition",
        (_test_id(
            "R08ASHAnalysisBridgeTests",
            "testTwoByTwoProtectionMapExpandsByDeterministicNearestNeighbor",
        ), _test_id(
            "R08ASHAnalysisBridgeTests",
            "testExactLearnedMaskWinsR07PixelwiseMaximumComposition",
        )),
    ),
    (
        "pixel_output_and_control_forbidden",
        (_test_id(
            "R08CoreAIAnalysisContractsTests",
            "testResetCausesAndPixelAuthorityAreFrozen",
        ), _test_id(
            "R08AnalysisOutputDecoderTests",
            "testDecoderRejectsPixelAndBackendAuthorityOutputsWithTypedErrors",
        ), _test_id(
            "R08ForbiddenOutputServiceTests",
            "testForbiddenPixelAndBackendOutputsUseTypedNoCommitFallbacks",
        )),
    ),
    (
        "simulation_identity_truthful",
        (_test_id(
            "R08CoreAIAnalysisContractsTests",
            "testFrozenProxyAndSimulationIdentityAreExact",
        ),),
    ),
)
FUNCTIONAL_CHECK_IDS = tuple(identifier for identifier, _ in FUNCTIONAL_TEST_METHODS)

ARTIFACT_PATHS = (
    ("xcodebuild_log", XCODEBUILD_LOG_PATH),
    ("xcresult_summary_json", XCRESULT_SUMMARY_PATH),
)

COMPARISON_POLICY = {
    "comparative_testing": "not_run_not_required",
    "a_b_testing": "not_run_not_required",
    "blinded_testing": "not_run_not_required",
    "ablation_testing": "not_run_not_required",
    "superiority_requirement": "superseded_not_required",
    "acceptance_dependency": "none",
}

OBSERVATION_STATUS = {
    "deterministic_software_execution": "observed",
    "deterministic_fixture_simulation": "observed",
    "hardware_execution": "not_observed",
    "apple_simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "xcode27_environment": "not_observed",
    "core_ai_framework_availability": "not_observed",
    "model_asset_availability": "not_observed",
    "native_core_ai_execution": "not_observed",
}

EXECUTION_RESULT = {
    "status": "passed",
    "functional_software_conformance": "passed",
    "declared_software_behavior": "conformant",
    "execution_mode": "deterministic_fixture_simulation",
    "comparison_requirement": "superseded_not_required",
    "native_core_ai_qualification": "not_claimed",
    "product_qualification": "not_claimed",
}

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "authorization_date": "2026-07-22",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "override_id": "r08.software-function-only-phase-acceptance.v1",
    "comparative_requirement": "superseded_not_required",
    "a_b_requirement": "superseded_not_required",
    "blinded_requirement": "superseded_not_required",
    "ablation_requirement": "superseded_not_required",
    "superiority_requirement": "superseded_not_required",
    "native_execution": "supplemental_not_required",
}

FUNCTIONAL_GATE = {
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_simulation",
    "required_test_suites": [identifier for identifier, _ in TEST_SUITES],
    "required_functional_check_ids": list(FUNCTIONAL_CHECK_IDS),
    "comparison_policy": dict(COMPARISON_POLICY),
    "native_core_ai_qualification": "not_claimed",
    "product_qualification": "not_claimed",
}

DERIVED_CHECK_IDS = (
    "source_checkpoint_exact",
    "contract_bindings_exact",
    "implementation_bindings_exact",
    "execution_artifacts_exact",
    "execution_receipt_exact",
    "selected_test_set_exact",
    *FUNCTIONAL_CHECK_IDS,
    "comparative_methods_absent_and_non_gating",
    "native_observations_truthful",
    "authorization_boundary_exact",
)

ACCEPTANCE_RESULT = {
    "status": "passed",
    "phase_status_before": "in_progress",
    "phase_status_after": "passed",
    "acceptance": "accepted",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_simulation",
    "native_core_ai_qualification": "not_claimed",
    "product_qualification": "not_claimed",
}

AUTHORIZATIONS = {
    "r08_phase_acceptance": "authorized",
    "r08_phase_status": "passed",
    "r09_phase_progression": "not_authorized_requires_separate_operator_authorization",
    "r09_residual_execution": "not_authorized",
    "product_qualification": "not_claimed",
    "production_default": "not_authorized",
    "auto_mode": "not_authorized",
    "pixel_output": "not_authorized",
    "pixel_control": "not_authorized",
    "holdout": "not_authorized",
    "quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "product_publication": "not_authorized",
    "release": "not_authorized",
    "native_core_ai_claims": "not_authorized",
}

EXECUTION_LIMITATIONS = (
    "The passing execution is deterministic fixture simulation of the declared "
    "analysis-only service behavior; it does not establish native Core AI execution.",
    "Xcode 27, Core AI framework availability, model assets, physical hardware, "
    "Apple-simulator operation, and operator-observed operation were not observed.",
    "No A/B, blinded, ablation, comparative, or superiority test was run or "
    "required for this functional acceptance.",
    "This receipt makes no product-qualification, production, Auto, R09, quality, "
    "performance, publication, or release claim.",
)

ACCEPTANCE_LIMITATIONS = (
    "R08 acceptance is limited to checkpoint-bound proof that the software "
    "performs its declared deterministic analysis-only task.",
    "Comparative, A/B, blinded, ablation, and superiority evidence is absent, "
    "non-authorizing, and not an acceptance dependency.",
    "Native Core AI execution and its unavailable environment, framework, model, "
    "hardware, and simulator observations remain truthfully not observed.",
    "R08 acceptance does not authorize production, Auto, pixel authority, R09, "
    "claims, publication, product qualification, or release.",
)

SUMMARY_KEYS = (
    "schema_version",
    "phase_id",
    "evidence_kind",
    "source",
    "execution_mode",
    "expected_selected_test_count",
    "selected_test_count",
    "passed_test_count",
    "failed_test_count",
    "skipped_test_count",
    "test_suites",
    "toolchain",
)
TOOLCHAIN_KEYS = (
    "platform",
    "architecture",
    "os_version",
    "xcode_version",
    "xcode_build_version",
    "command",
)
HASH_PATTERN = re.compile(r"^(?!0{40}$)[0-9a-f]{40}$")
COMPARATIVE_TEST_PATTERN = re.compile(
    r"(?:Comparison|Comparative|Ablation|Blind|Superiority|Versus|Baseline)"
    r"|^test(?:AB|A_B)(?:[A-Z_]|$)"
)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def inspect(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                if str(key).casefold() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"{context} contains private key at {location}.{key}")
                inspect(child, f"{location}.{key}")
        elif isinstance(item, list):
            for index, child in enumerate(item):
                inspect(child, f"{location}[{index}]")
        elif isinstance(item, str) and (
            EMAIL_PATTERN.search(item) or PRIVATE_PATH_PATTERN.search(item)
        ):
            errors.append(f"{context} contains private identity at {location}")

    inspect(value, "$")
    return errors


class R08PhaseAcceptanceVerifier:
    def __init__(
        self,
        root: Path,
        *,
        contract_paths: Sequence[tuple[str, Path]] = CONTRACT_PATHS,
        implementation_paths: Sequence[tuple[str, Path]] = IMPLEMENTATION_PATHS,
        test_suites: Sequence[tuple[str, Path]] = TEST_SUITES,
        functional_test_methods: Sequence[
            tuple[str, Sequence[str]]
        ] = FUNCTIONAL_TEST_METHODS,
        artifact_paths: Sequence[tuple[str, Path]] = ARTIFACT_PATHS,
    ) -> None:
        self.root = root.resolve()
        self.contract_paths = tuple(contract_paths)
        self.implementation_paths = tuple(implementation_paths)
        self.test_suites = tuple(test_suites)
        self.functional_test_methods = tuple(
            (identifier, tuple(methods))
            for identifier, methods in functional_test_methods
        )
        self.artifact_paths = tuple(artifact_paths)

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

    @staticmethod
    def _source_shape_errors(source: object) -> list[str]:
        if not isinstance(source, dict) or tuple(source) != ("commit", "tree"):
            return ["R08 source must contain exact ordered commit and tree fields"]
        errors: list[str] = []
        for key in ("commit", "tree"):
            value = source.get(key)
            if not isinstance(value, str) or HASH_PATTERN.fullmatch(value) is None:
                errors.append(f"R08 source {key} must be a nonzero lowercase Git hash")
        return errors

    def resolve_source(self, revision: str) -> dict[str, str]:
        commit = self.git("rev-parse", "--verify", f"{revision}^{{commit}}")
        if commit.returncode != 0 or HASH_PATTERN.fullmatch(commit.stdout.strip()) is None:
            raise ValueError("R08 source revision does not resolve to a commit")
        commit_hash = commit.stdout.strip()
        tree = self.git("rev-parse", f"{commit_hash}^{{tree}}")
        if tree.returncode != 0 or HASH_PATTERN.fullmatch(tree.stdout.strip()) is None:
            raise ValueError("R08 source commit tree is unavailable")
        return {"commit": commit_hash, "tree": tree.stdout.strip()}

    def _source_errors(self, source: object) -> list[str]:
        errors = self._source_shape_errors(source)
        if errors or not isinstance(source, dict):
            return errors
        commit = str(source["commit"])
        tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if tree.returncode != 0:
            return ["R08 functional source commit is unavailable"]
        if tree.stdout.strip() != source["tree"]:
            errors.append("R08 functional source tree differs")
        ancestor = self.git("merge-base", "--is-ancestor", commit, "HEAD")
        if ancestor.returncode != 0:
            errors.append("R08 functional source commit is not an ancestor of HEAD")
        return errors

    @staticmethod
    def _normalized_path(
        relative: Path, context: str, errors: list[str]
    ) -> str | None:
        text = relative.as_posix()
        pure = PurePosixPath(text)
        if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != text:
            errors.append(f"{context} path must be normalized and repository-relative")
            return None
        return text

    def _checkpoint_binding(
        self, source: Mapping[str, str], identifier: str, relative: Path
    ) -> dict[str, object]:
        historical = self.git_bytes(
            "show", f"{source['commit']}:{relative.as_posix()}"
        )
        if historical.returncode != 0 or not historical.stdout:
            raise ValueError(f"checkpoint file unavailable: {relative.as_posix()}")
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(historical.stdout),
            "sha256": _sha256(historical.stdout),
        }

    def _file_binding(self, identifier: str, relative: Path) -> dict[str, object]:
        payload = (self.root / relative).read_bytes()
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    def _checkpoint_file_errors(
        self,
        source: Mapping[str, str],
        bindings: Sequence[tuple[str, Path]],
        context: str,
    ) -> list[str]:
        errors: list[str] = []
        for identifier, relative in bindings:
            if self._normalized_path(relative, context, errors) is None:
                continue
            path = self.root / relative
            if path.is_symlink() or not path.is_file():
                errors.append(f"R08 {context} is absent: {identifier}")
                continue
            historical = self.git_bytes(
                "show", f"{source['commit']}:{relative.as_posix()}"
            )
            if historical.returncode != 0:
                errors.append(f"R08 {context} is absent from checkpoint: {identifier}")
            elif historical.stdout != path.read_bytes():
                errors.append(f"R08 {context} differs from checkpoint: {identifier}")
        return errors

    def contract_bindings(
        self, source: Mapping[str, str]
    ) -> list[dict[str, object]]:
        return [
            self._checkpoint_binding(source, identifier, relative)
            for identifier, relative in self.contract_paths
        ]

    def implementation_bindings(
        self, source: Mapping[str, str]
    ) -> list[dict[str, object]]:
        return [
            self._checkpoint_binding(source, identifier, relative)
            for identifier, relative in self.implementation_paths
        ]

    def artifact_bindings(self) -> list[dict[str, object]]:
        return [
            self._file_binding(identifier, relative)
            for identifier, relative in self.artifact_paths
        ]

    @staticmethod
    def _test_methods(source_text: str) -> tuple[str, ...]:
        return tuple(re.findall(
            r"^\s*func\s+(test[A-Za-z0-9_]+)\s*\(",
            source_text,
            flags=re.MULTILINE,
        ))

    @classmethod
    def _test_suite_methods(
        cls, source_text: str
    ) -> tuple[dict[str, tuple[str, ...]], list[str]]:
        pattern = re.compile(
            r"^\s*(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*XCTestCase\s*\{",
            flags=re.MULTILINE,
        )
        matches = list(pattern.finditer(source_text))
        suites: dict[str, tuple[str, ...]] = {}
        errors: list[str] = []
        for index, match in enumerate(matches):
            identifier = match.group(1)
            end = matches[index + 1].start() if index + 1 < len(matches) else len(source_text)
            methods = cls._test_methods(source_text[match.end():end])
            if identifier in suites:
                errors.append(f"R08 checkpoint test suite repeats: {identifier}")
            else:
                suites[identifier] = methods
        return suites, errors

    def _checkpoint_test_inventory(
        self, source: Mapping[str, str]
    ) -> tuple[list[dict[str, object]], list[str]]:
        suites: list[dict[str, object]] = []
        errors: list[str] = []
        observed_test_ids: set[str] = set()
        source_cache: dict[Path, tuple[dict[str, tuple[str, ...]], list[str]]] = {}
        for identifier, relative in self.test_suites:
            if relative not in source_cache:
                historical = self.git_bytes(
                    "show", f"{source['commit']}:{relative.as_posix()}"
                )
                try:
                    text = historical.stdout.decode("utf-8")
                except UnicodeDecodeError:
                    text = ""
                if historical.returncode != 0:
                    source_cache[relative] = ({}, [
                        f"R08 checkpoint test file is unavailable: {relative.as_posix()}"
                    ])
                else:
                    source_cache[relative] = self._test_suite_methods(text)
                errors.extend(source_cache[relative][1])
            file_suites, _ = source_cache[relative]
            methods = file_suites.get(identifier, ())
            if not methods:
                errors.append(f"R08 checkpoint test suite is unavailable: {identifier}")
                continue
            if len(methods) != len(set(methods)):
                errors.append(f"R08 checkpoint test methods repeat: {identifier}")
            comparative_methods = [
                method
                for method in methods
                if COMPARATIVE_TEST_PATTERN.search(method)
            ]
            if comparative_methods:
                errors.append(
                    f"R08 checkpoint test suite contains comparative methods: "
                    f"{identifier}: {', '.join(comparative_methods)}"
                )
            observed_test_ids.update(_test_id(identifier, method) for method in methods)
            count = len(methods)
            suites.append({
                "id": identifier,
                "expected_test_count": count,
                "passed_test_count": count,
                "failed_test_count": 0,
                "skipped_test_count": 0,
            })
        for check_id, evidence_tests in self.functional_test_methods:
            absent = sorted(set(evidence_tests) - observed_test_ids)
            if absent:
                errors.append(
                    f"R08 functional check {check_id} lacks checkpoint tests: "
                    + ", ".join(absent)
                )
        mapped_test_ids = {
            test_id
            for _, evidence_tests in self.functional_test_methods
            for test_id in evidence_tests
        }
        unmapped = sorted(observed_test_ids - mapped_test_ids)
        if unmapped:
            errors.append(
                "R08 checkpoint tests lack declared-function mappings: "
                + ", ".join(unmapped)
            )
        return suites, errors

    @staticmethod
    def _comparison_errors(value: object, context: str) -> list[str]:
        if value != COMPARISON_POLICY:
            return [
                f"{context} must keep comparison, A/B, blind, ablation, and "
                "superiority testing absent and non-gating"
            ]
        return []

    def _command_errors(self, command: object) -> list[str]:
        if not isinstance(command, str) or not command:
            return ["R08 test command is absent"]
        try:
            tokens = shlex.split(command)
        except ValueError as error:
            return [f"R08 test command is invalid: {error}"]
        errors: list[str] = []
        if not tokens or PurePosixPath(tokens[0]).name != "xcodebuild":
            errors.append("R08 test command is not xcodebuild")
        if "test" not in tokens and "test-without-building" not in tokens:
            errors.append("R08 test command does not execute tests")
        selections = [
            token.removeprefix("-only-testing:")
            for token in tokens
            if token.startswith("-only-testing:")
        ]
        expected = [f"MirmirTests/{identifier}" for identifier, _ in self.test_suites]
        if selections != expected:
            errors.append("R08 test command selection differs")
        if any(token.startswith("-skip-testing:") for token in tokens):
            errors.append("R08 test command skips selected tests")
        return errors

    def _summary_errors(
        self, value: object, source: Mapping[str, str]
    ) -> list[str]:
        errors = _privacy_errors(value, "R08 xcresult summary")
        if not isinstance(value, dict) or tuple(value) != SUMMARY_KEYS:
            errors.append("R08 xcresult summary keys/order differ")
            return errors
        suites, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        expected_count = sum(int(suite["expected_test_count"]) for suite in suites)
        expected = {
            "schema_version": "1.0.0",
            "phase_id": "R08",
            "evidence_kind": "r08_functional_selected_test_summary_v1",
            "source": dict(source),
            "execution_mode": "deterministic_fixture_simulation",
            "expected_selected_test_count": expected_count,
            "selected_test_count": expected_count,
            "passed_test_count": expected_count,
            "failed_test_count": 0,
            "skipped_test_count": 0,
            "test_suites": suites,
        }
        for key, expected_value in expected.items():
            if value.get(key) != expected_value:
                errors.append(f"R08 xcresult summary field differs: {key}")
        toolchain = value.get("toolchain")
        if not isinstance(toolchain, dict) or tuple(toolchain) != TOOLCHAIN_KEYS:
            errors.append("R08 xcresult summary toolchain keys/order differ")
            return errors
        for key in TOOLCHAIN_KEYS[:-1]:
            if not isinstance(toolchain.get(key), str) or not toolchain[key]:
                errors.append(f"R08 xcresult summary toolchain is absent: {key}")
        errors.extend(self._command_errors(toolchain.get("command")))
        return errors

    @staticmethod
    def _log_errors(value: str, expected_count: int) -> list[str]:
        errors = _privacy_errors(value, "R08 xcodebuild log")
        lines = value.splitlines()
        success_markers = ("** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **")
        failure_markers = ("** TEST FAILED **", "** TEST EXECUTE FAILED **")
        success_count = sum(lines.count(marker) for marker in success_markers)
        if success_count != 1 or any(marker in lines for marker in failure_markers):
            errors.append("R08 xcodebuild log does not record one exact test success")
        result = re.compile(
            rf"Executed {expected_count} tests, with 0 failures \(0 unexpected\)"
        )
        if not any(result.search(line) for line in lines):
            errors.append(
                f"R08 xcodebuild log does not record the exact {expected_count}-test result"
            )
        return errors

    @staticmethod
    def _test_execution(summary: Mapping[str, Any]) -> dict[str, object]:
        return {
            key: summary[key]
            for key in (
                "execution_mode",
                "expected_selected_test_count",
                "selected_test_count",
                "passed_test_count",
                "failed_test_count",
                "skipped_test_count",
                "test_suites",
                "toolchain",
            )
        }

    def expected_execution_receipt(
        self,
        summary: Mapping[str, Any],
        source: Mapping[str, str],
        *,
        artifact_bindings: list[dict[str, object]] | None = None,
    ) -> dict[str, object]:
        bindings = self.artifact_bindings() if artifact_bindings is None else artifact_bindings
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R08",
            "evidence_kind": "r08_deterministic_functional_execution_receipt_v1",
            "source": dict(source),
            "contract_bindings": self.contract_bindings(source),
            "implementation_bindings": self.implementation_bindings(source),
            "artifact_bindings": bindings,
            "test_execution": self._test_execution(summary),
            "observation_status": dict(OBSERVATION_STATUS),
            "comparison_policy": dict(COMPARISON_POLICY),
            "functional_checks": [
                {
                    "id": check_id,
                    "status": "passed",
                    "evidence_tests": list(evidence_tests),
                }
                for check_id, evidence_tests in self.functional_test_methods
            ],
            "result": dict(EXECUTION_RESULT),
            "limitations": list(EXECUTION_LIMITATIONS),
        }

    def expected_acceptance(
        self,
        receipt: Mapping[str, Any],
        *,
        receipt_binding: dict[str, object] | None = None,
    ) -> dict[str, object]:
        binding = (
            self._file_binding("r08_functional_execution_receipt", EXECUTION_RECEIPT_PATH)
            if receipt_binding is None
            else receipt_binding
        )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R08",
            "evidence_kind": "r08_operator_functional_phase_acceptance_v1",
            "source": dict(receipt["source"]),
            "operator_override": dict(OPERATOR_OVERRIDE),
            "functional_gate": dict(FUNCTIONAL_GATE),
            "contract_bindings": receipt["contract_bindings"],
            "implementation_bindings": receipt["implementation_bindings"],
            "execution_receipt_binding": binding,
            "comparison_policy": dict(COMPARISON_POLICY),
            "derived_checks": [
                {"id": check_id, "status": "passed"}
                for check_id in DERIVED_CHECK_IDS
            ],
            "result": dict(ACCEPTANCE_RESULT),
            "authorizations": dict(AUTHORIZATIONS),
            "limitations": list(ACCEPTANCE_LIMITATIONS),
        }

    def _base_errors(self, source: Mapping[str, str]) -> list[str]:
        errors = self._source_errors(source)
        if errors:
            return errors
        errors.extend(self._checkpoint_file_errors(
            source, self.contract_paths, "contract evidence"
        ))
        errors.extend(self._checkpoint_file_errors(
            source, self.implementation_paths, "implementation"
        ))
        _, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        contracts = R08ContractVerifier(self.root)
        errors.extend(contracts.check_preregistration())
        errors.extend(contracts.check_fixtures())
        return errors

    def _artifacts(
        self, source: Mapping[str, str], errors: list[str]
    ) -> tuple[dict[str, Any], str] | None:
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R08 xcresult summary", errors
        )
        log_path = self.root / XCODEBUILD_LOG_PATH
        if log_path.is_symlink() or not log_path.is_file():
            errors.append("R08 xcodebuild log must be a regular non-symlink file")
            return None
        try:
            log = log_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"R08 xcodebuild log is invalid: {error}")
            return None
        if summary is None:
            return None
        errors.extend(self._summary_errors(summary, source))
        expected_count = summary.get("expected_selected_test_count")
        if isinstance(expected_count, int) and not isinstance(expected_count, bool):
            errors.extend(self._log_errors(log, expected_count))
        else:
            errors.append("R08 summary expected test count must be an integer")
        return summary, log

    def check(self) -> list[str]:
        errors: list[str] = []
        receipt = self._read_json(
            EXECUTION_RECEIPT_PATH, "R08 functional execution receipt", errors
        )
        receipt_schema = self._read_json(
            EXECUTION_RECEIPT_SCHEMA_PATH,
            "R08 functional execution receipt schema",
            errors,
        )
        acceptance = self._read_json(
            ACCEPTANCE_PATH, "R08 functional phase acceptance", errors
        )
        acceptance_schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH,
            "R08 functional phase acceptance schema",
            errors,
        )
        if receipt is None:
            return sorted(set(errors))
        source = receipt.get("source")
        source_errors = self._source_shape_errors(source)
        errors.extend(source_errors)
        if source_errors or not isinstance(source, dict):
            return sorted(set(errors))
        typed_source = {"commit": str(source["commit"]), "tree": str(source["tree"])}
        errors.extend(self._base_errors(typed_source))
        artifacts = self._artifacts(typed_source, errors)
        if receipt_schema is not None:
            errors.extend(
                f"R08 functional execution receipt schema: {error}"
                for error in validate_json_schema_instance(receipt_schema, receipt)
            )
        if acceptance is not None and acceptance_schema is not None:
            errors.extend(
                f"R08 functional phase acceptance schema: {error}"
                for error in validate_json_schema_instance(acceptance_schema, acceptance)
            )
        errors.extend(self._comparison_errors(
            receipt.get("comparison_policy"), "R08 execution receipt comparison policy"
        ))
        if acceptance is not None:
            errors.extend(self._comparison_errors(
                acceptance.get("comparison_policy"),
                "R08 phase acceptance comparison policy",
            ))
        if artifacts is not None:
            summary, _ = artifacts
            try:
                expected_receipt = self.expected_execution_receipt(summary, typed_source)
            except (OSError, ValueError) as error:
                errors.append(f"R08 execution receipt derivation failed: {error}")
            else:
                if receipt != expected_receipt:
                    errors.append(
                        "R08 execution receipt is not exactly derived from the "
                        "checkpoint and functional test artifacts"
                    )
        if acceptance is not None:
            try:
                expected_acceptance = self.expected_acceptance(receipt)
            except OSError as error:
                errors.append(f"R08 acceptance derivation failed: {error}")
            else:
                if acceptance != expected_acceptance:
                    errors.append(
                        "R08 phase acceptance is not exactly derived from bound "
                        "software-function evidence"
                    )
        return sorted(set(errors))

    def write(self, revision: str) -> list[str]:
        try:
            source = self.resolve_source(revision)
        except ValueError as error:
            return [str(error)]
        errors = self._base_errors(source)
        artifacts = self._artifacts(source, errors)
        receipt_schema = self._read_json(
            EXECUTION_RECEIPT_SCHEMA_PATH,
            "R08 functional execution receipt schema",
            errors,
        )
        acceptance_schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH,
            "R08 functional phase acceptance schema",
            errors,
        )
        if errors or artifacts is None or receipt_schema is None or acceptance_schema is None:
            return sorted(set(errors))
        summary, _ = artifacts
        try:
            receipt = self.expected_execution_receipt(summary, source)
        except (OSError, ValueError) as error:
            return [f"R08 execution receipt derivation failed: {error}"]
        errors.extend(
            f"R08 functional execution receipt schema: {error}"
            for error in validate_json_schema_instance(receipt_schema, receipt)
        )
        if errors:
            return sorted(set(errors))
        receipt_path = self.root / EXECUTION_RECEIPT_PATH
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(
            json.dumps(receipt, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        acceptance = self.expected_acceptance(receipt)
        errors.extend(
            f"R08 functional phase acceptance schema: {error}"
            for error in validate_json_schema_instance(acceptance_schema, acceptance)
        )
        if errors:
            return sorted(set(errors))
        (self.root / ACCEPTANCE_PATH).write_text(
            json.dumps(acceptance, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        return self.check()


def emit_errors(errors: Iterable[str]) -> int:
    observed = list(dict.fromkeys(errors))
    for error in observed:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if observed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--write", metavar="SOURCE_COMMIT")
    arguments = parser.parse_args(argv)
    verifier = R08PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    errors = verifier.check() if arguments.check else verifier.write(arguments.write)
    if not errors:
        print("R08 functional phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
