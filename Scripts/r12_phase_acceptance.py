#!/usr/bin/env python3
"""Derive and deeply validate bounded R12 software-function evidence."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from typing import Any, Iterable, Mapping, Sequence


_MODULE_REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(_MODULE_REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_REPOSITORY_ROOT))

try:
    from phase_evidence import decode_json, validate_json_schema_instance
except ModuleNotFoundError:
    from Scripts.phase_evidence import (
        decode_json,
        validate_json_schema_instance,
    )


REPOSITORY_ROOT = _MODULE_REPOSITORY_ROOT
ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)
PREDECESSOR_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r11/records/functional-phase-acceptance.json"
)
RECORDS_DIRECTORY = Path("docs/roadmaps/evidence/r12/records")
EXECUTION_RECEIPT_PATH = RECORDS_DIRECTORY / "functional-execution-receipt.json"
ACCEPTANCE_PATH = RECORDS_DIRECTORY / "functional-phase-acceptance.json"
ARTIFACT_DIRECTORY = (
    RECORDS_DIRECTORY / "artifacts/functional-phase-acceptance"
)
BUILD_LOG_PATH = ARTIFACT_DIRECTORY / "build-for-testing.log"
TEST_LOG_PATH = ARTIFACT_DIRECTORY / "targeted-xctest.log"
LINT_LOG_PATH = ARTIFACT_DIRECTORY / "swiftlint.log"

FORMAT_SOURCE_PATH = Path(
    "Mirmir/Modules/UpscalerEngine/R12MediaFormatContractV2.swift"
)
ROUTE_SOURCE_PATH = Path(
    "Mirmir/Modules/UpscalerEngine/R12RouteAndHardwareResolver.swift"
)
RESUME_SOURCE_PATH = Path(
    "Mirmir/Modules/MediaPipeline/R12ChunkCheckpointLedger.swift"
)
FORMAT_TEST_PATH = Path("MirmirTests/R12MediaFormatContractV2Tests.swift")
ROUTE_TEST_PATH = Path("MirmirTests/R12RouteAndHardwareResolverTests.swift")
RESUME_TEST_PATH = Path("MirmirTests/R12ChunkCheckpointLedgerTests.swift")
PROJECT_PATH = Path("Mirmir.xcodeproj/project.pbxproj")
VALIDATOR_PATH = Path("Scripts/r12_phase_acceptance.py")
VALIDATOR_TEST_PATH = Path("Scripts/tests/test_r12_phase_acceptance.py")
EXECUTION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/"
    "r12-functional-execution-receipt-v1.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/"
    "r12-functional-phase-acceptance-v1.json"
)


@dataclass(frozen=True)
class SwiftTestSuite:
    class_name: str
    path: Path
    coverage_prefix: str

    @property
    def only_testing(self) -> str:
        return f"MirmirTests/{self.class_name}"


TEST_SUITES = (
    SwiftTestSuite(
        "R12MediaFormatContractV2Tests",
        FORMAT_TEST_PATH,
        "format",
    ),
    SwiftTestSuite(
        "R12RouteAndHardwareResolverTests",
        ROUTE_TEST_PATH,
        "route",
    ),
    SwiftTestSuite(
        "R12ChunkCheckpointLedgerTests",
        RESUME_TEST_PATH,
        "resume",
    ),
)
SOURCE_BINDING_PATHS = (
    ("r12_media_format_contract_v2", FORMAT_SOURCE_PATH),
    ("r12_route_and_hardware_resolver", ROUTE_SOURCE_PATH),
    ("r12_chunk_checkpoint_ledger", RESUME_SOURCE_PATH),
    ("r12_media_format_contract_v2_tests", FORMAT_TEST_PATH),
    ("r12_route_and_hardware_resolver_tests", ROUTE_TEST_PATH),
    ("r12_chunk_checkpoint_ledger_tests", RESUME_TEST_PATH),
    ("xcode_project", PROJECT_PATH),
    ("r12_phase_acceptance_validator", VALIDATOR_PATH),
    ("r12_phase_acceptance_validator_tests", VALIDATOR_TEST_PATH),
    ("r12_functional_execution_receipt_schema", EXECUTION_SCHEMA_PATH),
    ("r12_functional_phase_acceptance_schema", ACCEPTANCE_SCHEMA_PATH),
)

DERIVED_CHECK_IDS = (
    "source_checkpoint_commit_tree_and_ancestry_exact",
    "current_r12_source_bytes_exact",
    "xcode_project_checkpoint_binding_exact",
    "swift_test_inventory_derived_from_checkpoint",
    "build_for_testing_succeeded",
    "targeted_xctest_individual_cases_passed",
    "swiftlint_strict_zero_violations",
    "format_contracts_covered",
    "route_contracts_covered",
    "backend_contracts_covered",
    "resume_contracts_covered",
    "native_hardware_simulator_operator_observation_nonblocking",
    "comparison_and_ab_methods_absent_not_required",
    "product_auto_market_release_authority_not_granted",
    "artifact_closure_hashes_and_generation_seals_exact",
)
CLAIM_BOUNDARY = {
    "claim_scope": "software_behavior_report",
    "product_qualification": "not_authorized",
    "production_auto_mode": "not_authorized",
    "market_disposition": "no_market_claim",
    "release_publication": "not_authorized",
}
COMPARISON_POLICY = {
    "comparison_method": "absent_not_required",
    "ab_test": "absent_not_required",
    "acceptance_dependency": "none",
}
OBSERVATION_BOUNDARY = {
    "native_hardware": "not_observed",
    "simulator": "not_observed",
    "operator": "not_observed",
    "nonblocking_for_software_function_acceptance": True,
}
EXECUTION_LIMITATIONS = (
    "R12 evidence proves only the checkpointed format, route, backend, and "
    "resume software contracts exercised by the targeted XCTest inventory.",
    "Native hardware, simulator, and operator-observed execution were not "
    "observed and are nonblocking for this software-function acceptance.",
    "No comparative, A/B, superiority, or historical product-comparison "
    "method was run or required.",
    "Product qualification, production Auto, market claims, release "
    "publication, and product publication are not authorized by R12.",
    "Artifact logs are generated mode 0400; Git may materialize committed "
    "artifacts mode 0644, while exact bytes, hashes, no-follow reads, and "
    "single-link identities remain required.",
)
ACCEPTANCE_LIMITATIONS = (
    "R12 acceptance is limited to exact-source proof that the declared "
    "format, route, backend, and resumability software functions pass.",
    "Native hardware, simulator, and operator observations are recorded as "
    "not_observed and are not acceptance dependencies.",
    "No comparison or A/B result contributes to acceptance.",
    "R12 grants no product qualification, production Auto, market, product "
    "publication, or release-publication authority.",
)

BUILD_COMMAND = (
    "xcodebuild build-for-testing -project Mirmir.xcodeproj -scheme Mirmir "
    "-configuration Debug -destination platform=macOS,arch=arm64 "
    "-derivedDataPath <outside-repository> "
    "R12_ACCEPTANCE_SOURCE_COMMIT=<source.commit> "
    "R12_ACCEPTANCE_SOURCE_TREE=<source.tree>"
)
TEST_COMMAND = (
    "xcodebuild test-without-building -xctestrun <checkpoint-build.xctestrun> "
    "-destination platform=macOS,arch=arm64 "
    "-only-testing:MirmirTests/R12MediaFormatContractV2Tests "
    "-only-testing:MirmirTests/R12RouteAndHardwareResolverTests "
    "-only-testing:MirmirTests/R12ChunkCheckpointLedgerTests "
    "R12_ACCEPTANCE_SOURCE_COMMIT=<source.commit> "
    "R12_ACCEPTANCE_SOURCE_TREE=<source.tree>"
)
LINT_COMMAND = "swiftlint lint --strict --no-cache"

_GIT_OID_PATTERN = re.compile(r"^(?!0{40}$)[0-9a-f]{40}$")
_SWIFT_TEST_METHOD_PATTERN = re.compile(
    r"(?m)^[ \t]{4}func (test[A-Za-z0-9_]+)"
    r"\s*\([^)]*\)(?:\s+(?:async|throws))*\s*\{"
)
_XCTEST_CASE_PATTERN = re.compile(
    r"^Test Case '-\[MirmirTests\.([A-Za-z0-9_]+) "
    r"(test[A-Za-z0-9_]+)\]' (started|passed|failed|skipped)"
    r"(?: \(([0-9]+(?:\.[0-9]+)?) seconds\))?\.$"
)
_XCTEST_SUMMARY_PATTERN = re.compile(
    r"^[ \t]*Executed ([0-9]+) tests?, with ([0-9]+) failures "
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
_MAX_JSON_BYTES = 16 * 1024 * 1024
_MAX_SOURCE_BYTES = 16 * 1024 * 1024
_MAX_BUILD_LOG_BYTES = 64 * 1024 * 1024
_MAX_TEST_LOG_BYTES = 32 * 1024 * 1024
_MAX_LINT_LOG_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class TestInventory:
    methods_by_suite: tuple[tuple[str, tuple[str, ...]], ...]

    @property
    def identifiers(self) -> tuple[str, ...]:
        return tuple(
            f"MirmirTests.{suite}.{method}"
            for suite, methods in self.methods_by_suite
            for method in methods
        )

    @property
    def suite_counts(self) -> tuple[tuple[str, int], ...]:
        return tuple(
            (suite, len(methods))
            for suite, methods in self.methods_by_suite
        )


@dataclass(frozen=True)
class ParsedBuild:
    log_payload: bytes


@dataclass(frozen=True)
class ParsedTests:
    log_payload: bytes
    identifiers: tuple[str, ...]


@dataclass(frozen=True)
class ParsedLint:
    log_payload: bytes
    linted_file_count: int


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _safe_relative_path(value: object, context: str) -> str:
    if type(value) is not str or not value or "\x00" in value:
        raise ValueError(f"{context} must be one relative repository path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(
        part in {"", ".", ".."} for part in path.parts
    ):
        raise ValueError(f"{context} escapes the repository boundary")
    if path.as_posix() != value:
        raise ValueError(f"{context} is not canonical")
    return value


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


def _snake_case(value: str) -> str:
    without_prefix = value[4:] if value.startswith("test") else value
    step_one = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", without_prefix)
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", step_one).lower()


class R12PhaseAcceptanceVerifier:
    def __init__(
        self,
        root: Path,
        *,
        source_binding_paths: Sequence[tuple[str, Path]] = (
            SOURCE_BINDING_PATHS
        ),
        test_suites: Sequence[SwiftTestSuite] = TEST_SUITES,
    ) -> None:
        self.root = root.resolve()
        self.source_binding_paths = tuple(source_binding_paths)
        self.test_suites = tuple(test_suites)
        self._source_cache: dict[str, dict[str, str]] = {}
        self._checkpoint_cache: dict[tuple[str, Path], bytes] = {}

    def _git(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        executable = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"
        return subprocess.run(
            [executable, "-C", os.fspath(self.root), "--no-pager", *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def _git_text(self, *arguments: str, context: str) -> str:
        result = self._git(*arguments)
        if result.returncode != 0:
            raise ValueError(f"R12 {context} Git query failed")
        try:
            value = result.stdout.decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise ValueError(f"R12 {context} is not ASCII") from error
        if result.stdout != f"{value}\n".encode("ascii"):
            raise ValueError(f"R12 {context} Git output is not canonical")
        return value

    def resolve_source(self, revision: str) -> dict[str, str]:
        if (
            type(revision) is not str
            or _GIT_OID_PATTERN.fullmatch(revision) is None
        ):
            raise ValueError(
                "R12 implementation commit must be one exact nonzero "
                "lowercase 40-character Git object ID"
            )
        cached = self._source_cache.get(revision)
        if cached is not None:
            return dict(cached)
        commit = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{revision}^{{commit}}",
            context="implementation commit",
        )
        tree = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{commit}^{{tree}}",
            context="implementation tree",
        )
        if (
            commit != revision
            or _GIT_OID_PATTERN.fullmatch(tree) is None
        ):
            raise ValueError("R12 implementation commit or tree differs")
        ancestry = self._git("merge-base", "--is-ancestor", commit, "HEAD")
        if ancestry.returncode != 0:
            raise ValueError(
                "R12 implementation commit is not an ancestor of HEAD"
            )
        source = {"commit": commit, "tree": tree}
        self._source_cache[revision] = source
        return dict(source)

    def _source_errors(self, value: object) -> list[str]:
        if (
            type(value) is not dict
            or tuple(value) != ("commit", "tree")
            or _GIT_OID_PATTERN.fullmatch(str(value.get("commit", ""))) is None
            or _GIT_OID_PATTERN.fullmatch(str(value.get("tree", ""))) is None
        ):
            return ["R12 source commit/tree shape is invalid"]
        try:
            expected = self.resolve_source(str(value["commit"]))
        except ValueError as error:
            return [str(error)]
        if expected != value:
            return ["R12 source commit/tree binding differs"]
        return []

    def _checkpoint_bytes(
        self,
        source: Mapping[str, str],
        relative: Path,
    ) -> bytes:
        cache_key = (source["commit"], relative)
        cached = self._checkpoint_cache.get(cache_key)
        if cached is not None:
            return cached
        path = _safe_relative_path(
            relative.as_posix(), "R12 checkpoint path"
        )
        expression = f"{source['commit']}:{path}"
        object_id = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            expression,
            context=f"checkpoint blob {path}",
        )
        object_type = self._git("cat-file", "-t", object_id)
        if object_type.returncode != 0 or object_type.stdout != b"blob\n":
            raise ValueError(f"R12 checkpoint path is not a blob: {path}")
        size_text = self._git_text(
            "cat-file",
            "-s",
            object_id,
            context=f"checkpoint blob size {path}",
        )
        if (
            not size_text.isdecimal()
            or (len(size_text) > 1 and size_text.startswith("0"))
        ):
            raise ValueError(f"R12 checkpoint blob size is invalid: {path}")
        size = int(size_text)
        if size < 1 or size > _MAX_SOURCE_BYTES:
            raise ValueError(
                f"R12 checkpoint blob size is outside the boundary: {path}"
            )
        result = self._git(
            "show",
            "--no-ext-diff",
            "--no-textconv",
            "--format=",
            expression,
        )
        if result.returncode != 0 or len(result.stdout) != size:
            raise ValueError(
                f"R12 checkpoint blob cannot be read exactly: {path}"
            )
        self._checkpoint_cache[cache_key] = result.stdout
        return result.stdout

    @staticmethod
    def _stat_identity(value: os.stat_result) -> tuple[int, ...]:
        return (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )

    @staticmethod
    def _directory_flags() -> int:
        return (
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0)
        )

    @classmethod
    def _open_directory_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
    ) -> int:
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise ValueError(f"{context} directory component is unsafe")
        descriptor = -1
        try:
            before = os.stat(
                name, dir_fd=parent_descriptor, follow_symlinks=False
            )
            descriptor = os.open(
                name, cls._directory_flags(), dir_fd=parent_descriptor
            )
            opened = os.fstat(descriptor)
            after = os.stat(
                name, dir_fd=parent_descriptor, follow_symlinks=False
            )
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise ValueError(
                f"{context} directory ancestor is unavailable or unsafe"
            ) from error
        if (
            not stat.S_ISDIR(before.st_mode)
            or cls._stat_identity(before) != cls._stat_identity(opened)
            or cls._stat_identity(opened) != cls._stat_identity(after)
        ):
            os.close(descriptor)
            raise ValueError(f"{context} directory ancestor identity differs")
        return descriptor

    def _open_repository_directory(
        self,
        relative: Path,
        *,
        context: str,
    ) -> int:
        value = _safe_relative_path(relative.as_posix(), f"{context} path")
        descriptor = -1
        try:
            before = os.lstat(self.root)
            descriptor = os.open(self.root, self._directory_flags())
            opened = os.fstat(descriptor)
            after = os.lstat(self.root)
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise ValueError(
                f"{context} repository root is unavailable or unsafe"
            ) from error
        if (
            not stat.S_ISDIR(before.st_mode)
            or self._stat_identity(before) != self._stat_identity(opened)
            or self._stat_identity(opened) != self._stat_identity(after)
        ):
            os.close(descriptor)
            raise ValueError(f"{context} repository root identity differs")
        try:
            for part in PurePosixPath(value).parts:
                child = self._open_directory_at(
                    descriptor, part, context=context
                )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def _open_repository_parent(
        self,
        relative: Path,
        *,
        context: str,
    ) -> tuple[int, str]:
        value = _safe_relative_path(relative.as_posix(), f"{context} path")
        parts = PurePosixPath(value).parts
        return (
            self._open_repository_directory(
                Path(*parts[:-1]), context=context
            ),
            parts[-1],
        )

    @classmethod
    def _read_regular_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
        maximum: int,
        require_sealed: bool = False,
        allow_git_materialized: bool = False,
    ) -> bytes:
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise ValueError(f"{context} file name is unsafe")
        descriptor = -1
        try:
            before = os.stat(
                name, dir_fd=parent_descriptor, follow_symlinks=False
            )
        except OSError as error:
            raise ValueError(f"{context} cannot be inspected") from error
        accepted_modes = (
            {0o400, 0o444, 0o644}
            if allow_git_materialized
            else {0o400}
        )
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > maximum
            or (
                require_sealed
                and stat.S_IMODE(before.st_mode) not in accepted_modes
            )
        ):
            raise ValueError(f"{context} file identity, size, or mode differs")
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=parent_descriptor,
            )
            identity = cls._stat_identity(before)
            if cls._stat_identity(os.fstat(descriptor)) != identity:
                raise ValueError(f"{context} changed while being opened")
            chunks: list[bytes] = []
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError(f"{context} is truncated")
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise ValueError(f"{context} grew beyond its declared size")
            after = os.stat(
                name, dir_fd=parent_descriptor, follow_symlinks=False
            )
            if (
                cls._stat_identity(os.fstat(descriptor)) != identity
                or cls._stat_identity(after) != identity
            ):
                raise ValueError(f"{context} changed while being read")
            return b"".join(chunks)
        except OSError as error:
            raise ValueError(f"{context} cannot be read safely") from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _read_repository_file(
        self,
        relative: Path,
        *,
        context: str,
        maximum: int,
        require_sealed: bool = False,
        allow_git_materialized: bool = False,
    ) -> bytes:
        parent_descriptor = -1
        try:
            parent_descriptor, name = self._open_repository_parent(
                relative, context=context
            )
            return self._read_regular_at(
                parent_descriptor,
                name,
                context=context,
                maximum=maximum,
                require_sealed=require_sealed,
                allow_git_materialized=allow_git_materialized,
            )
        finally:
            if parent_descriptor >= 0:
                os.close(parent_descriptor)

    def _read_input_file(
        self,
        path: Path,
        *,
        context: str,
        maximum: int,
    ) -> bytes:
        absolute = path if path.is_absolute() else Path.cwd() / path
        absolute = Path(os.path.abspath(os.fspath(absolute)))
        parts = absolute.parent.parts
        if not parts or parts[0] != os.sep:
            raise ValueError(f"{context} absolute path is invalid")
        descriptor = os.open(os.sep, self._directory_flags())
        try:
            for part in parts[1:]:
                child = self._open_directory_at(
                    descriptor, part, context=context
                )
                os.close(descriptor)
                descriptor = child
            return self._read_regular_at(
                descriptor,
                absolute.name,
                context=context,
                maximum=maximum,
            )
        finally:
            os.close(descriptor)

    def _checkpoint_json(
        self,
        source: Mapping[str, str],
        relative: Path,
        context: str,
    ) -> dict[str, Any]:
        return _decode_object(self._checkpoint_bytes(source, relative), context)

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

    @staticmethod
    def _swift_test_methods(
        payload: bytes,
        suite: SwiftTestSuite,
    ) -> tuple[tuple[str, ...], list[str]]:
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return (), [
                f"R12 Swift test source is not UTF-8: {suite.path.as_posix()}"
            ]
        declaration = re.compile(
            rf"(?m)^final class {re.escape(suite.class_name)}: XCTestCase \{{"
        )
        if len(declaration.findall(text)) != 1:
            return (), [
                f"R12 Swift test class differs: {suite.class_name}"
            ]
        methods = tuple(_SWIFT_TEST_METHOD_PATTERN.findall(text))
        errors: list[str] = []
        if not methods:
            errors.append(f"R12 Swift test suite is empty: {suite.class_name}")
        if len(methods) != len(set(methods)):
            errors.append(
                f"R12 Swift test methods repeat: {suite.class_name}"
            )
        return methods, errors

    def _checkpoint_test_inventory(
        self,
        source: Mapping[str, str],
    ) -> tuple[TestInventory | None, list[str]]:
        values: list[tuple[str, tuple[str, ...]]] = []
        errors: list[str] = []
        seen_classes: set[str] = set()
        seen_paths: set[Path] = set()
        for suite in self.test_suites:
            if suite.class_name in seen_classes or suite.path in seen_paths:
                errors.append("R12 Swift test suite inventory repeats")
                continue
            seen_classes.add(suite.class_name)
            seen_paths.add(suite.path)
            try:
                payload = self._checkpoint_bytes(source, suite.path)
            except ValueError as error:
                errors.append(str(error))
                continue
            methods, method_errors = self._swift_test_methods(payload, suite)
            errors.extend(method_errors)
            values.append((suite.class_name, methods))
        if len(values) != len(self.test_suites):
            errors.append("R12 Swift test suite count differs")
        inventory = TestInventory(tuple(values)) if not errors else None
        if inventory is not None:
            identifiers = inventory.identifiers
            if len(identifiers) != len(set(identifiers)):
                errors.append("R12 Swift test identifiers repeat")
            if len(identifiers) < len(self.test_suites):
                errors.append("R12 Swift test inventory is incomplete")
        return (inventory if not errors else None), sorted(set(errors))

    @staticmethod
    def _coverage_areas(suite: str, method: str) -> tuple[str, ...]:
        if suite == "R12MediaFormatContractV2Tests":
            return (
                ("format", "backend")
                if "Backend" in method
                else ("format",)
            )
        if suite == "R12RouteAndHardwareResolverTests":
            return (
                ("route", "backend")
                if "Backend" in method
                else ("route",)
            )
        if suite == "R12ChunkCheckpointLedgerTests":
            return ("resume",)
        raise ValueError(f"R12 coverage suite is unknown: {suite}")

    def contract_coverage(
        self,
        inventory: TestInventory,
    ) -> list[dict[str, object]]:
        coverage: list[dict[str, object]] = []
        prefixes = {
            suite.class_name: suite.coverage_prefix
            for suite in self.test_suites
        }
        for suite, methods in inventory.methods_by_suite:
            prefix = prefixes[suite]
            for method in methods:
                coverage.append(
                    {
                        "contract_id": f"{prefix}.{_snake_case(method)}",
                        "contract_areas": list(
                            self._coverage_areas(suite, method)
                        ),
                        "test_identifier": (
                            f"MirmirTests.{suite}.{method}"
                        ),
                        "status": "passed",
                    }
                )
        if len(coverage) != len(inventory.identifiers):
            raise ValueError("R12 contract coverage is not one-to-one")
        if {item["test_identifier"] for item in coverage} != set(
            inventory.identifiers
        ):
            raise ValueError("R12 contract coverage test closure differs")
        observed_areas = {
            area
            for item in coverage
            for area in item["contract_areas"]
        }
        if observed_areas != {"format", "route", "backend", "resume"}:
            raise ValueError("R12 contract coverage areas differ")
        return coverage

    def _binding(
        self,
        source: Mapping[str, str],
        identifier: str,
        relative: Path,
    ) -> dict[str, object]:
        payload = self._checkpoint_bytes(source, relative)
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    @staticmethod
    def _payload_binding(
        path: Path,
        payload: bytes,
        *,
        identifier: str | None = None,
    ) -> dict[str, object]:
        value: dict[str, object] = {}
        if identifier is not None:
            value["id"] = identifier
        value.update(
            {
                "path": path.as_posix(),
                "size_bytes": len(payload),
                "sha256": _sha256(payload),
            }
        )
        return value

    def source_bindings(
        self,
        source: Mapping[str, str],
    ) -> list[dict[str, object]]:
        return [
            self._binding(source, identifier, relative)
            for identifier, relative in self.source_binding_paths
        ]

    def predecessor_binding(
        self,
        source: Mapping[str, str],
    ) -> dict[str, object]:
        payload = self._checkpoint_bytes(source, PREDECESSOR_ACCEPTANCE_PATH)
        record = _decode_object(payload, "R11 predecessor acceptance")
        predecessor_source = record.get("source")
        gate = record.get("functional_gate")
        if (
            type(predecessor_source) is not dict
            or tuple(predecessor_source) != ("commit", "tree")
            or _GIT_OID_PATTERN.fullmatch(
                str(predecessor_source.get("commit", ""))
            )
            is None
            or _GIT_OID_PATTERN.fullmatch(
                str(predecessor_source.get("tree", ""))
            )
            is None
            or type(gate) is not dict
            or gate.get("status") != "passed"
            or gate.get("acceptance_scope")
            != "declared_software_function_only"
        ):
            raise ValueError("R12 R11 predecessor acceptance differs")
        resolved_commit = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{predecessor_source['commit']}^{{commit}}",
            context="R11 predecessor commit",
        )
        resolved_tree = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{resolved_commit}^{{tree}}",
            context="R11 predecessor tree",
        )
        if (
            resolved_commit != predecessor_source["commit"]
            or resolved_tree != predecessor_source["tree"]
            or self._git(
                "merge-base",
                "--is-ancestor",
                resolved_commit,
                source["commit"],
            ).returncode
            != 0
        ):
            raise ValueError(
                "R12 R11 predecessor source identity or ancestry differs"
            )
        return {
            "phase_id": "R11",
            "phase_result": "passed",
            "acceptance_scope": "declared_software_function_only",
            "accepted_source": dict(predecessor_source),
            "functional_phase_acceptance": self._payload_binding(
                PREDECESSOR_ACCEPTANCE_PATH, payload
            ),
        }

    @staticmethod
    def _decode_log(
        payload: bytes,
        *,
        context: str,
        maximum: int,
    ) -> tuple[str | None, list[str]]:
        if (
            type(payload) is not bytes
            or not payload
            or len(payload) > maximum
            or b"\x00" in payload
            or b"\r" in payload
        ):
            return None, [f"{context} bytes are outside the closed boundary"]
        try:
            return payload.decode("utf-8"), []
        except UnicodeDecodeError:
            return None, [f"{context} is not UTF-8"]

    @classmethod
    def _build_log_errors(
        cls,
        payload: bytes,
        source: Mapping[str, str],
    ) -> list[str]:
        text, errors = cls._decode_log(
            payload,
            context="R12 build-for-testing log",
            maximum=_MAX_BUILD_LOG_BYTES,
        )
        if text is None:
            return errors
        lines = text.splitlines()
        invocation_needles = (
            "xcodebuild build-for-testing",
            "-project Mirmir.xcodeproj",
            "-scheme Mirmir",
            "-configuration Debug",
            "-destination platform=macOS,arch=arm64",
            f"R12_ACCEPTANCE_SOURCE_COMMIT={source['commit']}",
            f"R12_ACCEPTANCE_SOURCE_TREE={source['tree']}",
        )
        joined = " ".join(lines[:20])
        if not all(value in joined for value in invocation_needles):
            errors.append(
                "R12 build-for-testing invocation or source binding differs"
            )
        nonempty = [line.strip() for line in lines if line.strip()]
        if (
            nonempty.count("** TEST BUILD SUCCEEDED **") != 1
            or not nonempty
            or nonempty[-1] != "** TEST BUILD SUCCEEDED **"
        ):
            errors.append(
                "R12 build-for-testing log lacks one final success marker"
            )
        if any(
            "TEST BUILD FAILED" in line
            or re.search(r"(^|\s)(?:fatal )?error:", line, re.IGNORECASE)
            for line in lines
        ):
            errors.append("R12 build-for-testing log contains a build error")
        return sorted(set(errors))

    @classmethod
    def _test_log_errors(
        cls,
        payload: bytes,
        source: Mapping[str, str],
        inventory: TestInventory,
        suites: Sequence[SwiftTestSuite] = TEST_SUITES,
    ) -> list[str]:
        text, errors = cls._decode_log(
            payload,
            context="R12 targeted XCTest log",
            maximum=_MAX_TEST_LOG_BYTES,
        )
        if text is None:
            return errors
        lines = text.splitlines()
        markers = [
            index
            for index, line in enumerate(lines)
            if line.strip() == "** TEST EXECUTE SUCCEEDED **"
        ]
        if len(markers) != 1:
            errors.append(
                "R12 targeted XCTest log lacks one execute-success marker"
            )
            prefix = lines
        else:
            prefix = lines[: markers[0]]
        joined = " ".join(lines[:30])
        invocation_needles = (
            "xcodebuild test-without-building",
            "-destination platform=macOS,arch=arm64",
            f"R12_ACCEPTANCE_SOURCE_COMMIT={source['commit']}",
            f"R12_ACCEPTANCE_SOURCE_TREE={source['tree']}",
        )
        if not all(value in joined for value in invocation_needles):
            errors.append(
                "R12 targeted XCTest invocation or source binding differs"
            )
        only_testing = set(
            re.findall(
                r"-only-testing:MirmirTests/([A-Za-z0-9_]+)",
                joined,
            )
        )
        expected_suites = {suite.class_name for suite in suites}
        if only_testing != expected_suites:
            errors.append("R12 targeted XCTest suite selection differs")

        started: list[str] = []
        passed: list[str] = []
        forbidden_statuses: list[str] = []
        summaries: list[tuple[int, int, int, int]] = []
        for line in prefix:
            result = _XCTEST_CASE_PATTERN.fullmatch(line.strip())
            if result is not None:
                suite, method, status_value, _seconds = result.groups()
                identifier = f"MirmirTests.{suite}.{method}"
                if status_value == "started":
                    started.append(identifier)
                elif status_value == "passed":
                    passed.append(identifier)
                else:
                    forbidden_statuses.append(status_value)
            summary = _XCTEST_SUMMARY_PATTERN.fullmatch(line)
            if summary is not None:
                count, failures, unexpected, skipped = summary.groups()
                summaries.append(
                    (
                        int(count),
                        int(failures),
                        int(unexpected),
                        int(skipped or "0"),
                    )
                )
        expected = set(inventory.identifiers)
        if (
            set(started) != expected
            or set(passed) != expected
            or len(started) != len(expected)
            or len(passed) != len(expected)
        ):
            errors.append(
                "R12 targeted XCTest individual test inventory differs"
            )
        if forbidden_statuses or any(
            "TEST EXECUTE FAILED" in line
            or re.search(
                r"Test Case .+ (?:failed|skipped)(?: |\.)",
                line,
                re.IGNORECASE,
            )
            for line in lines
        ):
            errors.append(
                "R12 targeted XCTest log contains failure or skip"
            )
        expected_count = len(inventory.identifiers)
        if (
            not summaries
            or summaries[-1] != (expected_count, 0, 0, 0)
        ):
            errors.append(
                "R12 targeted XCTest final zero-failure count differs"
            )
        return sorted(set(errors))

    @classmethod
    def _lint_log(
        cls,
        payload: bytes,
    ) -> tuple[ParsedLint | None, list[str]]:
        text, errors = cls._decode_log(
            payload,
            context="R12 SwiftLint log",
            maximum=_MAX_LINT_LOG_BYTES,
        )
        if text is None:
            return None, errors
        lines = [line for line in text.splitlines() if line]
        if (
            not lines
            or lines[0]
            not in {
                "Linting Swift files in current working directory",
                "Linting Swift files at paths .",
            }
        ):
            errors.append("R12 SwiftLint invocation scope differs")
        file_records = [
            tuple(int(value) for value in result.groups())
            for line in lines
            if (result := _SWIFTLINT_FILE_PATTERN.fullmatch(line)) is not None
        ]
        summaries = [
            tuple(int(value) for value in result.groups())
            for line in lines
            if (result := _SWIFTLINT_SUMMARY_PATTERN.fullmatch(line)) is not None
        ]
        if (
            len(summaries) != 1
            or summaries[0][0:2] != (0, 0)
            or lines[-1]
            != (
                f"Done linting! Found 0 violations, 0 serious in "
                f"{summaries[0][2] if summaries else 0} files."
            )
        ):
            errors.append(
                "R12 SwiftLint log lacks one final zero-violation summary"
            )
        linted_count = summaries[0][2] if summaries else 0
        if (
            linted_count < 1
            or len(file_records) != linted_count
            or file_records
            != [(index, linted_count) for index in range(1, linted_count + 1)]
        ):
            errors.append("R12 SwiftLint per-file inventory differs")
        if any(
            re.search(r": (?:warning|error):", line) is not None
            for line in lines
        ):
            errors.append("R12 SwiftLint log contains a violation")
        if errors:
            return None, sorted(set(errors))
        return ParsedLint(payload, linted_count), []

    def _current_source_errors(
        self,
        source: Mapping[str, str],
        *,
        allow_project_evolution: bool,
    ) -> list[str]:
        errors: list[str] = []
        seen_ids: set[str] = set()
        seen_paths: set[Path] = set()
        for identifier, relative in self.source_binding_paths:
            if identifier in seen_ids or relative in seen_paths:
                errors.append("R12 source binding inventory repeats")
                continue
            seen_ids.add(identifier)
            seen_paths.add(relative)
            if allow_project_evolution and relative == PROJECT_PATH:
                continue
            try:
                checkpoint = self._checkpoint_bytes(source, relative)
                current = self._read_repository_file(
                    relative,
                    context=f"R12 current source {relative.as_posix()}",
                    maximum=_MAX_SOURCE_BYTES,
                )
            except ValueError as error:
                errors.append(str(error))
                continue
            if current != checkpoint:
                errors.append(
                    "R12 current source differs from implementation commit: "
                    f"{relative.as_posix()}"
                )
        try:
            predecessor_checkpoint = self._checkpoint_bytes(
                source, PREDECESSOR_ACCEPTANCE_PATH
            )
            predecessor_current = self._read_repository_file(
                PREDECESSOR_ACCEPTANCE_PATH,
                context="R12 current R11 predecessor acceptance",
                maximum=_MAX_JSON_BYTES,
            )
            if predecessor_current != predecessor_checkpoint:
                errors.append(
                    "R12 current R11 predecessor acceptance differs from "
                    "implementation commit"
                )
        except ValueError as error:
            errors.append(str(error))
        return sorted(set(errors))

    def _base_errors(
        self,
        source: Mapping[str, str],
        *,
        require_current_source: bool,
        allow_project_evolution: bool = False,
    ) -> list[str]:
        errors = self._source_errors(dict(source))
        if errors:
            return errors
        for _identifier, relative in self.source_binding_paths:
            try:
                self._checkpoint_bytes(source, relative)
            except ValueError as error:
                errors.append(str(error))
        try:
            self.predecessor_binding(source)
        except ValueError as error:
            errors.append(str(error))
        _inventory, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        if require_current_source:
            errors.extend(
                self._current_source_errors(
                    source,
                    allow_project_evolution=allow_project_evolution,
                )
            )
        return sorted(set(errors))

    def expected_execution_receipt(
        self,
        *,
        source: Mapping[str, str],
        inventory: TestInventory,
        build: ParsedBuild,
        tests: ParsedTests,
        lint: ParsedLint,
    ) -> dict[str, object]:
        coverage = self.contract_coverage(inventory)
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R12",
            "evidence_kind": (
                "r12_exact_source_software_function_execution_receipt_v1"
            ),
            "source": dict(source),
            "predecessor_binding": self.predecessor_binding(source),
            "source_bindings": self.source_bindings(source),
            "artifact_bindings": [
                self._payload_binding(
                    BUILD_LOG_PATH,
                    build.log_payload,
                    identifier="build_for_testing_log",
                ),
                self._payload_binding(
                    TEST_LOG_PATH,
                    tests.log_payload,
                    identifier="targeted_xctest_log",
                ),
                self._payload_binding(
                    LINT_LOG_PATH,
                    lint.log_payload,
                    identifier="swiftlint_log",
                ),
            ],
            "commands": {
                "build_for_testing": BUILD_COMMAND,
                "targeted_tests": TEST_COMMAND,
                "swiftlint": LINT_COMMAND,
            },
            "verification": {
                "build_for_testing": {"status": "passed"},
                "targeted_tests": {
                    "selected_test_count": len(inventory.identifiers),
                    "passed_test_count": len(inventory.identifiers),
                    "failed_test_count": 0,
                    "skipped_test_count": 0,
                    "suite_counts": [
                        {"suite": suite, "passed_test_count": count}
                        for suite, count in inventory.suite_counts
                    ],
                },
                "swiftlint": {
                    "status": "passed",
                    "violation_count": 0,
                    "serious_violation_count": 0,
                    "linted_file_count": lint.linted_file_count,
                },
            },
            "contract_coverage": coverage,
            "acceptance_basis": "software_does_what_it_says_it_does",
            "observations": dict(OBSERVATION_BOUNDARY),
            "claim_boundary": dict(CLAIM_BOUNDARY),
            "comparison_policy": dict(COMPARISON_POLICY),
            "limitations": list(EXECUTION_LIMITATIONS),
        }

    def expected_acceptance(
        self,
        *,
        source: Mapping[str, str],
        execution_payload: bytes,
        phase_status_before: str,
    ) -> dict[str, object]:
        if phase_status_before not in {"in_progress", "evidence_ready"}:
            raise ValueError(
                "R12 phase status before acceptance must be in_progress or "
                "evidence_ready"
            )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R12",
            "evidence_kind": (
                "r12_operator_software_function_phase_acceptance_v1"
            ),
            "source": dict(source),
            "execution_receipt_binding": self._payload_binding(
                EXECUTION_RECEIPT_PATH, execution_payload
            ),
            "checks": [
                {"id": identifier, "status": "passed"}
                for identifier in DERIVED_CHECK_IDS
            ],
            "functional_gate": {
                "status": "passed",
                "acceptance_basis": "software_does_what_it_says_it_does",
                "acceptance_scope": "declared_software_function_only",
                "phase_status_before": phase_status_before,
                "phase_status_after": "passed",
            },
            "observations": dict(OBSERVATION_BOUNDARY),
            "claim_boundary": dict(CLAIM_BOUNDARY),
            "comparison_policy": dict(COMPARISON_POLICY),
            "limitations": list(ACCEPTANCE_LIMITATIONS),
        }

    @staticmethod
    def _json_payload(value: Mapping[str, object]) -> bytes:
        return (
            json.dumps(
                value,
                indent=2,
                ensure_ascii=False,
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")

    def _roadmap_phase_status(self) -> str | None:
        try:
            roadmap = _decode_object(
                self._read_repository_file(
                    ROADMAP_PATH,
                    context="canonical roadmap",
                    maximum=_MAX_JSON_BYTES,
                ),
                "canonical roadmap",
            )
        except ValueError:
            return None
        phases = roadmap.get("phases")
        if type(phases) is not list:
            return None
        selected = [
            item
            for item in phases
            if type(item) is dict and item.get("id") == "R12"
        ]
        if len(selected) != 1:
            return None
        status = selected[0].get("status")
        return status if type(status) is str else None

    def _entry_state(
        self,
        relative: Path,
        *,
        expected_directory: bool,
        context: str,
    ) -> str:
        absolute = self.root / relative
        try:
            value = os.lstat(absolute)
        except FileNotFoundError:
            return "absent"
        except OSError as error:
            raise ValueError(f"{context} cannot be inspected") from error
        if expected_directory:
            if not stat.S_ISDIR(value.st_mode):
                raise ValueError(f"{context} is not a safe directory")
            descriptor = self._open_repository_directory(
                relative, context=context
            )
            os.close(descriptor)
        elif not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
            raise ValueError(
                f"{context} must be one regular no-follow single-link file"
            )
        return "present"

    @classmethod
    def _ensure_directory_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
    ) -> tuple[int, bool]:
        created = False
        try:
            os.mkdir(name, 0o755, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
            created = True
        except FileExistsError:
            pass
        except OSError as error:
            raise ValueError(f"{context} directory cannot be created") from error
        return (
            cls._open_directory_at(
                parent_descriptor, name, context=context
            ),
            created,
        )

    @classmethod
    def _publish_payload_at(
        cls,
        parent_descriptor: int,
        name: str,
        payload: bytes,
        *,
        mode: int,
        context: str,
    ) -> None:
        if (
            not name
            or name in {".", ".."}
            or "/" in name
            or "\x00" in name
            or not payload
        ):
            raise ValueError(f"{context} publication input is unsafe")
        descriptor = -1
        created = False
        try:
            descriptor = os.open(
                name,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
                mode,
                dir_fd=parent_descriptor,
            )
            created = True
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise ValueError(f"{context} write made no progress")
                offset += written
            os.fchmod(descriptor, mode)
            os.fsync(descriptor)
            value = os.fstat(descriptor)
            if (
                not stat.S_ISREG(value.st_mode)
                or value.st_nlink != 1
                or value.st_size != len(payload)
                or stat.S_IMODE(value.st_mode) != mode
            ):
                raise ValueError(f"{context} did not publish exactly")
            os.close(descriptor)
            descriptor = -1
            reopened = cls._read_regular_at(
                parent_descriptor,
                name,
                context=context,
                maximum=len(payload),
                require_sealed=mode == 0o400,
            )
            if reopened != payload:
                raise ValueError(f"{context} bytes differ after publication")
            os.fsync(parent_descriptor)
        except (OSError, ValueError) as error:
            if descriptor >= 0:
                os.close(descriptor)
            if created:
                try:
                    os.unlink(name, dir_fd=parent_descriptor)
                except OSError:
                    pass
            if isinstance(error, ValueError):
                raise
            raise ValueError(f"{context} publication failed") from error

    def _write_bundle(
        self,
        *,
        build_payload: bytes,
        test_payload: bytes,
        lint_payload: bytes,
        execution_payload: bytes,
        acceptance_payload: bytes,
    ) -> list[str]:
        evidence_descriptor = -1
        r12_descriptor = -1
        records_descriptor = -1
        artifacts_descriptor = -1
        bundle_descriptor = -1
        created_directories: list[tuple[int, str]] = []
        published: list[tuple[int, str]] = []
        try:
            for relative, is_directory, context in (
                (
                    EXECUTION_RECEIPT_PATH,
                    False,
                    "R12 functional execution receipt",
                ),
                (
                    ACCEPTANCE_PATH,
                    False,
                    "R12 functional phase acceptance",
                ),
                (
                    ARTIFACT_DIRECTORY,
                    True,
                    "R12 functional acceptance artifact directory",
                ),
            ):
                if (
                    self._entry_state(
                        relative,
                        expected_directory=is_directory,
                        context=context,
                    )
                    == "present"
                ):
                    raise ValueError(
                        "R12 generated outputs already exist; validate them "
                        "with --check-generated"
                    )
            evidence_descriptor = self._open_repository_directory(
                Path("docs/roadmaps/evidence"),
                context="R12 evidence root",
            )
            r12_descriptor, created = self._ensure_directory_at(
                evidence_descriptor, "r12", context="R12 evidence directory"
            )
            if created:
                created_directories.append((evidence_descriptor, "r12"))
            records_descriptor, created = self._ensure_directory_at(
                r12_descriptor, "records", context="R12 records directory"
            )
            if created:
                created_directories.append((r12_descriptor, "records"))
            artifacts_descriptor, created = self._ensure_directory_at(
                records_descriptor,
                "artifacts",
                context="R12 artifacts directory",
            )
            if created:
                created_directories.append((records_descriptor, "artifacts"))
            bundle_descriptor, created = self._ensure_directory_at(
                artifacts_descriptor,
                "functional-phase-acceptance",
                context="R12 acceptance artifact directory",
            )
            if not created:
                raise ValueError(
                    "R12 functional acceptance artifact directory already exists"
                )
            created_directories.append(
                (artifacts_descriptor, "functional-phase-acceptance")
            )
            for descriptor, name, payload, mode, context in (
                (
                    bundle_descriptor,
                    BUILD_LOG_PATH.name,
                    build_payload,
                    0o400,
                    "R12 build-for-testing log artifact",
                ),
                (
                    bundle_descriptor,
                    TEST_LOG_PATH.name,
                    test_payload,
                    0o400,
                    "R12 targeted XCTest log artifact",
                ),
                (
                    bundle_descriptor,
                    LINT_LOG_PATH.name,
                    lint_payload,
                    0o400,
                    "R12 SwiftLint log artifact",
                ),
                (
                    records_descriptor,
                    EXECUTION_RECEIPT_PATH.name,
                    execution_payload,
                    0o644,
                    "R12 functional execution receipt",
                ),
                (
                    records_descriptor,
                    ACCEPTANCE_PATH.name,
                    acceptance_payload,
                    0o644,
                    "R12 functional phase acceptance",
                ),
            ):
                self._publish_payload_at(
                    descriptor,
                    name,
                    payload,
                    mode=mode,
                    context=context,
                )
                published.append((descriptor, name))
            for path, expected in (
                (BUILD_LOG_PATH, build_payload),
                (TEST_LOG_PATH, test_payload),
                (LINT_LOG_PATH, lint_payload),
            ):
                if (
                    self._read_repository_file(
                        path,
                        context=f"R12 published artifact {path.name}",
                        maximum=max(len(expected), 1),
                        require_sealed=True,
                    )
                    != expected
                ):
                    raise ValueError(
                        f"R12 published artifact bytes differ: {path.name}"
                    )
            return []
        except (OSError, ValueError) as error:
            for descriptor, name in reversed(published):
                try:
                    os.unlink(name, dir_fd=descriptor)
                except OSError:
                    pass
            for parent_descriptor, name in reversed(created_directories):
                try:
                    os.rmdir(name, dir_fd=parent_descriptor)
                except OSError:
                    pass
            return [f"R12 evidence output transaction failed: {error}"]
        finally:
            for descriptor in (
                bundle_descriptor,
                artifacts_descriptor,
                records_descriptor,
                r12_descriptor,
                evidence_descriptor,
            ):
                if descriptor >= 0:
                    os.close(descriptor)

    def _read_generated_json(
        self,
        path: Path,
        context: str,
        errors: list[str],
    ) -> tuple[dict[str, Any], bytes] | None:
        try:
            payload = self._read_repository_file(
                path, context=context, maximum=_MAX_JSON_BYTES
            )
            return _decode_object(payload, context), payload
        except ValueError as error:
            errors.append(str(error))
            return None

    def _artifact_closure_errors(self) -> list[str]:
        errors: list[str] = []
        try:
            records = self._open_repository_directory(
                RECORDS_DIRECTORY, context="R12 records directory"
            )
            try:
                if tuple(sorted(os.listdir(records))) != (
                    "artifacts",
                    "functional-execution-receipt.json",
                    "functional-phase-acceptance.json",
                ):
                    errors.append("R12 records directory closure differs")
            finally:
                os.close(records)
            artifacts = self._open_repository_directory(
                ARTIFACT_DIRECTORY.parent,
                context="R12 artifacts directory",
            )
            try:
                if tuple(os.listdir(artifacts)) != (
                    "functional-phase-acceptance",
                ):
                    errors.append("R12 artifacts directory closure differs")
            finally:
                os.close(artifacts)
            bundle = self._open_repository_directory(
                ARTIFACT_DIRECTORY,
                context="R12 acceptance artifact directory",
            )
            try:
                if tuple(sorted(os.listdir(bundle))) != (
                    "build-for-testing.log",
                    "swiftlint.log",
                    "targeted-xctest.log",
                ):
                    errors.append("R12 acceptance artifact closure differs")
            finally:
                os.close(bundle)
        except (OSError, ValueError) as error:
            errors.append(str(error))
        return errors

    def check_generated(self) -> list[str]:
        errors = self._artifact_closure_errors()
        execution_record = self._read_generated_json(
            EXECUTION_RECEIPT_PATH,
            "R12 functional execution receipt",
            errors,
        )
        acceptance_record = self._read_generated_json(
            ACCEPTANCE_PATH,
            "R12 functional phase acceptance",
            errors,
        )
        try:
            build_payload = self._read_repository_file(
                BUILD_LOG_PATH,
                context="R12 build-for-testing log artifact",
                maximum=_MAX_BUILD_LOG_BYTES,
                require_sealed=True,
                allow_git_materialized=True,
            )
            test_payload = self._read_repository_file(
                TEST_LOG_PATH,
                context="R12 targeted XCTest log artifact",
                maximum=_MAX_TEST_LOG_BYTES,
                require_sealed=True,
                allow_git_materialized=True,
            )
            lint_payload = self._read_repository_file(
                LINT_LOG_PATH,
                context="R12 SwiftLint log artifact",
                maximum=_MAX_LINT_LOG_BYTES,
                require_sealed=True,
                allow_git_materialized=True,
            )
        except ValueError as error:
            errors.append(str(error))
            return sorted(set(errors))
        if execution_record is None or acceptance_record is None:
            return sorted(set(errors))
        execution, execution_payload = execution_record
        acceptance, acceptance_payload = acceptance_record
        source_value = execution.get("source")
        source_errors = self._source_errors(source_value)
        errors.extend(source_errors)
        if source_errors or type(source_value) is not dict:
            return sorted(set(errors))
        source = {
            "commit": str(source_value["commit"]),
            "tree": str(source_value["tree"]),
        }
        status = self._roadmap_phase_status()
        errors.extend(
            self._base_errors(
                source,
                require_current_source=True,
                allow_project_evolution=status == "passed",
            )
        )
        inventory, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        if inventory is None:
            return sorted(set(errors))
        errors.extend(self._build_log_errors(build_payload, source))
        errors.extend(
            self._test_log_errors(
                test_payload, source, inventory, self.test_suites
            )
        )
        lint, lint_errors = self._lint_log(lint_payload)
        errors.extend(lint_errors)
        if lint is None:
            return sorted(set(errors))
        build = ParsedBuild(build_payload)
        tests = ParsedTests(test_payload, inventory.identifiers)
        try:
            execution_schema = self._checkpoint_json(
                source,
                EXECUTION_SCHEMA_PATH,
                "R12 functional execution receipt schema",
            )
            acceptance_schema = self._checkpoint_json(
                source,
                ACCEPTANCE_SCHEMA_PATH,
                "R12 functional phase acceptance schema",
            )
        except ValueError as error:
            errors.append(str(error))
            return sorted(set(errors))
        errors.extend(
            self._schema_errors(
                execution_schema,
                execution,
                "R12 functional execution receipt schema",
            )
        )
        errors.extend(
            self._schema_errors(
                acceptance_schema,
                acceptance,
                "R12 functional phase acceptance schema",
            )
        )
        expected_execution = self.expected_execution_receipt(
            source=source,
            inventory=inventory,
            build=build,
            tests=tests,
            lint=lint,
        )
        if execution != expected_execution:
            errors.append(
                "R12 functional execution receipt is not exactly derived"
            )
        if execution_payload != self._json_payload(expected_execution):
            errors.append(
                "R12 functional execution receipt bytes are not canonical"
            )
        gate = acceptance.get("functional_gate")
        phase_before = (
            gate.get("phase_status_before")
            if type(gate) is dict
            else None
        )
        try:
            expected_acceptance = self.expected_acceptance(
                source=source,
                execution_payload=execution_payload,
                phase_status_before=(
                    phase_before if type(phase_before) is str else ""
                ),
            )
        except ValueError as error:
            errors.append(str(error))
            expected_acceptance = {}
        if acceptance != expected_acceptance:
            errors.append(
                "R12 functional phase acceptance is not exactly derived"
            )
        if acceptance_payload != self._json_payload(expected_acceptance):
            errors.append(
                "R12 functional phase acceptance bytes are not canonical"
            )
        return sorted(set(errors))

    def check(self) -> list[str]:
        targets = (
            (
                EXECUTION_RECEIPT_PATH,
                False,
                "R12 functional execution receipt",
            ),
            (
                ACCEPTANCE_PATH,
                False,
                "R12 functional phase acceptance",
            ),
            (
                ARTIFACT_DIRECTORY,
                True,
                "R12 functional acceptance artifact directory",
            ),
        )
        try:
            states = [
                self._entry_state(
                    path,
                    expected_directory=is_directory,
                    context=context,
                )
                for path, is_directory, context in targets
            ]
        except ValueError as error:
            return [str(error)]
        present = tuple(state == "present" for state in states)
        if not any(present):
            status = self._roadmap_phase_status()
            if status in {"in_progress", "evidence_ready"}:
                return []
            return [
                "R12 generated acceptance evidence is absent while canonical "
                f"phase status is {status!r}"
            ]
        if not all(present):
            return ["R12 generated acceptance evidence is only partially present"]
        return self.check_generated()

    def write(
        self,
        revision: str,
        *,
        build_log: Path,
        test_log: Path,
        lint_log: Path,
    ) -> list[str]:
        try:
            source = self.resolve_source(revision)
        except ValueError as error:
            return [str(error)]
        errors = self._base_errors(
            source,
            require_current_source=True,
            allow_project_evolution=False,
        )
        status = self._roadmap_phase_status()
        if status not in {"in_progress", "evidence_ready"}:
            errors.append(
                "R12 evidence can only be derived while canonical phase status "
                "is in_progress or evidence_ready"
            )
        inventory, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        inputs: dict[str, bytes] = {}
        for name, path, maximum in (
            ("build", build_log, _MAX_BUILD_LOG_BYTES),
            ("test", test_log, _MAX_TEST_LOG_BYTES),
            ("lint", lint_log, _MAX_LINT_LOG_BYTES),
        ):
            try:
                inputs[name] = self._read_input_file(
                    path,
                    context=f"R12 input {name} log",
                    maximum=maximum,
                )
            except ValueError as error:
                errors.append(str(error))
                inputs[name] = b""
        if inventory is not None:
            errors.extend(self._build_log_errors(inputs["build"], source))
            errors.extend(
                self._test_log_errors(
                    inputs["test"], source, inventory, self.test_suites
                )
            )
        lint, lint_errors = self._lint_log(inputs["lint"])
        errors.extend(lint_errors)
        if (
            errors
            or status is None
            or inventory is None
            or lint is None
        ):
            return sorted(set(errors))
        build = ParsedBuild(inputs["build"])
        tests = ParsedTests(inputs["test"], inventory.identifiers)
        try:
            execution = self.expected_execution_receipt(
                source=source,
                inventory=inventory,
                build=build,
                tests=tests,
                lint=lint,
            )
            execution_payload = self._json_payload(execution)
            acceptance = self.expected_acceptance(
                source=source,
                execution_payload=execution_payload,
                phase_status_before=status,
            )
            acceptance_payload = self._json_payload(acceptance)
            execution_schema = self._checkpoint_json(
                source,
                EXECUTION_SCHEMA_PATH,
                "R12 functional execution receipt schema",
            )
            acceptance_schema = self._checkpoint_json(
                source,
                ACCEPTANCE_SCHEMA_PATH,
                "R12 functional phase acceptance schema",
            )
        except ValueError as error:
            return [str(error)]
        errors.extend(
            self._schema_errors(
                execution_schema,
                execution,
                "R12 functional execution receipt schema",
            )
        )
        errors.extend(
            self._schema_errors(
                acceptance_schema,
                acceptance,
                "R12 functional phase acceptance schema",
            )
        )
        if errors:
            return sorted(set(errors))
        errors.extend(
            self._write_bundle(
                build_payload=inputs["build"],
                test_payload=inputs["test"],
                lint_payload=inputs["lint"],
                execution_payload=execution_payload,
                acceptance_payload=acceptance_payload,
            )
        )
        if errors:
            return sorted(set(errors))
        return self.check_generated()


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--check-generated", action="store_true")
    group.add_argument("--write", metavar="IMPLEMENTATION_COMMIT")
    parser.add_argument("--build-log", type=Path)
    parser.add_argument("--test-log", type=Path)
    parser.add_argument("--lint-log", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_argument_parser()
    arguments = parser.parse_args(argv)
    verifier = R12PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    log_arguments = (
        arguments.build_log,
        arguments.test_log,
        arguments.lint_log,
    )
    if arguments.write is not None:
        if any(value is None for value in log_arguments):
            parser.error(
                "--write requires --build-log, --test-log, and --lint-log"
            )
        errors = verifier.write(
            arguments.write,
            build_log=arguments.build_log,
            test_log=arguments.test_log,
            lint_log=arguments.lint_log,
        )
    else:
        if any(value is not None for value in log_arguments):
            parser.error("log arguments are valid only with --write")
        errors = (
            verifier.check_generated()
            if arguments.check_generated
            else verifier.check()
        )
    if not errors:
        print("R12 functional phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
