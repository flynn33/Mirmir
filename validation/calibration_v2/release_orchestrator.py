"""Single-transaction publisher for the immutable P06 spatial release lock."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import subprocess
import sys
from typing import Mapping

from validation.calibration_v2.native_adapter.factory import (
    NativeSwiftBuilder,
    P00NativeBuilder,
)
from validation.calibration_v2.macos_code_identity import static_code_identity
from validation.calibration_v2.release_lock import (
    ReleaseLockError,
    build_configuration_lock_from_bindings,
    build_locked_quality_policy,
    build_lut_manifest,
    build_native_parity_manifest,
    build_p06_release_bundle_manifest,
    locked_compiler_input_document,
    locked_metric_policy_document,
    operator_bank_document,
    route_analysis_grid_selection_document,
    validate_dispatch_measurement_document,
    validate_p06_release_bundle_manifest,
    video_mapping_document,
)
from validation.calibration_v2.release_evidence import (
    IMPLEMENTATION_IDS,
    NATIVE_INTEGRATION_TEST_IDS,
    P00_FAILURE_ID,
    PYTHON_TEST_RUNNER_IDS,
    RELEASE_LOCK_TEST_MODULES,
    RELEASE_RUNTIME_TEST_IDS,
    SELECTED_CONTROL_IDS,
    SUPPORT_TREE_IDS,
    TEST_EVIDENCE_IDS,
    actionable_diagnostic_counts,
    publish_p06_evidence_closure,
)
from validation.quality.src.mirmir_quality.holdout import HashBinding
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
    validate_schema,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
SCHEMAS_ROOT = CALIBRATION_ROOT / "schemas"
_PYTHON_ORACLE_SOURCES = (
    "validation/calibration_v2/reference/lut_oracle.py",
    "validation/calibration_v2/tools/compile_reference_luts.py",
    "validation/calibration_v2/contracts/lut-binary-contract-v1.json",
    "validation/calibration_v2/schemas/locked-compiler-input-v1.schema.json",
)
REQUIRED_G06_TEST_EVIDENCE_IDS = TEST_EVIDENCE_IDS
G06_TEST_EVIDENCE_SCHEMA = SCHEMAS_ROOT / "g06-test-evidence-v1.schema.json"


class P06ReleaseOrchestrationError(ReleaseLockError):
    """The selected calibration run could not be published as one release lock."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _read_regular(path: Path) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise P06ReleaseOrchestrationError(f"required file is absent: {path}") from error
    if path.is_symlink() or not stat.S_ISREG(before.st_mode):
        raise P06ReleaseOrchestrationError(f"required path is not a regular file: {path}")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise P06ReleaseOrchestrationError("file changed while opening")
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
        raise P06ReleaseOrchestrationError("file changed while reading")
    return b"".join(chunks)


def _read_json(path: Path) -> Mapping[str, object]:
    payload = _read_regular(path)
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                P06ReleaseOrchestrationError(f"non-finite JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise P06ReleaseOrchestrationError(f"invalid JSON file: {path}") from error
    if not isinstance(value, dict):
        raise P06ReleaseOrchestrationError(f"JSON top level is not an object: {path}")
    return value


def _reject_duplicate_pairs(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise P06ReleaseOrchestrationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _write_new(path: Path, payload: bytes, *, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o700 if executable else 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("release publication made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if _read_regular(path) != payload:
        raise P06ReleaseOrchestrationError(f"published bytes changed: {path}")


def _write_json(path: Path, document: Mapping[str, object]) -> None:
    _write_new(path, canonical_json_bytes(document) + b"\n")


def _copy_new(source: Path, destination: Path, *, executable: bool = False) -> None:
    _write_new(destination, _read_regular(source), executable=executable)


def _safe_evidence_id(identifier: str) -> str:
    if (
        not isinstance(identifier, str)
        or not identifier
        or len(identifier) > 96
        or identifier[0] not in "abcdefghijklmnopqrstuvwxyz0123456789"
        or any(
            character not in "abcdefghijklmnopqrstuvwxyz0123456789._-"
            for character in identifier
        )
    ):
        raise P06ReleaseOrchestrationError("evidence ID is unsafe")
    return identifier


def _copy_evidence_input(
    *,
    identifier: str,
    source: Path,
    release_root: Path,
    category: str,
) -> Path:
    identifier = _safe_evidence_id(identifier)
    source = source.resolve(strict=True)
    destination_root = release_root / category / identifier
    if source.is_symlink():
        raise P06ReleaseOrchestrationError("evidence input is symbolic")
    if source.is_file():
        destination = destination_root / source.name
        _copy_new(source, destination)
        return destination
    if not source.is_dir():
        raise P06ReleaseOrchestrationError("evidence input is not a file or directory")
    for current_name, directory_names, file_names in os.walk(
        source,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        relative = current.relative_to(source)
        target = destination_root.joinpath(*relative.parts)
        target.mkdir(parents=True, exist_ok=True)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            if (current / name).is_symlink():
                raise P06ReleaseOrchestrationError(
                    "evidence directory contains a symbolic link"
                )
        for name in file_names:
            candidate = current / name
            if candidate.is_symlink():
                raise P06ReleaseOrchestrationError(
                    "evidence directory contains a symbolic file"
                )
            _copy_new(candidate, target / name)
    return destination_root


def _g06_tree_binding(
    path: Path,
    *,
    artifact_id: str,
    artifact_kind: str,
) -> Mapping[str, object]:
    if path.is_symlink() or not path.is_dir():
        raise P06ReleaseOrchestrationError(
            f"G06 tree artifact is absent or symbolic: {artifact_id}"
        )
    root = path.resolve(strict=True)
    rows: list[Mapping[str, object]] = []
    for current_name, directory_names, file_names in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            if (current / name).is_symlink():
                raise P06ReleaseOrchestrationError(
                    f"G06 tree artifact contains a symbolic directory: {artifact_id}"
                )
        for name in file_names:
            candidate = current / name
            if candidate.is_symlink():
                raise P06ReleaseOrchestrationError(
                    f"G06 tree artifact contains a symbolic file: {artifact_id}"
                )
            payload = _read_regular(candidate)
            rows.append(
                {
                    "path": candidate.relative_to(root).as_posix(),
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
    rows.sort(key=lambda row: str(row["path"]))
    if not rows:
        raise P06ReleaseOrchestrationError(
            f"G06 tree artifact is empty: {artifact_id}"
        )
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "canonical_tree_manifest_sha256",
        "sha256": _sha256(canonical_json_bytes(rows)),
        "size_bytes": sum(int(row["size_bytes"]) for row in rows),
        "file_count": len(rows),
    }


def _g06_file_binding(
    path: Path,
    *,
    artifact_id: str,
    artifact_kind: str,
) -> Mapping[str, object]:
    payload = _read_regular(path)
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "file_sha256",
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
        "file_count": 1,
    }


def _g06_source_binding(path: Path, repository_path: str) -> Mapping[str, object]:
    payload = _read_regular(path)
    return {
        "repository_path": repository_path,
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _verify_g06_artifact_binding(
    *,
    run_root: Path,
    binding: Mapping[str, object],
) -> Path:
    artifact_id = binding.get("artifact_id")
    artifact_kind = binding.get("artifact_kind")
    if not isinstance(artifact_id, str) or not isinstance(artifact_kind, str):
        raise P06ReleaseOrchestrationError("G06 artifact identity is invalid")
    try:
        path = _safe_child(run_root, artifact_id)
        lexical_path = run_root.resolve(strict=True).joinpath(
            *PurePosixPath(artifact_id).parts
        )
        _reject_symlinked_ancestors(lexical_path)
    except (OSError, ValueError) as error:
        raise P06ReleaseOrchestrationError(
            f"G06 artifact path is unavailable: {artifact_id}"
        ) from error
    _reject_symlinked_ancestors(path)
    digest_mode = binding.get("digest_mode")
    if digest_mode == "file_sha256":
        reopened = _g06_file_binding(
            path,
            artifact_id=artifact_id,
            artifact_kind=artifact_kind,
        )
    elif digest_mode == "canonical_tree_manifest_sha256":
        reopened = _g06_tree_binding(
            path,
            artifact_id=artifact_id,
            artifact_kind=artifact_kind,
        )
    else:
        raise P06ReleaseOrchestrationError(
            f"G06 artifact digest mode is invalid: {artifact_id}"
        )
    if reopened != dict(binding):
        raise P06ReleaseOrchestrationError(
            f"G06 artifact binding changed: {artifact_id}"
        )
    return path


def _g06_diagnostic_counts(text: str) -> Mapping[str, int]:
    return actionable_diagnostic_counts(text)


def _g06_parse_unittest_log(text: str) -> Mapping[str, object]:
    matches = list(re.finditer(r"(?m)^Ran ([0-9]+) tests? in .+$", text))
    terminal = next(
        (line.strip() for line in reversed(text.splitlines()) if line.strip()),
        "",
    )
    if not matches or terminal != "OK":
        raise P06ReleaseOrchestrationError(
            "G06 unittest log lacks a passing terminal summary"
        )
    if re.search(r"(?m)^FAILED(?: |$)", text):
        raise P06ReleaseOrchestrationError("G06 unittest log reports failure")
    total = int(matches[-1].group(1))
    if total <= 0:
        raise P06ReleaseOrchestrationError("G06 unittest count is zero")
    return {
        "test_count": total,
        "passed": total,
        "failed": 0,
        "errors": 0,
        "skipped": 0,
        "expected_failures": 0,
        "unexpected_successes": 0,
        "terminal_status": "passed",
    }


def _g06_parse_pytest_log(text: str) -> Mapping[str, object]:
    terminal = next(
        (line.strip() for line in reversed(text.splitlines()) if line.strip()),
        "",
    )
    match = re.fullmatch(r"([0-9]+) passed in .+", terminal)
    if match is None:
        raise P06ReleaseOrchestrationError(
            "G06 pytest log lacks an all-passed terminal summary"
        )
    total = int(match.group(1))
    if total <= 0:
        raise P06ReleaseOrchestrationError("G06 pytest count is zero")
    return {
        "test_count": total,
        "passed": total,
        "failed": 0,
        "skipped": 0,
        "errors": 0,
        "xfailed": 0,
        "xpassed": 0,
        "deselected": 0,
        "terminal_status": "passed",
    }


def _g06_parse_xcresult_summary(document: Mapping[str, object]) -> Mapping[str, object]:
    names = (
        "totalTestCount",
        "passedTests",
        "failedTests",
        "skippedTests",
        "expectedFailures",
    )
    values = []
    for name in names:
        value = document.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise P06ReleaseOrchestrationError(
                f"G06 xcresult count is invalid: {name}"
            )
        values.append(value)
    total, passed, failed, skipped, expected = values
    if (
        total <= 0
        or passed != total
        or failed != 0
        or skipped != 0
        or expected != 0
        or document.get("result") != "Passed"
    ):
        raise P06ReleaseOrchestrationError(
            "G06 xcresult summary is not strictly passing"
        )
    return {
        "test_count": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "expected_failures": expected,
        "terminal_status": "passed",
    }


def _g06_text_artifact(
    run_root: Path,
    binding_by_id: Mapping[str, Mapping[str, object]],
    artifact_id: str,
) -> str:
    binding = binding_by_id.get(artifact_id)
    if (
        binding is None
        or binding.get("digest_mode") != "file_sha256"
        or binding.get("artifact_kind")
        not in {"command_log", "xcresult_summary"}
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 required log binding differs: {artifact_id}"
        )
    return _read_regular(_safe_child(run_root, artifact_id)).decode(
        "utf-8",
        errors="replace",
    )


def _g06_require_artifacts(
    bindings: tuple[Mapping[str, object], ...],
    expected: tuple[tuple[str, str, str], ...],
) -> None:
    actual = tuple(
        (
            str(binding.get("artifact_id")),
            str(binding.get("artifact_kind")),
            str(binding.get("digest_mode")),
        )
        for binding in bindings
    )
    if actual != expected:
        raise P06ReleaseOrchestrationError("G06 group artifact closure differs")


def _g06_require_path_suffix(value: object, suffix: tuple[str, ...]) -> str:
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise P06ReleaseOrchestrationError("G06 command path is not absolute")
    if tuple(Path(value).parts[-len(suffix) :]) != suffix:
        raise P06ReleaseOrchestrationError("G06 command path suffix differs")
    return value


def _g06_xcode_test_argv(
    *,
    configuration: str,
    derived: str,
    result_bundle: str,
    tests: tuple[str, ...],
    clean: bool,
) -> list[str]:
    return [
        "xcodebuild",
        "-project",
        "Mirmir.xcodeproj",
        "-scheme",
        "Mirmir",
        "-configuration",
        configuration,
        "-destination",
        "platform=macOS,arch=arm64",
        "-derivedDataPath",
        derived,
        "-resultBundlePath",
        result_bundle,
        "-enableCodeCoverage",
        "YES",
        "-parallel-testing-enabled",
        "NO",
        "CODE_SIGNING_ALLOWED=NO",
        *(("ENABLE_TESTABILITY=YES",) if configuration == "Release" else ()),
        *(f"-only-testing:MirmirTests/{name}" for name in tests),
        *(("clean", "test") if clean else ("test",)),
    ]


def _g06_require_command(
    command: Mapping[str, object],
    *,
    argv: list[str],
    log_id: str,
) -> None:
    log_binding = command.get("log_binding")
    if (
        command.get("argv") != argv
        or command.get("command_text") != shlex.join(argv)
        or not isinstance(log_binding, dict)
        or log_binding.get("artifact_id") != log_id
    ):
        raise P06ReleaseOrchestrationError("G06 command contract differs")


def _validate_g06_group_semantics(
    *,
    identifier: str,
    document: Mapping[str, object],
    run_root: Path,
    bindings: tuple[Mapping[str, object], ...],
) -> None:
    commands = document["commands"]
    summary = document["summary"]
    assert isinstance(commands, list)
    assert isinstance(summary, dict)
    expected_command_counts = {
        TEST_EVIDENCE_IDS[0]: 2,
        TEST_EVIDENCE_IDS[1]: 2,
        TEST_EVIDENCE_IDS[2]: 3,
        TEST_EVIDENCE_IDS[3]: 2,
        TEST_EVIDENCE_IDS[4]: 1,
    }
    if len(commands) != expected_command_counts.get(identifier):
        raise P06ReleaseOrchestrationError("G06 group command count differs")
    binding_by_id = {
        str(binding["artifact_id"]): binding for binding in bindings
    }

    if identifier == TEST_EVIDENCE_IDS[0]:
        expected_artifacts = (
            ("logs/python-unittest-discovery.log", "command_log", "file_sha256"),
            ("logs/python-pytest.log", "command_log", "file_sha256"),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        python = commands[0]["argv"][0]
        unittest_argv = [
            python,
            "-m",
            "unittest",
            "discover",
            "-s",
            "validation/calibration_v2/tests",
            "-p",
            "test_*.py",
        ]
        pytest_argv = [
            python,
            "-m",
            "pytest",
            "-q",
            "validation/calibration_v2/tests",
        ]
        _g06_require_command(
            commands[0],
            argv=unittest_argv,
            log_id=expected_artifacts[0][0],
        )
        _g06_require_command(
            commands[1],
            argv=pytest_argv,
            log_id=expected_artifacts[1][0],
        )
        counts = (
            _g06_parse_unittest_log(
                _g06_text_artifact(run_root, binding_by_id, expected_artifacts[0][0])
            ),
            _g06_parse_pytest_log(
                _g06_text_artifact(run_root, binding_by_id, expected_artifacts[1][0])
            ),
        )
        expected_summary = {
            "runners": [
                {"runner": runner, "counts": result}
                for runner, result in zip(PYTHON_TEST_RUNNER_IDS, counts)
            ],
            "aggregate_executed_test_count": sum(
                int(result["test_count"]) for result in counts
            ),
            "required_runner_order": list(PYTHON_TEST_RUNNER_IDS),
        }
        if summary != expected_summary:
            raise P06ReleaseOrchestrationError("G06 Python summary differs from logs")
        return

    if identifier == TEST_EVIDENCE_IDS[1]:
        expected_artifacts = (
            ("logs/xcode-native-integration.log", "command_log", "file_sha256"),
            (
                "artifacts/native-integration-xcresult-summary.log",
                "xcresult_summary",
                "file_sha256",
            ),
            (
                "artifacts/native-integration.xcresult",
                "xcresult",
                "canonical_tree_manifest_sha256",
            ),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        first_argv = commands[0]["argv"]
        derived = _g06_require_path_suffix(
            first_argv[10],
            ("build", "native-integration-derived-data"),
        )
        result_bundle = _g06_require_path_suffix(
            first_argv[12],
            ("artifacts", "native-integration.xcresult"),
        )
        _g06_require_command(
            commands[0],
            argv=_g06_xcode_test_argv(
                configuration="Debug",
                derived=derived,
                result_bundle=result_bundle,
                tests=NATIVE_INTEGRATION_TEST_IDS,
                clean=True,
            ),
            log_id=expected_artifacts[0][0],
        )
        summary_argv = [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle,
        ]
        _g06_require_command(
            commands[1],
            argv=summary_argv,
            log_id=expected_artifacts[1][0],
        )
        diagnostics = _g06_diagnostic_counts(
            _g06_text_artifact(run_root, binding_by_id, expected_artifacts[0][0])
        )
        if diagnostics["error_count"] != 0:
            raise P06ReleaseOrchestrationError("G06 native log contains errors")
        counts = _g06_parse_xcresult_summary(
            _read_json(_safe_child(run_root, expected_artifacts[1][0]))
        )
        expected_summary = {
            "configuration": "Debug",
            "scheme": "Mirmir",
            "destination": "platform=macOS,arch=arm64",
            "only_testing": list(NATIVE_INTEGRATION_TEST_IDS),
            "test_counts": counts,
            **diagnostics,
        }
        if summary != expected_summary:
            raise P06ReleaseOrchestrationError("G06 native summary differs from logs")
        return

    if identifier == TEST_EVIDENCE_IDS[2]:
        expected_artifacts = (
            ("logs/xcode-release-build.log", "command_log", "file_sha256"),
            ("logs/xcode-release-runtime.log", "command_log", "file_sha256"),
            (
                "artifacts/release-runtime-xcresult-summary.log",
                "xcresult_summary",
                "file_sha256",
            ),
            (
                "artifacts/release-runtime.xcresult",
                "xcresult",
                "canonical_tree_manifest_sha256",
            ),
            (
                "build/release-derived-data/Build/Products/Release/"
                "Mirmir.app/Contents/MacOS/Mirmir",
                "release_product",
                "file_sha256",
            ),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        build_argv = commands[0]["argv"]
        derived = _g06_require_path_suffix(
            build_argv[10],
            ("build", "release-derived-data"),
        )
        expected_build_argv = [
            "xcodebuild",
            "-project",
            "Mirmir.xcodeproj",
            "-scheme",
            "Mirmir",
            "-configuration",
            "Release",
            "-destination",
            "platform=macOS,arch=arm64",
            "-derivedDataPath",
            derived,
            "CODE_SIGNING_ALLOWED=NO",
            "ENABLE_TESTABILITY=YES",
            "clean",
            "build",
        ]
        _g06_require_command(
            commands[0],
            argv=expected_build_argv,
            log_id=expected_artifacts[0][0],
        )
        runtime_argv = commands[1]["argv"]
        result_bundle = _g06_require_path_suffix(
            runtime_argv[12],
            ("artifacts", "release-runtime.xcresult"),
        )
        _g06_require_command(
            commands[1],
            argv=_g06_xcode_test_argv(
                configuration="Release",
                derived=derived,
                result_bundle=result_bundle,
                tests=RELEASE_RUNTIME_TEST_IDS,
                clean=False,
            ),
            log_id=expected_artifacts[1][0],
        )
        summary_argv = [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle,
        ]
        _g06_require_command(
            commands[2],
            argv=summary_argv,
            log_id=expected_artifacts[2][0],
        )
        build_log = _g06_text_artifact(
            run_root,
            binding_by_id,
            expected_artifacts[0][0],
        )
        runtime_log = _g06_text_artifact(
            run_root,
            binding_by_id,
            expected_artifacts[1][0],
        )
        build_diagnostics = _g06_diagnostic_counts(build_log)
        runtime_diagnostics = _g06_diagnostic_counts(runtime_log)
        if (
            build_diagnostics != {"warning_count": 0, "error_count": 0}
            or runtime_diagnostics != {"warning_count": 0, "error_count": 0}
            or "** BUILD SUCCEEDED **" not in build_log
        ):
            raise P06ReleaseOrchestrationError(
                "G06 Release logs are not zero-warning passing logs"
            )
        counts = _g06_parse_xcresult_summary(
            _read_json(_safe_child(run_root, expected_artifacts[2][0]))
        )
        expected_summary = {
            "configuration": "Release",
            "scheme": "Mirmir",
            "destination": "platform=macOS,arch=arm64",
            "only_testing": list(RELEASE_RUNTIME_TEST_IDS),
            "build_warning_count": 0,
            "build_error_count": 0,
            "runtime_warning_count": 0,
            "runtime_error_count": 0,
            "test_counts": counts,
        }
        if summary != expected_summary:
            raise P06ReleaseOrchestrationError("G06 Release summary differs from logs")
        return

    if identifier == TEST_EVIDENCE_IDS[3]:
        expected_artifacts = (
            ("logs/swiftlint-version.log", "command_log", "file_sha256"),
            ("logs/swiftlint-strict.log", "command_log", "file_sha256"),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        executable = commands[0]["argv"][0]
        _g06_require_command(
            commands[0],
            argv=[executable, "version"],
            log_id=expected_artifacts[0][0],
        )
        _g06_require_command(
            commands[1],
            argv=[executable, "lint", "--strict", "--config", ".swiftlint.yml"],
            log_id=expected_artifacts[1][0],
        )
        diagnostics = _g06_diagnostic_counts(
            _g06_text_artifact(run_root, binding_by_id, expected_artifacts[1][0])
        )
        if diagnostics != {"warning_count": 0, "error_count": 0}:
            raise P06ReleaseOrchestrationError("G06 SwiftLint log is not clean")
        if summary != {"strict": True, **diagnostics}:
            raise P06ReleaseOrchestrationError("G06 SwiftLint summary differs")
        return

    if identifier == TEST_EVIDENCE_IDS[4]:
        expected_artifacts = (
            ("logs/release-lock-unit-suite.log", "command_log", "file_sha256"),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        python = commands[0]["argv"][0]
        argv = [python, "-m", "unittest", *RELEASE_LOCK_TEST_MODULES]
        _g06_require_command(
            commands[0],
            argv=argv,
            log_id=expected_artifacts[0][0],
        )
        counts = _g06_parse_unittest_log(
            _g06_text_artifact(run_root, binding_by_id, expected_artifacts[0][0])
        )
        expected_summary = {
            "modules": list(RELEASE_LOCK_TEST_MODULES),
            "test_counts": counts,
        }
        if summary != expected_summary:
            raise P06ReleaseOrchestrationError(
                "G06 release-lock summary differs from log"
            )
        return

    raise P06ReleaseOrchestrationError("G06 evidence ID has no semantic contract")


def _validate_g06_evidence_document(
    *,
    identifier: str,
    ordinal: int,
    source: Path,
    run_root: Path,
) -> tuple[Mapping[str, object], tuple[Mapping[str, object], ...]]:
    if source.name != f"{identifier}.json":
        raise P06ReleaseOrchestrationError("G06 evidence filename differs")
    document = _read_json(source)
    try:
        validate_schema(document, G06_TEST_EVIDENCE_SCHEMA)
    except ValueError as error:
        raise P06ReleaseOrchestrationError(
            f"G06 evidence schema validation failed: {identifier}"
        ) from error
    unhashed = dict(document)
    declared_sha256 = unhashed.pop("evidence_sha256", None)
    if declared_sha256 != _sha256(canonical_json_bytes(unhashed)):
        raise P06ReleaseOrchestrationError(
            f"G06 evidence self-hash differs: {identifier}"
        )
    expected_verifier_source = _g06_source_binding(
        CALIBRATION_ROOT / "tools/run_g06_verification.py",
        "validation/calibration_v2/tools/run_g06_verification.py",
    )
    expected_schema = _g06_source_binding(
        G06_TEST_EVIDENCE_SCHEMA,
        "validation/calibration_v2/schemas/g06-test-evidence-v1.schema.json",
    )
    if (
        document.get("verifier_source") != expected_verifier_source
        or document.get("evidence_schema") != expected_schema
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 verifier source or schema binding differs: {identifier}"
        )
    if (
        document.get("evidence_id") != identifier
        or document.get("evidence_ordinal") != ordinal
        or document.get("status") != "passed"
        or document.get("failure_reason") is not None
        or document.get("holdout_accessed") is not False
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 evidence identity or passing status differs: {identifier}"
        )
    commands = document.get("commands")
    artifacts = document.get("artifacts")
    if not isinstance(commands, list) or not commands:
        raise P06ReleaseOrchestrationError(
            f"G06 passing evidence has no commands: {identifier}"
        )
    if not isinstance(artifacts, list) or not artifacts:
        raise P06ReleaseOrchestrationError(
            f"G06 passing evidence has no artifacts: {identifier}"
        )
    if [command.get("command_index") for command in commands] != list(
        range(1, len(commands) + 1)
    ) or any(
        command.get("status") != "passed"
        or command.get("exit_code") != 0
        or command.get("timed_out") is not False
        for command in commands
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 passing evidence contains a non-passing command: {identifier}"
        )
    bindings: list[Mapping[str, object]] = []
    binding_by_id: dict[str, Mapping[str, object]] = {}
    artifact_paths: list[PurePosixPath] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise P06ReleaseOrchestrationError("G06 artifact binding is invalid")
        artifact_id = artifact.get("artifact_id")
        if not isinstance(artifact_id, str):
            raise P06ReleaseOrchestrationError("G06 artifact ID is invalid")
        relative = PurePosixPath(artifact_id)
        _safe_child(run_root, artifact_id)
        if artifact_id in binding_by_id:
            raise P06ReleaseOrchestrationError(
                f"G06 artifact binding is duplicated: {artifact_id}"
            )
        evidence_relative = PurePosixPath(source.name)
        if (
            relative == evidence_relative
            or evidence_relative in relative.parents
            or relative in evidence_relative.parents
        ) or any(
            relative == prior
            or relative in prior.parents
            or prior in relative.parents
            for prior in artifact_paths
        ):
            raise P06ReleaseOrchestrationError(
                f"G06 artifact paths overlap: {artifact_id}"
            )
        binding = dict(artifact)
        binding_by_id[artifact_id] = binding
        artifact_paths.append(relative)
        bindings.append(binding)
    command_log_ids: list[str] = []
    for command in commands:
        log_binding = command.get("log_binding")
        if not isinstance(log_binding, dict):
            raise P06ReleaseOrchestrationError("G06 command log binding is invalid")
        artifact_id = log_binding.get("artifact_id")
        if (
            not isinstance(artifact_id, str)
            or binding_by_id.get(artifact_id) != log_binding
            or artifact_id in command_log_ids
            or log_binding.get("artifact_kind")
            not in {"command_log", "xcresult_summary"}
            or log_binding.get("digest_mode") != "file_sha256"
        ):
            raise P06ReleaseOrchestrationError(
                f"G06 command log closure differs: {identifier}"
            )
        command_log_ids.append(artifact_id)
    for binding in bindings:
        _verify_g06_artifact_binding(run_root=run_root, binding=binding)
    _validate_g06_group_semantics(
        identifier=identifier,
        document=document,
        run_root=run_root,
        bindings=tuple(bindings),
    )
    return document, tuple(bindings)


def _copy_g06_tree(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise P06ReleaseOrchestrationError(
            "G06 source tree is absent or symbolic"
        )
    if destination.exists() or destination.is_symlink():
        raise P06ReleaseOrchestrationError("G06 tree destination collides")
    destination.mkdir(parents=True, mode=0o700)
    for current_name, directory_names, file_names in os.walk(
        source,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        relative = current.relative_to(source)
        target = destination.joinpath(*relative.parts)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            child = current / name
            if child.is_symlink():
                raise P06ReleaseOrchestrationError(
                    "G06 source tree contains a symbolic directory"
                )
            (target / name).mkdir(mode=0o700)
        for name in file_names:
            child = current / name
            if child.is_symlink():
                raise P06ReleaseOrchestrationError(
                    "G06 source tree contains a symbolic file"
                )
            _copy_new(child, target / name)


def _reject_symlinked_ancestors(path: Path) -> None:
    absolute = Path(os.path.abspath(path))
    for candidate in (absolute, *absolute.parents):
        try:
            mode = os.lstat(candidate).st_mode
        except OSError as error:
            raise P06ReleaseOrchestrationError(
                f"G06 evidence ancestor is unavailable: {candidate}"
            ) from error
        if stat.S_ISLNK(mode):
            raise P06ReleaseOrchestrationError(
                f"G06 evidence run root has a symbolic ancestor: {candidate}"
            )


def _copy_g06_test_evidence_set(
    *,
    test_evidence_paths: Mapping[str, Path],
    release_root: Path,
) -> Mapping[str, Path]:
    """Validate and copy the exact ordered G06 JSONs and declared closure."""

    if tuple(test_evidence_paths) != REQUIRED_G06_TEST_EVIDENCE_IDS:
        raise P06ReleaseOrchestrationError("G06 test evidence set or order differs")
    sources = [(identifier, Path(path)) for identifier, path in test_evidence_paths.items()]
    roots = []
    for identifier, source in sources:
        _reject_symlinked_ancestors(source.parent)
        _read_regular(source)
        if source.parent.is_symlink() or not source.parent.is_dir():
            raise P06ReleaseOrchestrationError("G06 evidence run root is symbolic")
        if source.name != f"{identifier}.json":
            raise P06ReleaseOrchestrationError("G06 evidence filename differs")
        roots.append(source.parent.resolve(strict=True))
    if not roots or any(root != roots[0] for root in roots[1:]):
        raise P06ReleaseOrchestrationError("G06 evidence paths do not share one run root")
    run_root = roots[0]
    expected_json_names = sorted(
        f"{identifier}.json" for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
    )
    actual_json_names = sorted(
        path.name for path in run_root.iterdir() if path.suffix == ".json"
    )
    if actual_json_names != expected_json_names:
        raise P06ReleaseOrchestrationError("G06 evidence root JSON set differs")
    validated = []
    for ordinal, (identifier, source) in enumerate(sources, 1):
        document, bindings = _validate_g06_evidence_document(
            identifier=identifier,
            ordinal=ordinal,
            source=source,
            run_root=run_root,
        )
        validated.append((identifier, source, document, bindings))

    copied: dict[str, Path] = {}
    for identifier, source, document, bindings in validated:
        destination_root = release_root / "test-evidence" / identifier
        if destination_root.exists() or destination_root.is_symlink():
            raise P06ReleaseOrchestrationError("G06 evidence destination collides")
        destination_root.mkdir(parents=True, mode=0o700)
        destination_json = destination_root / source.name
        _copy_new(source, destination_json)
        for binding in bindings:
            artifact_id = str(binding["artifact_id"])
            source_artifact = _verify_g06_artifact_binding(
                run_root=run_root,
                binding=binding,
            )
            destination_artifact = destination_root.joinpath(
                *PurePosixPath(artifact_id).parts
            )
            if binding["digest_mode"] == "file_sha256":
                _copy_new(source_artifact, destination_artifact)
            else:
                _copy_g06_tree(source_artifact, destination_artifact)
            _verify_g06_artifact_binding(
                run_root=destination_root,
                binding=binding,
            )
        if _read_json(destination_json) != document:
            raise P06ReleaseOrchestrationError(
                f"copied G06 evidence JSON changed: {identifier}"
            )
        copied[identifier] = destination_root
    return copied


def _safe_child(root: Path, relative_value: object) -> Path:
    if not isinstance(relative_value, str):
        raise P06ReleaseOrchestrationError("relative artifact path is absent")
    relative = PurePosixPath(relative_value)
    if (
        not relative_value
        or relative_value.startswith("/")
        or "\\" in relative_value
        or relative.as_posix() != relative_value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise P06ReleaseOrchestrationError("relative artifact path is unsafe")
    absolute_root = root.resolve(strict=True)
    candidate = absolute_root.joinpath(*relative.parts)
    resolved_parent = candidate.parent.resolve(strict=True)
    try:
        resolved_parent.relative_to(absolute_root)
    except ValueError as error:
        raise P06ReleaseOrchestrationError("artifact path escapes its root") from error
    return resolved_parent / candidate.name


def _verify_binding(path: Path, binding: Mapping[str, object]) -> None:
    payload = _read_regular(path)
    if (
        binding.get("sha256") != _sha256(payload)
        or binding.get("size_bytes") != len(payload)
    ):
        raise P06ReleaseOrchestrationError("content-addressed binding changed")


def _run(command: tuple[str, ...], *, cwd: Path) -> bytes:
    result = subprocess.run(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise P06ReleaseOrchestrationError(
            "release command failed: "
            + " ".join(command)
            + "\n"
            + result.stderr.decode("utf-8", errors="replace")
        )
    return result.stdout


def _python_source_manifest(repository_root: Path) -> Mapping[str, object]:
    rows = []
    for relative in _PYTHON_ORACLE_SOURCES:
        payload = _read_regular(repository_root.joinpath(*PurePosixPath(relative).parts))
        rows.append(
            {"path": relative, "sha256": _sha256(payload), "size_bytes": len(payload)}
        )
    return {
        "schema_version": "1.0.0",
        "implementation_role": "independent_test_python",
        "python_implementation": sys.implementation.name,
        "python_version": sys.version,
        "sources": rows,
    }


def _configuration_bindings(
    *,
    repository_root: Path,
    release_root: Path,
    p04_quality_root: Path,
    bound_inputs: object,
) -> Mapping[str, HashBinding]:
    record = bound_inputs.record
    return {
        "mapping_sha256": HashBinding(
            path=release_root / "locked-mapping.json", root=release_root
        ),
        "operator_bank_sha256": HashBinding(
            path=release_root / "locked-operator-bank.json", root=release_root
        ),
        "quality_policy_sha256": HashBinding(
            path=release_root / "locked-quality-policy.json", root=release_root
        ),
        "metric_policy_sha256": HashBinding(
            path=release_root / "locked-metric-policy.json", root=release_root
        ),
        "metric_implementation_sha256": HashBinding(
            path=repository_root
            / "validation/quality/src/mirmir_quality/metrics.py",
            root=repository_root,
        ),
        "metric_conformance_sha256": HashBinding(
            path=p04_quality_root
            / "production-run/production-prechange/metric-conformance.json",
            root=p04_quality_root,
        ),
        "degradation_policy_sha256": HashBinding(
            path=repository_root.joinpath(*PurePosixPath(record("degradation_policy")["path"]).parts),
            root=repository_root,
        ),
        "actual_codec_fixture_sha256": HashBinding(
            path=repository_root
            / "validation/quality/fixtures/actual-h264-software-nv12-v1/actual-codec-fixture-lock.json",
            root=repository_root,
        ),
        "actual_codec_evidence_sha256": HashBinding(
            path=p04_quality_root
            / "production-run/production-prechange/actual-codec-evidence.json",
            root=p04_quality_root,
        ),
        "quality_harness_implementation_manifest_sha256": HashBinding(
            path=repository_root.joinpath(
                *PurePosixPath(
                    record("quality_harness_implementation_manifest")["path"]
                ).parts
            ),
            root=repository_root,
            digest_mode="quality_harness_manifest",
        ),
        "compiler_inputs_sha256": HashBinding(
            path=release_root / "locked-compiler-input.json", root=release_root
        ),
        "route_luts_sha256": HashBinding(
            path=release_root / "lut-manifest.json",
            root=release_root,
            digest_mode="manifest_sha256",
        ),
        "corpus_manifest_sha256": HashBinding(
            path=repository_root.joinpath(
                *PurePosixPath(record("corpus_lock")["path"]).parts
            ),
            root=repository_root,
            digest_mode="manifest_sha256",
        ),
    }


def _copy_selected_control_artifacts(
    *,
    run_root: Path,
    release_root: Path,
    selection: Mapping[str, object],
) -> None:
    rows = selection.get("selected_control_selection_artifacts")
    if not isinstance(rows, list) or len(rows) != 3:
        raise P06ReleaseOrchestrationError("selected controls are not exactly three")
    for binding in rows:
        if not isinstance(binding, dict):
            raise P06ReleaseOrchestrationError("selected control binding is invalid")
        source = _safe_child(run_root, binding.get("path"))
        destination = release_root.joinpath(*PurePosixPath(str(binding["path"])).parts)
        _verify_binding(source, binding)
        _copy_new(source, destination)
        _verify_binding(destination, binding)


def _publish_release(
    *,
    repository_root: Path,
    calibration_run_root: Path,
    release_root: Path,
    native_cache_root: Path,
    open_split_root: Path,
    evidence_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    p04_quality_root: Path,
    locked_utc: str,
    bound_inputs: object,
    test_evidence_paths: Mapping[str, Path],
    preserved_failure_paths: Mapping[str, Path],
) -> Mapping[str, object]:
    bound_inputs.verify_unchanged()
    selection_source = calibration_run_root / "selection.json"
    ledger_source = calibration_run_root / "calibration-run-ledger.json"
    selection = _read_json(selection_source)
    ledger = _read_json(ledger_source)
    validate_schema(selection, SCHEMAS_ROOT / "calibration-selection-v1.schema.json")
    validate_schema(ledger, SCHEMAS_ROOT / "calibration-run-ledger-v1.schema.json")
    if (
        selection.get("manifest_sha256") != manifest_sha256(selection)
        or ledger.get("manifest_sha256") != manifest_sha256(ledger)
        or selection.get("input_bundle_sha256") != bound_inputs.bundle_sha256
        or ledger.get("input_bundle_sha256") != bound_inputs.bundle_sha256
    ):
        raise P06ReleaseOrchestrationError("calibration selection or ledger is stale")
    _copy_new(selection_source, release_root / "calibration-selection.json")
    _copy_new(ledger_source, release_root / "calibration-run-ledger.json")
    selection_file_sha256 = _sha256(
        _read_regular(release_root / "calibration-selection.json")
    )

    selected_evaluation_sha256 = str(selection["selected_evaluation_sha256"])
    selected_relative = f"evaluations/{selected_evaluation_sha256}.json"
    selected_source = _safe_child(calibration_run_root, selected_relative)
    selected_payload = _read_regular(selected_source)
    if _sha256(selected_payload) != selected_evaluation_sha256:
        raise P06ReleaseOrchestrationError("selected evaluation content address differs")
    _write_new(release_root / selected_relative, selected_payload)
    evaluation = _read_json(release_root / selected_relative)
    validate_schema(evaluation, SCHEMAS_ROOT / "candidate-evaluation-v1.schema.json")
    _copy_selected_control_artifacts(
        run_root=calibration_run_root,
        release_root=release_root,
        selection=selection,
    )

    live = dict(bound_inputs.live_holdout_preopen_verification)
    if (
        selection.get("live_holdout_preopen_verification") != live
        or ledger.get("live_holdout_preopen_verification") != live
    ):
        raise P06ReleaseOrchestrationError("live preopen verification changed")
    _write_json(release_root / "live-holdout-preopen-verification.json", live)

    dispatch_wrapper = evaluation.get("dispatch_measurement")
    if not isinstance(dispatch_wrapper, dict):
        raise P06ReleaseOrchestrationError("selected dispatch evidence is absent")
    dispatch_bindings = dispatch_wrapper.get("measurement_evidence_bindings")
    dispatch_records = dispatch_wrapper.get("measurement_records")
    if (
        not isinstance(dispatch_bindings, list)
        or len(dispatch_bindings) != 1
        or not isinstance(dispatch_bindings[0], dict)
        or not isinstance(dispatch_records, list)
        or len(dispatch_records) != 1
        or not isinstance(dispatch_records[0], dict)
    ):
        raise P06ReleaseOrchestrationError("selected dispatch evidence is not singular")
    dispatch_source = _safe_child(
        dispatch_measurement_root,
        dispatch_bindings[0].get("path"),
    )
    _verify_binding(dispatch_source, dispatch_bindings[0])
    _copy_new(dispatch_source, release_root / "dispatch-measurement.json")
    dispatch_payload = _read_regular(release_root / "dispatch-measurement.json")
    dispatch = _read_json(release_root / "dispatch-measurement.json")
    if dispatch != dispatch_records[0]:
        raise P06ReleaseOrchestrationError("reopened dispatch bytes differ from evaluation")
    validate_dispatch_measurement_document(dispatch)

    tolerances = bound_inputs.documents["metric_performance_tolerances"]
    metric_policy = locked_metric_policy_document(
        metric_seed=bound_inputs.documents["metric_policy_seed"],
        tolerances=tolerances,
        tolerances_sha256=str(
            bound_inputs.record("metric_performance_tolerances")["sha256"]
        ),
        dispatch_measurement=dispatch,
        dispatch_measurement_file_sha256=_sha256(dispatch_payload),
        dispatch_measurement_size_bytes=len(dispatch_payload),
    )
    _write_json(release_root / "locked-metric-policy.json", metric_policy)
    metric_policy_file_sha256 = _sha256(
        _read_regular(release_root / "locked-metric-policy.json")
    )

    selected_controls = selection["selected_controls"]
    if not isinstance(selected_controls, dict):
        raise P06ReleaseOrchestrationError("selected controls are absent")
    build_locked_quality_policy(
        output_path=release_root / "locked-quality-policy.json",
        selected_controls=selected_controls,
        quality_policy_seed_sha256=str(selection["quality_policy_seed_sha256"]),
        baseline_ablation_contract=bound_inputs.documents[
            "baseline_ablation_contract"
        ],
        baseline_ablation_contract_sha256=str(
            selection["baseline_ablation_contract_sha256"]
        ),
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        shared_bank_configuration_sha256=str(
            selected_controls["shared_bank_configuration_sha256"]
        ),
    )

    vector = selection["selected_vector"]
    plan = bound_inputs.documents["calibration_plan"]
    if not isinstance(vector, dict):
        raise P06ReleaseOrchestrationError("selected vector is absent")
    configuration_id = f"ash-p06-{selection['selected_vector_sha256'][:24]}"
    runtime_summary = evaluation.get("runtime_summary")
    if (
        not isinstance(runtime_summary, dict)
        or runtime_summary.get("configuration_id") != configuration_id
    ):
        raise P06ReleaseOrchestrationError("selected native configuration differs")
    mapping = video_mapping_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        mapping_seed_sha256=str(bound_inputs.record("mapping_seed")["sha256"]),
        status="locked_before_p07",
        calibration_selection_sha256=selection_file_sha256,
        selected_evaluation_sha256=selected_evaluation_sha256,
    )
    operator_bank = operator_bank_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        operator_bank_seed_sha256=str(
            bound_inputs.record("operator_bank_seed")["sha256"]
        ),
        status="locked_before_p07",
        calibration_selection_sha256=selection_file_sha256,
        selected_evaluation_sha256=selected_evaluation_sha256,
    )
    _write_json(release_root / "locked-mapping.json", mapping)
    _write_json(release_root / "locked-operator-bank.json", operator_bank)
    mapping_file_sha256 = _sha256(_read_regular(release_root / "locked-mapping.json"))
    operator_file_sha256 = _sha256(
        _read_regular(release_root / "locked-operator-bank.json")
    )
    compiler_input = locked_compiler_input_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        mapping_sha256=mapping_file_sha256,
        operator_bank_sha256=operator_file_sha256,
        metric_policy_sha256=metric_policy_file_sha256,
        calibration_plan_sha256=str(
            bound_inputs.record("calibration_plan")["sha256"]
        ),
        corpus_lock_bundle_sha256=str(selection["corpus_lock_bundle_sha256"]),
    )
    _write_json(release_root / "locked-compiler-input.json", compiler_input)
    compiler_inputs_sha256 = str(
        compiler_input["hash_bindings"]["compiler_inputs_sha256"]
    )
    route_selection = route_analysis_grid_selection_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        calibration_selection_sha256=selection_file_sha256,
        selected_evaluation_sha256=selected_evaluation_sha256,
        mapping_sha256=mapping_file_sha256,
        operator_bank_sha256=operator_file_sha256,
        compiler_inputs_sha256=compiler_inputs_sha256,
    )
    _write_json(
        release_root / "route-analysis-grid-selection.json",
        route_selection,
    )

    native_builder = NativeSwiftBuilder(repository_root, native_cache_root)
    p00_builder = P00NativeBuilder(repository_root, native_cache_root)
    executable = native_builder.executable
    _copy_new(
        executable.path,
        release_root / "bin/ash-calibration-cli",
        executable=True,
    )
    _copy_new(
        executable.source_manifest_path,
        release_root / "sources/production-swift-source-manifest.json",
    )
    macos_code_identities = {
        "production_swift_executable": static_code_identity(
            release_root / "bin/ash-calibration-cli"
        ),
        "production_writer_executable": static_code_identity(
            writer_root / "production-writer"
        ),
        "p00_native_executable": static_code_identity(
            p00_builder.executable.path
        ),
    }
    _write_json(
        release_root / "sources/independent-python-source-manifest.json",
        _python_source_manifest(repository_root),
    )
    (release_root / "swift").mkdir()
    swift_output = _run(
        (
            str(release_root / "bin/ash-calibration-cli"),
            "compile-candidate",
            "--compiler-input",
            str(release_root / "locked-compiler-input.json"),
            "--mapping",
            str(release_root / "locked-mapping.json"),
            "--operator-bank",
            str(release_root / "locked-operator-bank.json"),
            "--output-directory",
            str(release_root / "swift"),
        ),
        cwd=repository_root,
    )
    _write_new(release_root / "swift/native-compile-summary.json", swift_output)
    _run(
        (
            sys.executable,
            str(repository_root / "validation/calibration_v2/tools/compile_reference_luts.py"),
            str(release_root / "locked-compiler-input.json"),
            str(release_root / "python"),
        ),
        cwd=repository_root,
    )
    build_native_parity_manifest(
        release_root=release_root,
        compiler_input_path=release_root / "locked-compiler-input.json",
        production_source_manifest_path=(
            "sources/production-swift-source-manifest.json"
        ),
        independent_source_manifest_path=(
            "sources/independent-python-source-manifest.json"
        ),
        output_path=release_root / "native-lut-parity-manifest.json",
        failure_output_path=release_root / "native-lut-parity-failure.json",
        conflict_record=str(plan["authority"]["conflict_record"]),
    )
    for filename in ("direct2x.ashlut", "direct3over2.ashlut"):
        _copy_new(release_root / "swift" / filename, release_root / filename)
    build_lut_manifest(
        repository_root=repository_root,
        release_root=release_root,
        output_path=release_root / "lut-manifest.json",
    )

    configuration_artifact_bindings = _configuration_bindings(
        repository_root=repository_root,
        release_root=release_root,
        p04_quality_root=p04_quality_root,
        bound_inputs=bound_inputs,
    )
    build_configuration_lock_from_bindings(
        output_path=release_root / "configuration-lock.json",
        locked_utc=locked_utc,
        artifact_bindings=configuration_artifact_bindings,
    )
    if P00_FAILURE_ID not in preserved_failure_paths:
        raise P06ReleaseOrchestrationError(
            "pinned P00 compatibility failure evidence is absent"
        )
    copied_tests = _copy_g06_test_evidence_set(
        test_evidence_paths=test_evidence_paths,
        release_root=release_root,
    )
    copied_failures = {
        identifier: _copy_evidence_input(
            identifier=identifier,
            source=path,
            release_root=release_root,
            category="preserved-failures",
        )
        for identifier, path in preserved_failure_paths.items()
    }
    control_rows = selection["selected_control_selection_artifacts"]
    assert isinstance(control_rows, list)
    control_paths = {
        str(row["control"]): release_root.joinpath(
            *PurePosixPath(str(row["path"])).parts
        )
        for row in control_rows
    }
    publish_p06_evidence_closure(
        output_path=release_root / "p06-evidence-closure.json",
        configuration_id=configuration_id,
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        corpus_lock_bundle_sha256=str(selection["corpus_lock_bundle_sha256"]),
        configuration_bindings=configuration_artifact_bindings,
        configuration_roots={
            "repository": repository_root,
            "release": release_root,
            "p04_quality": p04_quality_root,
        },
        implementation_artifacts={
            IMPLEMENTATION_IDS[0]: (
                "release",
                release_root / "bin/ash-calibration-cli",
                release_root,
            ),
            IMPLEMENTATION_IDS[1]: (
                "release",
                release_root / "sources/production-swift-source-manifest.json",
                release_root,
            ),
            IMPLEMENTATION_IDS[2]: (
                "release",
                release_root / "sources/independent-python-source-manifest.json",
                release_root,
            ),
            IMPLEMENTATION_IDS[3]: (
                "repository",
                repository_root / "validation/calibration_v2/release_orchestrator.py",
                repository_root,
            ),
            IMPLEMENTATION_IDS[4]: (
                "repository",
                repository_root
                / "validation/calibration_v2/tools/run_p06_production_calibration.py",
                repository_root,
            ),
        },
        macos_code_identities=macos_code_identities,
        selected_control_artifacts={
            identifier: ("release", control_paths[identifier], release_root)
            for identifier in SELECTED_CONTROL_IDS
        },
        support_evidence_trees={
            SUPPORT_TREE_IDS[0]: (
                "open_split",
                open_split_root / "quality-corpus-v1",
                open_split_root,
            ),
            SUPPORT_TREE_IDS[1]: (
                "calibration_evidence",
                evidence_root,
                evidence_root.parent,
            ),
            SUPPORT_TREE_IDS[2]: (
                "native_cache",
                native_cache_root,
                native_cache_root.parent,
            ),
            SUPPORT_TREE_IDS[3]: (
                "production_writer",
                writer_root,
                writer_root.parent,
            ),
            SUPPORT_TREE_IDS[4]: (
                "dispatch_measurement",
                dispatch_measurement_root,
                dispatch_measurement_root.parent,
            ),
        },
        test_evidence={
            identifier: ("release", path, release_root)
            for identifier, path in copied_tests.items()
        },
        preserved_failures={
            identifier: ("release", path, release_root)
            for identifier, path in copied_failures.items()
        },
        calibration_run_path=calibration_run_root,
        calibration_run_root=calibration_run_root.parent,
    )
    bound_inputs.verify_unchanged()
    bundle = build_p06_release_bundle_manifest(
        release_root=release_root,
        output_path=release_root / "p06-release-bundle.json",
        configuration_id=configuration_id,
        locked_utc=locked_utc,
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        corpus_lock_bundle_sha256=str(selection["corpus_lock_bundle_sha256"]),
        selected_evaluation_path=selected_relative,
    )
    bound_inputs.verify_unchanged()
    return bundle


def build_p06_release_transaction(
    *,
    repository_root: Path,
    calibration_run_root: Path,
    release_root: Path,
    native_cache_root: Path,
    open_split_root: Path,
    evidence_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    p04_quality_root: Path,
    locked_utc: str,
    bound_inputs: object,
    test_evidence_paths: Mapping[str, Path],
    preserved_failure_paths: Mapping[str, Path],
) -> Mapping[str, object]:
    """Create, validate, and atomically publish one selected P06 release bundle."""

    destination = Path(os.path.abspath(release_root))
    partial = destination.with_name(f".{destination.name}.partial")
    failed = destination.with_name(f"{destination.name}.failed")
    if destination.exists() or partial.exists() or failed.exists():
        raise P06ReleaseOrchestrationError(
            "release destination, partial, or failure path already exists"
        )
    repository = repository_root.resolve(strict=True)
    run = calibration_run_root.resolve(strict=True)
    dispatch_root = dispatch_measurement_root.resolve(strict=True)
    open_split = open_split_root.resolve(strict=True)
    evidence = evidence_root.resolve(strict=True)
    writer = writer_root.resolve(strict=True)
    native_cache = native_cache_root.resolve(strict=True)
    p04_root = p04_quality_root.resolve(strict=True)
    partial.mkdir(parents=True, mode=0o700)
    try:
        bundle = _publish_release(
            repository_root=repository,
            calibration_run_root=run,
            release_root=partial,
            native_cache_root=native_cache,
            open_split_root=open_split,
            evidence_root=evidence,
            writer_root=writer,
            dispatch_measurement_root=dispatch_root,
            p04_quality_root=p04_root,
            locked_utc=locked_utc,
            bound_inputs=bound_inputs,
            test_evidence_paths=test_evidence_paths,
            preserved_failure_paths=preserved_failure_paths,
        )
        os.replace(partial, destination)
        reopened = validate_p06_release_bundle_manifest(
            release_root=destination,
            manifest_path=destination / "p06-release-bundle.json",
            support_evidence_roots={
                "open_split": open_split,
                "calibration_evidence": evidence.parent,
                "native_cache": native_cache.parent,
                "production_writer": writer.parent,
                "dispatch_measurement": dispatch_root.parent,
                "calibration_run": run.parent,
            },
        )
        if reopened != bundle:
            raise P06ReleaseOrchestrationError("renamed release bundle changed")
        return reopened
    except Exception as error:
        if partial.exists():
            try:
                _write_json(
                    partial / "release-failure.json",
                    {
                        "schema_version": "1.0.0",
                        "artifact_kind": "p06_release_publication_failure",
                        "error_type": type(error).__name__,
                        "error": str(error),
                        "holdout_accessed": False,
                    },
                )
            except Exception:
                pass
            os.replace(partial, failed)
        raise


__all__ = [
    "P06ReleaseOrchestrationError",
    "build_p06_release_transaction",
]
