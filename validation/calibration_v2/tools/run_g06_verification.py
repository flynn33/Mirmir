#!/usr/bin/env python3
"""Run and atomically publish the five ordered pre-release G06 evidence files."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import subprocess
import sys
import time
import traceback
from typing import Callable, Dict, List, Mapping, Optional, Sequence, Tuple


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.release_evidence import (  # noqa: E402
    NATIVE_INTEGRATION_TEST_IDS,
    PYTHON_TEST_RUNNER_IDS,
    RELEASE_LOCK_TEST_MODULES,
    RELEASE_RUNTIME_TEST_IDS,
    TEST_EVIDENCE_IDS,
    actionable_diagnostic_counts,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


SCHEMA_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/g06-test-evidence-v1.schema.json"
)
VERIFIER_SOURCE_PATH = Path(__file__).resolve(strict=True)
REQUIRED_G06_TEST_EVIDENCE_IDS = TEST_EVIDENCE_IDS
NATIVE_INTEGRATION_TESTS = NATIVE_INTEGRATION_TEST_IDS
RELEASE_RUNTIME_TESTS = RELEASE_RUNTIME_TEST_IDS


class G06VerificationError(RuntimeError):
    """The verification run or its immutable evidence publication is invalid."""


@dataclass(frozen=True)
class GroupResult:
    status: str
    started_utc: str
    finished_utc: str
    commands: Tuple[Mapping[str, object], ...]
    artifacts: Tuple[Mapping[str, object], ...]
    summary: Mapping[str, object]
    failure_reason: Optional[str]


@dataclass(frozen=True)
class VerificationRunResult:
    status: str
    path: Path
    evidence_paths: Tuple[Tuple[str, Path], ...]


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def _validate_run_id(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or Path(value).name != value
        or Path(value).is_absolute()
        or "/" in value
        or "\\" in value
        or "\x00" in value
    ):
        raise G06VerificationError("run ID must be one safe filename component")
    return value


def _safe_relative(value: object) -> PurePosixPath:
    if not isinstance(value, str):
        raise G06VerificationError("artifact ID is not a string")
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise G06VerificationError(f"unsafe artifact ID: {value!r}")
    return path


def _safe_child(root: Path, artifact_id: str) -> Path:
    relative = _safe_relative(artifact_id)
    path = root.joinpath(*relative.parts)
    try:
        path.parent.resolve(strict=False).relative_to(root.resolve(strict=True))
    except ValueError as error:
        raise G06VerificationError("artifact path escapes the run root") from error
    return path


def _read_regular(path: Path) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G06VerificationError(f"evidence file is absent: {path}") from error
    if path.is_symlink() or not stat.S_ISREG(before.st_mode):
        raise G06VerificationError(f"evidence path is not a regular file: {path}")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise G06VerificationError("evidence file changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
    ):
        raise G06VerificationError("evidence file changed while reading")
    return b"".join(chunks)


def _write_new(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("evidence publication made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if _read_regular(path) != payload:
        raise G06VerificationError(f"published evidence changed: {path}")


def _write_json_new(path: Path, document: Mapping[str, object]) -> None:
    _write_new(path, canonical_json_bytes(document) + b"\n")


def _reject_duplicate_pairs(
    pairs: Sequence[Tuple[str, object]],
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise G06VerificationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _read_json(path: Path) -> Mapping[str, object]:
    try:
        value = json.loads(
            _read_regular(path),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                G06VerificationError(f"non-finite JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise G06VerificationError(f"invalid JSON evidence: {path}") from error
    if not isinstance(value, dict):
        raise G06VerificationError("JSON evidence top level is not an object")
    return value


def _file_binding(
    path: Path,
    *,
    run_root: Path,
    artifact_kind: str,
) -> Mapping[str, object]:
    payload = _read_regular(path)
    artifact_id = path.relative_to(run_root).as_posix()
    _safe_relative(artifact_id)
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "file_sha256",
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
        "file_count": 1,
    }


def _tree_binding(
    path: Path,
    *,
    run_root: Path,
    artifact_kind: str,
) -> Mapping[str, object]:
    if path.is_symlink() or not path.is_dir():
        raise G06VerificationError(f"tree evidence is absent or symbolic: {path}")
    entries: List[Mapping[str, object]] = []
    for current, directories, filenames in os.walk(path, followlinks=False):
        current_path = Path(current)
        for directory in directories:
            if (current_path / directory).is_symlink():
                raise G06VerificationError("tree evidence contains a symbolic directory")
        for filename in sorted(filenames):
            child = current_path / filename
            if child.is_symlink():
                raise G06VerificationError("tree evidence contains a symbolic file")
            payload = _read_regular(child)
            entries.append(
                {
                    "path": child.relative_to(path).as_posix(),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
    entries.sort(key=lambda row: str(row["path"]))
    if not entries:
        raise G06VerificationError("tree evidence is empty")
    artifact_id = path.relative_to(run_root).as_posix()
    _safe_relative(artifact_id)
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "canonical_tree_manifest_sha256",
        "sha256": canonical_sha256(entries),
        "size_bytes": sum(int(row["size_bytes"]) for row in entries),
        "file_count": len(entries),
    }


def _repository_source_binding(path: Path) -> Mapping[str, object]:
    payload = _read_regular(path)
    try:
        relative = path.resolve(strict=True).relative_to(REPOSITORY_ROOT).as_posix()
    except ValueError as error:
        raise G06VerificationError("verifier source escapes the repository") from error
    return {
        "repository_path": relative,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def parse_unittest_output(text: str) -> Mapping[str, object]:
    matches = list(re.finditer(r"(?m)^Ran ([0-9]+) tests? in .+$", text))
    if not matches:
        raise G06VerificationError("unittest log lacks an executed-test count")
    total = int(matches[-1].group(1))
    failed = errors = skipped = expected_failures = unexpected_successes = 0
    failed_match = re.search(r"(?m)^FAILED \(([^)]*)\)\s*$", text)
    ok_match = re.search(r"(?m)^OK(?: \(([^)]*)\))?\s*$", text)
    details = ""
    if failed_match is not None:
        details = failed_match.group(1)
    elif ok_match is not None:
        details = ok_match.group(1) or ""
    else:
        raise G06VerificationError("unittest log lacks a terminal status")
    values = {
        key.strip().replace(" ", "_"): int(value)
        for key, value in re.findall(r"([a-z_ ]+)=([0-9]+)", details)
    }
    failed = values.get("failures", 0)
    errors = values.get("errors", 0)
    skipped = values.get("skipped", 0)
    expected_failures = values.get("expected_failures", 0)
    unexpected_successes = values.get("unexpected_successes", 0)
    passed = total - failed - errors - skipped - expected_failures - unexpected_successes
    if total <= 0 or passed < 0:
        raise G06VerificationError("unittest counts are arithmetically invalid")
    return {
        "test_count": total,
        "passed": passed,
        "failed": failed,
        "errors": errors,
        "skipped": skipped,
        "expected_failures": expected_failures,
        "unexpected_successes": unexpected_successes,
        "terminal_status": "passed" if failed_match is None else "failed",
    }


def parse_pytest_output(text: str) -> Mapping[str, object]:
    summary_line = None
    for line in reversed(text.splitlines()):
        if re.search(
            r"[0-9]+ (?:passed|failed|skipped|error|errors|xfailed|xpassed|deselected)",
            line,
        ):
            summary_line = line
            break
    if summary_line is None:
        raise G06VerificationError("pytest log lacks a terminal count summary")
    counts = {
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "errors": 0,
        "xfailed": 0,
        "xpassed": 0,
        "deselected": 0,
    }
    for value, label in re.findall(
        r"([0-9]+) (passed|failed|skipped|error|errors|xfailed|xpassed|deselected)",
        summary_line,
    ):
        key = "errors" if label in {"error", "errors"} else label
        counts[key] += int(value)
    total = sum(counts[key] for key in counts if key != "deselected")
    if total <= 0:
        raise G06VerificationError("pytest executed-test count is zero")
    return {
        "test_count": total,
        **counts,
        "terminal_status": (
            "passed"
            if all(counts[key] == 0 for key in counts if key != "passed")
            else "failed"
        ),
    }


def parse_xcresult_summary(document: Mapping[str, object]) -> Mapping[str, object]:
    def count(name: str) -> int:
        value = document.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise G06VerificationError(f"xcresult summary count is invalid: {name}")
        return value

    total = count("totalTestCount")
    passed = count("passedTests")
    failed = count("failedTests")
    skipped = count("skippedTests")
    expected = count("expectedFailures")
    if total <= 0 or passed + failed + skipped + expected != total:
        raise G06VerificationError("xcresult summary arithmetic differs")
    result = document.get("result")
    if not isinstance(result, str) or not result:
        raise G06VerificationError("xcresult summary status is absent")
    return {
        "test_count": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "expected_failures": expected,
        "terminal_status": "passed" if result == "Passed" else "failed",
    }


def parse_diagnostic_counts(text: str) -> Mapping[str, int]:
    return actionable_diagnostic_counts(text)


def _diagnostics_are_clean(counts: Mapping[str, object]) -> bool:
    return (
        counts.get("warning_count") == 0
        and counts.get("error_count") == 0
    )


def _test_counts_pass(counts: Mapping[str, object]) -> bool:
    return (
        counts.get("terminal_status") == "passed"
        and int(counts.get("test_count", 0)) > 0
        and all(
            int(counts.get(field, 0)) == 0
            for field in (
                "failed",
                "errors",
                "skipped",
                "expected_failures",
                "unexpected_successes",
                "xfailed",
                "xpassed",
                "deselected",
            )
        )
    )


class G06VerificationRunner:
    def __init__(
        self,
        *,
        repository_root: Path,
        output_root: Path,
        run_id: str,
        project: str = "Mirmir.xcodeproj",
        scheme: str = "Mirmir",
        destination: str = "platform=macOS,arch=arm64",
        python_executable: str = sys.executable,
        swiftlint_executable: str = "swiftlint",
        timeout_seconds: float = 3600.0,
        group_executors: Optional[
            Mapping[str, Callable[[Path], GroupResult]]
        ] = None,
    ) -> None:
        self.repository_root = repository_root.resolve(strict=True)
        if repository_root.is_symlink() or not self.repository_root.is_dir():
            raise G06VerificationError("repository root is symbolic or not a directory")
        self.output_root = Path(os.path.abspath(output_root))
        self.run_id = _validate_run_id(run_id)
        project_relative = _safe_relative(project)
        self.project = project_relative.as_posix()
        project_path = self.repository_root.joinpath(*project_relative.parts)
        if project_path.is_symlink() or not project_path.is_dir():
            raise G06VerificationError("Xcode project is absent or symbolic")
        if not isinstance(scheme, str) or not scheme:
            raise G06VerificationError("Xcode scheme is absent")
        if not isinstance(destination, str) or not destination:
            raise G06VerificationError("Xcode destination is absent")
        if not isinstance(timeout_seconds, (int, float)) or timeout_seconds <= 0:
            raise G06VerificationError("command timeout must be positive")
        self.scheme = scheme
        self.destination = destination
        self.python_executable = python_executable
        self.swiftlint_executable = swiftlint_executable
        self.timeout_seconds = float(timeout_seconds)
        self.group_executors = dict(group_executors or {})

    def _execute_command(
        self,
        *,
        run_root: Path,
        command_index: int,
        argv: Sequence[str],
        log_artifact_id: str,
        artifact_kind: str = "command_log",
        raw_output: bool = False,
    ) -> Mapping[str, object]:
        if not argv or any(not isinstance(value, str) or not value for value in argv):
            raise G06VerificationError("command argv is empty or invalid")
        log_path = _safe_child(run_root, log_artifact_id)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(log_path, flags, 0o600)
        started = time.monotonic()
        timed_out = False
        exit_code = 127
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            if not raw_output:
                handle.write((f"command: {shlex.join(argv)}\n").encode("utf-8"))
                handle.write(b"working_directory: .\n")
                handle.flush()
            environment = os.environ.copy()
            existing_pythonpath = environment.get("PYTHONPATH")
            environment["PYTHONPATH"] = str(self.repository_root) + (
                os.pathsep + existing_pythonpath if existing_pythonpath else ""
            )
            try:
                completed = subprocess.run(
                    list(argv),
                    cwd=self.repository_root,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                    timeout=self.timeout_seconds,
                    check=False,
                )
                exit_code = int(completed.returncode)
            except subprocess.TimeoutExpired:
                timed_out = True
                exit_code = 124
                handle.write(b"\ncommand_timed_out: true\n")
            except OSError as error:
                exit_code = 127
                handle.write(
                    (
                        "\ncommand_launch_error: "
                        f"{type(error).__name__}: {error}\n"
                    ).encode("utf-8", errors="replace")
                )
            handle.flush()
            os.fsync(handle.fileno())
        duration = round(max(0.0, time.monotonic() - started), 6)
        log_binding = _file_binding(
            log_path,
            run_root=run_root,
            artifact_kind=artifact_kind,
        )
        return {
            "command_index": command_index,
            "argv": list(argv),
            "command_text": shlex.join(argv),
            "working_directory": ".",
            "exit_code": exit_code,
            "timed_out": timed_out,
            "duration_seconds": duration,
            "status": "passed" if exit_code == 0 and not timed_out else "failed",
            "log_binding": log_binding,
        }

    @staticmethod
    def _artifacts_from_commands(
        commands: Sequence[Mapping[str, object]],
        extras: Sequence[Mapping[str, object]] = (),
    ) -> Tuple[Mapping[str, object], ...]:
        ordered: List[Mapping[str, object]] = []
        seen = set()
        for binding in [
            *(command["log_binding"] for command in commands),
            *extras,
        ]:
            assert isinstance(binding, dict)
            artifact_id = binding["artifact_id"]
            if artifact_id in seen:
                continue
            seen.add(artifact_id)
            ordered.append(dict(binding))
        return tuple(ordered)

    @staticmethod
    def _finish_group(
        *,
        started: str,
        commands: Sequence[Mapping[str, object]],
        artifacts: Sequence[Mapping[str, object]],
        summary: Mapping[str, object],
        passed: bool,
        failures: Sequence[str],
    ) -> GroupResult:
        reason = None if passed else "; ".join(failures) or "verification failed"
        return GroupResult(
            status="passed" if passed else "failed",
            started_utc=started,
            finished_utc=_utc_now(),
            commands=tuple(dict(command) for command in commands),
            artifacts=tuple(dict(binding) for binding in artifacts),
            summary=dict(summary),
            failure_reason=reason,
        )

    def _python_full_suite(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        commands = [
            self._execute_command(
                run_root=run_root,
                command_index=1,
                argv=(
                    self.python_executable,
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    "validation/calibration_v2/tests",
                    "-p",
                    "test_*.py",
                ),
                log_artifact_id="logs/python-unittest-discovery.log",
            ),
            self._execute_command(
                run_root=run_root,
                command_index=2,
                argv=(
                    self.python_executable,
                    "-m",
                    "pytest",
                    "-q",
                    "validation/calibration_v2/tests",
                ),
                log_artifact_id="logs/python-pytest.log",
            ),
        ]
        failures = []
        runner_rows = []
        for runner_id, command in zip(PYTHON_TEST_RUNNER_IDS, commands):
            text = _read_regular(
                _safe_child(run_root, str(command["log_binding"]["artifact_id"]))
            ).decode("utf-8", errors="replace")
            try:
                counts = (
                    parse_unittest_output(text)
                    if runner_id == "unittest_discovery"
                    else parse_pytest_output(text)
                )
            except G06VerificationError as error:
                counts = {"parser_error": str(error)}
                failures.append(f"{runner_id}: {error}")
            if command["status"] != "passed":
                failures.append(f"{runner_id} command failed")
            if "parser_error" not in counts and not _test_counts_pass(counts):
                failures.append(f"{runner_id} reported non-passing or skipped tests")
            runner_rows.append({"runner": runner_id, "counts": counts})
        aggregate = sum(
            int(row["counts"].get("test_count", 0))
            for row in runner_rows
            if isinstance(row["counts"], dict)
        )
        artifacts = self._artifacts_from_commands(commands)
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=artifacts,
            summary={
                "runners": runner_rows,
                "aggregate_executed_test_count": aggregate,
                "required_runner_order": list(PYTHON_TEST_RUNNER_IDS),
            },
            passed=not failures,
            failures=failures,
        )

    def _xcode_test_command(
        self,
        *,
        configuration: str,
        derived_data: Path,
        result_bundle: Path,
        tests: Sequence[str],
        clean: bool,
    ) -> Tuple[str, ...]:
        return (
            "xcodebuild",
            "-project",
            self.project,
            "-scheme",
            self.scheme,
            "-configuration",
            configuration,
            "-destination",
            self.destination,
            "-derivedDataPath",
            str(derived_data),
            "-resultBundlePath",
            str(result_bundle),
            "-enableCodeCoverage",
            "YES",
            "-parallel-testing-enabled",
            "NO",
            "CODE_SIGNING_ALLOWED=NO",
            *(("ENABLE_TESTABILITY=YES",) if configuration == "Release" else ()),
            *(f"-only-testing:MirmirTests/{name}" for name in tests),
            *(("clean", "test") if clean else ("test",)),
        )

    def _xcresult_summary(
        self,
        *,
        run_root: Path,
        command_index: int,
        result_bundle: Path,
        log_artifact_id: str,
    ) -> Mapping[str, object]:
        return self._execute_command(
            run_root=run_root,
            command_index=command_index,
            argv=(
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--path",
                str(result_bundle),
            ),
            log_artifact_id=log_artifact_id,
            artifact_kind="xcresult_summary",
            raw_output=True,
        )

    def _xcode_native_integration(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        derived = run_root / "build/native-integration-derived-data"
        result_bundle = run_root / "artifacts/native-integration.xcresult"
        result_bundle.parent.mkdir(parents=True, exist_ok=True)
        commands = [
            self._execute_command(
                run_root=run_root,
                command_index=1,
                argv=self._xcode_test_command(
                    configuration="Debug",
                    derived_data=derived,
                    result_bundle=result_bundle,
                    tests=NATIVE_INTEGRATION_TESTS,
                    clean=True,
                ),
                log_artifact_id="logs/xcode-native-integration.log",
            )
        ]
        extras: List[Mapping[str, object]] = []
        failures = []
        counts: Mapping[str, object] = {"parser_error": "xcresult absent"}
        if result_bundle.is_dir() and not result_bundle.is_symlink():
            summary_command = self._xcresult_summary(
                run_root=run_root,
                command_index=2,
                result_bundle=result_bundle,
                log_artifact_id="artifacts/native-integration-xcresult-summary.log",
            )
            commands.append(summary_command)
            if summary_command["status"] == "passed":
                try:
                    counts = parse_xcresult_summary(
                        _read_json(
                            _safe_child(
                                run_root,
                                str(summary_command["log_binding"]["artifact_id"]),
                            )
                        )
                    )
                except G06VerificationError as error:
                    counts = {"parser_error": str(error)}
                    failures.append(str(error))
            else:
                failures.append("xcresult summary extraction failed")
            extras.append(
                _tree_binding(
                    result_bundle,
                    run_root=run_root,
                    artifact_kind="xcresult",
                )
            )
        else:
            failures.append("native integration xcresult is absent")
        build_log = _read_regular(
            _safe_child(run_root, str(commands[0]["log_binding"]["artifact_id"]))
        ).decode("utf-8", errors="replace")
        diagnostics = parse_diagnostic_counts(build_log)
        if commands[0]["status"] != "passed":
            failures.append("native integration xcodebuild failed")
        if diagnostics["error_count"] != 0:
            failures.append("native integration log contains compiler errors")
        if "parser_error" not in counts and not _test_counts_pass(counts):
            failures.append("native integration tests failed or were skipped")
        elif "parser_error" in counts:
            failures.append("native integration result counts are unavailable")
        artifacts = self._artifacts_from_commands(commands, extras)
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=artifacts,
            summary={
                "configuration": "Debug",
                "scheme": self.scheme,
                "destination": self.destination,
                "only_testing": list(NATIVE_INTEGRATION_TESTS),
                "test_counts": counts,
                **diagnostics,
            },
            passed=not failures,
            failures=failures,
        )

    def _xcode_release_runtime(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        derived = run_root / "build/release-derived-data"
        build_command = self._execute_command(
            run_root=run_root,
            command_index=1,
            argv=(
                "xcodebuild",
                "-project",
                self.project,
                "-scheme",
                self.scheme,
                "-configuration",
                "Release",
                "-destination",
                self.destination,
                "-derivedDataPath",
                str(derived),
                "CODE_SIGNING_ALLOWED=NO",
                "ENABLE_TESTABILITY=YES",
                "clean",
                "build",
            ),
            log_artifact_id="logs/xcode-release-build.log",
        )
        commands = [build_command]
        extras: List[Mapping[str, object]] = []
        failures = []
        build_log = _read_regular(
            _safe_child(run_root, str(build_command["log_binding"]["artifact_id"]))
        ).decode("utf-8", errors="replace")
        build_diagnostics = parse_diagnostic_counts(build_log)
        build_succeeded = (
            build_command["status"] == "passed"
            and "** BUILD SUCCEEDED **" in build_log
            and _diagnostics_are_clean(build_diagnostics)
        )
        if not build_succeeded:
            failures.append(
                "Release build failed, warned, errored, or lacks its success marker"
            )
        executable = derived / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
        product_exists_after_build = (
            executable.is_file() and not executable.is_symlink()
        )
        if not product_exists_after_build:
            failures.append("Release application executable is absent")

        runtime_counts: Mapping[str, object] = {"parser_error": "not run"}
        runtime_diagnostics = {"warning_count": 0, "error_count": 0}
        result_bundle = run_root / "artifacts/release-runtime.xcresult"
        if build_succeeded:
            result_bundle.parent.mkdir(parents=True, exist_ok=True)
            runtime_command = self._execute_command(
                run_root=run_root,
                command_index=2,
                argv=self._xcode_test_command(
                    configuration="Release",
                    derived_data=derived,
                    result_bundle=result_bundle,
                    tests=RELEASE_RUNTIME_TESTS,
                    clean=False,
                ),
                log_artifact_id="logs/xcode-release-runtime.log",
            )
            commands.append(runtime_command)
            runtime_log = _read_regular(
                _safe_child(
                    run_root,
                    str(runtime_command["log_binding"]["artifact_id"]),
                )
            ).decode("utf-8", errors="replace")
            runtime_diagnostics = dict(parse_diagnostic_counts(runtime_log))
            if runtime_command["status"] != "passed":
                failures.append("Release runtime xcodebuild failed")
            if result_bundle.is_dir() and not result_bundle.is_symlink():
                summary_command = self._xcresult_summary(
                    run_root=run_root,
                    command_index=3,
                    result_bundle=result_bundle,
                    log_artifact_id="artifacts/release-runtime-xcresult-summary.log",
                )
                commands.append(summary_command)
                if summary_command["status"] == "passed":
                    try:
                        runtime_counts = parse_xcresult_summary(
                            _read_json(
                                _safe_child(
                                    run_root,
                                    str(
                                        summary_command["log_binding"]["artifact_id"]
                                    ),
                                )
                            )
                        )
                    except G06VerificationError as error:
                        runtime_counts = {"parser_error": str(error)}
                        failures.append(str(error))
                else:
                    failures.append("Release runtime xcresult extraction failed")
                extras.append(
                    _tree_binding(
                        result_bundle,
                        run_root=run_root,
                        artifact_kind="xcresult",
                    )
                )
            else:
                failures.append("Release runtime xcresult is absent")
        if not _diagnostics_are_clean(runtime_diagnostics):
            failures.append("Release runtime log contains warnings or compiler errors")
        if "parser_error" not in runtime_counts:
            if not _test_counts_pass(runtime_counts):
                failures.append("Release runtime tests failed or were skipped")
        else:
            failures.append("Release runtime result counts are unavailable")
        if executable.is_file() and not executable.is_symlink():
            extras.append(
                _file_binding(
                    executable,
                    run_root=run_root,
                    artifact_kind="release_product",
                )
            )
        elif product_exists_after_build:
            failures.append("Release application executable disappeared during runtime tests")
        artifacts = self._artifacts_from_commands(commands, extras)
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=artifacts,
            summary={
                "configuration": "Release",
                "scheme": self.scheme,
                "destination": self.destination,
                "only_testing": list(RELEASE_RUNTIME_TESTS),
                "build_warning_count": build_diagnostics["warning_count"],
                "build_error_count": build_diagnostics["error_count"],
                "runtime_warning_count": runtime_diagnostics["warning_count"],
                "runtime_error_count": runtime_diagnostics["error_count"],
                "test_counts": runtime_counts,
            },
            passed=not failures,
            failures=failures,
        )

    def _swiftlint(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        commands = [
            self._execute_command(
                run_root=run_root,
                command_index=1,
                argv=(self.swiftlint_executable, "version"),
                log_artifact_id="logs/swiftlint-version.log",
            ),
            self._execute_command(
                run_root=run_root,
                command_index=2,
                argv=(
                    self.swiftlint_executable,
                    "lint",
                    "--strict",
                    "--config",
                    ".swiftlint.yml",
                ),
                log_artifact_id="logs/swiftlint-strict.log",
            ),
        ]
        lint_log = _read_regular(
            _safe_child(run_root, str(commands[1]["log_binding"]["artifact_id"]))
        ).decode("utf-8", errors="replace")
        diagnostics = parse_diagnostic_counts(lint_log)
        failures = []
        if any(command["status"] != "passed" for command in commands):
            failures.append("SwiftLint version or strict lint command failed")
        if diagnostics["warning_count"] or diagnostics["error_count"]:
            failures.append("SwiftLint strict reported violations")
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=self._artifacts_from_commands(commands),
            summary={
                "strict": True,
                **diagnostics,
            },
            passed=not failures,
            failures=failures,
        )

    def _release_lock_unit_suite(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        command = self._execute_command(
            run_root=run_root,
            command_index=1,
            argv=(
                self.python_executable,
                "-m",
                "unittest",
                *RELEASE_LOCK_TEST_MODULES,
            ),
            log_artifact_id="logs/release-lock-unit-suite.log",
        )
        text = _read_regular(
            _safe_child(run_root, str(command["log_binding"]["artifact_id"]))
        ).decode("utf-8", errors="replace")
        failures = []
        try:
            counts = parse_unittest_output(text)
        except G06VerificationError as error:
            counts = {"parser_error": str(error)}
            failures.append(str(error))
        if command["status"] != "passed":
            failures.append("release-lock unit command failed")
        if "parser_error" not in counts and not _test_counts_pass(counts):
            failures.append("release-lock unit tests failed or were skipped")
        return self._finish_group(
            started=started,
            commands=(command,),
            artifacts=self._artifacts_from_commands((command,)),
            summary={
                "modules": [
                    *RELEASE_LOCK_TEST_MODULES,
                ],
                "test_counts": counts,
            },
            passed=not failures,
            failures=failures,
        )

    @staticmethod
    def _not_run(prior_failure: str) -> GroupResult:
        now = _utc_now()
        return GroupResult(
            status="not_run",
            started_utc=now,
            finished_utc=now,
            commands=(),
            artifacts=(),
            summary={"prior_failed_evidence_id": prior_failure},
            failure_reason=f"not run because {prior_failure} failed",
        )

    @staticmethod
    def _evidence_document(
        identifier: str,
        ordinal: int,
        result: GroupResult,
    ) -> Mapping[str, object]:
        artifact_ids = [binding.get("artifact_id") for binding in result.artifacts]
        command_logs = [
            command.get("log_binding") for command in result.commands
        ]
        if (
            result.status == "passed"
            and (
                not result.commands
                or any(command.get("status") != "passed" for command in result.commands)
                or result.failure_reason is not None
            )
        ):
            raise G06VerificationError("passed evidence has incomplete commands")
        if result.status != "passed" and not result.failure_reason:
            raise G06VerificationError("non-passing evidence lacks a failure reason")
        if (
            len(artifact_ids) != len(set(artifact_ids))
            or any(binding not in result.artifacts for binding in command_logs)
        ):
            raise G06VerificationError("evidence artifact bindings are duplicated or incomplete")
        document: Dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_g06_test_evidence",
            "evidence_id": identifier,
            "evidence_ordinal": ordinal,
            "status": result.status,
            "started_utc": result.started_utc,
            "finished_utc": result.finished_utc,
            "commands": [dict(value) for value in result.commands],
            "artifacts": [dict(value) for value in result.artifacts],
            "summary": dict(result.summary),
            "failure_reason": result.failure_reason,
            "holdout_accessed": False,
            "verifier_source": _repository_source_binding(VERIFIER_SOURCE_PATH),
            "evidence_schema": _repository_source_binding(SCHEMA_PATH),
        }
        document["evidence_sha256"] = canonical_sha256(document)
        validate_schema(document, SCHEMA_PATH)
        return document

    def _internal_failure_result(
        self,
        *,
        run_root: Path,
        identifier: str,
        started: str,
        error: BaseException,
    ) -> GroupResult:
        artifact_id = f"logs/{identifier}-internal-error.log"
        path = _safe_child(run_root, artifact_id)
        payload = (
            "".join(traceback.format_exception(type(error), error, error.__traceback__))
        ).encode("utf-8", errors="replace")
        _write_new(path, payload)
        binding = _file_binding(
            path,
            run_root=run_root,
            artifact_kind="internal_error",
        )
        return GroupResult(
            status="failed",
            started_utc=started,
            finished_utc=_utc_now(),
            commands=(),
            artifacts=(binding,),
            summary={"internal_error_type": type(error).__name__},
            failure_reason=f"{type(error).__name__}: {error}",
        )

    def _default_executors(self) -> Mapping[str, Callable[[Path], GroupResult]]:
        return {
            "python_calibration_full_suite": self._python_full_suite,
            "xcode_native_integration": self._xcode_native_integration,
            "xcode_release_runtime": self._xcode_release_runtime,
            "swiftlint": self._swiftlint,
            "release_lock_unit_suite": self._release_lock_unit_suite,
        }

    def _verify_published(
        self,
        root: Path,
    ) -> Tuple[Tuple[str, Path], ...]:
        json_paths = sorted(path.name for path in root.glob("*.json"))
        expected_names = [f"{identifier}.json" for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS]
        if json_paths != sorted(expected_names):
            raise G06VerificationError("published G06 evidence file set differs")
        result = []
        for ordinal, identifier in enumerate(REQUIRED_G06_TEST_EVIDENCE_IDS, 1):
            path = root / f"{identifier}.json"
            document = _read_json(path)
            unhashed = dict(document)
            declared = unhashed.pop("evidence_sha256", None)
            if (
                document.get("evidence_id") != identifier
                or document.get("evidence_ordinal") != ordinal
                or declared != canonical_sha256(unhashed)
            ):
                raise G06VerificationError("published G06 evidence identity changed")
            validate_schema(document, SCHEMA_PATH)
            artifacts = document.get("artifacts")
            assert isinstance(artifacts, list)
            for binding in artifacts:
                assert isinstance(binding, dict)
                artifact_id = binding.get("artifact_id")
                digest_mode = binding.get("digest_mode")
                artifact_kind = binding.get("artifact_kind")
                if not isinstance(artifact_id, str) or not isinstance(
                    artifact_kind, str
                ):
                    raise G06VerificationError("artifact binding identity is invalid")
                artifact_path = _safe_child(root, artifact_id)
                if digest_mode == "file_sha256":
                    recomputed = _file_binding(
                        artifact_path,
                        run_root=root,
                        artifact_kind=artifact_kind,
                    )
                elif digest_mode == "canonical_tree_manifest_sha256":
                    recomputed = _tree_binding(
                        artifact_path,
                        run_root=root,
                        artifact_kind=artifact_kind,
                    )
                else:
                    raise G06VerificationError("artifact binding digest mode is invalid")
                if binding != recomputed:
                    raise G06VerificationError(
                        f"artifact binding changed: {artifact_id}"
                    )
            result.append((identifier, path))
        return tuple(result)

    def run(self) -> VerificationRunResult:
        self.output_root.mkdir(parents=True, exist_ok=True)
        if self.output_root.is_symlink() or not self.output_root.is_dir():
            raise G06VerificationError("output root is symbolic or not a directory")
        final = self.output_root / self.run_id
        partial = self.output_root / f".{self.run_id}.partial"
        failed = self.output_root / f"{self.run_id}.failed"
        if any(path.exists() or path.is_symlink() for path in (final, partial, failed)):
            raise G06VerificationError("run destination already exists")
        partial.mkdir(mode=0o700)
        defaults = self._default_executors()
        executors = {
            identifier: self.group_executors.get(identifier, defaults[identifier])
            for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
        }
        prior_failure = None
        statuses = []
        for ordinal, identifier in enumerate(REQUIRED_G06_TEST_EVIDENCE_IDS, 1):
            if prior_failure is not None:
                result = self._not_run(prior_failure)
            else:
                started = _utc_now()
                try:
                    result = executors[identifier](partial)
                except BaseException as error:
                    result = self._internal_failure_result(
                        run_root=partial,
                        identifier=identifier,
                        started=started,
                        error=error,
                    )
                if result.status != "passed":
                    prior_failure = identifier
            if result.status not in {"passed", "failed", "not_run"}:
                raise G06VerificationError("group executor returned an invalid status")
            document = self._evidence_document(identifier, ordinal, result)
            _write_json_new(partial / f"{identifier}.json", document)
            statuses.append(result.status)
        passed = statuses == ["passed"] * len(REQUIRED_G06_TEST_EVIDENCE_IDS)
        destination = final if passed else failed
        self._verify_published(partial)
        if destination.exists() or destination.is_symlink():
            raise G06VerificationError("publication destination appeared during run")
        partial.rename(destination)
        descriptor = os.open(self.output_root, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        evidence_paths = self._verify_published(destination)
        return VerificationRunResult(
            status="passed" if passed else "failed",
            path=destination,
            evidence_paths=evidence_paths,
        )


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run both Python suites, focused Xcode Debug/Release verification, "
            "SwiftLint strict, and release-lock tests without opening holdout data."
        )
    )
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--project", default="Mirmir.xcodeproj")
    parser.add_argument("--scheme", default="Mirmir")
    parser.add_argument("--destination", default="platform=macOS,arch=arm64")
    parser.add_argument("--python-executable", default=sys.executable)
    parser.add_argument("--swiftlint-executable", default="swiftlint")
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    return parser.parse_args()


def main() -> int:
    arguments = _arguments()
    try:
        result = G06VerificationRunner(
            repository_root=arguments.repository_root,
            output_root=arguments.output_root,
            run_id=arguments.run_id,
            project=arguments.project,
            scheme=arguments.scheme,
            destination=arguments.destination,
            python_executable=arguments.python_executable,
            swiftlint_executable=arguments.swiftlint_executable,
            timeout_seconds=arguments.timeout_seconds,
        ).run()
    except (G06VerificationError, OSError, ValueError) as error:
        print(f"G06 verification setup failed: {error}", file=sys.stderr)
        return 2
    output = {
        "schema_version": "1.0.0",
        "status": result.status,
        "run_root": str(result.path.resolve(strict=True)),
        "holdout_accessed": False,
        "ordered_test_evidence": [
            {"id": identifier, "path": str(path.resolve(strict=True))}
            for identifier, path in result.evidence_paths
        ],
        "run_p06_production_calibration_arguments": [
            value
            for identifier, path in result.evidence_paths
            for value in ("--test-evidence", f"{identifier}={path.resolve(strict=True)}")
        ],
    }
    print(
        json.dumps(
            output,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0 if result.status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
