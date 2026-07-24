#!/usr/bin/env python3
"""Generate and verify exact-source R13 release-candidate evidence."""

from __future__ import annotations

import argparse
import base64
import binascii
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping, Sequence
import zipfile


_MODULE_REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(_MODULE_REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_REPOSITORY_ROOT))

try:
    from phase_evidence import decode_json, validate_json_schema_instance
except ModuleNotFoundError:
    from Scripts.phase_evidence import decode_json, validate_json_schema_instance

try:
    from Scripts.r11_phase_acceptance import R11PhaseAcceptanceVerifier
except (ImportError, ModuleNotFoundError) as error:
    R11PhaseAcceptanceVerifier = None  # type: ignore[assignment,misc]
    _R11_IMPORT_ERROR: BaseException | None = error
else:
    _R11_IMPORT_ERROR = None

try:
    from Scripts.r12_phase_acceptance import R12PhaseAcceptanceVerifier
except (ImportError, ModuleNotFoundError) as error:
    R12PhaseAcceptanceVerifier = None  # type: ignore[assignment,misc]
    _R12_IMPORT_ERROR: BaseException | None = error
else:
    _R12_IMPORT_ERROR = None


REPOSITORY_ROOT = _MODULE_REPOSITORY_ROOT
ROADMAP_VERSION = "1.0.1"
ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)
R11_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r11/records/functional-phase-acceptance.json"
)
R12_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r12/records/functional-phase-acceptance.json"
)

RECORDS_DIRECTORY = Path("docs/roadmaps/evidence/r13/records")
RELEASE_CANDIDATE_RECEIPT_PATH = (
    RECORDS_DIRECTORY / "release-candidate-receipt.json"
)
OUTPUT_REOPEN_RECEIPT_PATH = (
    RECORDS_DIRECTORY / "output-reopen-receipt.json"
)
EXECUTION_RECEIPT_PATH = (
    RECORDS_DIRECTORY / "functional-execution-receipt.json"
)
ACCEPTANCE_PATH = RECORDS_DIRECTORY / "functional-phase-acceptance.json"
ARTIFACT_DIRECTORY = (
    RECORDS_DIRECTORY / "artifacts/functional-phase-acceptance"
)
BUILD_FOR_TESTING_LOG_PATH = ARTIFACT_DIRECTORY / "build-for-testing.log"
TARGETED_TEST_LOG_PATH = ARTIFACT_DIRECTORY / "targeted-xctest.log"
RELEASE_BUILD_LOG_PATH = ARTIFACT_DIRECTORY / "release-app-build.log"
LINT_LOG_PATH = ARTIFACT_DIRECTORY / "swiftlint.log"
OUTPUT_MEDIA_ARTIFACT_PATH = (
    ARTIFACT_DIRECTORY / "r13-output-reopen-fixture.mov"
)
RELEASE_CANDIDATE_ARCHIVE_PATH = (
    ARTIFACT_DIRECTORY / "r13-release-candidate.zip"
)

PROJECT_PATH = Path("Mirmir.xcodeproj/project.pbxproj")
VALIDATOR_PATH = Path("Scripts/r13_phase_acceptance.py")
VALIDATOR_TEST_PATH = Path("Scripts/tests/test_r13_phase_acceptance.py")
RELEASE_CANDIDATE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r13-release-candidate-receipt-v1.json"
)
EXECUTION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/"
    "r13-functional-execution-receipt-v1.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/"
    "r13-functional-phase-acceptance-v1.json"
)

EXPLICIT_PRODUCT_SOURCE_PATHS = (
    Path("Mirmir/App/MirmirAppBootstrap.swift"),
    Path("Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift"),
    Path(
        "Mirmir/Modules/MediaPipeline/"
        "AVFoundationMediaSessionConfiguration.swift"
    ),
    Path(
        "Mirmir/Modules/MediaPipeline/"
        "AVFoundationMediaSessionFinalization.swift"
    ),
    Path(
        "Mirmir/Modules/MediaPipeline/"
        "AtomicMediaVerifiedTemporaryFile.swift"
    ),
    Path("Mirmir/Modules/MediaPipeline/AtomicMediaOutput.swift"),
    Path(
        "Mirmir/Modules/MediaPipeline/"
        "LocalAtomicMediaFileSystem.swift"
    ),
    Path("Mirmir/Modules/MediaPipeline/MediaPipelineService.swift"),
    Path("Mirmir/Modules/MediaPipeline/MediaTypes.swift"),
    Path("Mirmir/Modules/MediaPipeline/MirmirTimedMetadataPolicy.swift"),
    Path(
        "Mirmir/Modules/MediaPipeline/"
        "OutputMediaVerificationTypes.swift"
    ),
    Path("Mirmir/Modules/MediaPipeline/OutputMediaVerifier.swift"),
    Path("Mirmir/Modules/ModelAssets/DefaultModelAssetsService.swift"),
    Path("Mirmir/Modules/ModelAssets/ModelAssetsService.swift"),
    Path("Mirmir/Modules/ModelAssets/NotRequiredModelAssetsService.swift"),
    Path("Mirmir/Modules/UI/MirmirReleasePresentation.swift"),
    Path("Mirmir/Modules/UI/MirmirViewModel.swift"),
    Path("Mirmir/Modules/UI/MirmirViewModel+R13Diagnostics.swift"),
    Path("Mirmir/Modules/UI/MirmirViewModel+R13Errors.swift"),
    Path("Mirmir/Modules/UI/MirmirViewModel+R13Recovery.swift"),
    Path("Mirmir/Modules/UI/Views/MirmirSettingsViews.swift"),
    Path("Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift"),
    Path("Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift"),
    Path("Mirmir/Modules/UI/Views/MirmirWorkspaceScreens.swift"),
    Path("Mirmir/Modules/UI/Views/UpscaleControlsView.swift"),
    Path("Mirmir/Modules/UpscalerEngine/UpscaleJob.swift"),
    Path("Mirmir/Modules/UpscalerEngine/UpscaleMode.swift"),
    Path("Mirmir/Modules/UpscalerEngine/UpscalerEngineService.swift"),
)

EXPLICIT_EXISTING_TEST_PATHS = (
    Path("MirmirTests/ArchitectureGuardrailTests.swift"),
    Path(
        "MirmirTests/"
        "AtomicMediaOutputPublicationCleanupTests.swift"
    ),
    Path("MirmirTests/AtomicMediaOutputTests.swift"),
    Path("MirmirTests/MirmirAppBootstrapTests.swift"),
    Path("MirmirTests/MirmirUIWorkflowTests.swift"),
    Path("MirmirTests/OutputMediaAACIdentityReaderTests.swift"),
    Path("MirmirTests/OutputMediaMetadataVerificationTests.swift"),
    Path("MirmirTests/UpscalerEngineAvailabilityTests.swift"),
)

EXPLICIT_TEST_SUPPORT_PATHS = (
    Path("MirmirTests/OutputMediaVerifierTestSupport.swift"),
    Path("MirmirTests/R13ReleaseIntegrationFixtureSupport.swift"),
    Path("MirmirTests/R13ReleaseIntegrationHardeningSupport.swift"),
    Path("MirmirTests/R13ReleaseIntegrationMediaSupport.swift"),
    Path("MirmirTests/R13ReleaseUpscalerEngineTestSupport.swift"),
)

MANDATORY_SUITE_AREAS = {
    "R13A11ProductBackendTests": "backend_routes_modes_auto",
    "R13EngineRecoveryScopeTests": "resume_cache_bookmark_storage",
    "R13ReleaseIntegrationTests": "backend_routes_modes_auto",
    "R13ReleaseModePolicyTests": "backend_routes_modes_auto",
    "R13NV12FrameNormalizerTests": "backend_routes_modes_auto",
    "R13ReleaseUpscalerEngineServiceTests": "backend_routes_modes_auto",
    "R13UIReleaseModeTests": "assets_bootstrap_ui",
    "R13ReleaseIdentityTests": "identity_metadata_prepublish",
    "R13MediaFinalizationTests": "identity_metadata_prepublish",
    "R13HardeningStorageLifecycleTests":
        "resume_cache_bookmark_storage",
    "R13NV12FrameCacheTests": "resume_cache_bookmark_storage",
    "R13RestartJobContractsTests": "resume_cache_bookmark_storage",
    "R13RestartJobInitializationTests": "resume_cache_bookmark_storage",
    "R13RestartJobStoreTests": "resume_cache_bookmark_storage",
    "R13SecurityScopedBookmarksTests": "resume_cache_bookmark_storage",
    "R13SourceSnapshotTests": "resume_cache_bookmark_storage",
    "R13StoragePreflightTests": "resume_cache_bookmark_storage",
    "R13StorageSourceSnapshotCapacityTests":
        "resume_cache_bookmark_storage",
    "R13StorageTopologyTests": "resume_cache_bookmark_storage",
    "R13ResourceGovernanceTests": "resource_fault_diagnostics",
    "R13ResourceLifecycleSoakTests": "resource_fault_diagnostics",
    "R13FaultInjectionTests": "resource_fault_diagnostics",
    "R13ReleaseDiagnosticsTests": "resource_fault_diagnostics",
    "R13ReleaseEngineTerminalBoundaryTests":
        "resource_fault_diagnostics",
}

MPS_PRODUCT_EXECUTION_TEST = (
    "MirmirTests.R13A11ProductBackendTests."
    "testDefaultSessionFactoryProcessesGenuineProductA11FramesForBothRoutes"
)
MANDATORY_INTEGRATION_IDENTIFIERS = frozenset(
    {
        (
            "MirmirTests.R13ReleaseIntegrationTests."
            "testShippingServiceBindsExactReleaseIdentityAndReopensControlledMetadata"
        ),
        (
            "MirmirTests.R13ReleaseIntegrationTests."
            "testShippingServiceResumesInterruptedJobWithStableIDAndExactCachedPrefixReplay"
        ),
        (
            "MirmirTests.R13ReleaseIntegrationTests."
            "testShippingServiceFaultsNeverPublishAndReleaseEveryResourceExactlyOnce"
        ),
        (
            "MirmirTests.R13ReleaseIntegrationTests."
            "testShippingServiceUsesExactSourceFrameCountNotEstimatedFrameCount"
        ),
    }
)
PRODUCT_OUTPUT_PRODUCER_TEST = (
    "MirmirTests.R13ReleaseIntegrationTests."
    "testShippingServiceBindsExactReleaseIdentityAndReopensControlledMetadata"
)
REQUIRED_RELEASE_METADATA_KEYS = frozenset(
    {
        "com.mirmir.release.app",
        "com.mirmir.release.app-executable-bytes",
        "com.mirmir.release.app-executable-sha256",
        "com.mirmir.release.backend-id",
        "com.mirmir.release.backend-revision",
        "com.mirmir.release.capability-id",
        "com.mirmir.release.configuration-id",
        "com.mirmir.release.effective-mode",
        "com.mirmir.release.fallback-history",
        "com.mirmir.release.framework",
        "com.mirmir.release.identity-sha256",
        "com.mirmir.release.material-decision-id",
        "com.mirmir.release.model-status",
        "com.mirmir.release.output",
        "com.mirmir.release.policy-id",
        "com.mirmir.release.policy-sha256",
        "com.mirmir.release.requested-mode",
        "com.mirmir.release.resource-manifest-sha256",
        "com.mirmir.release.route-id",
        "com.mirmir.release.runtime",
        "com.mirmir.release.source-bytes",
        "com.mirmir.release.source-sha256",
    }
)

EXISTING_SUITE_AREAS = {
    "ArchitectureGuardrailTests": "assets_bootstrap_ui",
    "AtomicMediaOutputPublicationCleanupTests":
        "identity_metadata_prepublish",
    "AtomicMediaOutputTests": "identity_metadata_prepublish",
    "MirmirAppBootstrapTests": "assets_bootstrap_ui",
    "MirmirUIWorkflowTests": "assets_bootstrap_ui",
    "OutputMediaAACIdentityReaderTests": "identity_metadata_prepublish",
    "OutputMediaMetadataVerificationTests": "identity_metadata_prepublish",
    "UpscalerEngineAvailabilityTests": "backend_routes_modes_auto",
}

REQUIRED_COVERAGE_AREAS = frozenset(
    {
        "backend_routes_modes_auto",
        "assets_bootstrap_ui",
        "identity_metadata_prepublish",
        "resume_cache_bookmark_storage",
        "resource_fault_diagnostics",
    }
)

ACCEPTANCE_BASIS = "software_does_what_it_says_it_does"
ACCEPTANCE_SCOPE = "declared_software_function_only"
RELEASE_OUTCOME = "release_ready_candidate"
OBSERVATIONS = {
    "debug_xctest_mps_lanczos_execution": "observed_both_product_routes",
    "gpu_profiling": "not_observed",
    "hardware_qualification": "not_observed",
    "instruments": "not_observed",
    "operator": "not_observed",
    "release_candidate_gpu_execution": "not_observed",
    "simulator": "not_observed",
    "nonblocking_for_software_function_acceptance": True,
}
COMPARISON_POLICY = {
    "ab_test": "absent_not_required",
    "acceptance_dependency": "none",
    "comparison_method": "absent_not_required",
}
CLAIM_BOUNDARY = {
    "auto_mode": "not_authorized",
    "claim_scope": "software_behavior_report",
    "fallback": "none",
    "market_claim": "not_authorized",
    "model": "not_required",
    "product_publication": "not_authorized",
    "release_publication": "not_authorized",
    "tag_publication": "not_authorized",
}
MODE_POLICY = {
    "auto_authority": "not_authorized",
    "auto_availability": "unavailable",
    "fallback": "none",
    "model": "not_required",
}
CANDIDATE_BUILD_BOUNDARY = {
    "default_metallib": "absent",
    "metal_source_compilation": "excluded",
    "release_candidate_gpu_execution": "not_observed",
}
EXECUTION_BOUNDARY = {
    "output_execution": "debug_xctest_genuine_a11_mps_avfoundation",
    "release_app_execution": "not_observed",
    "release_app_produced_output": False,
}
DISTRIBUTION_BOUNDARY = {
    "distributable_claim": "not_authorized",
    "distribution_authority": "not_authorized",
    "distribution_signing_identity": "not_observed",
    "gatekeeper": "not_observed",
    "launch_smoke": "not_observed",
    "notarization": "not_observed",
    "notarized_claim": "not_authorized",
}
LIMITATIONS = (
    "R13 evidence proves the behavior exercised by the exact checkpointed "
    "Debug XCTest inventory; it separately proves build and archive identity, "
    "not execution, of the exact clean Release app.",
    "Automated Debug XCTest executed the genuine MPS Lanczos A11 backend for "
    "both product routes; this is functional execution, not GPU profiling or "
    "hardware qualification.",
    "Release-candidate GPU execution, GPU profiling, hardware qualification, "
    "simulator, Instruments, and operator observations are not_observed and "
    "are nonblocking.",
    "No comparative, historical-comparison, or A/B result is required or "
    "used.",
    "Auto is unavailable and not_authorized, model acquisition is "
    "not_required, and no fallback route is accepted.",
    "This acceptance authorizes a release-ready candidate outcome; it does "
    "not authorize a tag, release publication, product publication, or "
    "market claim.",
    "The available Release toolchain build excludes Metal source files; the "
    "candidate contains no default.metallib and makes no Release-candidate GPU "
    "execution claim.",
    "The retained MOV is produced by Debug XCTest through the genuine default "
    "A11 MPS Lanczos backend and AVFoundation media pipeline, with a "
    "deterministic test-scoped release environment; the separately built "
    "Release app did not produce that output and its execution was not "
    "observed.",
    "Distribution signing identity, notarization, Gatekeeper, launch smoke, "
    "and Release-app execution were not observed; distribution, notarized, "
    "and distributable claims are not authorized.",
)

BUILD_FOR_TESTING_COMMAND = (
    "xcodebuild build-for-testing -project Mirmir.xcodeproj -scheme Mirmir "
    "-configuration Debug -destination platform=macOS,arch=arm64 "
    "-derivedDataPath <outside-repository> "
    "-disableAutomaticPackageResolution "
    "R13_ACCEPTANCE_SOURCE_COMMIT=<source.commit> "
    "R13_ACCEPTANCE_SOURCE_TREE=<source.tree> "
    "EXCLUDED_SOURCE_FILE_NAMES=*.metal "
    "ENABLE_TESTABILITY=YES"
)
TARGETED_TEST_COMMAND = (
    "xcodebuild test-without-building -xctestrun "
    "<checkpoint-build.xctestrun> "
    "-destination platform=macOS,arch=arm64 "
    "<derived-r13-only-testing-selectors> "
    "R13_ACCEPTANCE_SOURCE_COMMIT=<source.commit> "
    "R13_ACCEPTANCE_SOURCE_TREE=<source.tree>"
)
RELEASE_BUILD_COMMAND = (
    "xcodebuild build -project Mirmir.xcodeproj -scheme Mirmir "
    "-configuration Release -destination platform=macOS,arch=arm64 "
    "-derivedDataPath <outside-repository> "
    "-disableAutomaticPackageResolution "
    "R13_ACCEPTANCE_SOURCE_COMMIT=<source.commit> "
    "R13_ACCEPTANCE_SOURCE_TREE=<source.tree> "
    "EXCLUDED_SOURCE_FILE_NAMES=*.metal"
)
LINT_COMMAND = "swiftlint lint --strict --no-cache"
OUTPUT_REOPEN_COMMAND = (
    "xcrun swift <outside-repository>/r13-output-reopen.swift "
    "<outside-repository>/r13-output-reopen-fixture.mov"
)

DERIVED_CHECK_IDS = (
    "source_checkpoint_commit_tree_and_ancestry_exact",
    "r11_and_r12_accepted_source_identities_exact",
    "source_test_project_schema_validator_bindings_exact",
    "debug_build_for_testing_succeeded",
    "targeted_r13_xctest_inventory_passed",
    "debug_xctest_genuine_mps_lanczos_both_routes_passed",
    "release_app_build_succeeded",
    "swiftlint_strict_zero_violations",
    "built_app_tree_executable_bundle_framework_identity_exact",
    "release_candidate_and_output_reopen_receipts_exact",
    "backend_routes_modes_and_auto_contracts_passed",
    "assets_bootstrap_and_ui_contracts_passed",
    "identity_metadata_and_prepublish_contracts_passed",
    "resume_cache_bookmark_and_storage_contracts_passed",
    "resource_fault_and_diagnostics_contracts_passed",
    "comparison_and_ab_methods_absent_not_required",
    "observation_requirements_nonblocking",
    "release_tag_publish_and_market_claim_not_authorized",
    "artifact_closure_hashes_exact",
)

_GIT_OID_PATTERN = re.compile(r"^(?!0{40}$)[0-9a-f]{40}$")
_SWIFT_CLASS_PATTERN = re.compile(
    r"(?m)^final class ([A-Za-z0-9_]+Tests): XCTestCase \{"
)
_SWIFT_TEST_METHOD_PATTERN = re.compile(
    r"(?m)^[ \t]{4}func (test[A-Za-z0-9_]+)"
    r"\s*\([^)]*\)(?:\s+(?:async|throws))*\s*\{"
)
_XCTEST_CASE_PATTERN = re.compile(
    r"^Test Case '-\[MirmirTests\.([A-Za-z0-9_]+) "
    r"(test[A-Za-z0-9_]+)\]' (started|passed|failed|skipped)"
    r"(?: \(([0-9]+(?:\.[0-9]+)?) seconds\))?\.$"
)
_XCTEST_BENIGN_LINKD_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2} "
    r"[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}[+-][0-9]{4} "
    r"Mirmir\[[0-9]+:[0-9]+\] \[Connection\] "
    r"Unable to (?:get synchronousRemoteObjectProxy|re-register with "
    r"Process Instance Registry), "
    r"error: Error Domain=NSCocoaErrorDomain Code=4097 "
    r'"connection to service named com\.apple\.linkd\.autoShortcut" '
    r"UserInfo=\{NSDebugDescription=connection to service named "
    r"com\.apple\.linkd\.autoShortcut\}$"
)
_XCTEST_SUMMARY_PATTERN = re.compile(
    r"^[ \t]*Executed ([0-9]+) tests?, with ([0-9]+) failures? "
    r"\(([0-9]+) unexpected\)(?:, ([0-9]+) skipped)?"
    r" in .+ seconds$"
)
_SWIFTLINT_FILE_PATTERN = re.compile(
    r"^Linting '.+\.swift' \(([0-9]+)/([0-9]+)\)$"
)
_SWIFTLINT_SUMMARY_PATTERN = re.compile(
    r"^Done linting! Found ([0-9]+) violations, ([0-9]+) serious "
    r"in ([0-9]+) files?\.$"
)
_EXECUTION_IDENTITY_PREFIX = "R13_EXECUTION_IDENTITY="
_OUTPUT_MEDIA_BASE64_PREFIX = b"R13_ACCEPTANCE_OUTPUT_BASE64="
_CHECKPOINT_KIND = "detached_clean_exact_git_checkpoint"
_MAX_JSON_BYTES = 16 * 1024 * 1024
_MAX_SOURCE_BYTES = 16 * 1024 * 1024
_MAX_BUILD_LOG_BYTES = 64 * 1024 * 1024
_MAX_TEST_LOG_BYTES = 64 * 1024 * 1024
_MAX_LINT_LOG_BYTES = 16 * 1024 * 1024
_MAX_MEDIA_BYTES = 32 * 1024 * 1024
_MAX_CANDIDATE_ARCHIVE_BYTES = 25 * 1024 * 1024
_MAX_CANDIDATE_EXTRACTED_BYTES = 100 * 1024 * 1024


@dataclass(frozen=True)
class SwiftTestSuite:
    class_name: str
    path: Path
    area: str
    methods: tuple[str, ...]

    @property
    def only_testing(self) -> str:
        return f"MirmirTests/{self.class_name}"


@dataclass(frozen=True)
class TestInventory:
    suites: tuple[SwiftTestSuite, ...]

    @property
    def identifiers(self) -> tuple[str, ...]:
        return tuple(
            f"MirmirTests.{suite.class_name}.{method}"
            for suite in self.suites
            for method in suite.methods
        )


@dataclass(frozen=True)
class ParsedLint:
    linted_file_count: int


@dataclass(frozen=True)
class CapturedExecution:
    build_for_testing_log: bytes
    targeted_test_log: bytes
    release_build_log: bytes
    lint_log: bytes
    app_identity: dict[str, Any]
    candidate_archive_payload: bytes
    output_media_payload: bytes
    output_reopen_receipt: dict[str, Any]


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_json(value: object) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def _canonical_compact_json(value: object) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _decode_object(payload: bytes, context: str) -> dict[str, Any]:
    if (
        type(payload) is not bytes
        or not payload
        or len(payload) > _MAX_JSON_BYTES
        or b"\x00" in payload
        or b"\r" in payload
    ):
        raise ValueError(f"{context} bytes are outside the closed boundary")
    try:
        value = decode_json(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError(f"{context} is not strict JSON: {error}") from error
    if type(value) is not dict:
        raise ValueError(f"{context} must be one JSON object")
    return value


def _identifier_for_path(role: str, path: Path) -> str:
    stem = re.sub(r"[^a-z0-9]+", "_", path.as_posix().lower()).strip("_")
    return f"{role}_{stem}"


def _snake_case(value: str) -> str:
    value = value[4:] if value.startswith("test") else value
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", value)
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value).lower()


_BaseVerifier = R12PhaseAcceptanceVerifier or object


class R13PhaseAcceptanceVerifier(_BaseVerifier):  # type: ignore[misc]
    """Fail-closed verifier for exact R13 release-candidate evidence."""

    def __init__(self, root: Path) -> None:
        if R12PhaseAcceptanceVerifier is None:
            raise RuntimeError(
                f"R13 cannot import R12 verifier: {_R12_IMPORT_ERROR}"
            )
        super().__init__(root, source_binding_paths=(), test_suites=())

    @classmethod
    def _tool_identity(cls, name: str) -> dict[str, str]:
        if name not in {"swift", "xcrun"}:
            return super()._tool_identity(name)
        if name == "swift":
            lookup = subprocess.run(
                ["/usr/bin/xcrun", "--find", "swift"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            try:
                candidate = lookup.stdout.decode("utf-8").strip()
            except UnicodeDecodeError as error:
                raise ValueError(
                    "R13 swift executable path is not UTF-8"
                ) from error
            if (
                lookup.returncode
                or not candidate
                or lookup.stdout != f"{candidate}\n".encode("utf-8")
            ):
                raise ValueError("R13 swift executable path differs")
            try:
                path = Path(candidate).resolve(strict=True)
            except OSError as error:
                raise ValueError(
                    "R13 swift executable cannot be resolved"
                ) from error
        else:
            path = cls._resolved_executable(name)
        descriptor = -1
        try:
            before = path.stat()
            descriptor = os.open(
                path,
                os.O_RDONLY
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
            )
            if cls._stat_identity(os.fstat(descriptor)) != cls._stat_identity(
                before
            ):
                raise ValueError(
                    f"R13 {name} identity changed while opening"
                )
            digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            if (
                cls._stat_identity(os.fstat(descriptor))
                != cls._stat_identity(before)
                or cls._stat_identity(path.stat())
                != cls._stat_identity(before)
            ):
                raise ValueError(
                    f"R13 {name} identity changed while hashing"
                )
        except OSError as error:
            raise ValueError(f"R13 {name} cannot be hashed") from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        try:
            result = subprocess.run(
                [os.fspath(path), "--version"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError(
                f"R13 {name} version query failed"
            ) from error
        if (
            result.returncode
            or not result.stdout
            or len(result.stdout) > 4096
            or b"\x00" in result.stdout
            or b"\r" in result.stdout
        ):
            raise ValueError(f"R13 {name} version identity differs")
        try:
            version = result.stdout.decode("utf-8").strip()
        except UnicodeDecodeError as error:
            raise ValueError(
                f"R13 {name} version identity is not UTF-8"
            ) from error
        return {
            "executable_path": os.fspath(path),
            "executable_sha256": digest.hexdigest(),
            "name": name,
            "version": version,
        }

    def resolve_source(self, revision: str) -> dict[str, str]:
        if (
            type(revision) is not str
            or _GIT_OID_PATTERN.fullmatch(revision) is None
        ):
            raise ValueError(
                "R13 implementation commit must be one exact nonzero "
                "lowercase 40-character Git object ID"
            )
        commit = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{revision}^{{commit}}",
            context="R13 implementation commit",
        )
        tree = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{commit}^{{tree}}",
            context="R13 implementation tree",
        )
        if commit != revision or _GIT_OID_PATTERN.fullmatch(tree) is None:
            raise ValueError("R13 implementation commit or tree differs")
        if self._git("merge-base", "--is-ancestor", commit, "HEAD").returncode:
            raise ValueError(
                "R13 implementation commit is not an ancestor of HEAD"
            )
        return {"commit": commit, "tree": tree}

    def _source_errors(self, value: object) -> list[str]:
        if (
            type(value) is not dict
            or tuple(value) != ("commit", "tree")
            or _GIT_OID_PATTERN.fullmatch(str(value.get("commit", ""))) is None
            or _GIT_OID_PATTERN.fullmatch(str(value.get("tree", ""))) is None
        ):
            return ["R13 source commit/tree shape is invalid"]
        try:
            expected = self.resolve_source(str(value["commit"]))
        except ValueError as error:
            return [str(error)]
        return [] if expected == value else ["R13 source binding differs"]

    def _checkpoint_paths(self, source: Mapping[str, str]) -> tuple[Path, ...]:
        result = self._git(
            "ls-tree",
            "-r",
            "--name-only",
            "-z",
            source["commit"],
        )
        if result.returncode or not result.stdout.endswith(b"\x00"):
            raise ValueError("R13 checkpoint path inventory cannot be read")
        values: list[Path] = []
        for encoded in result.stdout[:-1].split(b"\x00"):
            try:
                text = encoded.decode("utf-8")
            except UnicodeDecodeError as error:
                raise ValueError(
                    "R13 checkpoint path inventory is not UTF-8"
                ) from error
            path = PurePosixPath(text)
            if (
                not text
                or path.is_absolute()
                or path.as_posix() != text
                or any(part in {"", ".", ".."} for part in path.parts)
            ):
                raise ValueError(
                    "R13 checkpoint path inventory is not canonical"
                )
            values.append(Path(*path.parts))
        if not values or len(values) != len(set(values)):
            raise ValueError("R13 checkpoint path inventory differs")
        return tuple(sorted(values, key=lambda item: item.as_posix()))

    @staticmethod
    def _suite_area(class_name: str) -> str | None:
        if class_name in MANDATORY_SUITE_AREAS:
            return MANDATORY_SUITE_AREAS[class_name]
        if class_name in EXISTING_SUITE_AREAS:
            return EXISTING_SUITE_AREAS[class_name]
        if class_name.startswith("R13"):
            if any(
                token in class_name
                for token in ("Restart", "Cache", "Bookmark", "Storage")
            ):
                return "resume_cache_bookmark_storage"
            if any(
                token in class_name
                for token in ("Resource", "Fault", "Diagnostic")
            ):
                return "resource_fault_diagnostics"
            if any(
                token in class_name
                for token in ("Identity", "Metadata", "Finalization")
            ):
                return "identity_metadata_prepublish"
            if any(token in class_name for token in ("UI", "Bootstrap")):
                return "assets_bootstrap_ui"
            if any(
                token in class_name
                for token in ("Mode", "Engine", "Normalizer", "Backend", "Route")
            ):
                return "backend_routes_modes_auto"
        return None

    def _checkpoint_test_inventory(
        self,
        source: Mapping[str, str],
    ) -> tuple[TestInventory | None, list[str]]:
        errors: list[str] = []
        try:
            paths = self._checkpoint_paths(source)
        except ValueError as error:
            return None, [str(error)]
        selected = {
            path
            for path in paths
            if (
                path.parts
                and path.parts[0] == "MirmirTests"
                and path.suffix == ".swift"
                and (
                    (
                        path.name.startswith("R13")
                        and path.name.endswith("Tests.swift")
                    )
                    or path in EXPLICIT_EXISTING_TEST_PATHS
                )
            )
        }
        missing_existing = sorted(
            set(EXPLICIT_EXISTING_TEST_PATHS) - selected,
            key=lambda item: item.as_posix(),
        )
        errors.extend(
            f"R13 required existing test source is absent: {path.as_posix()}"
            for path in missing_existing
        )
        suites: list[SwiftTestSuite] = []
        seen_classes: set[str] = set()
        for path in sorted(selected, key=lambda item: item.as_posix()):
            try:
                payload = self._checkpoint_bytes(source, path)
                text = payload.decode("utf-8")
            except (UnicodeDecodeError, ValueError) as error:
                errors.append(f"R13 test source cannot be read: {path}: {error}")
                continue
            classes = _SWIFT_CLASS_PATTERN.findall(text)
            methods = tuple(_SWIFT_TEST_METHOD_PATTERN.findall(text))
            if len(classes) != 1 or not methods or len(methods) != len(set(methods)):
                errors.append(f"R13 test suite shape differs: {path.as_posix()}")
                continue
            class_name = classes[0]
            area = self._suite_area(class_name)
            if area is None:
                errors.append(
                    f"R13 test suite has no closed coverage area: {class_name}"
                )
                continue
            if class_name in seen_classes:
                errors.append(f"R13 test suite repeats: {class_name}")
                continue
            seen_classes.add(class_name)
            suites.append(SwiftTestSuite(class_name, path, area, methods))
        missing_suites = sorted(set(MANDATORY_SUITE_AREAS) - seen_classes)
        if missing_suites:
            errors.append(
                "R13 mandatory test suite inventory differs: "
                + ", ".join(missing_suites)
            )
        observed_areas = {suite.area for suite in suites}
        if observed_areas != REQUIRED_COVERAGE_AREAS:
            errors.append("R13 required test coverage areas differ")
        inventory = TestInventory(
            tuple(sorted(suites, key=lambda item: item.class_name))
        )
        if (
            not inventory.identifiers
            or len(inventory.identifiers) != len(set(inventory.identifiers))
        ):
            errors.append("R13 test identifier inventory differs")
        missing_integration = sorted(
            MANDATORY_INTEGRATION_IDENTIFIERS - set(inventory.identifiers)
        )
        if missing_integration:
            errors.append(
                "R13 shipping-service integration inventory differs: "
                + ", ".join(missing_integration)
            )
        if MPS_PRODUCT_EXECUTION_TEST not in inventory.identifiers:
            errors.append(
                "R13 automated Debug MPS product execution inventory differs"
            )
        return (inventory if not errors else None), sorted(set(errors))

    def _source_binding_inventory(
        self,
        source: Mapping[str, str],
        inventory: TestInventory,
    ) -> tuple[tuple[str, str, Path], ...]:
        paths = set(self._checkpoint_paths(source))
        missing = sorted(
            set(EXPLICIT_PRODUCT_SOURCE_PATHS) - paths,
            key=lambda item: item.as_posix(),
        )
        if missing:
            raise ValueError(
                "R13 required product source inventory differs: "
                + ", ".join(path.as_posix() for path in missing)
            )
        product_paths = set(EXPLICIT_PRODUCT_SOURCE_PATHS)
        product_paths.update(
            path
            for path in paths
            if (
                len(path.parts) >= 2
                and path.parts[0] == "Mirmir"
                and path.suffix == ".swift"
                and path.name.startswith("R13")
            )
        )
        fixed = (
            ("project", PROJECT_PATH),
            ("validator", VALIDATOR_PATH),
            ("validator_test", VALIDATOR_TEST_PATH),
            ("schema", RELEASE_CANDIDATE_SCHEMA_PATH),
            ("schema", EXECUTION_SCHEMA_PATH),
            ("schema", ACCEPTANCE_SCHEMA_PATH),
            *(
                ("test_source", path)
                for path in EXPLICIT_TEST_SUPPORT_PATHS
            ),
        )
        all_values = [
            (
                _identifier_for_path("product_source", path),
                "product_source",
                path,
            )
            for path in sorted(product_paths, key=lambda item: item.as_posix())
        ]
        all_values.extend(
            (
                _identifier_for_path("test_source", suite.path),
                "test_source",
                suite.path,
            )
            for suite in inventory.suites
        )
        all_values.extend(
            (_identifier_for_path(role, path), role, path)
            for role, path in fixed
        )
        identifiers = [value[0] for value in all_values]
        binding_paths = [value[2] for value in all_values]
        if (
            len(identifiers) != len(set(identifiers))
            or len(binding_paths) != len(set(binding_paths))
            or any(path not in paths for path in binding_paths)
        ):
            raise ValueError("R13 source binding inventory differs")
        return tuple(all_values)

    def source_bindings(
        self,
        source: Mapping[str, str],
        inventory: TestInventory,
    ) -> list[dict[str, object]]:
        values: list[dict[str, object]] = []
        for identifier, role, path in self._source_binding_inventory(
            source, inventory
        ):
            payload = self._checkpoint_bytes(source, path)
            values.append(
                {
                    "id": identifier,
                    "path": path.as_posix(),
                    "role": role,
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
        return values

    def _canonical_predecessor_errors(self) -> list[str]:
        errors: list[str] = []
        for phase, verifier, import_error in (
            ("R11", R11PhaseAcceptanceVerifier, _R11_IMPORT_ERROR),
            ("R12", R12PhaseAcceptanceVerifier, _R12_IMPORT_ERROR),
        ):
            if verifier is None:
                errors.append(
                    f"R13 cannot import canonical {phase} verifier: "
                    f"{import_error}"
                )
                continue
            try:
                predecessor_errors = verifier(self.root).check_generated()
            except (OSError, RuntimeError, TypeError, ValueError) as error:
                errors.append(
                    f"R13 canonical {phase} validation raised: {error}"
                )
            else:
                errors.extend(
                    f"R13 canonical {phase} validation failed: {error}"
                    for error in predecessor_errors
                )
        return sorted(set(errors))

    def _predecessor_bindings(
        self,
        source: Mapping[str, str],
    ) -> list[dict[str, object]]:
        errors = self._canonical_predecessor_errors()
        if errors:
            raise ValueError(" | ".join(errors))
        values: list[dict[str, object]] = []
        previous_commit: str | None = None
        for phase, path in (
            ("R11", R11_ACCEPTANCE_PATH),
            ("R12", R12_ACCEPTANCE_PATH),
        ):
            payload = self._checkpoint_bytes(source, path)
            record = _decode_object(payload, f"{phase} predecessor acceptance")
            accepted_source = record.get("source")
            gate = record.get("functional_gate")
            if (
                type(accepted_source) is not dict
                or tuple(accepted_source) != ("commit", "tree")
                or _GIT_OID_PATTERN.fullmatch(
                    str(accepted_source.get("commit", ""))
                )
                is None
                or _GIT_OID_PATTERN.fullmatch(
                    str(accepted_source.get("tree", ""))
                )
                is None
                or type(gate) is not dict
                or gate.get("status") != "passed"
                or gate.get("acceptance_scope") != ACCEPTANCE_SCOPE
            ):
                raise ValueError(f"R13 {phase} predecessor acceptance differs")
            commit = self._git_text(
                "rev-parse",
                "--verify",
                "--end-of-options",
                f"{accepted_source['commit']}^{{commit}}",
                context=f"R13 {phase} predecessor commit",
            )
            tree = self._git_text(
                "rev-parse",
                "--verify",
                "--end-of-options",
                f"{commit}^{{tree}}",
                context=f"R13 {phase} predecessor tree",
            )
            descendant = source["commit"] if phase == "R12" else None
            if (
                commit != accepted_source["commit"]
                or tree != accepted_source["tree"]
            ):
                raise ValueError(
                    f"R13 {phase} predecessor source identity differs"
                )
            if previous_commit is not None and self._git(
                "merge-base", "--is-ancestor", previous_commit, commit
            ).returncode:
                raise ValueError("R13 predecessor phase ordering differs")
            if descendant is not None and self._git(
                "merge-base", "--is-ancestor", commit, descendant
            ).returncode:
                raise ValueError(
                    "R13 predecessor source is not an ancestor of R13"
                )
            values.append(
                {
                    "acceptance_scope": ACCEPTANCE_SCOPE,
                    "accepted_source": dict(accepted_source),
                    "functional_phase_acceptance": {
                        "path": path.as_posix(),
                        "sha256": _sha256(payload),
                        "size_bytes": len(payload),
                    },
                    "phase_id": phase,
                    "phase_result": "passed",
                }
            )
            previous_commit = commit
        return values

    @staticmethod
    def _execution_identity_header(identity: Mapping[str, object]) -> str:
        return _EXECUTION_IDENTITY_PREFIX + _canonical_compact_json(
            identity
        ).decode("ascii")

    @staticmethod
    def _build_for_testing_arguments(
        executable: str,
        source: Mapping[str, str],
        derived_data: str,
    ) -> list[str]:
        return [
            executable,
            "build-for-testing",
            "-project",
            "Mirmir.xcodeproj",
            "-scheme",
            "Mirmir",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=arm64",
            "-derivedDataPath",
            derived_data,
            "-disableAutomaticPackageResolution",
            f"R13_ACCEPTANCE_SOURCE_COMMIT={source['commit']}",
            f"R13_ACCEPTANCE_SOURCE_TREE={source['tree']}",
            "EXCLUDED_SOURCE_FILE_NAMES=*.metal",
            "ENABLE_TESTABILITY=YES",
        ]

    @staticmethod
    def _targeted_test_arguments(
        executable: str,
        source: Mapping[str, str],
        xctestrun: str,
        inventory: TestInventory,
    ) -> list[str]:
        return [
            executable,
            "test-without-building",
            "-xctestrun",
            xctestrun,
            "-destination",
            "platform=macOS,arch=arm64",
            *[
                f"-only-testing:{suite.only_testing}"
                for suite in inventory.suites
            ],
            f"R13_ACCEPTANCE_SOURCE_COMMIT={source['commit']}",
            f"R13_ACCEPTANCE_SOURCE_TREE={source['tree']}",
        ]

    @staticmethod
    def _release_build_arguments(
        executable: str,
        source: Mapping[str, str],
        derived_data: str,
    ) -> list[str]:
        return [
            executable,
            "build",
            "-project",
            "Mirmir.xcodeproj",
            "-scheme",
            "Mirmir",
            "-configuration",
            "Release",
            "-destination",
            "platform=macOS,arch=arm64",
            "-derivedDataPath",
            derived_data,
            "-disableAutomaticPackageResolution",
            f"R13_ACCEPTANCE_SOURCE_COMMIT={source['commit']}",
            f"R13_ACCEPTANCE_SOURCE_TREE={source['tree']}",
            "EXCLUDED_SOURCE_FILE_NAMES=*.metal",
        ]

    @staticmethod
    def _lint_arguments(executable: str) -> list[str]:
        return [executable, "lint", "--strict", "--no-cache"]

    def _outside_repository_path(
        self,
        value: object,
        *,
        context: str,
    ) -> Path | None:
        if (
            type(value) is not str
            or not value
            or len(value.encode("utf-8")) > 4096
            or "\x00" in value
            or "\r" in value
            or not Path(value).is_absolute()
            or os.path.normpath(value) != value
        ):
            return None
        path = Path(value)
        try:
            if os.path.commonpath((os.fspath(path), os.fspath(self.root))) == (
                os.fspath(self.root)
            ):
                return None
        except ValueError:
            return None
        return path

    def _expected_argv(
        self,
        command_id: str,
        argv: object,
        tool: Mapping[str, Any],
        source: Mapping[str, str],
        inventory: TestInventory,
    ) -> list[str] | None:
        if (
            type(argv) is not list
            or not argv
            or any(
                type(value) is not str
                or not value
                or len(value.encode("utf-8")) > 4096
                or "\x00" in value
                or "\r" in value
                for value in argv
            )
            or type(tool.get("executable_path")) is not str
        ):
            return None
        executable = str(tool["executable_path"])
        if command_id in {"build_for_testing", "release_app_build"}:
            expected_length = (
                17 if command_id == "build_for_testing" else 16
            )
            if len(argv) != expected_length:
                return None
            derived = self._outside_repository_path(
                argv[11], context=f"R13 {command_id} derived data"
            )
            if derived is None or derived.name != "DerivedData":
                return None
            if command_id == "build_for_testing":
                return self._build_for_testing_arguments(
                    executable, source, os.fspath(derived)
                )
            return self._release_build_arguments(
                executable, source, os.fspath(derived)
            )
        if command_id == "targeted_tests":
            expected_count = 8 + len(inventory.suites)
            if len(argv) != expected_count:
                return None
            xctestrun = self._outside_repository_path(
                argv[3], context="R13 targeted test xctestrun"
            )
            if (
                xctestrun is None
                or xctestrun.suffix != ".xctestrun"
                or xctestrun.parent.name != "Products"
            ):
                return None
            return self._targeted_test_arguments(
                executable, source, os.fspath(xctestrun), inventory
            )
        if command_id == "swiftlint":
            return self._lint_arguments(executable)
        if command_id == "output_reopen":
            if len(argv) != 4 or argv[1] != "swift":
                return None
            script = self._outside_repository_path(
                argv[2], context="R13 media generator source"
            )
            output = self._outside_repository_path(
                argv[3], context="R13 media generator output"
            )
            if (
                script is None
                or output is None
                or script.name != "r13-output-reopen.swift"
                or output.name != "r13-output-reopen-fixture.mov"
                or script.parent != output.parent
            ):
                return None
            return [executable, "swift", os.fspath(script), os.fspath(output)]
        return None

    def _identity_errors(
        self,
        identity: object,
        *,
        source: Mapping[str, str],
        command_id: str,
        command: str,
        tool_name: str,
        inventory: TestInventory,
    ) -> list[str]:
        context = f"R13 {command_id} execution identity"
        required = {
            "argv",
            "checkpoint",
            "command",
            "command_id",
            "exit_code",
            "source",
            "tool",
        }
        if command_id == "release_app_build":
            required.add("release_app_tree_sha256")
        if type(identity) is not dict or set(identity) != required:
            return [f"{context} shape differs"]
        errors: list[str] = []
        if identity.get("command_id") != command_id:
            errors.append(f"{context} command identifier differs")
        if identity.get("command") != command:
            errors.append(f"{context} canonical command differs")
        if identity.get("exit_code") != 0:
            errors.append(f"{context} exit status differs")
        if identity.get("source") != dict(source):
            errors.append(f"{context} source differs")
        if (
            command_id == "release_app_build"
            and re.fullmatch(
                r"[0-9a-f]{64}",
                str(identity.get("release_app_tree_sha256", "")),
            )
            is None
        ):
            errors.append(f"{context} Release app tree identity differs")
        if identity.get("checkpoint") != {
            "clean_after": True,
            "clean_before": True,
            "commit_after": source["commit"],
            "commit_before": source["commit"],
            "kind": _CHECKPOINT_KIND,
            "tree_after": source["tree"],
            "tree_before": source["tree"],
        }:
            errors.append(f"{context} checkpoint differs")
        tool = identity.get("tool")
        if (
            type(tool) is not dict
            or set(tool) != {
                "executable_path",
                "executable_sha256",
                "name",
                "version",
            }
            or tool.get("name") != tool_name
            or _GIT_OID_PATTERN.fullmatch(
                str(tool.get("executable_sha256", ""))[:40]
            )
            is None
            or re.fullmatch(
                r"[0-9a-f]{64}",
                str(tool.get("executable_sha256", "")),
            )
            is None
            or type(tool.get("version")) is not str
            or not tool.get("version")
            or type(tool.get("executable_path")) is not str
            or not Path(str(tool.get("executable_path"))).is_absolute()
            or os.path.normpath(str(tool.get("executable_path")))
            != tool.get("executable_path")
        ):
            errors.append(f"{context} tool identity differs")
        elif self._expected_argv(
            command_id, identity.get("argv"), tool, source, inventory
        ) != identity.get("argv"):
            errors.append(f"{context} argv differs")
        return sorted(set(errors))

    @staticmethod
    def _bind_release_app_tree(
        payload: bytes,
        tree_sha256: str,
    ) -> bytes:
        if re.fullmatch(r"[0-9a-f]{64}", tree_sha256) is None:
            raise ValueError("R13 Release app tree digest differs")
        try:
            header, body = payload.split(b"\n", 1)
            if not header.startswith(_EXECUTION_IDENTITY_PREFIX.encode("ascii")):
                raise ValueError
            identity = _decode_object(
                header[len(_EXECUTION_IDENTITY_PREFIX) :],
                "R13 Release app build execution identity",
            )
        except (ValueError, TypeError) as error:
            raise ValueError(
                "R13 Release app build identity cannot bind its tree"
            ) from error
        if (
            identity.get("command_id") != "release_app_build"
            or "release_app_tree_sha256" in identity
        ):
            raise ValueError(
                "R13 Release app build identity tree boundary differs"
            )
        identity["release_app_tree_sha256"] = tree_sha256
        return (
            R13PhaseAcceptanceVerifier._execution_identity_header(identity)
            + "\n"
        ).encode("utf-8") + body

    @staticmethod
    def _tool_binding_errors(
        identities: Mapping[str, Mapping[str, Any]],
        tools: Mapping[str, Mapping[str, str]],
    ) -> list[str]:
        expected_names = {
            "build_for_testing": "xcodebuild",
            "targeted_tests": "xcodebuild",
            "release_app_build": "xcodebuild",
            "swiftlint": "swiftlint",
            "output_reopen": "xcrun",
        }
        if set(tools) != {"swift", "swiftlint", "xcodebuild", "xcrun"}:
            return ["R13 independently resolved tool inventory differs"]
        errors: list[str] = []
        for command_id, name in expected_names.items():
            identity = identities.get(command_id)
            if (
                type(identity) is not dict
                or identity.get("tool") != dict(tools[name])
            ):
                errors.append(
                    f"R13 {command_id} independently resolved tool identity differs"
                )
        return sorted(set(errors))

    def _log_identity(
        self,
        payload: bytes,
        *,
        source: Mapping[str, str],
        command_id: str,
        command: str,
        tool_name: str,
        inventory: TestInventory,
        maximum: int,
    ) -> tuple[dict[str, Any] | None, str | None, list[str]]:
        if (
            not payload
            or len(payload) > maximum
            or b"\x00" in payload
            or b"\r" in payload
        ):
            return None, None, [
                f"R13 {command_id} log bytes are outside the boundary"
            ]
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return None, None, [f"R13 {command_id} log is not UTF-8"]
        lines = text.splitlines()
        if not lines or not lines[0].startswith(_EXECUTION_IDENTITY_PREFIX):
            return None, text, [
                f"R13 {command_id} execution identity is absent"
            ]
        encoded = lines[0][len(_EXECUTION_IDENTITY_PREFIX) :]
        try:
            identity = _decode_object(
                encoded.encode("utf-8"),
                f"R13 {command_id} execution identity",
            )
        except ValueError as error:
            return None, text, [str(error)]
        errors = self._identity_errors(
            identity,
            source=source,
            command_id=command_id,
            command=command,
            tool_name=tool_name,
            inventory=inventory,
        )
        if lines[0] != self._execution_identity_header(identity):
            errors.append(
                f"R13 {command_id} execution identity is not canonical"
            )
        return (
            identity if not errors else None,
            text,
            sorted(set(errors)),
        )

    def _build_log(
        self,
        payload: bytes,
        *,
        source: Mapping[str, str],
        inventory: TestInventory,
        release: bool,
    ) -> tuple[dict[str, Any] | None, list[str]]:
        command_id = "release_app_build" if release else "build_for_testing"
        command = RELEASE_BUILD_COMMAND if release else BUILD_FOR_TESTING_COMMAND
        identity, text, errors = self._log_identity(
            payload,
            source=source,
            command_id=command_id,
            command=command,
            tool_name="xcodebuild",
            inventory=inventory,
            maximum=_MAX_BUILD_LOG_BYTES,
        )
        if text is None:
            return None, errors
        marker = "** BUILD SUCCEEDED **" if release else "** TEST BUILD SUCCEEDED **"
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if lines.count(marker) != 1 or lines[-1] != marker:
            errors.append(f"R13 {command_id} final success marker differs")
        if any(
            "BUILD FAILED" in line
            or re.search(r"(^|\s)(?:fatal )?error:", line, re.IGNORECASE)
            for line in lines
        ):
            errors.append(f"R13 {command_id} log contains a build error")
        return (identity if not errors else None), sorted(set(errors))

    def _test_log(
        self,
        payload: bytes,
        *,
        source: Mapping[str, str],
        inventory: TestInventory,
    ) -> tuple[dict[str, Any] | None, list[str]]:
        identity, text, errors = self._log_identity(
            payload,
            source=source,
            command_id="targeted_tests",
            command=TARGETED_TEST_COMMAND,
            tool_name="xcodebuild",
            inventory=inventory,
            maximum=_MAX_TEST_LOG_BYTES,
        )
        if text is None:
            return None, errors
        lines = text.splitlines()
        markers = [
            index
            for index, line in enumerate(lines)
            if line.strip() == "** TEST EXECUTE SUCCEEDED **"
        ]
        prefix = lines if len(markers) != 1 else lines[: markers[0]]
        trailing = (
            []
            if len(markers) != 1
            else [
                line
                for line in lines[markers[0] + 1 :]
                if line.strip()
            ]
        )
        if len(markers) != 1 or trailing not in ([], ["Testing started"]):
            errors.append("R13 targeted XCTest success marker differs")
        started: list[str] = []
        passed: list[str] = []
        forbidden: list[str] = []
        summaries: list[tuple[int, int, int, int]] = []
        for line in prefix:
            match = _XCTEST_CASE_PATTERN.fullmatch(line.strip())
            if match:
                suite, method, status_value, _seconds = match.groups()
                identifier = f"MirmirTests.{suite}.{method}"
                if status_value == "started":
                    started.append(identifier)
                elif status_value == "passed":
                    passed.append(identifier)
                else:
                    forbidden.append(status_value)
            summary = _XCTEST_SUMMARY_PATTERN.fullmatch(line)
            if summary:
                count, failures, unexpected, skipped = summary.groups()
                summaries.append(
                    (
                        int(count),
                        int(failures),
                        int(unexpected),
                        int(skipped or "0"),
                    )
                )
        if any(
            (
                "TEST EXECUTE FAILED" in line
                or "TEST FAILED" in line
                or re.search(
                    r"(^|\s)(?:fatal )?error:",
                    line,
                    re.IGNORECASE,
                )
            )
            and not _XCTEST_BENIGN_LINKD_PATTERN.fullmatch(line)
            for line in lines
        ):
            errors.append("R13 targeted XCTest log contains a test error")
        expected = set(inventory.identifiers)
        if (
            set(started) != expected
            or set(passed) != expected
            or len(started) != len(expected)
            or len(passed) != len(expected)
        ):
            errors.append("R13 targeted XCTest individual inventory differs")
        count = len(expected)
        if (
            forbidden
            or not summaries
            or summaries[-1] != (count, 0, 0, 0)
            or any(item[1:] != (0, 0, 0) for item in summaries)
        ):
            errors.append("R13 targeted XCTest failure/skip count differs")
        return (identity if not errors else None), sorted(set(errors))

    def _lint_log(
        self,
        payload: bytes,
        *,
        source: Mapping[str, str],
        inventory: TestInventory,
    ) -> tuple[dict[str, Any] | None, ParsedLint | None, list[str]]:
        identity, text, errors = self._log_identity(
            payload,
            source=source,
            command_id="swiftlint",
            command=LINT_COMMAND,
            tool_name="swiftlint",
            inventory=inventory,
            maximum=_MAX_LINT_LOG_BYTES,
        )
        if text is None:
            return None, None, errors
        lines = text.splitlines()[1:]
        file_records = [
            tuple(int(value) for value in match.groups())
            for line in lines
            if (match := _SWIFTLINT_FILE_PATTERN.fullmatch(line)) is not None
        ]
        summaries = [
            tuple(int(value) for value in match.groups())
            for line in lines
            if (match := _SWIFTLINT_SUMMARY_PATTERN.fullmatch(line)) is not None
        ]
        if (
            not lines
            or lines[0]
            not in {
                "Linting Swift files in current working directory",
                "Linting Swift files at paths .",
            }
            or len(summaries) != 1
            or summaries[0][:2] != (0, 0)
        ):
            errors.append("R13 SwiftLint zero-violation summary differs")
        linted = summaries[0][2] if summaries else 0
        if (
            linted < 1
            or len(file_records) != linted
            or set(file_records)
            != {(index, linted) for index in range(1, linted + 1)}
            or not lines
            or lines[-1]
            != (
                f"Done linting! Found 0 violations, 0 serious in "
                f"{linted} files."
            )
            or any(re.search(r": (?:warning|error):", line) for line in lines)
        ):
            errors.append("R13 SwiftLint per-file inventory differs")
        return (
            identity if not errors else None,
            ParsedLint(linted) if not errors else None,
            sorted(set(errors)),
        )

    @staticmethod
    def _file_binding(path: Path, payload: bytes) -> dict[str, object]:
        return {
            "path": path.as_posix(),
            "sha256": _sha256(payload),
            "size_bytes": len(payload),
        }

    def _contract_coverage(
        self,
        inventory: TestInventory,
    ) -> list[dict[str, object]]:
        values = [
            {
                "contract_area": suite.area,
                "contract_id": f"{suite.area}.{_snake_case(method)}",
                "status": "passed",
                "test_identifier": (
                    f"MirmirTests.{suite.class_name}.{method}"
                ),
            }
            for suite in inventory.suites
            for method in suite.methods
        ]
        if (
            len(values) != len(inventory.identifiers)
            or {value["test_identifier"] for value in values}
            != set(inventory.identifiers)
            or {value["contract_area"] for value in values}
            != REQUIRED_COVERAGE_AREAS
        ):
            raise ValueError("R13 contract coverage closure differs")
        return values

    def _test_inventory_record(
        self,
        inventory: TestInventory,
    ) -> list[dict[str, object]]:
        return [
            {
                "class_name": suite.class_name,
                "methods": list(suite.methods),
                "only_testing": suite.only_testing,
                "path": suite.path.as_posix(),
            }
            for suite in inventory.suites
        ]

    def _app_identity_errors(self, value: object) -> list[str]:
        if type(value) is not dict:
            return ["R13 app identity is not an object"]
        required = {
            "bundle",
            "bundle_path",
            "file_count",
            "file_manifest",
            "frameworks",
            "total_size_bytes",
            "tree_sha256",
        }
        if set(value) != required:
            return ["R13 app identity shape differs"]
        manifest = value.get("file_manifest")
        if type(manifest) is not list or not manifest:
            return ["R13 app file manifest differs"]
        errors: list[str] = []
        paths: list[str] = []
        total = 0
        for entry in manifest:
            if (
                type(entry) is not dict
                or set(entry) != {"mode", "path", "sha256", "size_bytes"}
                or type(entry.get("path")) is not str
                or PurePosixPath(str(entry.get("path"))).is_absolute()
                or ".." in PurePosixPath(str(entry.get("path"))).parts
                or type(entry.get("mode")) is not int
                or type(entry.get("size_bytes")) is not int
                or entry["size_bytes"] < 1
                or re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", "")))
                is None
            ):
                errors.append("R13 app file manifest entry differs")
                continue
            paths.append(str(entry["path"]))
            total += int(entry["size_bytes"])
        if paths != sorted(paths) or len(paths) != len(set(paths)):
            errors.append("R13 app file manifest ordering differs")
        if any(
            path.endswith(".xctest")
            or ".xctest/" in path
            or "/XCTest" in path
            or path.endswith("/default.metallib")
            or path == "default.metallib"
            for path in paths
        ):
            errors.append(
                "R13 candidate embeds a test product or default.metallib"
            )
        if value.get("file_count") != len(manifest):
            errors.append("R13 app file count differs")
        if value.get("total_size_bytes") != total:
            errors.append("R13 app total size differs")
        if value.get("tree_sha256") != _sha256(
            _canonical_compact_json(manifest)
        ):
            errors.append("R13 app tree digest differs")
        bundle = value.get("bundle")
        if type(bundle) is not dict or set(bundle) != {
            "build_version",
            "bundle_identifier",
            "executable",
            "executable_name",
            "info_plist",
            "short_version",
        }:
            errors.append("R13 app bundle identity differs")
        else:
            for key in ("executable", "info_plist"):
                binding = bundle.get(key)
                if (
                    type(binding) is not dict
                    or set(binding) != {"path", "sha256", "size_bytes"}
                    or binding not in [
                        {
                            "path": entry["path"],
                            "sha256": entry["sha256"],
                            "size_bytes": entry["size_bytes"],
                        }
                        for entry in manifest
                        if type(entry) is dict
                        and set(entry)
                        == {"mode", "path", "sha256", "size_bytes"}
                    ]
                ):
                    errors.append(f"R13 app {key} binding differs")
        frameworks = value.get("frameworks")
        if type(frameworks) is not dict or set(frameworks) != {
            "entries",
            "status",
            "tree_sha256",
        }:
            errors.append("R13 framework identity differs")
        else:
            entries = frameworks.get("entries")
            expected_entries = [
                entry
                for entry in manifest
                if type(entry) is dict
                and str(entry.get("path", "")).startswith(
                    "Contents/Frameworks/"
                )
            ]
            if (
                entries != expected_entries
                or frameworks.get("status")
                != ("present" if expected_entries else "none_embedded")
                or frameworks.get("tree_sha256")
                != _sha256(_canonical_compact_json(expected_entries))
            ):
                errors.append("R13 framework tree identity differs")
        return sorted(set(errors))

    @staticmethod
    def _canonical_candidate_archive_payload(
        entries: Sequence[tuple[str, int, bytes]],
    ) -> bytes:
        buffer = io.BytesIO()
        with zipfile.ZipFile(
            buffer,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
            strict_timestamps=True,
        ) as archive:
            archive.comment = b""
            for relative, mode, entry_payload in entries:
                info = zipfile.ZipInfo(
                    f"Mirmir.app/{relative}",
                    date_time=(1980, 1, 1, 0, 0, 0),
                )
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = mode << 16
                info.extra = b""
                info.comment = b""
                archive.writestr(info, entry_payload)
        return buffer.getvalue()

    @staticmethod
    def _archived_bundle_identity_errors(
        app_identity: Mapping[str, Any],
        extracted_entries: Sequence[tuple[str, int, bytes]],
    ) -> list[str]:
        bundle = app_identity.get("bundle")
        if type(bundle) is not dict:
            return ["R13 archived app bundle identity differs"]
        payloads = {
            relative: payload
            for relative, _mode, payload in extracted_entries
        }
        info_binding = bundle.get("info_plist")
        executable_binding = bundle.get("executable")
        if type(info_binding) is not dict or type(executable_binding) is not dict:
            return ["R13 archived app bound file identity differs"]
        info_path = info_binding.get("path")
        executable_path = executable_binding.get("path")
        if (
            type(info_path) is not str
            or type(executable_path) is not str
            or info_path not in payloads
            or executable_path not in payloads
        ):
            return ["R13 archived app bound file inventory differs"]
        expected_info_path = (
            "Contents/Info.plist"
            if "Contents/Info.plist" in payloads
            else "Info.plist"
        )
        if info_path != expected_info_path:
            return ["R13 archived app Info.plist binding differs"]
        try:
            info = plistlib.loads(payloads[info_path])
        except plistlib.InvalidFileException:
            return ["R13 archived app Info.plist cannot be parsed"]
        if type(info) is not dict:
            return ["R13 archived app Info.plist root differs"]
        executable_name = info.get("CFBundleExecutable")
        if type(executable_name) is not str or not executable_name:
            return ["R13 archived app executable name differs"]
        preferred_executable = f"Contents/MacOS/{executable_name}"
        expected_executable = (
            preferred_executable
            if preferred_executable in payloads
            else executable_name
        )
        expected = {
            "build_version": str(info.get("CFBundleVersion", "")),
            "bundle_identifier": str(info.get("CFBundleIdentifier", "")),
            "executable_name": executable_name,
            "short_version": str(
                info.get("CFBundleShortVersionString", "")
            ),
        }
        errors = [
            f"R13 archived app {key} differs"
            for key, expected_value in expected.items()
            if bundle.get(key) != expected_value
        ]
        if executable_path != expected_executable:
            errors.append("R13 archived app executable binding differs")
        return sorted(set(errors))

    def _candidate_archive_errors(
        self,
        payload: bytes,
        app_identity: object,
    ) -> list[str]:
        if (
            not payload
            or len(payload) > _MAX_CANDIDATE_ARCHIVE_BYTES
            or type(app_identity) is not dict
        ):
            return ["R13 candidate archive boundary differs"]
        app_errors = self._app_identity_errors(app_identity)
        if app_errors:
            return app_errors
        expected_manifest = app_identity["file_manifest"]
        observed_manifest: list[dict[str, object]] = []
        extracted_entries: list[tuple[str, int, bytes]] = []
        extracted_size = 0
        try:
            with zipfile.ZipFile(io.BytesIO(payload), "r") as archive:
                infos = archive.infolist()
                expected_names = [
                    f"Mirmir.app/{entry['path']}"
                    for entry in expected_manifest
                ]
                if (
                    not infos
                    or len(infos) != len(expected_manifest)
                    or len({info.filename for info in infos}) != len(infos)
                    or [info.filename for info in infos] != expected_names
                    or archive.comment != b""
                ):
                    return ["R13 candidate archive entry inventory differs"]
                for info in infos:
                    path = PurePosixPath(info.filename)
                    raw_mode = (info.external_attr >> 16) & 0xFFFF
                    if (
                        info.is_dir()
                        or path.is_absolute()
                        or path.as_posix() != info.filename
                        or len(path.parts) < 2
                        or path.parts[0] != "Mirmir.app"
                        or any(
                            part in {"", ".", ".."} for part in path.parts
                        )
                        or info.flag_bits & 0x1
                        or stat.S_ISLNK(raw_mode)
                        or stat.S_ISDIR(raw_mode)
                        or info.compress_type != zipfile.ZIP_DEFLATED
                        or info.date_time != (1980, 1, 1, 0, 0, 0)
                        or info.extra != b""
                        or info.comment != b""
                        or info.create_system != 3
                        or info.file_size < 1
                        or info.file_size > _MAX_CANDIDATE_ARCHIVE_BYTES
                    ):
                        return ["R13 candidate archive entry differs"]
                    entry_payload = archive.read(info)
                    if len(entry_payload) != info.file_size:
                        return ["R13 candidate archive entry size differs"]
                    relative = PurePosixPath(
                        *path.parts[1:]
                    ).as_posix()
                    extracted_size += len(entry_payload)
                    if extracted_size > _MAX_CANDIDATE_EXTRACTED_BYTES:
                        return [
                            "R13 candidate archive extracted size differs"
                        ]
                    extracted_entries.append(
                        (
                            relative,
                            stat.S_IMODE(raw_mode),
                            entry_payload,
                        )
                    )
                    observed_manifest.append(
                        {
                            "mode": stat.S_IMODE(raw_mode),
                            "path": relative,
                            "sha256": _sha256(entry_payload),
                            "size_bytes": len(entry_payload),
                        }
                    )
        except (OSError, ValueError, zipfile.BadZipFile) as error:
            return [f"R13 candidate archive cannot be reopened: {error}"]
        if observed_manifest != expected_manifest:
            return ["R13 reopened candidate archive app tree differs"]
        try:
            canonical_payload = self._canonical_candidate_archive_payload(
                extracted_entries
            )
        except (OSError, ValueError, zipfile.BadZipFile) as error:
            return [f"R13 candidate archive cannot be canonicalized: {error}"]
        if payload != canonical_payload:
            return ["R13 candidate archive encoding differs"]
        bundle_errors = self._archived_bundle_identity_errors(
            app_identity,
            extracted_entries,
        )
        if bundle_errors:
            return bundle_errors
        try:
            with tempfile.TemporaryDirectory(
                prefix="mirmir-r13-archive-reopen-"
            ) as temporary:
                extraction_root = Path(temporary) / "Mirmir.app"
                extraction_root.mkdir(mode=0o700)
                for relative, mode, entry_payload in extracted_entries:
                    destination = extraction_root / relative
                    destination.parent.mkdir(
                        mode=0o700,
                        parents=True,
                        exist_ok=True,
                    )
                    descriptor = os.open(
                        destination,
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | os.O_NOFOLLOW
                        | getattr(os, "O_CLOEXEC", 0),
                        mode,
                    )
                    try:
                        written = 0
                        while written < len(entry_payload):
                            written += os.write(
                                descriptor,
                                entry_payload[written:],
                            )
                        os.fchmod(descriptor, mode)
                    finally:
                        os.close(descriptor)
                reopened_manifest: list[dict[str, object]] = []
                for directory, names, files in os.walk(
                    extraction_root,
                    followlinks=False,
                ):
                    directory_path = Path(directory)
                    if any(
                        (directory_path / name).is_symlink()
                        for name in names
                    ):
                        return [
                            "R13 extracted candidate directory is unsafe"
                        ]
                    for name in files:
                        file_path = directory_path / name
                        value = file_path.stat()
                        payload_value = file_path.read_bytes()
                        reopened_manifest.append(
                            {
                                "mode": stat.S_IMODE(value.st_mode),
                                "path": file_path.relative_to(
                                    extraction_root
                                ).as_posix(),
                                "sha256": _sha256(payload_value),
                                "size_bytes": len(payload_value),
                            }
                        )
                reopened_manifest.sort(
                    key=lambda item: str(item["path"])
                )
                if reopened_manifest != expected_manifest:
                    return [
                        "R13 extracted candidate app tree differs"
                    ]
        except OSError as error:
            return [f"R13 candidate archive extraction failed: {error}"]
        return []

    def expected_release_candidate(
        self,
        *,
        source: Mapping[str, str],
        app_identity: Mapping[str, Any],
        candidate_archive_payload: bytes,
        output_reopen_payload: bytes,
        output_media_payload: bytes,
        tools: Mapping[str, Mapping[str, str]],
    ) -> dict[str, Any]:
        output_reopen = _decode_object(
            output_reopen_payload,
            "R13 output-reopen receipt",
        )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": ROADMAP_VERSION,
            "phase_id": "R13",
            "evidence_kind": "r13_exact_release_candidate_receipt_v1",
            "source": dict(source),
            "outcome": RELEASE_OUTCOME,
            "app_identity": dict(app_identity),
            "candidate_archive": {
                "artifact_binding": self._file_binding(
                    RELEASE_CANDIDATE_ARCHIVE_PATH,
                    candidate_archive_payload,
                ),
                "format": "zip_deflate_single_mirmir_app_v1",
                "reopen_status": "passed",
                "reopened_app_tree_sha256": app_identity["tree_sha256"],
                "top_level": "Mirmir.app",
            },
            "candidate_build_boundary": dict(CANDIDATE_BUILD_BOUNDARY),
            "execution_boundary": dict(EXECUTION_BOUNDARY),
            "distribution_boundary": dict(DISTRIBUTION_BOUNDARY),
            "output_reopen_receipt_binding": self._file_binding(
                OUTPUT_REOPEN_RECEIPT_PATH, output_reopen_payload
            ),
            "output_reopen_evidence": {
                "observed_media": output_reopen.get("observed_media"),
                "producer_test_identifier": output_reopen.get(
                    "producer_test_identifier"
                ),
                "status": output_reopen.get("status"),
            },
            "output_media_artifact_binding": self._file_binding(
                OUTPUT_MEDIA_ARTIFACT_PATH, output_media_payload
            ),
            "toolchain_identity": {
                "host": {
                    "machine": platform.machine(),
                    "release": platform.release(),
                    "system": platform.system(),
                },
                "swift": dict(tools["swift"]),
                "swiftlint": dict(tools["swiftlint"]),
                "xcodebuild": dict(tools["xcodebuild"]),
                "xcrun": dict(tools["xcrun"]),
            },
            "acceptance_basis": ACCEPTANCE_BASIS,
            "observations": dict(OBSERVATIONS),
            "mode_policy": dict(MODE_POLICY),
            "claim_boundary": dict(CLAIM_BOUNDARY),
            "comparison_policy": dict(COMPARISON_POLICY),
            "limitations": list(LIMITATIONS),
        }

    def expected_execution_receipt(
        self,
        *,
        source: Mapping[str, str],
        inventory: TestInventory,
        build_payload: bytes,
        test_payload: bytes,
        release_payload: bytes,
        lint_payload: bytes,
        release_candidate_payload: bytes,
        candidate_archive_payload: bytes,
        output_reopen_payload: bytes,
        output_media_payload: bytes,
        identities: Mapping[str, Mapping[str, Any]],
        linted_file_count: int,
    ) -> dict[str, Any]:
        build_argv = identities.get("build_for_testing", {}).get("argv")
        release_argv = identities.get("release_app_build", {}).get("argv")
        if (
            type(build_argv) is not list
            or type(release_argv) is not list
            or len(build_argv) != 17
            or len(release_argv) != 16
            or build_argv[11] == release_argv[11]
            or Path(str(build_argv[11])).parent.name != "Test"
            or Path(str(release_argv[11])).parent.name != "Release"
        ):
            raise ValueError(
                "R13 test and Release DerivedData boundaries differ"
            )
        release_app_tree_sha256 = identities.get(
            "release_app_build", {}
        ).get("release_app_tree_sha256")
        if (
            type(release_app_tree_sha256) is not str
            or re.fullmatch(r"[0-9a-f]{64}", release_app_tree_sha256) is None
        ):
            raise ValueError("R13 Release app tree binding differs")
        artifacts = (
            ("build_for_testing_log", BUILD_FOR_TESTING_LOG_PATH, build_payload),
            ("targeted_xctest_log", TARGETED_TEST_LOG_PATH, test_payload),
            ("release_app_build_log", RELEASE_BUILD_LOG_PATH, release_payload),
            ("swiftlint_log", LINT_LOG_PATH, lint_payload),
            (
                "release_candidate_receipt",
                RELEASE_CANDIDATE_RECEIPT_PATH,
                release_candidate_payload,
            ),
            (
                "release_candidate_archive",
                RELEASE_CANDIDATE_ARCHIVE_PATH,
                candidate_archive_payload,
            ),
            (
                "output_reopen_receipt",
                OUTPUT_REOPEN_RECEIPT_PATH,
                output_reopen_payload,
            ),
            (
                "output_media_artifact",
                OUTPUT_MEDIA_ARTIFACT_PATH,
                output_media_payload,
            ),
        )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": ROADMAP_VERSION,
            "phase_id": "R13",
            "evidence_kind": (
                "r13_exact_source_software_function_execution_receipt_v1"
            ),
            "source": dict(source),
            "predecessor_bindings": self._predecessor_bindings(source),
            "source_bindings": self.source_bindings(source, inventory),
            "artifact_bindings": [
                {
                    "id": identifier,
                    **self._file_binding(path, payload),
                }
                for identifier, path, payload in artifacts
            ],
            "commands": {
                "build_for_testing": BUILD_FOR_TESTING_COMMAND,
                "output_reopen": OUTPUT_REOPEN_COMMAND,
                "release_app_build": RELEASE_BUILD_COMMAND,
                "swiftlint": LINT_COMMAND,
                "targeted_tests": TARGETED_TEST_COMMAND,
            },
            "execution_identities": {
                key: dict(identities[key])
                for key in (
                    "build_for_testing",
                    "targeted_tests",
                    "release_app_build",
                    "swiftlint",
                    "output_reopen",
                )
            },
            "verification": {
                "build_for_testing": {
                    "configuration": "Debug",
                    "status": "passed",
                },
                "output_reopen": {
                    "artifact_sha256": _sha256(output_media_payload),
                    "status": "passed",
                },
                "release_app_build": {
                    "configuration": "Release",
                    "outcome": RELEASE_OUTCOME,
                    "release_app_tree_sha256": release_app_tree_sha256,
                    "status": "passed",
                },
                "swiftlint": {
                    "linted_file_count": linted_file_count,
                    "serious_violation_count": 0,
                    "status": "passed",
                    "violation_count": 0,
                },
                "targeted_tests": {
                    "configuration": "Debug",
                    "failed_test_count": 0,
                    "passed_test_count": len(inventory.identifiers),
                    "selected_test_count": len(inventory.identifiers),
                    "skipped_test_count": 0,
                    "status": "passed",
                },
            },
            "test_inventory": self._test_inventory_record(inventory),
            "contract_coverage": self._contract_coverage(inventory),
            "acceptance_basis": ACCEPTANCE_BASIS,
            "acceptance_scope": ACCEPTANCE_SCOPE,
            "outcome": RELEASE_OUTCOME,
            "execution_boundary": dict(EXECUTION_BOUNDARY),
            "distribution_boundary": dict(DISTRIBUTION_BOUNDARY),
            "observations": dict(OBSERVATIONS),
            "claim_boundary": dict(CLAIM_BOUNDARY),
            "comparison_policy": dict(COMPARISON_POLICY),
            "limitations": list(LIMITATIONS),
        }

    @staticmethod
    def expected_acceptance(
        *,
        source: Mapping[str, str],
        execution_payload: bytes,
        release_candidate_payload: bytes,
        phase_status_before: str,
    ) -> dict[str, Any]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": ROADMAP_VERSION,
            "phase_id": "R13",
            "evidence_kind": "r13_functional_phase_acceptance_v1",
            "source": dict(source),
            "execution_receipt_binding": R13PhaseAcceptanceVerifier._file_binding(
                EXECUTION_RECEIPT_PATH, execution_payload
            ),
            "release_candidate_receipt_binding": (
                R13PhaseAcceptanceVerifier._file_binding(
                    RELEASE_CANDIDATE_RECEIPT_PATH,
                    release_candidate_payload,
                )
            ),
            "checks": [
                {"id": identifier, "status": "passed"}
                for identifier in DERIVED_CHECK_IDS
            ],
            "functional_gate": {
                "acceptance_basis": ACCEPTANCE_BASIS,
                "acceptance_scope": ACCEPTANCE_SCOPE,
                "outcome": RELEASE_OUTCOME,
                "phase_status_after": "passed",
                "phase_status_before": phase_status_before,
                "status": "passed",
            },
            "execution_boundary": dict(EXECUTION_BOUNDARY),
            "distribution_boundary": dict(DISTRIBUTION_BOUNDARY),
            "observations": dict(OBSERVATIONS),
            "claim_boundary": dict(CLAIM_BOUNDARY),
            "comparison_policy": dict(COMPARISON_POLICY),
            "limitations": list(LIMITATIONS),
        }

    def _roadmap_status(self) -> tuple[str | None, list[str]]:
        try:
            payload = self._read_repository_file(
                ROADMAP_PATH,
                context="R13 roadmap",
                maximum=_MAX_JSON_BYTES,
            )
            roadmap = _decode_object(payload, "R13 roadmap")
        except ValueError as error:
            return None, [str(error)]
        errors: list[str] = []
        if roadmap.get("roadmap_version") != ROADMAP_VERSION:
            errors.append("R13 roadmap version differs")
        phases = roadmap.get("phases")
        if type(phases) is not list:
            return None, errors + ["R13 roadmap phases differ"]
        selected: dict[str, Mapping[str, Any]] = {}
        for phase in phases:
            if type(phase) is dict and phase.get("id") in {"R11", "R12", "R13"}:
                selected[str(phase["id"])] = phase
        expected = {
            "R11": (
                "Evidence traceability and claim boundary",
                ["R10"],
                "passed",
            ),
            "R12": (
                "Format, route, and product expansion",
                ["R11"],
                "passed",
            ),
            "R13": (
                "Release hardening",
                ["R11", "R12"],
                None,
            ),
        }
        for phase_id, (name, dependencies, status) in expected.items():
            phase = selected.get(phase_id)
            if (
                phase is None
                or phase.get("name") != name
                or phase.get("depends_on") != dependencies
                or (
                    status is not None
                    and phase.get("status") != status
                )
            ):
                errors.append(f"R13 roadmap {phase_id} contract differs")
        r13 = selected.get("R13")
        current = str(r13.get("status")) if r13 is not None else None
        if current not in {"in_progress", "evidence_ready", "passed"}:
            errors.append("R13 roadmap status differs")
        return (current if not errors else None), sorted(set(errors))

    def _current_source_errors(
        self,
        source: Mapping[str, str],
        inventory: TestInventory,
    ) -> list[str]:
        errors: list[str] = []
        try:
            bindings = self._source_binding_inventory(source, inventory)
        except ValueError as error:
            return [str(error)]
        for _identifier, _role, path in bindings:
            try:
                checkpoint = self._checkpoint_bytes(source, path)
                current = self._read_repository_file(
                    path,
                    context=f"R13 current source {path.as_posix()}",
                    maximum=_MAX_SOURCE_BYTES,
                )
            except ValueError as error:
                errors.append(str(error))
                continue
            if current != checkpoint:
                errors.append(
                    f"R13 current source differs from checkpoint: "
                    f"{path.as_posix()}"
                )
        return sorted(set(errors))

    @staticmethod
    def _schema_errors(
        schema: Mapping[str, Any],
        value: object,
        context: str,
    ) -> list[str]:
        return [
            f"{context}: {error}"
            for error in validate_json_schema_instance(schema, value)
        ]

    def _checkpoint_schema(
        self,
        source: Mapping[str, str],
        path: Path,
        context: str,
    ) -> dict[str, Any]:
        return _decode_object(self._checkpoint_bytes(source, path), context)

    def _output_reopen_errors(
        self,
        receipt: object,
        *,
        source: Mapping[str, str],
        media_payload: bytes,
        inventory: TestInventory,
    ) -> list[str]:
        if type(receipt) is not dict or set(receipt) != {
            "artifact_binding",
            "evidence_kind",
            "execution_identity",
            "observed_media",
            "phase_id",
            "producer_test_identifier",
            "roadmap_version",
            "schema_version",
            "source",
            "status",
        }:
            return ["R13 output-reopen receipt shape differs"]
        errors = self._identity_errors(
            receipt["execution_identity"],
            source=source,
            command_id="output_reopen",
            command=OUTPUT_REOPEN_COMMAND,
            tool_name="xcrun",
            inventory=inventory,
        )
        expected_fixed = {
            "schema_version": "1.0.0",
            "roadmap_version": ROADMAP_VERSION,
            "phase_id": "R13",
            "evidence_kind": "r13_output_reopen_receipt_v1",
            "source": dict(source),
            "status": "passed",
            "producer_test_identifier": PRODUCT_OUTPUT_PRODUCER_TEST,
            "artifact_binding": self._file_binding(
                OUTPUT_MEDIA_ARTIFACT_PATH, media_payload
            ),
        }
        for key, expected in expected_fixed.items():
            if receipt.get(key) != expected:
                errors.append(f"R13 output-reopen {key} differs")
        observed = receipt.get("observed_media")
        if (
            type(observed) is not dict
            or set(observed) != {
            "container_type",
            "controlled_metadata",
            "duration_seconds",
            "frame_count",
                "height",
                "video_track_count",
                "width",
            }
            or observed.get("container_type") != "com.apple.quicktime-movie"
            or observed.get("video_track_count") != 1
            or type(observed.get("width")) is not int
            or observed["width"] <= 0
            or type(observed.get("height")) is not int
            or observed["height"] <= 0
            or type(observed.get("frame_count")) is not int
            or observed["frame_count"] <= 0
            or type(observed.get("duration_seconds")) not in {int, float}
            or observed["duration_seconds"] <= 0
        ):
            errors.append("R13 output-reopen observed media differs")
        metadata = (
            observed.get("controlled_metadata")
            if type(observed) is dict
            else None
        )
        if type(metadata) is not list:
            errors.append("R13 output-reopen controlled metadata differs")
        else:
            pairs: list[tuple[str, str]] = []
            for item in metadata:
                if (
                    type(item) is not dict
                    or set(item) != {"key", "value"}
                    or type(item.get("key")) is not str
                    or type(item.get("value")) is not str
                    or not item["value"]
                ):
                    errors.append(
                        "R13 output-reopen controlled metadata entry differs"
                    )
                    continue
                pairs.append((item["key"], item["value"]))
            if (
                pairs != sorted(pairs)
                or len(pairs) != len(set(pairs))
                or {key for key, _value in pairs}
                != REQUIRED_RELEASE_METADATA_KEYS
                or dict(pairs).get("com.mirmir.release.model-status")
                != "not_required"
                or dict(pairs).get("com.mirmir.release.fallback-history")
                != "[]"
                or any(
                    str(dict(pairs).get(key, "")).strip().casefold() == "auto"
                    for key in (
                        "com.mirmir.release.requested-mode",
                        "com.mirmir.release.effective-mode",
                    )
                )
            ):
                errors.append(
                    "R13 output-reopen exact release metadata differs"
                )
        return sorted(set(errors))

    def _release_candidate_errors(
        self,
        receipt: object,
        *,
        source: Mapping[str, str],
        candidate_archive_payload: bytes,
        output_reopen_payload: bytes,
        media_payload: bytes,
        tools: Mapping[str, Mapping[str, str]],
    ) -> list[str]:
        if type(receipt) is not dict:
            return ["R13 release-candidate receipt is not an object"]
        errors = self._app_identity_errors(receipt.get("app_identity"))
        try:
            output_reopen = _decode_object(
                output_reopen_payload,
                "R13 output-reopen receipt",
            )
        except ValueError as error:
            return errors + [str(error)]
        fixed = {
            "schema_version": "1.0.0",
            "roadmap_version": ROADMAP_VERSION,
            "phase_id": "R13",
            "evidence_kind": "r13_exact_release_candidate_receipt_v1",
            "source": dict(source),
            "outcome": RELEASE_OUTCOME,
            "candidate_archive": {
                "artifact_binding": self._file_binding(
                    RELEASE_CANDIDATE_ARCHIVE_PATH,
                    candidate_archive_payload,
                ),
                "format": "zip_deflate_single_mirmir_app_v1",
                "reopen_status": "passed",
                "reopened_app_tree_sha256": (
                    receipt.get("app_identity", {}).get("tree_sha256")
                    if type(receipt.get("app_identity")) is dict
                    else None
                ),
                "top_level": "Mirmir.app",
            },
            "candidate_build_boundary": CANDIDATE_BUILD_BOUNDARY,
            "execution_boundary": EXECUTION_BOUNDARY,
            "distribution_boundary": DISTRIBUTION_BOUNDARY,
            "output_reopen_receipt_binding": self._file_binding(
                OUTPUT_REOPEN_RECEIPT_PATH, output_reopen_payload
            ),
            "output_reopen_evidence": {
                "observed_media": output_reopen.get("observed_media"),
                "producer_test_identifier": output_reopen.get(
                    "producer_test_identifier"
                ),
                "status": output_reopen.get("status"),
            },
            "output_media_artifact_binding": self._file_binding(
                OUTPUT_MEDIA_ARTIFACT_PATH, media_payload
            ),
            "acceptance_basis": ACCEPTANCE_BASIS,
            "observations": OBSERVATIONS,
            "mode_policy": MODE_POLICY,
            "claim_boundary": CLAIM_BOUNDARY,
            "comparison_policy": COMPARISON_POLICY,
            "limitations": list(LIMITATIONS),
        }
        for key, expected in fixed.items():
            if receipt.get(key) != expected:
                errors.append(f"R13 release-candidate {key} differs")
        errors.extend(
            self._candidate_archive_errors(
                candidate_archive_payload,
                receipt.get("app_identity"),
            )
        )
        toolchain = receipt.get("toolchain_identity")
        if type(toolchain) is not dict or set(toolchain) != {
            "host",
            "swift",
            "swiftlint",
            "xcodebuild",
            "xcrun",
        }:
            errors.append("R13 release-candidate toolchain identity differs")
        else:
            for name in ("swift", "swiftlint", "xcodebuild", "xcrun"):
                if toolchain.get(name) != dict(tools[name]):
                    errors.append(
                        f"R13 release-candidate {name} identity differs"
                    )
            host = toolchain.get("host")
            if (
                type(host) is not dict
                or set(host) != {"machine", "release", "system"}
                or any(type(value) is not str or not value for value in host.values())
            ):
                errors.append("R13 release-candidate host identity differs")
        return sorted(set(errors))

    @staticmethod
    def _release_tree_binding_errors(
        candidate: object,
        release_identity: object,
    ) -> list[str]:
        app_identity = (
            candidate.get("app_identity")
            if type(candidate) is dict
            else None
        )
        candidate_archive = (
            candidate.get("candidate_archive")
            if type(candidate) is dict
            else None
        )
        if (
            type(app_identity) is not dict
            or type(candidate_archive) is not dict
            or type(release_identity) is not dict
        ):
            return ["R13 Release-build candidate tree binding differs"]
        app_tree = app_identity.get("tree_sha256")
        if (
            re.fullmatch(r"[0-9a-f]{64}", str(app_tree)) is None
            or release_identity.get("release_app_tree_sha256") != app_tree
            or candidate_archive.get("reopened_app_tree_sha256") != app_tree
        ):
            return ["R13 Release-build candidate tree binding differs"]
        return []

    def _artifact_closure_errors(self) -> list[str]:
        expected = {
            RELEASE_CANDIDATE_RECEIPT_PATH,
            OUTPUT_REOPEN_RECEIPT_PATH,
            EXECUTION_RECEIPT_PATH,
            ACCEPTANCE_PATH,
            BUILD_FOR_TESTING_LOG_PATH,
            TARGETED_TEST_LOG_PATH,
            RELEASE_BUILD_LOG_PATH,
            LINT_LOG_PATH,
            OUTPUT_MEDIA_ARTIFACT_PATH,
            RELEASE_CANDIDATE_ARCHIVE_PATH,
        }
        base = self.root / RECORDS_DIRECTORY
        if not base.is_dir() or base.is_symlink():
            return ["R13 evidence record directory is absent or unsafe"]
        observed: set[Path] = set()
        for directory, names, files in os.walk(base, followlinks=False):
            directory_path = Path(directory)
            for name in names:
                if (directory_path / name).is_symlink():
                    return ["R13 evidence directory contains a symlink"]
            for name in files:
                absolute = directory_path / name
                if absolute.is_symlink():
                    return ["R13 evidence artifact contains a symlink"]
                observed.add(absolute.relative_to(self.root))
        return (
            []
            if observed == expected
            else ["R13 generated evidence artifact closure differs"]
        )

    def _read_generated(self, path: Path, maximum: int) -> bytes:
        return self._read_repository_file(
            path,
            context=f"R13 generated artifact {path.as_posix()}",
            maximum=maximum,
            require_sealed=True,
            allow_git_materialized=True,
        )

    def check_generated(self) -> list[str]:
        errors = self._artifact_closure_errors()
        payloads: dict[str, bytes] = {}
        for key, path, maximum in (
            ("candidate", RELEASE_CANDIDATE_RECEIPT_PATH, _MAX_JSON_BYTES),
            ("reopen", OUTPUT_REOPEN_RECEIPT_PATH, _MAX_JSON_BYTES),
            ("execution", EXECUTION_RECEIPT_PATH, _MAX_JSON_BYTES),
            ("acceptance", ACCEPTANCE_PATH, _MAX_JSON_BYTES),
            ("build", BUILD_FOR_TESTING_LOG_PATH, _MAX_BUILD_LOG_BYTES),
            ("test", TARGETED_TEST_LOG_PATH, _MAX_TEST_LOG_BYTES),
            ("release", RELEASE_BUILD_LOG_PATH, _MAX_BUILD_LOG_BYTES),
            ("lint", LINT_LOG_PATH, _MAX_LINT_LOG_BYTES),
            ("media", OUTPUT_MEDIA_ARTIFACT_PATH, _MAX_MEDIA_BYTES),
            (
                "archive",
                RELEASE_CANDIDATE_ARCHIVE_PATH,
                _MAX_CANDIDATE_ARCHIVE_BYTES,
            ),
        ):
            try:
                payloads[key] = self._read_generated(path, maximum)
            except ValueError as error:
                errors.append(str(error))
        if errors:
            return sorted(set(errors))
        try:
            candidate = _decode_object(payloads["candidate"], "R13 candidate")
            reopen = _decode_object(payloads["reopen"], "R13 output reopen")
            execution = _decode_object(payloads["execution"], "R13 execution")
            acceptance = _decode_object(
                payloads["acceptance"], "R13 acceptance"
            )
        except ValueError as error:
            return [str(error)]
        source = execution.get("source")
        errors.extend(self._source_errors(source))
        if errors or type(source) is not dict:
            return sorted(set(errors))
        inventory, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        if inventory is None:
            return sorted(set(errors))
        errors.extend(self._current_source_errors(source, inventory))
        try:
            tools = {
                name: self._tool_identity(name)
                for name in ("swift", "swiftlint", "xcodebuild", "xcrun")
            }
        except (OSError, TypeError, ValueError) as error:
            errors.append(
                f"R13 independently resolved tool identity failed: {error}"
            )
            return sorted(set(errors))
        build_identity, build_errors = self._build_log(
            payloads["build"],
            source=source,
            inventory=inventory,
            release=False,
        )
        test_identity, test_errors = self._test_log(
            payloads["test"], source=source, inventory=inventory
        )
        release_identity, release_errors = self._build_log(
            payloads["release"],
            source=source,
            inventory=inventory,
            release=True,
        )
        lint_identity, lint, lint_errors = self._lint_log(
            payloads["lint"], source=source, inventory=inventory
        )
        errors.extend(
            build_errors + test_errors + release_errors + lint_errors
        )
        reopen_identity = (
            reopen.get("execution_identity") if type(reopen) is dict else None
        )
        errors.extend(
            self._output_reopen_errors(
                reopen,
                source=source,
                media_payload=payloads["media"],
                inventory=inventory,
            )
        )
        identities = {
            "build_for_testing": build_identity,
            "targeted_tests": test_identity,
            "release_app_build": release_identity,
            "swiftlint": lint_identity,
            "output_reopen": reopen_identity,
        }
        if (
            errors
            or lint is None
            or any(value is None for value in identities.values())
        ):
            return sorted(set(errors))
        typed_identities = {
            key: value
            for key, value in identities.items()
            if isinstance(value, dict)
        }
        errors.extend(self._tool_binding_errors(typed_identities, tools))
        errors.extend(
            self._release_tree_binding_errors(
                candidate,
                typed_identities.get("release_app_build"),
            )
        )
        if errors:
            return sorted(set(errors))
        errors.extend(
            self._release_candidate_errors(
                candidate,
                source=source,
                candidate_archive_payload=payloads["archive"],
                output_reopen_payload=payloads["reopen"],
                media_payload=payloads["media"],
                tools=tools,
            )
        )
        try:
            expected_execution = self.expected_execution_receipt(
                source=source,
                inventory=inventory,
                build_payload=payloads["build"],
                test_payload=payloads["test"],
                release_payload=payloads["release"],
                lint_payload=payloads["lint"],
                release_candidate_payload=payloads["candidate"],
                candidate_archive_payload=payloads["archive"],
                output_reopen_payload=payloads["reopen"],
                output_media_payload=payloads["media"],
                identities=typed_identities,
                linted_file_count=lint.linted_file_count,
            )
        except ValueError as error:
            errors.append(str(error))
            expected_execution = {}
        if execution != expected_execution:
            errors.append("R13 functional execution receipt differs")
        gate = acceptance.get("functional_gate")
        before = (
            gate.get("phase_status_before")
            if type(gate) is dict
            else None
        )
        if before not in {"in_progress", "evidence_ready"}:
            errors.append("R13 acceptance prior phase status differs")
        else:
            expected_acceptance = self.expected_acceptance(
                source=source,
                execution_payload=payloads["execution"],
                release_candidate_payload=payloads["candidate"],
                phase_status_before=str(before),
            )
            if acceptance != expected_acceptance:
                errors.append("R13 functional phase acceptance differs")
        try:
            candidate_schema = self._checkpoint_schema(
                source,
                RELEASE_CANDIDATE_SCHEMA_PATH,
                "R13 release-candidate schema",
            )
            execution_schema = self._checkpoint_schema(
                source,
                EXECUTION_SCHEMA_PATH,
                "R13 execution schema",
            )
            acceptance_schema = self._checkpoint_schema(
                source,
                ACCEPTANCE_SCHEMA_PATH,
                "R13 acceptance schema",
            )
        except ValueError as error:
            errors.append(str(error))
        else:
            errors.extend(
                self._schema_errors(
                    candidate_schema, candidate, "R13 release-candidate schema"
                )
            )
            errors.extend(
                self._schema_errors(
                    execution_schema, execution, "R13 execution schema"
                )
            )
            errors.extend(
                self._schema_errors(
                    acceptance_schema, acceptance, "R13 acceptance schema"
                )
            )
        return sorted(set(errors))

    def check(self) -> list[str]:
        status, roadmap_errors = self._roadmap_status()
        errors = list(roadmap_errors)
        generated = [
            self.root / path
            for path in (
                RELEASE_CANDIDATE_RECEIPT_PATH,
                OUTPUT_REOPEN_RECEIPT_PATH,
                EXECUTION_RECEIPT_PATH,
                ACCEPTANCE_PATH,
            )
        ]
        present = [path.exists() for path in generated]
        if not any(present):
            if status in {"in_progress", "evidence_ready"}:
                errors.append(
                    "INCOMPLETE: R13 exact-source release-candidate evidence "
                    "has not been generated"
                )
            elif status == "passed":
                errors.append(
                    "R13 roadmap is passed without generated acceptance"
                )
            return sorted(set(errors))
        if not all(present):
            errors.append("R13 generated evidence bundle is partial")
            return sorted(set(errors))
        errors.extend(self.check_generated())
        if status != "passed":
            errors.append(
                "R13 roadmap status must be passed after accepted evidence"
            )
        return sorted(set(errors))

    @classmethod
    def _media_reopener_source_errors(
        cls,
        source: str | None = None,
    ) -> list[str]:
        text = cls._media_generator_source() if source is None else source
        metadata_required = (
            "func metadataKey(_ item: AVMetadataItem) -> String?",
            "if let value = item.key as? String { return value }",
            "if let value = item.key as? NSString { return value as String }",
            "guard let key = metadataKey(item),",
        )
        container_required = (
            (
                "func isoBMFFContainerType(at url: URL) "
                "throws -> String {"
            ),
            (
                "let bytes = try Data("
                "contentsOf: url, options: .mappedIfSafe)"
            ),
            'if boxType == "ftyp" {',
            'case "qt  ":',
            "containerType = AVFileType.mov.rawValue",
            'case "isom", "iso2", "mp41", "mp42":',
            "containerType = AVFileType.mp4.rawValue",
            "let containerType = try isoBMFFContainerType(at: url)",
            '"container_type": containerType,',
        )
        errors: list[str] = []
        if (
            type(text) is not str
            or any(
                text.count(fragment) != 1
                for fragment in metadata_required
            )
            or "item.identifier" in text
        ):
            errors.append(
                "R13 media reopener metadata-key canonicalization differs"
            )
        if (
            type(text) is not str
            or any(
                text.count(fragment) != 1
                for fragment in container_required
            )
            or '"container_type": "com.apple.quicktime-movie"' in text
            or '"container_type": "public.mpeg-4"' in text
        ):
            errors.append(
                "R13 media reopener container observation differs"
            )
        return errors

    @staticmethod
    def _media_generator_source() -> str:
        return r'''import AVFoundation
import Foundation

enum ReopenError: Error { case failed(String) }

func fourCC(_ value: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "unknown"
}

func metadataKey(_ item: AVMetadataItem) -> String? {
    if let value = item.key as? String { return value }
    if let value = item.key as? NSString { return value as String }
    return nil
}

func readUInt32BE(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset <= data.count, data.count - offset >= 4 else {
        throw ReopenError.failed("iso_bmff_uint32")
    }
    var value: UInt32 = 0
    for index in 0..<4 {
        value = (value << 8) | UInt32(data[offset + index])
    }
    return value
}

func readUInt64BE(_ data: Data, at offset: Int) throws -> UInt64 {
    guard offset >= 0, offset <= data.count, data.count - offset >= 8 else {
        throw ReopenError.failed("iso_bmff_uint64")
    }
    var value: UInt64 = 0
    for index in 0..<8 {
        value = (value << 8) | UInt64(data[offset + index])
    }
    return value
}

func isoBMFFContainerType(at url: URL) throws -> String {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    var offset = 0
    var containerType: String?
    while offset < bytes.count {
        guard bytes.count - offset >= 8 else {
            throw ReopenError.failed("iso_bmff_box_header")
        }
        let compactSize = try readUInt32BE(bytes, at: offset)
        guard let boxType = String(
            bytes: bytes[(offset + 4)..<(offset + 8)],
            encoding: .ascii
        ) else {
            throw ReopenError.failed("iso_bmff_box_type")
        }
        var headerSize = 8
        let boxSize: Int
        switch compactSize {
        case 0:
            boxSize = bytes.count - offset
        case 1:
            guard bytes.count - offset >= 16 else {
                throw ReopenError.failed("iso_bmff_large_box_header")
            }
            let largeSize = try readUInt64BE(bytes, at: offset + 8)
            guard largeSize <= UInt64(Int.max) else {
                throw ReopenError.failed("iso_bmff_large_box_size")
            }
            headerSize = 16
            boxSize = Int(largeSize)
        default:
            boxSize = Int(compactSize)
        }
        guard boxSize >= headerSize, boxSize <= bytes.count - offset else {
            throw ReopenError.failed("iso_bmff_box_size")
        }
        if boxType == "ftyp" {
            let payloadSize = boxSize - headerSize
            guard containerType == nil,
                  payloadSize >= 8,
                  payloadSize.isMultiple(of: 4) else {
                throw ReopenError.failed("iso_bmff_ftyp_shape")
            }
            let majorBrandOffset = offset + headerSize
            guard let majorBrand = String(
                bytes: bytes[
                    majorBrandOffset..<(majorBrandOffset + 4)
                ],
                encoding: .ascii
            ) else {
                throw ReopenError.failed("iso_bmff_major_brand")
            }
            switch majorBrand {
            case "qt  ":
                containerType = AVFileType.mov.rawValue
            case "isom", "iso2", "mp41", "mp42":
                containerType = AVFileType.mp4.rawValue
            default:
                throw ReopenError.failed(
                    "iso_bmff_unsupported_major_brand"
                )
            }
        }
        offset += boxSize
        if compactSize == 0 {
            break
        }
    }
    guard let containerType else {
        throw ReopenError.failed("iso_bmff_ftyp_missing")
    }
    return containerType
}

Task {
    do {
        guard CommandLine.arguments.count == 2 else {
            throw ReopenError.failed("argument_count")
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let containerType = try isoBMFFContainerType(at: url)
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1 else {
            throw ReopenError.failed("video_track_count")
        }
        let duration = try await asset.load(.duration)
        let size = try await videoTracks[0].load(.naturalSize)
        let descriptions = try await videoTracks[0].load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw ReopenError.failed("format_description")
        }

        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTracks[0], outputSettings: nil
        )
        guard videoReader.canAdd(videoOutput) else {
            throw ReopenError.failed("video_reader_output")
        }
        videoReader.add(videoOutput)
        guard videoReader.startReading() else {
            throw ReopenError.failed("video_reader_start")
        }
        var frameCount = 0
        while videoOutput.copyNextSampleBuffer() != nil {
            frameCount += 1
        }
        guard videoReader.status == .completed, frameCount > 0 else {
            throw ReopenError.failed("video_reader_complete")
        }

        var controlledMetadata: [[String: String]] = []
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: nil
            )
            guard reader.canAdd(output) else {
                throw ReopenError.failed("metadata_reader_output")
            }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(
                assetReaderTrackOutput: output
            )
            guard reader.startReading() else {
                throw ReopenError.failed("metadata_reader_start")
            }
            while let group = adaptor.nextTimedMetadataGroup() {
                for item in group.items {
                    guard let key = metadataKey(item),
                          key.hasPrefix("com.mirmir.release."),
                          let value = try await item.load(.stringValue) else {
                        continue
                    }
                    controlledMetadata.append(["key": key, "value": value])
                }
            }
            guard reader.status == .completed else {
                throw ReopenError.failed("metadata_reader_complete")
            }
        }
        controlledMetadata.sort {
            ($0["key"] ?? "") < ($1["key"] ?? "")
        }
        let result: [String: Any] = [
            "codec": fourCC(CMFormatDescriptionGetMediaSubType(description)),
            "container_type": containerType,
            "controlled_metadata": controlledMetadata,
            "duration_seconds": CMTimeGetSeconds(duration),
            "frame_count": frameCount,
            "height": Int(size.height),
            "video_track_count": videoTracks.count,
            "width": Int(size.width)
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: result, options: [.sortedKeys]
        )
        FileHandle.standardOutput.write(payload)
        FileHandle.standardOutput.write(Data([0x0a]))
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(
            Data("R13 product output reopen failed: \(error)\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
}
dispatchMain()
'''

    def _app_identity(self, app: Path, derived_data: Path) -> dict[str, Any]:
        expected = derived_data / "Build/Products/Release/Mirmir.app"
        if app != expected or not app.is_dir() or app.is_symlink():
            raise ValueError("R13 Release app path differs")
        manifest: list[dict[str, object]] = []
        for directory, names, files in os.walk(app, followlinks=False):
            directory_path = Path(directory)
            for name in names:
                if (directory_path / name).is_symlink():
                    raise ValueError("R13 Release app contains a symlink")
            for name in files:
                path = directory_path / name
                if path.is_symlink():
                    raise ValueError("R13 Release app contains a symlink")
                value = path.stat()
                if (
                    not stat.S_ISREG(value.st_mode)
                    or value.st_nlink != 1
                    or value.st_size < 1
                ):
                    raise ValueError("R13 Release app file identity differs")
                payload = path.read_bytes()
                relative = path.relative_to(app).as_posix()
                manifest.append(
                    {
                        "mode": stat.S_IMODE(value.st_mode),
                        "path": relative,
                        "sha256": _sha256(payload),
                        "size_bytes": len(payload),
                    }
                )
        manifest.sort(key=lambda item: str(item["path"]))
        info_path = app / "Contents/Info.plist"
        if not info_path.is_file():
            info_path = app / "Info.plist"
        try:
            info_payload = info_path.read_bytes()
            info = plistlib.loads(info_payload)
        except (OSError, plistlib.InvalidFileException) as error:
            raise ValueError("R13 Release app Info.plist differs") from error
        executable_name = info.get("CFBundleExecutable")
        if type(executable_name) is not str or not executable_name:
            raise ValueError("R13 Release app executable name differs")
        executable_path = app / "Contents/MacOS" / executable_name
        if not executable_path.is_file():
            executable_path = app / executable_name
        by_path = {str(item["path"]): item for item in manifest}
        info_relative = info_path.relative_to(app).as_posix()
        executable_relative = executable_path.relative_to(app).as_posix()
        if info_relative not in by_path or executable_relative not in by_path:
            raise ValueError("R13 Release app bound file inventory differs")
        def binding(relative: str) -> dict[str, object]:
            entry = by_path[relative]
            return {
                "path": relative,
                "sha256": entry["sha256"],
                "size_bytes": entry["size_bytes"],
            }
        frameworks = [
            item
            for item in manifest
            if str(item["path"]).startswith("Contents/Frameworks/")
        ]
        return {
            "bundle": {
                "build_version": str(info.get("CFBundleVersion", "")),
                "bundle_identifier": str(
                    info.get("CFBundleIdentifier", "")
                ),
                "executable": binding(executable_relative),
                "executable_name": executable_name,
                "info_plist": binding(info_relative),
                "short_version": str(
                    info.get("CFBundleShortVersionString", "")
                ),
            },
            "bundle_path": (
                "<outside-repository>/DerivedData/"
                "Build/Products/Release/Mirmir.app"
            ),
            "file_count": len(manifest),
            "file_manifest": manifest,
            "frameworks": {
                "entries": frameworks,
                "status": "present" if frameworks else "none_embedded",
                "tree_sha256": _sha256(
                    _canonical_compact_json(frameworks)
                ),
            },
            "total_size_bytes": sum(
                int(item["size_bytes"]) for item in manifest
            ),
            "tree_sha256": _sha256(_canonical_compact_json(manifest)),
        }

    def _candidate_archive(
        self,
        app: Path,
        app_identity: Mapping[str, Any],
    ) -> bytes:
        try:
            entries: list[tuple[str, int, bytes]] = []
            for entry in app_identity["file_manifest"]:
                relative = str(entry["path"])
                payload = (app / relative).read_bytes()
                if (
                    len(payload) != entry["size_bytes"]
                    or _sha256(payload) != entry["sha256"]
                ):
                    raise ValueError(
                        "R13 app changed during candidate archival"
                    )
                entries.append((relative, int(entry["mode"]), payload))
            payload = self._canonical_candidate_archive_payload(entries)
        except (KeyError, OSError, TypeError, ValueError) as error:
            raise ValueError(
                f"R13 candidate archive creation failed: {error}"
            ) from error
        errors = self._candidate_archive_errors(payload, app_identity)
        if errors:
            raise ValueError(" | ".join(errors))
        return payload

    def _run_output_reopen(
        self,
        *,
        base: Path,
        checkout: Path,
        source: Mapping[str, str],
        tool: Mapping[str, str],
        inventory: TestInventory,
        output: Path,
    ) -> tuple[bytes, dict[str, Any]]:
        script = base / "r13-output-reopen.swift"
        if (
            output != base / "r13-output-reopen-fixture.mov"
            or not output.is_file()
            or output.is_symlink()
        ):
            raise ValueError(
                "R13 shipping-service product output is absent or unsafe"
            )
        source_errors = self._media_reopener_source_errors()
        if source_errors:
            raise ValueError(" | ".join(source_errors))
        script.write_text(self._media_generator_source(), encoding="utf-8")
        before = self._checkpoint_state(
            checkout,
            source,
            context="R13 output reopen",
            boundary="before execution",
        )
        arguments = [
            tool["executable_path"],
            "swift",
            os.fspath(script),
            os.fspath(output),
        ]
        observed_payload = self._run_bounded_command(
            arguments,
            cwd=checkout,
            context="R13 output reopen",
            maximum=1024 * 1024,
        )
        after = self._checkpoint_state(
            checkout,
            source,
            context="R13 output reopen",
            boundary="after execution",
        )
        observed = _decode_object(observed_payload, "R13 reopened media")
        if set(observed) != {
            "codec",
            "container_type",
            "controlled_metadata",
            "duration_seconds",
            "frame_count",
            "height",
            "video_track_count",
            "width",
        }:
            raise ValueError("R13 reopened media observation shape differs")
        media_payload = output.read_bytes()
        if not media_payload or len(media_payload) > _MAX_MEDIA_BYTES:
            raise ValueError("R13 output media artifact size differs")
        identity: dict[str, Any] = {
            "argv": arguments,
            "checkpoint": {
                "clean_after": after["clean"],
                "clean_before": before["clean"],
                "commit_after": after["commit"],
                "commit_before": before["commit"],
                "kind": _CHECKPOINT_KIND,
                "tree_after": after["tree"],
                "tree_before": before["tree"],
            },
            "command": OUTPUT_REOPEN_COMMAND,
            "command_id": "output_reopen",
            "exit_code": 0,
            "source": dict(source),
            "tool": dict(tool),
        }
        receipt = {
            "schema_version": "1.0.0",
            "roadmap_version": ROADMAP_VERSION,
            "phase_id": "R13",
            "evidence_kind": "r13_output_reopen_receipt_v1",
            "source": dict(source),
            "status": "passed",
            "producer_test_identifier": PRODUCT_OUTPUT_PRODUCER_TEST,
            "artifact_binding": self._file_binding(
                OUTPUT_MEDIA_ARTIFACT_PATH, media_payload
            ),
            "execution_identity": identity,
            "observed_media": {
                "container_type": observed["container_type"],
                "controlled_metadata": observed["controlled_metadata"],
                "duration_seconds": observed["duration_seconds"],
                "frame_count": observed["frame_count"],
                "height": observed["height"],
                "video_track_count": observed["video_track_count"],
                "width": observed["width"],
            },
        }
        errors = self._output_reopen_errors(
            receipt,
            source=source,
            media_payload=media_payload,
            inventory=inventory,
        )
        if errors:
            raise ValueError(" | ".join(errors))
        return media_payload, receipt

    @staticmethod
    def _configure_xctestrun_product_output(
        xctestrun: Path,
        output: Path,
    ) -> dict[str, object]:
        try:
            before = xctestrun.read_bytes()
            document = plistlib.loads(before)
        except (OSError, plistlib.InvalidFileException) as error:
            raise ValueError(
                "R13 xctestrun cannot be configured exactly"
            ) from error
        if type(document) is not dict:
            raise ValueError("R13 xctestrun root differs")
        configured = 0
        for key, target in document.items():
            if key == "__xctestrun_metadata__":
                continue
            if type(target) is not dict:
                continue
            environment = target.get("EnvironmentVariables", {})
            if (
                type(environment) is not dict
                or "R13_ACCEPTANCE_OUTPUT_ARTIFACT_PATH" in environment
            ):
                raise ValueError(
                    "R13 xctestrun environment boundary differs"
                )
            environment[
                "R13_ACCEPTANCE_OUTPUT_ARTIFACT_PATH"
            ] = os.fspath(output)
            target["EnvironmentVariables"] = environment
            configured += 1
        if configured < 1:
            raise ValueError("R13 xctestrun has no configurable test target")
        payload = plistlib.dumps(
            document,
            fmt=plistlib.FMT_XML,
            sort_keys=True,
        )
        xctestrun.write_bytes(payload)
        return {
            "configured_target_count": configured,
            "environment_variable": (
                "R13_ACCEPTANCE_OUTPUT_ARTIFACT_PATH="
                "<outside-repository>/r13-output-reopen-fixture.mov"
            ),
            "xctestrun_sha256_after": _sha256(payload),
            "xctestrun_sha256_before": _sha256(before),
        }

    @staticmethod
    def _extract_product_output_from_test_log(
        payload: bytes,
        output: Path,
    ) -> bytes:
        encoded_values = [
            line[len(_OUTPUT_MEDIA_BASE64_PREFIX) :]
            for line in payload.splitlines()
            if line.startswith(_OUTPUT_MEDIA_BASE64_PREFIX)
        ]
        maximum_encoded = ((_MAX_MEDIA_BYTES + 2) // 3) * 4
        if (
            payload.count(_OUTPUT_MEDIA_BASE64_PREFIX) != 1
            or len(encoded_values) != 1
            or not encoded_values[0]
            or len(encoded_values[0]) > maximum_encoded
            or output.exists()
            or output.is_symlink()
        ):
            raise ValueError(
                "R13 targeted test output bridge inventory differs"
            )
        encoded = encoded_values[0]
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as error:
            raise ValueError(
                "R13 targeted test output bridge encoding differs"
            ) from error
        if (
            not decoded
            or len(decoded) > _MAX_MEDIA_BYTES
            or base64.b64encode(decoded) != encoded
        ):
            raise ValueError(
                "R13 targeted test output bridge payload differs"
            )

        descriptor = -1
        try:
            descriptor = os.open(
                output,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
                0o600,
            )
            written = 0
            while written < len(decoded):
                count = os.write(descriptor, decoded[written:])
                if count < 1:
                    raise OSError("R13 output bridge write made no progress")
                written += count
            os.fsync(descriptor)
        except OSError as error:
            raise ValueError(
                "R13 targeted test output bridge publication failed"
            ) from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        return decoded

    def _run_checkpoint_commands(
        self,
        source: Mapping[str, str],
        tools: Mapping[str, Mapping[str, str]],
        inventory: TestInventory,
    ) -> CapturedExecution:
        if set(tools) != {"swift", "swiftlint", "xcodebuild", "xcrun"}:
            raise ValueError("R13 tool identity inventory differs")
        with tempfile.TemporaryDirectory(
            prefix="mirmir-r13-checkpoint-"
        ) as temporary:
            base = Path(os.path.realpath(temporary))
            checkout = base / "checkpoint"
            test_derived_data = base / "Test/DerivedData"
            release_derived_data = base / "Release/DerivedData"
            product_output = base / "r13-output-reopen-fixture.mov"
            result = self._git(
                "worktree",
                "add",
                "--detach",
                os.fspath(checkout),
                source["commit"],
            )
            if result.returncode:
                raise ValueError(
                    "R13 exact checkpoint worktree could not be created"
                )
            pending: BaseException | None = None
            captured: CapturedExecution | None = None
            try:
                xcodebuild = tools["xcodebuild"]
                build_args = self._build_for_testing_arguments(
                    xcodebuild["executable_path"],
                    source,
                    os.fspath(test_derived_data),
                )
                build_log = self._captured_command_log(
                    arguments=build_args,
                    cwd=checkout,
                    source=source,
                    command_id="build_for_testing",
                    command=BUILD_FOR_TESTING_COMMAND,
                    tool=xcodebuild,
                    context="R13 build-for-testing",
                    maximum=_MAX_BUILD_LOG_BYTES,
                )
                products = test_derived_data / "Build/Products"
                xctestruns = (
                    sorted(products.glob("*.xctestrun"))
                    if products.is_dir()
                    else []
                )
                if len(xctestruns) != 1 or not xctestruns[0].is_file():
                    raise ValueError("R13 xctestrun inventory differs")
                self._configure_xctestrun_product_output(
                    xctestruns[0], product_output
                )
                test_args = self._targeted_test_arguments(
                    xcodebuild["executable_path"],
                    source,
                    os.fspath(xctestruns[0]),
                    inventory,
                )
                test_log = self._captured_command_log(
                    arguments=test_args,
                    cwd=checkout,
                    source=source,
                    command_id="targeted_tests",
                    command=TARGETED_TEST_COMMAND,
                    tool=xcodebuild,
                    context="R13 targeted XCTest",
                    maximum=_MAX_TEST_LOG_BYTES,
                )
                self._extract_product_output_from_test_log(
                    test_log,
                    product_output,
                )
                release_args = self._release_build_arguments(
                    xcodebuild["executable_path"],
                    source,
                    os.fspath(release_derived_data),
                )
                release_log = self._captured_command_log(
                    arguments=release_args,
                    cwd=checkout,
                    source=source,
                    command_id="release_app_build",
                    command=RELEASE_BUILD_COMMAND,
                    tool=xcodebuild,
                    context="R13 Release app build",
                    maximum=_MAX_BUILD_LOG_BYTES,
                )
                app = (
                    release_derived_data
                    / "Build/Products/Release/Mirmir.app"
                )
                app_identity = self._app_identity(
                    app, release_derived_data
                )
                release_log = self._bind_release_app_tree(
                    release_log,
                    str(app_identity["tree_sha256"]),
                )
                candidate_archive = self._candidate_archive(
                    app, app_identity
                )
                lint_args = self._lint_arguments(
                    tools["swiftlint"]["executable_path"]
                )
                lint_log = self._captured_command_log(
                    arguments=lint_args,
                    cwd=checkout,
                    source=source,
                    command_id="swiftlint",
                    command=LINT_COMMAND,
                    tool=tools["swiftlint"],
                    context="R13 SwiftLint",
                    maximum=_MAX_LINT_LOG_BYTES,
                )
                media, reopen = self._run_output_reopen(
                    base=base,
                    checkout=checkout,
                    source=source,
                    tool=tools["xcrun"],
                    inventory=inventory,
                    output=product_output,
                )
                captured = CapturedExecution(
                    build_log,
                    test_log,
                    release_log,
                    lint_log,
                    app_identity,
                    candidate_archive,
                    media,
                    reopen,
                )
            except BaseException as error:
                pending = error
            finally:
                removal = self._git(
                    "worktree", "remove", "--force", os.fspath(checkout)
                )
                if removal.returncode and pending is None:
                    pending = ValueError(
                        "R13 exact checkpoint worktree cleanup failed"
                    )
            if pending is not None:
                raise pending
            if captured is None:
                raise ValueError("R13 checkpoint capture is absent")
            return captured

    def _write_bundle(self, payloads: Mapping[Path, bytes]) -> list[str]:
        expected = {
            RELEASE_CANDIDATE_RECEIPT_PATH,
            OUTPUT_REOPEN_RECEIPT_PATH,
            EXECUTION_RECEIPT_PATH,
            ACCEPTANCE_PATH,
            BUILD_FOR_TESTING_LOG_PATH,
            TARGETED_TEST_LOG_PATH,
            RELEASE_BUILD_LOG_PATH,
            LINT_LOG_PATH,
            OUTPUT_MEDIA_ARTIFACT_PATH,
            RELEASE_CANDIDATE_ARCHIVE_PATH,
        }
        if set(payloads) != expected or any(not value for value in payloads.values()):
            return ["R13 publication payload inventory differs"]
        destinations = [self.root / path for path in expected]
        if any(path.exists() or path.is_symlink() for path in destinations):
            return ["R13 generated evidence already exists; refusing overwrite"]
        records = self.root / RECORDS_DIRECTORY
        published: list[Path] = []
        try:
            records.mkdir(parents=True, exist_ok=True)
            if records.is_symlink() or not records.is_dir():
                raise ValueError("R13 records directory is unsafe")
            staging = Path(
                tempfile.mkdtemp(prefix=".r13-stage-", dir=records)
            )
            for relative, payload in payloads.items():
                stage_path = staging / relative.relative_to(RECORDS_DIRECTORY)
                stage_path.parent.mkdir(parents=True, exist_ok=True)
                descriptor = os.open(
                    stage_path,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_NOFOLLOW
                    | getattr(os, "O_CLOEXEC", 0),
                    0o400,
                )
                try:
                    written = 0
                    while written < len(payload):
                        written += os.write(descriptor, payload[written:])
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            for relative in sorted(payloads, key=lambda item: len(item.parts)):
                destination = self.root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                stage_path = (
                    staging / relative.relative_to(RECORDS_DIRECTORY)
                )
                os.link(
                    stage_path,
                    destination,
                    follow_symlinks=False,
                )
                published.append(destination)
                stage_path.unlink()
            shutil.rmtree(staging)
        except (OSError, ValueError) as error:
            for destination in reversed(published):
                if destination.is_file() and not destination.is_symlink():
                    destination.unlink()
            if "staging" in locals() and staging.exists():
                shutil.rmtree(staging)
            return [f"R13 evidence publication failed: {error}"]
        return []

    def write(self, revision: str) -> list[str]:
        try:
            source = self.resolve_source(revision)
        except ValueError as error:
            return [str(error)]
        status, errors = self._roadmap_status()
        if status not in {"in_progress", "evidence_ready"}:
            errors.append(
                "R13 writer requires in_progress or evidence_ready roadmap status"
            )
        inventory, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        if inventory is None:
            return sorted(set(errors))
        errors.extend(self._current_source_errors(source, inventory))
        try:
            self._predecessor_bindings(source)
        except ValueError as error:
            errors.append(str(error))
        if errors:
            return sorted(set(errors))
        try:
            tools = {
                "swift": self._tool_identity("swift"),
                "swiftlint": self._tool_identity("swiftlint"),
                "xcodebuild": self._tool_identity("xcodebuild"),
                "xcrun": self._tool_identity("xcrun"),
            }
            captured = self._run_checkpoint_commands(
                source, tools, inventory
            )
        except (
            OSError,
            RuntimeError,
            TypeError,
            ValueError,
            subprocess.SubprocessError,
        ) as error:
            return [f"R13 checkpoint execution failed: {error}"]
        build_identity, build_errors = self._build_log(
            captured.build_for_testing_log,
            source=source,
            inventory=inventory,
            release=False,
        )
        test_identity, test_errors = self._test_log(
            captured.targeted_test_log,
            source=source,
            inventory=inventory,
        )
        release_identity, release_errors = self._build_log(
            captured.release_build_log,
            source=source,
            inventory=inventory,
            release=True,
        )
        lint_identity, lint, lint_errors = self._lint_log(
            captured.lint_log,
            source=source,
            inventory=inventory,
        )
        errors.extend(
            build_errors + test_errors + release_errors + lint_errors
        )
        reopen_payload = _canonical_json(captured.output_reopen_receipt)
        reopen_identity = captured.output_reopen_receipt.get(
            "execution_identity"
        )
        errors.extend(
            self._output_reopen_errors(
                captured.output_reopen_receipt,
                source=source,
                media_payload=captured.output_media_payload,
                inventory=inventory,
            )
        )
        identities = {
            "build_for_testing": build_identity,
            "targeted_tests": test_identity,
            "release_app_build": release_identity,
            "swiftlint": lint_identity,
            "output_reopen": reopen_identity,
        }
        if (
            errors
            or lint is None
            or any(value is None for value in identities.values())
        ):
            return sorted(set(errors))
        errors.extend(self._app_identity_errors(captured.app_identity))
        errors.extend(
            self._candidate_archive_errors(
                captured.candidate_archive_payload,
                captured.app_identity,
            )
        )
        if errors:
            return sorted(set(errors))
        candidate = self.expected_release_candidate(
            source=source,
            app_identity=captured.app_identity,
            candidate_archive_payload=captured.candidate_archive_payload,
            output_reopen_payload=reopen_payload,
            output_media_payload=captured.output_media_payload,
            tools=tools,
        )
        candidate_payload = _canonical_json(candidate)
        typed_identities = {
            key: value
            for key, value in identities.items()
            if isinstance(value, dict)
        }
        errors.extend(self._tool_binding_errors(typed_identities, tools))
        errors.extend(
            self._release_tree_binding_errors(
                candidate,
                typed_identities.get("release_app_build"),
            )
        )
        if errors:
            return sorted(set(errors))
        execution = self.expected_execution_receipt(
            source=source,
            inventory=inventory,
            build_payload=captured.build_for_testing_log,
            test_payload=captured.targeted_test_log,
            release_payload=captured.release_build_log,
            lint_payload=captured.lint_log,
            release_candidate_payload=candidate_payload,
            candidate_archive_payload=captured.candidate_archive_payload,
            output_reopen_payload=reopen_payload,
            output_media_payload=captured.output_media_payload,
            identities=typed_identities,
            linted_file_count=lint.linted_file_count,
        )
        execution_payload = _canonical_json(execution)
        acceptance = self.expected_acceptance(
            source=source,
            execution_payload=execution_payload,
            release_candidate_payload=candidate_payload,
            phase_status_before=str(status),
        )
        acceptance_payload = _canonical_json(acceptance)
        try:
            schemas = (
                (
                    self._checkpoint_schema(
                        source,
                        RELEASE_CANDIDATE_SCHEMA_PATH,
                        "R13 release-candidate schema",
                    ),
                    candidate,
                    "R13 release-candidate schema",
                ),
                (
                    self._checkpoint_schema(
                        source,
                        EXECUTION_SCHEMA_PATH,
                        "R13 execution schema",
                    ),
                    execution,
                    "R13 execution schema",
                ),
                (
                    self._checkpoint_schema(
                        source,
                        ACCEPTANCE_SCHEMA_PATH,
                        "R13 acceptance schema",
                    ),
                    acceptance,
                    "R13 acceptance schema",
                ),
            )
        except ValueError as error:
            return [str(error)]
        for schema, value, context in schemas:
            errors.extend(self._schema_errors(schema, value, context))
        if errors:
            return sorted(set(errors))
        payloads = {
            RELEASE_CANDIDATE_RECEIPT_PATH: candidate_payload,
            OUTPUT_REOPEN_RECEIPT_PATH: reopen_payload,
            EXECUTION_RECEIPT_PATH: execution_payload,
            ACCEPTANCE_PATH: acceptance_payload,
            BUILD_FOR_TESTING_LOG_PATH: captured.build_for_testing_log,
            TARGETED_TEST_LOG_PATH: captured.targeted_test_log,
            RELEASE_BUILD_LOG_PATH: captured.release_build_log,
            LINT_LOG_PATH: captured.lint_log,
            OUTPUT_MEDIA_ARTIFACT_PATH: captured.output_media_payload,
            RELEASE_CANDIDATE_ARCHIVE_PATH: (
                captured.candidate_archive_payload
            ),
        }
        errors.extend(self._write_bundle(payloads))
        if errors:
            return sorted(set(errors))
        return self.check_generated()


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        if error.startswith("INCOMPLETE: "):
            print(error)
        else:
            print(f"ERROR: {error}", file=sys.stderr)
    return 1 if any(
        not value.startswith("INCOMPLETE: ") for value in values
    ) else 0


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", metavar="IMPLEMENTATION_COMMIT")
    group.add_argument("--check-generated", action="store_true")
    group.add_argument("--check", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_argument_parser().parse_args(argv)
    verifier = R13PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    if arguments.write is not None:
        errors = verifier.write(arguments.write)
    elif arguments.check_generated:
        errors = verifier.check_generated()
    else:
        errors = verifier.check()
    if errors:
        return emit_errors(errors)
    print("R13 exact-source release-candidate evidence verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
