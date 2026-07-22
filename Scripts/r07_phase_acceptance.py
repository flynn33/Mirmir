#!/usr/bin/env python3
"""Derive and validate operator-authorized R07 functional phase acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
from typing import Any, Iterable

from phase_evidence import (
    EMAIL_PATTERN,
    PRIVATE_EVIDENCE_KEYS,
    PRIVATE_PATH_PATTERN,
    decode_json,
    validate_json_schema_instance,
)
from r07_contracts import CONFORMANCE_PATH, R07ContractVerifier


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
EXECUTION_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r07/records/functional-execution-receipt.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r07-functional-execution-receipt-v1.json"
)
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r07/records/functional-phase-acceptance.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r07-functional-phase-acceptance-v1.json"
)
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r07/records/artifacts/functional-phase-acceptance"
)
XCODEBUILD_LOG_PATH = ARTIFACT_DIRECTORY / "xcodebuild.log"
XCRESULT_SUMMARY_PATH = ARTIFACT_DIRECTORY / "xcresult-summary.json"

SOURCE_COMMIT = "1b46ad469265a6ba837a8449d28b8850889f1d3f"
SOURCE_TREE = "09d3a48df01738bb26077aadfd83c08e389a1dc2"
SOURCE = {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE}

HISTORICAL_BINDINGS = (
    (
        "r07_preregistration",
        Path("docs/roadmaps/evidence/r07/records/preregistration.json"),
        18_672,
        "150bdbc7e0c06cba33bf8ba67bc8502a292a96de4784b8492be7663d523df4be",
    ),
    (
        "r07_fixture_catalog",
        Path("docs/roadmaps/evidence/r07/records/fixtures/fixture-catalog.json"),
        48_288,
        "c919c1f9314654d120fe20ef2698bd3938133139dd6c8de306f823a7805ac610",
    ),
    (
        "r07_preregistration_schema",
        Path("docs/roadmaps/evidence/schema/r07-preregistration-v1.json"),
        26_559,
        "a3bbad9456311c0ddb7f9ed508c725dd38a2ac5a0244499c096fa2503cafc5b6",
    ),
    (
        "r07_fixture_catalog_schema",
        Path("docs/roadmaps/evidence/schema/r07-fixture-catalog-v1.json"),
        83_310,
        "9992ad942256d50ad8e1a7231ca378cf29c262954af15d753d2a14b1015f6178",
    ),
    (
        "r07_temporal_conformance_schema",
        Path(
            "docs/roadmaps/evidence/schema/"
            "r07-temporal-artifact-conformance-v1.json"
        ),
        9_338,
        "3fba168f254c888ba77fae3ccfc63f96816dad44cd869f8f86e4d6e431314dc3",
    ),
    (
        "r06_phase_evidence",
        Path("docs/roadmaps/evidence/r06/phase-evidence.json"),
        11_395,
        "555508b60108903019798d31e34f3cecd6575e18a39cff07069237e7cf823f00",
    ),
    (
        "r06_orchestration_conformance",
        Path(
            "docs/roadmaps/evidence/r06/records/orchestration-conformance.json"
        ),
        5_800,
        "19f25269e9cb62ba162e2c53d716a79a392fef740a0be0c7d981cbdac3bfeccc",
    ),
)

IMPLEMENTATION_PATHS = (
    (
        "r07_temporal_governance_contracts_source",
        Path("Mirmir/Modules/UpscalerEngine/R07TemporalGovernanceContracts.swift"),
    ),
    (
        "r07_temporal_history_source",
        Path("Mirmir/Modules/UpscalerEngine/R07TemporalHistory.swift"),
    ),
    (
        "r07_artifact_governance_source",
        Path("Mirmir/Modules/UpscalerEngine/R07ArtifactGovernance.swift"),
    ),
    (
        "r07_protected_region_policy_source",
        Path("Mirmir/Modules/UpscalerEngine/R07ProtectedRegionPolicy.swift"),
    ),
    (
        "r07_support_stage_policy_source",
        Path("Mirmir/Modules/UpscalerEngine/R07SupportStagePolicy.swift"),
    ),
    (
        "r07_postflight_governance_source",
        Path("Mirmir/Modules/UpscalerEngine/R07PostflightGovernance.swift"),
    ),
    (
        "r07_functional_coordinator_source",
        Path("Mirmir/Modules/UpscalerEngine/R07FunctionalCoordinator.swift"),
    ),
    (
        "r07_functional_coordinator_analysis_source",
        Path("Mirmir/Modules/UpscalerEngine/R07FunctionalCoordinatorAnalysis.swift"),
    ),
    (
        "r07_functional_coordinator_runtime_source",
        Path("Mirmir/Modules/UpscalerEngine/R07FunctionalCoordinatorRuntime.swift"),
    ),
    (
        "r07_functional_coordinator_validation_source",
        Path("Mirmir/Modules/UpscalerEngine/R07FunctionalCoordinatorValidation.swift"),
    ),
    (
        "r07_functional_support_executor_source",
        Path("Mirmir/Modules/UpscalerEngine/R07FunctionalSupportExecutor.swift"),
    ),
    (
        "r07_temporal_governance_contracts_tests",
        Path(
            "MirmirTests/UpscalerEngine/R07TemporalGovernanceContractsTests.swift"
        ),
    ),
    (
        "r07_temporal_history_tests",
        Path("MirmirTests/UpscalerEngine/R07TemporalHistoryTests.swift"),
    ),
    (
        "r07_artifact_governance_tests",
        Path("MirmirTests/UpscalerEngine/R07ArtifactGovernanceTests.swift"),
    ),
    (
        "r07_protected_region_policy_tests",
        Path("MirmirTests/UpscalerEngine/R07ProtectedRegionPolicyTests.swift"),
    ),
    (
        "r07_support_stage_policy_tests",
        Path("MirmirTests/UpscalerEngine/R07SupportStagePolicyTests.swift"),
    ),
    (
        "r07_postflight_governance_tests",
        Path("MirmirTests/UpscalerEngine/R07PostflightGovernanceTests.swift"),
    ),
    (
        "r07_postflight_feedback_consumption_tests",
        Path(
            "MirmirTests/UpscalerEngine/"
            "R07PostflightFeedbackConsumptionTests.swift"
        ),
    ),
    (
        "r07_functional_test_support",
        Path("MirmirTests/UpscalerEngine/R07FunctionalTestSupport.swift"),
    ),
    (
        "r07_functional_support_executor_tests",
        Path("MirmirTests/UpscalerEngine/R07FunctionalSupportExecutorTests.swift"),
    ),
    (
        "r07_functional_coordinator_tests",
        Path("MirmirTests/UpscalerEngine/R07FunctionalCoordinatorTests.swift"),
    ),
    (
        "r07_functional_coordinator_boundary_tests",
        Path(
            "MirmirTests/UpscalerEngine/R07FunctionalCoordinatorBoundaryTests.swift"
        ),
    ),
    (
        "r07_functional_coordinator_transaction_tests",
        Path(
            "MirmirTests/UpscalerEngine/"
            "R07FunctionalCoordinatorTransactionTests.swift"
        ),
    ),
    ("project_manifest", Path("project.yml")),
    ("xcode_project", Path("Mirmir.xcodeproj/project.pbxproj")),
)

TEST_SUITES = (
    ("R07TemporalGovernanceContractsTests", 10),
    ("R07TemporalHistoryTests", 12),
    ("R07ArtifactGovernanceTests", 20),
    ("R07ProtectedRegionPolicyTests", 15),
    ("R07SupportStagePolicyTests", 7),
    ("R07PostflightGovernanceTests", 9),
    ("R07PostflightFeedbackConsumptionTests", 4),
    ("R07FunctionalSupportExecutorTests", 8),
    ("R07FunctionalCoordinatorTests", 6),
    ("R07FunctionalCoordinatorBoundaryTests", 4),
    ("R07FunctionalCoordinatorTransactionTests", 3),
)
EXPECTED_TEST_COUNT = 98

ARTIFACT_PATHS = (
    ("xcodebuild_log", XCODEBUILD_LOG_PATH),
    ("xcresult_summary_json", XCRESULT_SUMMARY_PATH),
)

FUNCTIONAL_CHECK_IDS = (
    "product_gate_first",
    "temporal_boundary_current_only",
    "invalid_motion_history_not_consumed",
    "a04_fixture_function",
    "a13_fixture_function",
    "a15_fixture_function",
    "artifact_and_not_applicable_function",
    "protected_content_function",
    "postflight_n_plus_1_no_rewrite",
    "coordinator_end_to_end",
    "failure_transactionality",
    "simulation_identity_truthful",
)

DERIVED_CHECK_IDS = (
    "source_checkpoint_exact",
    "implementation_bindings_exact",
    "historical_r07_bindings_immutable",
    "r06_alignment_override_exact",
    "execution_receipt_exact",
    "test_set_exact",
    *FUNCTIONAL_CHECK_IDS,
    "comparative_gate_not_required",
    "authorization_boundary_exact",
)

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "authorization_date": "2026-07-21",
    "acceptance_basis": "software_performs_intended_task",
    "override_id": "r07.software-function-phase-acceptance.v1",
    "comparative_requirement": "superseded_not_required",
    "hardware_requirement": "waived_not_a_blocker",
    "simulator_requirement": "waived_not_a_blocker",
    "operator_observation_requirement": "waived_not_a_blocker",
    "deterministic_fixture_simulation": "permitted_when_truthful_and_tested",
    "historical_evidence_policy": "preserve_frozen_r07_records_unchanged",
}

DEPENDENCY_ALIGNMENT_OVERRIDE = {
    "phase_id": "R06",
    "phase_status": "in_progress",
    "predecessor_result": "blocked",
    "acceptance_state": "not_claimed",
    "closure_commit": "9ed01ea938a933f6406fd67e88edb74e7c84f5f4",
    "closure_tree": "32365e745dbf53d59213fe2294a6b63ba2642df7",
    "blocked_evidence_disposition": (
        "preserved_non_authorizing_historical_evidence"
    ),
    "r07_progression": "operator_authorized_functional_acceptance_only",
}

SUPERSEDED_GATE = {
    "gate": (
        "ASH Auto must reduce preregistered temporal artifact and "
        "chroma-displacement measures relative to each underlying backend used "
        "alone, with no material loss in spatial quality."
    ),
    "disposition": "superseded_for_r07_phase_acceptance",
    "retained_value": "historical_optional_non_authorizing_evidence",
}

FUNCTIONAL_GATE = {
    "acceptance_scope": "functional_deterministic_software_phase_acceptance",
    "execution_mode": "deterministic_fixture_simulation",
    "required_test_suites": [identifier for identifier, _ in TEST_SUITES],
    "required_test_count": EXPECTED_TEST_COUNT,
    "required_functional_check_ids": list(FUNCTIONAL_CHECK_IDS),
    "comparison_disposition": "superseded_not_required",
    "product_gate_reason": (
        "deterministic_fixture_simulation_not_product_authorized"
    ),
    "product_qualification": "not_claimed",
}

OBSERVATION_STATUS = {
    "deterministic_software_execution": "observed",
    "fixture_simulation": "observed",
    "hardware_capability_observation": "not_observed",
    "apple_device_simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "native_backend_execution": "not_claimed",
    "product_qualification": "not_claimed",
    "comparison_execution": "not_required",
}

EXECUTION_RESULT = {
    "status": "passed",
    "execution_mode": "deterministic_fixture_simulation",
    "functional_software_conformance": "passed",
    "comparison_requirement": "superseded_not_required",
    "product_qualification": "not_claimed",
}

EXECUTION_LIMITATIONS = (
    "The passing execution uses deterministic fixture simulators with truthful "
    "fixture-only identities; it does not establish native backend execution or "
    "product qualification.",
    "Hardware capability, Apple device-simulator execution, and operator-observed "
    "operation were not observed and were waived as blockers by the operator.",
    "The comparative gate is superseded and not required; this receipt makes no "
    "quality, performance, publication, production-default, or release claim.",
)

ACCEPTANCE_RESULT = {
    "status": "passed",
    "phase_status_before": "in_progress",
    "phase_status_after": "passed",
    "acceptance": "accepted",
    "acceptance_scope": "functional_deterministic_software_phase_acceptance",
    "execution_mode": "deterministic_fixture_simulation",
    "product_qualification": "not_claimed",
}

AUTHORIZATIONS = {
    "phase_progression": "authorized",
    "r07_phase_status": "passed",
    "r06_phase_status": "in_progress",
    "product_qualification": "not_claimed",
    "production_default": "not_authorized",
    "auto_mode": "not_authorized",
    "holdout": "not_authorized",
    "perceptual_quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "product_publication": "not_authorized",
    "release": "not_authorized",
    "native_execution_claims": "not_authorized",
}

ACCEPTANCE_LIMITATIONS = (
    "R07 phase acceptance is limited to the operator-authorized deterministic "
    "software-function gate and its exact 98-test execution receipt.",
    "Frozen R07 preregistration and fixture evidence, including the old comparison "
    "gate, remain unchanged historical records and do not authorize acceptance.",
    "R06 remains in progress and unaccepted; R07 acceptance does not authorize "
    "product qualification, production use, Auto, holdout, quality, performance, "
    "publication, native-execution, or release claims.",
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


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _expected_test_suites() -> list[dict[str, object]]:
    return [
        {
            "id": identifier,
            "expected_test_count": count,
            "passed_test_count": count,
            "failed_test_count": 0,
            "skipped_test_count": 0,
        }
        for identifier, count in TEST_SUITES
    ]


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def inspect(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                if key.casefold() in PRIVATE_EVIDENCE_KEYS:
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


class R07PhaseAcceptanceVerifier:
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

    def _checkpoint_binding(
        self, identifier: str, relative: Path
    ) -> dict[str, object]:
        historical = self.git_bytes(
            "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
        )
        if historical.returncode != 0:
            raise ValueError(f"checkpoint file unavailable: {relative.as_posix()}")
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
            return ["R07 functional source commit is unavailable"]
        tree = self.git("rev-parse", f"{SOURCE_COMMIT}^{{tree}}")
        if tree.returncode != 0 or tree.stdout.strip() != SOURCE_TREE:
            errors.append("R07 functional source tree differs")
        ancestor = self.git("merge-base", "--is-ancestor", SOURCE_COMMIT, "HEAD")
        if ancestor.returncode != 0:
            errors.append("R07 functional source commit is not an ancestor of HEAD")
        return errors

    def _historical_errors(self) -> list[str]:
        errors: list[str] = []
        for identifier, relative, size_bytes, sha256 in HISTORICAL_BINDINGS:
            path = self.root / relative
            if path.is_symlink() or not path.is_file():
                errors.append(f"R07 historical evidence is absent: {identifier}")
                continue
            payload = path.read_bytes()
            if len(payload) != size_bytes or _sha256(payload) != sha256:
                errors.append(f"R07 historical evidence binding differs: {identifier}")
            historical = self.git_bytes(
                "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            )
            if historical.returncode != 0 or historical.stdout != payload:
                errors.append(
                    f"R07 historical evidence differs from checkpoint: {identifier}"
                )
        conformance = self.root / CONFORMANCE_PATH
        if conformance.exists() or conformance.is_symlink():
            errors.append(
                "frozen R07 temporal-artifact conformance must remain unmaterialized"
            )

        r06_phase = self._read_json(
            HISTORICAL_BINDINGS[-2][1], "R06 phase evidence", errors
        )
        r06_conformance = self._read_json(
            HISTORICAL_BINDINGS[-1][1], "R06 orchestration conformance", errors
        )
        phase_result = r06_phase.get("result") if r06_phase is not None else None
        if not isinstance(phase_result, dict) or (
            phase_result.get("status") != "blocked"
            or phase_result.get("phase_status_after") != "in_progress"
        ):
            errors.append("R06 phase evidence alignment differs")
        conformance_result = (
            r06_conformance.get("result")
            if r06_conformance is not None
            else None
        )
        if not isinstance(conformance_result, dict) or (
            conformance_result.get("status") != "blocked"
            or conformance_result.get("acceptance") != "not_claimed"
            or conformance_result.get("product_qualification") != "not_claimed"
        ):
            errors.append("R06 conformance alignment differs")
        return errors

    def _implementation_errors(self) -> list[str]:
        errors: list[str] = []
        for identifier, relative in IMPLEMENTATION_PATHS:
            try:
                self._checkpoint_binding(identifier, relative)
            except ValueError:
                errors.append(
                    f"R07 implementation is absent from checkpoint: {identifier}"
                )
        return errors

    def historical_evidence_bindings(self) -> list[dict[str, object]]:
        return [
            {
                "id": identifier,
                "path": relative.as_posix(),
                "size_bytes": size_bytes,
                "sha256": sha256,
            }
            for identifier, relative, size_bytes, sha256 in HISTORICAL_BINDINGS
        ]

    def implementation_bindings(self) -> list[dict[str, object]]:
        return [
            self._checkpoint_binding(identifier, relative)
            for identifier, relative in IMPLEMENTATION_PATHS
        ]

    def artifact_bindings(self) -> list[dict[str, object]]:
        return [
            self._file_binding(identifier, relative)
            for identifier, relative in ARTIFACT_PATHS
        ]

    def _checkpoint_test_suite_errors(self) -> list[str]:
        errors: list[str] = []
        for identifier, expected_count in TEST_SUITES:
            relative = Path(f"MirmirTests/UpscalerEngine/{identifier}.swift")
            historical = self.git_bytes(
                "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            )
            try:
                source = historical.stdout.decode("utf-8")
            except UnicodeDecodeError:
                source = ""
            methods = re.findall(
                r"^\s*func\s+(test[A-Za-z0-9_]+)\s*\(",
                source,
                flags=re.MULTILINE,
            )
            if historical.returncode != 0 or len(methods) != expected_count:
                errors.append(f"R07 checkpoint test count differs: {identifier}")
            if len(methods) != len(set(methods)):
                errors.append(f"R07 checkpoint test methods repeat: {identifier}")
        return errors

    @staticmethod
    def _command_errors(command: object) -> list[str]:
        errors: list[str] = []
        if not isinstance(command, str) or not command:
            return ["R07 test command is absent"]
        try:
            tokens = shlex.split(command)
        except ValueError as error:
            return [f"R07 test command is invalid: {error}"]
        if not tokens or PurePosixPath(tokens[0]).name != "xcodebuild":
            errors.append("R07 test command is not xcodebuild")
        if "test" not in tokens and "test-without-building" not in tokens:
            errors.append("R07 test command does not execute tests")
        selections = [
            token.removeprefix("-only-testing:")
            for token in tokens
            if token.startswith("-only-testing:")
        ]
        expected = [f"MirmirTests/{identifier}" for identifier, _ in TEST_SUITES]
        if selections != expected:
            errors.append("R07 test command selection differs")
        if any(token.startswith("-skip-testing:") for token in tokens):
            errors.append("R07 test command skips selected tests")
        return errors

    def _summary_errors(self, value: object) -> list[str]:
        errors = _privacy_errors(value, "R07 xcresult summary")
        if not isinstance(value, dict) or tuple(value) != SUMMARY_KEYS:
            errors.append("R07 xcresult summary keys/order differ")
            return errors
        expected_identity = {
            "schema_version": "1.0.0",
            "phase_id": "R07",
            "evidence_kind": "r07_functional_selected_test_summary_v1",
            "source": SOURCE,
            "execution_mode": "deterministic_fixture_simulation",
            "expected_selected_test_count": EXPECTED_TEST_COUNT,
            "selected_test_count": EXPECTED_TEST_COUNT,
            "passed_test_count": EXPECTED_TEST_COUNT,
            "failed_test_count": 0,
            "skipped_test_count": 0,
            "test_suites": _expected_test_suites(),
        }
        for key, expected in expected_identity.items():
            if value.get(key) != expected:
                errors.append(f"R07 xcresult summary field differs: {key}")
        errors.extend(self._checkpoint_test_suite_errors())
        toolchain = value.get("toolchain")
        if not isinstance(toolchain, dict) or tuple(toolchain) != TOOLCHAIN_KEYS:
            errors.append("R07 xcresult summary toolchain keys/order differ")
            return errors
        expected_toolchain = {
            "platform": "macos_host",
            "architecture": "arm64",
            "os_version": "26.5.2",
            "xcode_version": "26.2",
            "xcode_build_version": "17C52",
        }
        for key, expected in expected_toolchain.items():
            if toolchain.get(key) != expected:
                errors.append(f"R07 xcresult summary toolchain differs: {key}")
        errors.extend(self._command_errors(toolchain.get("command")))
        return errors

    @staticmethod
    def _log_errors(value: str) -> list[str]:
        errors = _privacy_errors(value, "R07 xcodebuild log")
        lines = value.splitlines()
        success_markers = ("** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **")
        failure_markers = ("** TEST FAILED **", "** TEST EXECUTE FAILED **")
        success_count = sum(lines.count(marker) for marker in success_markers)
        if success_count != 1 or any(marker in lines for marker in failure_markers):
            errors.append("R07 xcodebuild log does not record one exact test success")
        result_pattern = re.compile(
            r"Executed 98 tests, with 0 failures \(0 unexpected\)"
        )
        if not any(result_pattern.search(line) for line in lines):
            errors.append("R07 xcodebuild log does not record the exact 98-test result")
        return errors

    @staticmethod
    def _test_execution(summary: dict[str, Any]) -> dict[str, object]:
        return {
            "execution_mode": summary["execution_mode"],
            "expected_selected_test_count": summary[
                "expected_selected_test_count"
            ],
            "selected_test_count": summary["selected_test_count"],
            "passed_test_count": summary["passed_test_count"],
            "failed_test_count": summary["failed_test_count"],
            "skipped_test_count": summary["skipped_test_count"],
            "test_suites": summary["test_suites"],
            "toolchain": summary["toolchain"],
        }

    def expected_execution_receipt(
        self,
        summary: dict[str, Any],
        *,
        artifact_bindings: list[dict[str, object]] | None = None,
    ) -> dict[str, object]:
        bindings = (
            self.artifact_bindings()
            if artifact_bindings is None
            else artifact_bindings
        )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R07",
            "evidence_kind": (
                "r07_deterministic_fixture_functional_execution_receipt_v1"
            ),
            "source": dict(SOURCE),
            "implementation_bindings": self.implementation_bindings(),
            "artifact_bindings": bindings,
            "test_execution": self._test_execution(summary),
            "observation_status": dict(OBSERVATION_STATUS),
            "functional_checks": [
                {"id": check_id, "status": "passed"}
                for check_id in FUNCTIONAL_CHECK_IDS
            ],
            "result": dict(EXECUTION_RESULT),
            "limitations": list(EXECUTION_LIMITATIONS),
        }

    def expected_acceptance(
        self,
        receipt: dict[str, Any],
        *,
        receipt_binding: dict[str, object] | None = None,
    ) -> dict[str, object]:
        binding = (
            self._file_binding("r07_functional_execution_receipt", EXECUTION_RECEIPT_PATH)
            if receipt_binding is None
            else receipt_binding
        )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R07",
            "evidence_kind": "r07_operator_functional_phase_acceptance_v1",
            "source": dict(SOURCE),
            "operator_override": dict(OPERATOR_OVERRIDE),
            "dependency_alignment_override": dict(DEPENDENCY_ALIGNMENT_OVERRIDE),
            "superseded_gate": dict(SUPERSEDED_GATE),
            "functional_gate": dict(FUNCTIONAL_GATE),
            "historical_evidence_bindings": self.historical_evidence_bindings(),
            "implementation_bindings": receipt["implementation_bindings"],
            "execution_receipt_binding": binding,
            "derived_checks": [
                {"id": check_id, "status": "passed"}
                for check_id in DERIVED_CHECK_IDS
            ],
            "result": dict(ACCEPTANCE_RESULT),
            "authorizations": dict(AUTHORIZATIONS),
            "limitations": list(ACCEPTANCE_LIMITATIONS),
        }

    def _base_errors(self) -> list[str]:
        errors = self._source_errors()
        errors.extend(self._historical_errors())
        errors.extend(self._implementation_errors())
        contracts = R07ContractVerifier(self.root)
        errors.extend(contracts.check_preregistration())
        errors.extend(contracts.check_fixtures())
        return errors

    def _artifacts(
        self, errors: list[str]
    ) -> tuple[dict[str, Any], str] | None:
        summary = self._read_json(
            XCRESULT_SUMMARY_PATH, "R07 xcresult summary", errors
        )
        log_path = self.root / XCODEBUILD_LOG_PATH
        if log_path.is_symlink() or not log_path.is_file():
            errors.append("R07 xcodebuild log must be a regular non-symlink file")
            return None
        try:
            log = log_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"R07 xcodebuild log is invalid: {error}")
            return None
        if summary is None:
            return None
        errors.extend(self._summary_errors(summary))
        errors.extend(self._log_errors(log))
        return summary, log

    def check(self) -> list[str]:
        errors = self._base_errors()
        artifacts = self._artifacts(errors)
        receipt = self._read_json(
            EXECUTION_RECEIPT_PATH, "R07 functional execution receipt", errors
        )
        receipt_schema = self._read_json(
            EXECUTION_RECEIPT_SCHEMA_PATH,
            "R07 functional execution receipt schema",
            errors,
        )
        acceptance = self._read_json(
            ACCEPTANCE_PATH, "R07 functional phase acceptance", errors
        )
        acceptance_schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH,
            "R07 functional phase acceptance schema",
            errors,
        )
        if receipt is not None and receipt_schema is not None:
            errors.extend(
                f"R07 functional execution receipt schema: {error}"
                for error in validate_json_schema_instance(receipt_schema, receipt)
            )
        if acceptance is not None and acceptance_schema is not None:
            errors.extend(
                f"R07 functional phase acceptance schema: {error}"
                for error in validate_json_schema_instance(
                    acceptance_schema, acceptance
                )
            )
        if artifacts is not None and receipt is not None:
            summary, _ = artifacts
            try:
                expected_receipt = self.expected_execution_receipt(summary)
            except (OSError, ValueError) as error:
                errors.append(f"R07 execution receipt derivation failed: {error}")
            else:
                if receipt != expected_receipt:
                    errors.append(
                        "R07 execution receipt is not exactly derived from the "
                        "checkpoint and test artifacts"
                    )
        if receipt is not None and acceptance is not None:
            try:
                expected_acceptance = self.expected_acceptance(receipt)
            except OSError as error:
                errors.append(f"R07 acceptance derivation failed: {error}")
            else:
                if acceptance != expected_acceptance:
                    errors.append(
                        "R07 phase acceptance is not exactly derived from bound "
                        "functional evidence"
                    )
        return sorted(set(errors))

    def write(self) -> list[str]:
        errors = self._base_errors()
        artifacts = self._artifacts(errors)
        receipt_schema = self._read_json(
            EXECUTION_RECEIPT_SCHEMA_PATH,
            "R07 functional execution receipt schema",
            errors,
        )
        acceptance_schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH,
            "R07 functional phase acceptance schema",
            errors,
        )
        if artifacts is None or receipt_schema is None or acceptance_schema is None:
            return sorted(set(errors))
        if errors:
            return sorted(set(errors))
        summary, _ = artifacts
        try:
            receipt = self.expected_execution_receipt(summary)
        except (OSError, ValueError) as error:
            return [f"R07 execution receipt derivation failed: {error}"]
        errors.extend(
            f"R07 functional execution receipt schema: {error}"
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
            f"R07 functional phase acceptance schema: {error}"
            for error in validate_json_schema_instance(acceptance_schema, acceptance)
        )
        if errors:
            return sorted(set(errors))
        acceptance_path = self.root / ACCEPTANCE_PATH
        acceptance_path.write_text(
            json.dumps(acceptance, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
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
    arguments = parser.parse_args(argv)
    verifier = R07PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    errors = verifier.write() if arguments.write else verifier.check()
    if not errors:
        print("R07 functional phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
