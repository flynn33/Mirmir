#!/usr/bin/env python3
"""Derive and validate R09 software-function-only phase acceptance evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping, Sequence

from phase_evidence import (
    EMAIL_PATTERN,
    PRIVATE_EVIDENCE_KEYS,
    PRIVATE_PATH_PATTERN,
    decode_json,
    validate_json_schema_instance,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
EXECUTION_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r09/records/functional-execution-receipt.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r09-functional-execution-receipt-v1.json"
)
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r09/records/functional-phase-acceptance.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r09-functional-phase-acceptance-v1.json"
)
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r09/records/artifacts/functional-phase-acceptance"
)
XCODEBUILD_LOG_PATH = ARTIFACT_DIRECTORY / "xcodebuild.log"
XCRESULT_SUMMARY_PATH = ARTIFACT_DIRECTORY / "xcresult-summary.json"

CONTRACT_PATHS = (
    ("r09_operator_authorization", Path(
        "docs/roadmaps/evidence/r09/records/operator-authorization.json"
    )),
    ("r09_preregistration", Path(
        "docs/roadmaps/evidence/r09/records/preregistration.json"
    )),
    ("r09_fixture_catalog", Path(
        "docs/roadmaps/evidence/r09/records/fixtures/fixture-catalog.json"
    )),
    ("r09_operator_authorization_schema", Path(
        "docs/roadmaps/evidence/schema/r09-operator-authorization-v1.json"
    )),
    ("r09_preregistration_schema", Path(
        "docs/roadmaps/evidence/schema/r09-preregistration-v1.json"
    )),
    ("r09_fixture_catalog_schema", Path(
        "docs/roadmaps/evidence/schema/r09-fixture-catalog-v1.json"
    )),
    ("r09_contract_validator", Path("Scripts/r09_contracts.py")),
    ("r09_contract_validator_tests", Path(
        "Scripts/tests/test_r09_contracts.py"
    )),
    ("phase_evidence_validator_dependency", Path("Scripts/phase_evidence.py")),
    ("r09_phase_acceptance_validator", Path(
        "Scripts/r09_phase_acceptance.py"
    )),
    ("r09_phase_acceptance_validator_tests", Path(
        "Scripts/tests/test_r09_phase_acceptance.py"
    )),
    ("r09_functional_execution_receipt_schema", Path(
        "docs/roadmaps/evidence/schema/"
        "r09-functional-execution-receipt-v1.json"
    )),
    ("r09_functional_phase_acceptance_schema", Path(
        "docs/roadmaps/evidence/schema/"
        "r09-functional-phase-acceptance-v1.json"
    )),
)

IMPLEMENTATION_PATHS = (
    ("r09_residual_identity_contracts_source", Path(
        "Mirmir/Modules/ModelAssets/R09ResidualIdentityContracts.swift"
    )),
    ("r09_core_ai_residual_contracts_source", Path(
        "Mirmir/Modules/ModelAssets/R09CoreAIResidualContracts.swift"
    )),
    ("r09_residual_numeric_contracts_source", Path(
        "Mirmir/Modules/ModelAssets/R09ResidualNumericContracts.swift"
    )),
    ("r09_residual_service_contracts_source", Path(
        "Mirmir/Modules/ModelAssets/R09ResidualServiceContracts.swift"
    )),
    ("r09_residual_validation_source", Path(
        "Mirmir/Modules/ModelAssets/R09ResidualValidation.swift"
    )),
    ("r09_deterministic_residual_service_source", Path(
        "Mirmir/Modules/ModelAssets/R09DeterministicResidualService.swift"
    )),
    ("r09_ash_authorization_contracts_source", Path(
        "Mirmir/Modules/UpscalerEngine/R09ASHResidualAuthorizationContracts.swift"
    )),
    ("r09_ash_authorization_source", Path(
        "Mirmir/Modules/UpscalerEngine/R09ASHResidualAuthorization.swift"
    )),
    ("r09_nv12_planar_codec_source", Path(
        "Mirmir/Modules/UpscalerEngine/R09NV12PlanarCodec.swift"
    )),
    ("r09_bounded_residual_stage_source", Path(
        "Mirmir/Modules/UpscalerEngine/R09BoundedResidualStage.swift"
    )),
    ("r09_residual_test_support", Path(
        "MirmirTests/UpscalerEngine/R09ResidualTestSupport.swift"
    )),
    ("r09_core_ai_residual_contracts_tests", Path(
        "MirmirTests/UpscalerEngine/R09CoreAIResidualContractsTests.swift"
    )),
    ("r09_deterministic_residual_service_tests", Path(
        "MirmirTests/UpscalerEngine/R09DeterministicResidualServiceTests.swift"
    )),
    ("r09_ash_authorization_test_support", Path(
        "MirmirTests/UpscalerEngine/R09ASHResidualAuthorizationTestSupport.swift"
    )),
    ("r09_ash_authorization_tests", Path(
        "MirmirTests/UpscalerEngine/R09ASHResidualAuthorizationTests.swift"
    )),
    ("r09_bounded_residual_stage_test_support", Path(
        "MirmirTests/UpscalerEngine/R09BoundedResidualStageTestSupport.swift"
    )),
    ("r09_bounded_residual_stage_tests", Path(
        "MirmirTests/UpscalerEngine/R09BoundedResidualStageTests.swift"
    )),
    ("r07_functional_test_support_dependency", Path(
        "MirmirTests/UpscalerEngine/R07FunctionalTestSupport.swift"
    )),
    ("project_manifest", Path("project.yml")),
    ("xcode_project", Path("Mirmir.xcodeproj/project.pbxproj")),
)

TEST_SUITES = (
    (
        "R09CoreAIResidualContractsTests",
        Path("MirmirTests/UpscalerEngine/R09CoreAIResidualContractsTests.swift"),
    ),
    (
        "R09DeterministicResidualServiceTests",
        Path("MirmirTests/UpscalerEngine/R09DeterministicResidualServiceTests.swift"),
    ),
    (
        "R09ASHResidualAuthorizationTests",
        Path("MirmirTests/UpscalerEngine/R09ASHResidualAuthorizationTests.swift"),
    ),
    (
        "R09BoundedResidualStageTests",
        Path("MirmirTests/UpscalerEngine/R09BoundedResidualStageTests.swift"),
    ),
)

EXPECTED_SUITE_COUNTS = {
    "R09CoreAIResidualContractsTests": 7,
    "R09DeterministicResidualServiceTests": 8,
    "R09ASHResidualAuthorizationTests": 6,
    "R09BoundedResidualStageTests": 5,
}
EXPECTED_SELECTED_TEST_COUNT = 26


def _test_id(suite: str, method: str) -> str:
    return f"MirmirTests/{suite}/{method}"


FUNCTIONAL_TEST_METHODS = (
    (
        "numeric_contracts_geometry_plane_and_range",
        (
            _test_id(
                "R09CoreAIResidualContractsTests",
                "testUnsignedQ16PlaneValidatesGeometryCountAndRange",
            ),
            _test_id(
                "R09CoreAIResidualContractsTests",
                "testPlanarContractsRequireExactlyOneOfEveryPlane",
            ),
            _test_id(
                "R09CoreAIResidualContractsTests",
                "testMasksLimitsAndSignedResidualsEnforceIntegerDomains",
            ),
        ),
    ),
    (
        "request_authorization_execution_identity_and_budget",
        (
            _test_id(
                "R09CoreAIResidualContractsTests",
                "testRequestRejectsAnyGeometryMismatch",
            ),
            _test_id(
                "R09CoreAIResidualContractsTests",
                "testAuthorizationCannotReplayAcrossBoundaryIdentity",
            ),
            _test_id(
                "R09CoreAIResidualContractsTests",
                "testExecutionIdentityCannotMisstateNativeObservation",
            ),
            _test_id(
                "R09CoreAIResidualContractsTests",
                "testReferenceOrdinalsAndResourceBudgetsFailClosedAtConstruction",
            ),
        ),
    ),
    (
        "deterministic_signed_bounded_residual_proposal",
        (
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testDeterministicOutputIsRepeatableAndTruthfullySimulated",
            ),
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testOutputIsSignedZeroCenteredAndBoundedByEveryInputPolicy",
            ),
        ),
    ),
    (
        "service_fail_closed_confidence_resource_safety_lifecycle",
        (
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testInputAndProviderConfidenceFailuresBypassWithoutResidual",
            ),
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testResourceFailuresAreTypedAndFailClosed",
            ),
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testMalformedProviderRangeAndDirectionBypass",
            ),
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testIdentityMismatchAndProviderFailureAreDistinctBypasses",
            ),
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testEligibilityHallucinationAndConsistencyStopsAreTyped",
            ),
            _test_id(
                "R09DeterministicResidualServiceTests",
                "testPolicyAvailabilityBusyAndCancellationRemainFailClosed",
            ),
        ),
    ),
    (
        "ash_authorization_mask_and_chroma_bounds",
        (
            _test_id(
                "R09ASHResidualAuthorizationTests",
                "testAnalyzedSidecarAuthorizesExactRequestAndEchoesPlanSuppliedBounds",
            ),
            _test_id(
                "R09ASHResidualAuthorizationTests",
                "testFaceTextAndR07ProtectionSuppressEligibilityAndUseMaximumProtection",
            ),
            _test_id(
                "R09ASHResidualAuthorizationTests",
                "testChromaEligibilityUsesMinimumOfEachTwoByTwoLumaBlock",
            ),
        ),
    ),
    (
        "ash_bypass_identity_and_replay_rejection",
        (
            _test_id(
                "R09ASHResidualAuthorizationTests",
                "testR08BypassProducesTypedNoAuthorizationAndAppleOnlyFallback",
            ),
            _test_id(
                "R09ASHResidualAuthorizationTests",
                "testFrameShotStreamGenerationAndPrimaryRouteMismatchesReject",
            ),
            _test_id(
                "R09ASHResidualAuthorizationTests",
                "testAuthorizationReplayAndFrozenContractDriftReject",
            ),
        ),
    ),
    (
        "transactional_application_rollback_and_independent_validation",
        (
            _test_id(
                "R09BoundedResidualStageTests",
                "testServiceToStageAppliesBoundedResidualAndPreservesExactRollback",
            ),
            _test_id(
                "R09BoundedResidualStageTests",
                "testProtectedSampleRejectsWholeProposalWithoutPartialPixelApplication",
            ),
            _test_id(
                "R09BoundedResidualStageTests",
                "testStageIndependentlyRejectsConfidenceResourceAndHallucinationFailures",
            ),
            _test_id(
                "R09BoundedResidualStageTests",
                "testExecutionAndAppleFrameIdentityMismatchesReturnOriginalFrame",
            ),
        ),
    ),
    (
        "nv12_planar_round_trip_and_format_rejection",
        (_test_id(
            "R09BoundedResidualStageTests",
            "testNV12CodecRoundTripsActiveSamplesAndRejectsUnsupportedFormat",
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
    "superiority_requirement": "not_run_not_required",
    "acceptance_dependency": "none",
}

CONTRACT_INTERPRETATIONS = {
    "hallucination_risk_present":
        "typed_risk_exceeds_request_supplied_maximum",
    "deterministic_provider_content_sha256":
        "semantic_contract_identity_not_source_file_digest",
    "provider_source_provenance":
        "checkpoint_commit_tree_and_implementation_binding",
    "fixture_catalog_execution":
        "semantic_test_mapping_not_direct_catalog_execution",
}

OBSERVATION_STATUS = {
    "deterministic_software_execution": "observed",
    "deterministic_fixture_simulation": "observed",
    "native_core_ai_execution": "not_observed",
    "core_ai_framework_availability": "not_observed",
    "model_asset_availability": "not_observed",
    "model_asset_execution": "not_observed",
    "physical_hardware_execution": "not_observed",
    "apple_simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
}

EXECUTION_RESULT = {
    "status": "passed",
    "functional_software_conformance": "passed",
    "declared_software_behavior": "conformant",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_simulation",
    "native_core_ai_qualification": "not_claimed",
    "product_qualification": "not_claimed",
    "roadmap_exit_outcome": "qualified_local_residual",
}

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "authorization_date": "2026-07-22",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "override_id": "r09.software-function-only-phase-acceptance.v1",
    "comparative_requirement": "not_run_not_required",
    "a_b_requirement": "not_run_not_required",
    "blinded_requirement": "not_run_not_required",
    "ablation_requirement": "not_run_not_required",
    "superiority_requirement": "not_run_not_required",
    "native_execution": "supplemental_not_required",
}

FUNCTIONAL_GATE = {
    "acceptance_basis": "software_does_what_it_says_it_does",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_simulation",
    "required_test_suites": [identifier for identifier, _ in TEST_SUITES],
    "required_test_count": EXPECTED_SELECTED_TEST_COUNT,
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
    "selected_26_test_set_exact",
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
    "acceptance_basis": "software_does_what_it_says_it_does",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_simulation",
    "native_core_ai_qualification": "not_claimed",
    "product_qualification": "not_claimed",
    "roadmap_exit_outcome": "qualified_local_residual",
}

AUTHORIZATIONS = {
    "r09_phase_acceptance": "authorized",
    "r09_phase_status": "passed",
    "r10_phase_progression": "not_authorized_requires_separate_operator_authorization",
    "production_default": "not_authorized",
    "auto_mode": "not_authorized",
    "holdout": "not_authorized",
    "quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "product_publication": "not_authorized",
    "release": "not_authorized",
    "native_core_ai_claims": "not_authorized",
}

EXECUTION_LIMITATIONS = (
    "The passing execution is deterministic fixture simulation of the declared "
    "bounded residual behavior; it does not establish native Core AI execution.",
    "Native Core AI, Core AI framework and model-asset availability or execution, "
    "physical hardware, Apple simulator, and operator operation were not observed.",
    "No A/B, blinded, ablation, comparative, or superiority test was run or "
    "required for this functional acceptance.",
    "This receipt makes no product-qualification, production, Auto, holdout, "
    "quality, performance, publication, or release claim.",
    "The frozen phrase hallucination risk present is interpreted as typed risk "
    "exceeding the request-supplied maximum; nonzero risk at or below that maximum "
    "is not a declared violation.",
    "The deterministic provider content SHA-256 is a semantic contract identity, "
    "not a digest of one source file; exact source provenance is the checkpoint "
    "commit, tree, and implementation bindings.",
    "The frozen fixture catalog is bound and its semantics are mapped to selected "
    "tests, but the catalog JSON itself is not directly executed by the Swift suite.",
)

ACCEPTANCE_LIMITATIONS = (
    "R09 acceptance is limited to checkpoint-bound proof that the software "
    "performs its declared bounded residual task.",
    "Comparative, A/B, blinded, ablation, and superiority evidence is absent, "
    "non-authorizing, and not an acceptance dependency.",
    "Native Core AI, model, hardware, simulator, and operator observations remain "
    "truthfully not observed and are not required by this functional gate.",
    "R09 acceptance does not authorize production, Auto, holdout, claims, "
    "publication, product qualification, R10 progression, or release.",
    "Hallucination risk present means typed risk above the request-supplied "
    "maximum for this acceptance; values at or below that maximum remain eligible.",
    "The provider SHA-256 is a semantic contract identity; provider source bytes "
    "are authenticated by the checkpoint commit, tree, and named bindings.",
    "Selected tests provide semantic mappings to the frozen fixture catalog; the "
    "catalog JSON was not itself used as a Swift test input resource.",
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
    "test_identifiers",
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


class R09PhaseAcceptanceVerifier:
    def __init__(
        self,
        root: Path,
        *,
        contract_paths: Sequence[tuple[str, Path]] = CONTRACT_PATHS,
        implementation_paths: Sequence[tuple[str, Path]] = IMPLEMENTATION_PATHS,
        test_suites: Sequence[tuple[str, Path]] = TEST_SUITES,
        expected_suite_counts: Mapping[str, int] = EXPECTED_SUITE_COUNTS,
        functional_test_methods: Sequence[
            tuple[str, Sequence[str]]
        ] = FUNCTIONAL_TEST_METHODS,
        artifact_paths: Sequence[tuple[str, Path]] = ARTIFACT_PATHS,
    ) -> None:
        self.root = root.resolve()
        self.contract_paths = tuple(contract_paths)
        self.implementation_paths = tuple(implementation_paths)
        self.test_suites = tuple(test_suites)
        self.expected_suite_counts = dict(expected_suite_counts)
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
            return ["R09 source must contain exact ordered commit and tree fields"]
        errors: list[str] = []
        for key in ("commit", "tree"):
            value = source.get(key)
            if not isinstance(value, str) or HASH_PATTERN.fullmatch(value) is None:
                errors.append(f"R09 source {key} must be a nonzero lowercase Git hash")
        return errors

    def resolve_source(self, revision: str) -> dict[str, str]:
        commit = self.git("rev-parse", "--verify", f"{revision}^{{commit}}")
        if commit.returncode != 0 or HASH_PATTERN.fullmatch(commit.stdout.strip()) is None:
            raise ValueError("R09 source revision does not resolve to a commit")
        commit_hash = commit.stdout.strip()
        tree = self.git("rev-parse", f"{commit_hash}^{{tree}}")
        if tree.returncode != 0 or HASH_PATTERN.fullmatch(tree.stdout.strip()) is None:
            raise ValueError("R09 source commit tree is unavailable")
        return {"commit": commit_hash, "tree": tree.stdout.strip()}

    def _source_errors(self, source: object) -> list[str]:
        errors = self._source_shape_errors(source)
        if errors or not isinstance(source, dict):
            return errors
        commit = str(source["commit"])
        tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if tree.returncode != 0:
            return ["R09 functional source commit is unavailable"]
        if tree.stdout.strip() != source["tree"]:
            errors.append("R09 functional source tree differs")
        ancestor = self.git("merge-base", "--is-ancestor", commit, "HEAD")
        if ancestor.returncode != 0:
            errors.append("R09 functional source commit is not an ancestor of HEAD")
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

    @staticmethod
    def _payload_binding(
        identifier: str, relative: Path, payload: bytes
    ) -> dict[str, object]:
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
            historical = self.git_bytes(
                "show", f"{source['commit']}:{relative.as_posix()}"
            )
            if historical.returncode != 0 or not historical.stdout:
                errors.append(f"R09 {context} is absent from checkpoint: {identifier}")
        return errors

    def _write_source_errors(self, source: Mapping[str, str]) -> list[str]:
        errors: list[str] = []
        head = self.git("rev-parse", "HEAD")
        if head.returncode != 0 or head.stdout.strip() != source["commit"]:
            errors.append("R09 evidence write source must equal the exact current HEAD")
            return errors
        relative_paths = tuple(dict.fromkeys(
            relative.as_posix()
            for _, relative in (*self.contract_paths, *self.implementation_paths)
        ))
        for relative in relative_paths:
            current = self.root / relative
            if current.is_symlink() or not current.is_file():
                errors.append(
                    f"R09 evidence write path must be a regular checkpoint file: {relative}"
                )
        diff = self.git("diff", "--quiet", source["commit"], "--", *relative_paths)
        if diff.returncode == 1:
            errors.append("R09 evidence write bound paths differ from the source checkpoint")
        elif diff.returncode != 0:
            errors.append("R09 evidence write could not compare bound checkpoint paths")
        return errors

    def _production_boundary_errors(
        self, source: Mapping[str, str]
    ) -> list[str]:
        listing = self.git(
            "ls-tree", "-r", "--name-only", source["commit"], "--", "Mirmir"
        )
        if listing.returncode != 0:
            return ["R09 production-boundary source inventory is unavailable"]
        allowed = {
            relative.as_posix()
            for _, relative in self.implementation_paths
            if relative.parts[:1] == ("Mirmir",)
            and relative.name.startswith("R09")
        }
        pattern = re.compile(
            r"\b(?:R09BoundedResidualStage|R09DeterministicResidualService)\b"
        )
        errors: list[str] = []
        for path in listing.stdout.splitlines():
            if not path.endswith(".swift") or path in allowed:
                continue
            historical = self.git_bytes("show", f"{source['commit']}:{path}")
            if historical.returncode != 0:
                errors.append(f"R09 production-boundary file is unavailable: {path}")
                continue
            try:
                text = historical.stdout.decode("utf-8")
            except UnicodeDecodeError:
                errors.append(f"R09 production-boundary file is not UTF-8: {path}")
                continue
            if pattern.search(text):
                errors.append(f"R09 runtime is wired outside its experiment boundary: {path}")
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
                errors.append(f"R09 checkpoint test suite repeats: {identifier}")
            else:
                suites[identifier] = methods
        return suites, errors

    def _checkpoint_test_inventory(
        self, source: Mapping[str, str]
    ) -> tuple[list[dict[str, object]], list[str], list[str]]:
        suites: list[dict[str, object]] = []
        ordered_test_ids: list[str] = []
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
                        f"R09 checkpoint test file is unavailable: {relative.as_posix()}"
                    ])
                else:
                    source_cache[relative] = self._test_suite_methods(text)
                errors.extend(source_cache[relative][1])
            file_suites, _ = source_cache[relative]
            methods = file_suites.get(identifier, ())
            if not methods:
                errors.append(f"R09 checkpoint test suite is unavailable: {identifier}")
                continue
            if len(methods) != len(set(methods)):
                errors.append(f"R09 checkpoint test methods repeat: {identifier}")
            expected_count = self.expected_suite_counts.get(identifier)
            if expected_count is None or len(methods) != expected_count:
                errors.append(
                    f"R09 checkpoint test count differs: {identifier}: "
                    f"expected {expected_count}, observed {len(methods)}"
                )
            comparative_methods = [
                method for method in methods if COMPARATIVE_TEST_PATTERN.search(method)
            ]
            if comparative_methods:
                errors.append(
                    f"R09 checkpoint test suite contains comparative methods: "
                    f"{identifier}: {', '.join(comparative_methods)}"
                )
            observed_test_ids.update(_test_id(identifier, method) for method in methods)
            ordered_test_ids.extend(_test_id(identifier, method) for method in methods)
            count = len(methods)
            suites.append({
                "id": identifier,
                "expected_test_count": count,
                "passed_test_count": count,
                "failed_test_count": 0,
                "skipped_test_count": 0,
            })
        selected_count = sum(
            int(suite["expected_test_count"]) for suite in suites
        )
        expected_total = sum(self.expected_suite_counts.values())
        if selected_count != expected_total:
            errors.append(
                f"R09 checkpoint selected test count differs: expected "
                f"{expected_total}, observed {selected_count}"
            )
        required_test_ids = {
            test_id
            for _, evidence_tests in self.functional_test_methods
            for test_id in evidence_tests
        }
        missing = sorted(required_test_ids - observed_test_ids)
        if missing:
            errors.append(
                "R09 functional checks lack checkpoint tests: " + ", ".join(missing)
            )
        unmapped = sorted(observed_test_ids - required_test_ids)
        if unmapped:
            errors.append(
                "R09 checkpoint tests lack declared-function mappings: "
                + ", ".join(unmapped)
            )
        return suites, ordered_test_ids, errors

    @staticmethod
    def _comparison_errors(value: object, context: str) -> list[str]:
        if value != COMPARISON_POLICY:
            return [
                f"{context} must keep comparison, A/B, blind, ablation, and "
                "superiority testing not run, not required, and non-gating"
            ]
        return []

    def _command_errors(self, command: object) -> list[str]:
        if not isinstance(command, str) or not command:
            return ["R09 test command is absent"]
        try:
            tokens = shlex.split(command)
        except ValueError as error:
            return [f"R09 test command is invalid: {error}"]
        errors: list[str] = []
        if not tokens or PurePosixPath(tokens[0]).name != "xcodebuild":
            errors.append("R09 test command is not xcodebuild")
        if tokens.count("test") != 1 or "test-without-building" in tokens:
            errors.append("R09 test command must perform one fresh build-and-test action")
        for option, expected in (
            ("-project", "Mirmir.xcodeproj"),
            ("-scheme", "Mirmir"),
        ):
            try:
                value = tokens[tokens.index(option) + 1]
            except (ValueError, IndexError):
                value = None
            if value != expected:
                errors.append(f"R09 test command {option} differs")
        destinations = [
            tokens[index + 1]
            for index, token in enumerate(tokens[:-1])
            if token == "-destination"
        ]
        if len(destinations) != 1 or not destinations[0].startswith("platform=macOS"):
            errors.append("R09 test command destination must be macOS")
        selections = [
            token.removeprefix("-only-testing:")
            for token in tokens
            if token.startswith("-only-testing:")
        ]
        expected = [f"MirmirTests/{identifier}" for identifier, _ in self.test_suites]
        if selections != expected:
            errors.append("R09 test command selection differs")
        if any(token.startswith("-skip-testing:") for token in tokens):
            errors.append("R09 test command skips selected tests")
        if "CODE_SIGNING_ALLOWED=NO" not in tokens:
            errors.append("R09 test command code-signing boundary differs")
        return errors

    def _summary_errors(
        self, value: object, source: Mapping[str, str]
    ) -> list[str]:
        errors = _privacy_errors(value, "R09 xcresult summary")
        if not isinstance(value, dict) or tuple(value) != SUMMARY_KEYS:
            errors.append("R09 xcresult summary keys/order differ")
            return errors
        suites, test_identifiers, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        expected_count = sum(int(suite["expected_test_count"]) for suite in suites)
        expected = {
            "schema_version": "1.0.0",
            "phase_id": "R09",
            "evidence_kind": "r09_functional_selected_test_summary_v1",
            "source": dict(source),
            "execution_mode": "deterministic_fixture_simulation",
            "expected_selected_test_count": expected_count,
            "selected_test_count": expected_count,
            "passed_test_count": expected_count,
            "failed_test_count": 0,
            "skipped_test_count": 0,
            "test_suites": suites,
            "test_identifiers": test_identifiers,
        }
        for key, expected_value in expected.items():
            if value.get(key) != expected_value:
                errors.append(f"R09 xcresult summary field differs: {key}")
        if expected_count != EXPECTED_SELECTED_TEST_COUNT:
            errors.append("R09 xcresult summary does not derive exactly 26 tests")
        toolchain = value.get("toolchain")
        if not isinstance(toolchain, dict) or tuple(toolchain) != TOOLCHAIN_KEYS:
            errors.append("R09 xcresult summary toolchain keys/order differ")
            return errors
        for key in TOOLCHAIN_KEYS[:-1]:
            if not isinstance(toolchain.get(key), str) or not toolchain[key]:
                errors.append(f"R09 xcresult summary toolchain is absent: {key}")
        errors.extend(self._command_errors(toolchain.get("command")))
        return errors

    @staticmethod
    def _log_errors(value: str, expected_count: int) -> list[str]:
        errors = _privacy_errors(value, "R09 xcodebuild log")
        lines = value.splitlines()
        success_markers = ("** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **")
        failure_markers = ("** TEST FAILED **", "** TEST EXECUTE FAILED **")
        success_count = sum(lines.count(marker) for marker in success_markers)
        if success_count != 1 or any(marker in lines for marker in failure_markers):
            errors.append("R09 xcodebuild log does not record one exact test success")
        result = re.compile(
            rf"Executed {expected_count} tests, with 0 failures \(0 unexpected\)"
        )
        if not any(result.search(line) for line in lines):
            errors.append(
                f"R09 xcodebuild log does not record the exact "
                f"{expected_count}-test result"
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
                "test_identifiers",
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
            "phase_id": "R09",
            "evidence_kind": "r09_deterministic_functional_execution_receipt_v1",
            "source": dict(source),
            "contract_bindings": self.contract_bindings(source),
            "implementation_bindings": self.implementation_bindings(source),
            "artifact_bindings": bindings,
            "test_execution": self._test_execution(summary),
            "observation_status": dict(OBSERVATION_STATUS),
            "comparison_policy": dict(COMPARISON_POLICY),
            "contract_interpretations": dict(CONTRACT_INTERPRETATIONS),
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
            self._file_binding("r09_functional_execution_receipt", EXECUTION_RECEIPT_PATH)
            if receipt_binding is None
            else receipt_binding
        )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R09",
            "evidence_kind": "r09_operator_functional_phase_acceptance_v1",
            "source": dict(receipt["source"]),
            "operator_override": dict(OPERATOR_OVERRIDE),
            "functional_gate": dict(FUNCTIONAL_GATE),
            "contract_bindings": receipt["contract_bindings"],
            "implementation_bindings": receipt["implementation_bindings"],
            "execution_receipt_binding": binding,
            "comparison_policy": dict(COMPARISON_POLICY),
            "contract_interpretations": dict(CONTRACT_INTERPRETATIONS),
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
        _, _, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        errors.extend(self._production_boundary_errors(source))
        return errors

    def _artifacts(
        self, source: Mapping[str, str], errors: list[str]
    ) -> tuple[dict[str, Any], str] | None:
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R09 xcresult summary", errors
        )
        log_path = self.root / XCODEBUILD_LOG_PATH
        if log_path.is_symlink() or not log_path.is_file():
            errors.append("R09 xcodebuild log must be a regular non-symlink file")
            return None
        try:
            log = log_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"R09 xcodebuild log is invalid: {error}")
            return None
        if summary is None:
            return None
        errors.extend(self._summary_errors(summary, source))
        expected_count = summary.get("expected_selected_test_count")
        if isinstance(expected_count, int) and not isinstance(expected_count, bool):
            errors.extend(self._log_errors(log, expected_count))
        else:
            errors.append("R09 summary expected test count must be an integer")
        return summary, log

    def check(self) -> list[str]:
        errors: list[str] = []
        receipt = self._read_json(
            EXECUTION_RECEIPT_PATH, "R09 functional execution receipt", errors
        )
        receipt_schema = self._read_json(
            EXECUTION_RECEIPT_SCHEMA_PATH,
            "R09 functional execution receipt schema",
            errors,
        )
        acceptance = self._read_json(
            ACCEPTANCE_PATH, "R09 functional phase acceptance", errors
        )
        acceptance_schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH,
            "R09 functional phase acceptance schema",
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
                f"R09 functional execution receipt schema: {error}"
                for error in validate_json_schema_instance(receipt_schema, receipt)
            )
        if acceptance is not None and acceptance_schema is not None:
            errors.extend(
                f"R09 functional phase acceptance schema: {error}"
                for error in validate_json_schema_instance(acceptance_schema, acceptance)
            )
        errors.extend(self._comparison_errors(
            receipt.get("comparison_policy"), "R09 execution receipt comparison policy"
        ))
        if acceptance is not None:
            errors.extend(self._comparison_errors(
                acceptance.get("comparison_policy"),
                "R09 phase acceptance comparison policy",
            ))
        if artifacts is not None:
            summary, _ = artifacts
            try:
                expected_receipt = self.expected_execution_receipt(summary, typed_source)
            except (OSError, ValueError) as error:
                errors.append(f"R09 execution receipt derivation failed: {error}")
            else:
                if receipt != expected_receipt:
                    errors.append(
                        "R09 execution receipt is not exactly derived from the "
                        "checkpoint and functional test artifacts"
                    )
        if acceptance is not None:
            try:
                expected_acceptance = self.expected_acceptance(receipt)
            except OSError as error:
                errors.append(f"R09 acceptance derivation failed: {error}")
            else:
                if acceptance != expected_acceptance:
                    errors.append(
                        "R09 phase acceptance is not exactly derived from bound "
                        "software-function evidence"
                    )
        return sorted(set(errors))

    def write(self, revision: str) -> list[str]:
        try:
            source = self.resolve_source(revision)
        except ValueError as error:
            return [str(error)]
        errors = self._base_errors(source)
        errors.extend(self._write_source_errors(source))
        artifacts = self._artifacts(source, errors)
        receipt_schema = self._read_json(
            EXECUTION_RECEIPT_SCHEMA_PATH,
            "R09 functional execution receipt schema",
            errors,
        )
        acceptance_schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH,
            "R09 functional phase acceptance schema",
            errors,
        )
        if errors or artifacts is None or receipt_schema is None or acceptance_schema is None:
            return sorted(set(errors))
        summary, _ = artifacts
        try:
            receipt = self.expected_execution_receipt(summary, source)
        except (OSError, ValueError) as error:
            return [f"R09 execution receipt derivation failed: {error}"]
        errors.extend(
            f"R09 functional execution receipt schema: {error}"
            for error in validate_json_schema_instance(receipt_schema, receipt)
        )
        if errors:
            return sorted(set(errors))
        receipt_payload = (
            json.dumps(receipt, indent=2, ensure_ascii=False) + "\n"
        ).encode("utf-8")
        receipt_binding = self._payload_binding(
            "r09_functional_execution_receipt",
            EXECUTION_RECEIPT_PATH,
            receipt_payload,
        )
        acceptance = self.expected_acceptance(
            receipt,
            receipt_binding=receipt_binding,
        )
        errors.extend(
            f"R09 functional phase acceptance schema: {error}"
            for error in validate_json_schema_instance(acceptance_schema, acceptance)
        )
        if errors:
            return sorted(set(errors))
        acceptance_payload = (
            json.dumps(acceptance, indent=2, ensure_ascii=False) + "\n"
        ).encode("utf-8")
        outputs = (
            (self.root / EXECUTION_RECEIPT_PATH, receipt_payload),
            (self.root / ACCEPTANCE_PATH, acceptance_payload),
        )
        for path, _ in outputs:
            if path.is_symlink():
                errors.append(f"R09 evidence output must not be a symlink: {path.name}")
        if errors:
            return sorted(set(errors))
        temporary_paths: list[Path] = []
        try:
            for path, payload in outputs:
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
                    temporary_paths.append(Path(temporary.name))
            for (path, _), temporary_path in zip(outputs, temporary_paths):
                os.replace(temporary_path, path)
        except OSError as error:
            return [f"R09 evidence output write failed: {error}"]
        finally:
            for temporary_path in temporary_paths:
                temporary_path.unlink(missing_ok=True)
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
    verifier = R09PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    errors = verifier.check() if arguments.check else verifier.write(arguments.write)
    if not errors:
        print("R09 functional phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
