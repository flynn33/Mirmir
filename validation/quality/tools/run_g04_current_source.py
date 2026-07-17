#!/usr/bin/env python3
"""Execute, stage, validate, and publish one fresh-current-source G04 run.

The runner accepts only an exact clean committed repository, executes every
mandatory G04 producer while continuously rechecking that source identity,
stages the canonical evidence consumed by ``finalize_g04_current_source.py``,
and delegates publication to that finalizer.  It exposes no holdout-specific
input and never invokes a holdout loader.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any, Callable, Iterator, Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.tools import run_g05_current_source as g05  # noqa: E402
from validation.calibration_v2.tools.finalize_evidence_wrapper import (  # noqa: E402
    RepositoryState,
    _repository_state,
)
from validation.calibration_v2.tools.run_g06_verification import (  # noqa: E402
    G06VerificationError,
    parse_unittest_output,
    parse_xcresult_summary,
)
from validation.quality.src.mirmir_quality.harness_manifest import (  # noqa: E402
    QualityHarnessManifestError,
    validate_quality_harness_implementation_manifest,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    manifest_sha256,
    validate_schema,
)
from validation.quality.tools import finalize_g04_current_source as finalizer  # noqa: E402


COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
CANONICAL_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
QUALITY_MANIFEST_RELATIVE = Path(g05.QUALITY_MANIFEST_RELATIVE)
PRODUCTION_IMPLEMENTATION_RELATIVE = Path(
    "validation/quality/src/mirmir_quality/production_dry_run.py"
)
ACTUAL_CODEC_SCHEMA_RELATIVE = Path(
    "validation/quality/schemas/actual-codec-fixture.schema.json"
)
PRODUCTION_MANIFEST_SCHEMA_RELATIVE = Path(
    "validation/quality/schemas/artifact-manifest.schema.json"
)
CORPUS_LOCK_RELATIVE = Path("validation/quality/locks/corpus-lock.json")
DEVELOPMENT_SAMPLE_LOCK_RELATIVE = Path(
    "validation/quality/locks/development-sample-lock.json"
)
METRIC_VECTORS_RELATIVE = Path(
    "validation/quality/reference/metric-vectors-v1.json"
)


class G04ExecutionError(RuntimeError):
    """A producer or staged-evidence invariant failed."""


@dataclass(frozen=True)
class CommandSpec:
    """One source-bound command executed by the G04 runner."""

    identifier: str
    argv: tuple[str, ...]
    cwd: Path
    environment: Mapping[str, str]
    allowed_returncodes: tuple[int, ...] = (0,)
    merge_stderr: bool = False


@dataclass(frozen=True)
class CommandResult:
    """Captured command result used by production and fake executors."""

    returncode: int
    stdout: bytes
    stderr: bytes

    @property
    def combined(self) -> bytes:
        return self.stdout + self.stderr


CommandExecutor = Callable[[CommandSpec], CommandResult]
RepositoryStateProvider = Callable[[Path], RepositoryState]
G04Finalizer = Callable[..., Path]
BaselineValidator = Callable[[Path, str, str], None]


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise G04ExecutionError(message)


def _canonical_directory(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    try:
        resolved = absolute.resolve(strict=True)
        metadata = os.stat(absolute, follow_symlinks=False)
    except OSError as error:
        raise G04ExecutionError(f"{label} is absent") from error
    _require(
        resolved == absolute
        and stat.S_ISDIR(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode),
        f"{label} is linked, aliased, or not a directory",
    )
    return absolute


def _canonical_absent(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    parent = _canonical_directory(absolute.parent, f"{label} parent")
    _require(parent == absolute.parent, f"{label} parent differs")
    _require(not os.path.lexists(absolute), f"{label} already exists")
    return absolute


def _canonical_executable(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    try:
        resolved = absolute.resolve(strict=True)
        metadata = os.stat(resolved, follow_symlinks=False)
    except OSError as error:
        raise G04ExecutionError(f"{label} is absent") from error
    _require(
        stat.S_ISREG(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and os.access(resolved, os.X_OK),
        f"{label} is not a canonical executable regular file",
    )
    return resolved


def _safe_relative(value: str, label: str) -> PurePosixPath:
    parsed = PurePosixPath(value)
    _require(
        bool(value)
        and parsed.as_posix() == value
        and not parsed.is_absolute()
        and "\\" not in value
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"{label} is unsafe",
    )
    return parsed


def _read_regular(path: Path, label: str) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G04ExecutionError(f"{label} is absent") from error
    _require(
        stat.S_ISREG(before.st_mode)
        and not stat.S_ISLNK(before.st_mode)
        and before.st_nlink == 1,
        f"{label} is linked or not a single-link regular file",
    )
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        _require(
            (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"{label} changed while opening",
        )
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        after_path = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G04ExecutionError(f"{label} pathname disappeared while reading") from error
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    _require(
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) == identity
        and (
            after_path.st_dev,
            after_path.st_ino,
            after_path.st_size,
            after_path.st_mtime_ns,
        )
        == identity
        and stat.S_ISREG(after_path.st_mode)
        and after_path.st_nlink == 1,
        f"{label} changed while reading",
    )
    return b"".join(chunks)


def _json_object(payload: bytes, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(
            payload.decode("utf-8", errors="strict"),
            object_pairs_hook=lambda pairs: _unique_pairs(pairs, label),
            parse_constant=lambda token: (_ for _ in ()).throw(
                G04ExecutionError(f"{label} contains non-finite {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise G04ExecutionError(f"{label} is not valid UTF-8 JSON") from error
    _require(isinstance(value, Mapping), f"{label} is not a JSON object")
    return value


def _unique_pairs(
    pairs: Sequence[tuple[str, Any]],
    label: str,
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        _require(key not in result, f"{label} contains duplicate member {key}")
        result[key] = value
    return result


def _write_new(path: Path, payload: bytes, label: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _require(not os.path.lexists(path), f"{label} already exists")
    try:
        with path.open("xb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError as error:
        raise G04ExecutionError(f"{label} could not be written") from error


def _write_json_new(path: Path, document: Mapping[str, Any], label: str) -> None:
    _write_new(path, canonical_json_bytes(document) + b"\n", label)


def _copy_regular_new(source: Path, destination: Path, label: str) -> None:
    _write_new(destination, _read_regular(source, label), label)


def _binding(root: Path, path: Path, label: str) -> Mapping[str, Any]:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as error:
        raise G04ExecutionError(f"{label} escapes its binding root") from error
    _safe_relative(relative, f"{label} path")
    payload = _read_regular(path, label)
    return {
        "path": relative,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _subprocess_executor(spec: CommandSpec) -> CommandResult:
    stderr: int = subprocess.STDOUT if spec.merge_stderr else subprocess.PIPE
    result = subprocess.run(
        spec.argv,
        cwd=spec.cwd,
        env=dict(spec.environment),
        stdout=subprocess.PIPE,
        stderr=stderr,
        check=False,
    )
    return CommandResult(
        returncode=result.returncode,
        stdout=result.stdout,
        stderr=b"" if spec.merge_stderr else result.stderr,
    )


def _validate_git_baseline(
    repository_root: Path,
    baseline_commit: str,
    source_commit: str,
) -> None:
    for arguments, label in (
        (("cat-file", "-e", f"{baseline_commit}^{{commit}}"), "Git commit object"),
        (
            ("merge-base", "--is-ancestor", baseline_commit, source_commit),
            "source-ancestor relationship",
        ),
    ):
        result = subprocess.run(
            ("/usr/bin/git", *arguments),
            cwd=repository_root,
            env={
                "HOME": os.environ.get("HOME", ""),
                "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
                "PATH": CANONICAL_PATH,
                "LANG": "C",
                "LC_ALL": "C",
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        _require(
            result.returncode == 0 and result.stdout == b"" and result.stderr == b"",
            f"P00 baseline {label} is invalid",
        )
def _command_environment(
    repository_root: Path,
    *,
    python: bool,
    pycache_root: Path,
) -> Mapping[str, str]:
    environment = {
        "HOME": os.environ.get("HOME", ""),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": CANONICAL_PATH,
    }
    if python:
        environment.update(
            {
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONPYCACHEPREFIX": os.fspath(pycache_root),
                "PYTHONPATH": os.pathsep.join(
                    (
                        os.fspath(repository_root),
                        os.fspath(repository_root / "validation/quality/src"),
                    )
                ),
            }
        )
    return environment


def _execute_source_bound(
    spec: CommandSpec,
    *,
    executor: CommandExecutor,
    repository_root: Path,
    initial_state: RepositoryState,
    state_provider: RepositoryStateProvider,
) -> CommandResult:
    _require(
        state_provider(repository_root) == initial_state,
        f"repository state changed before {spec.identifier}",
    )
    result = executor(spec)
    _require(
        isinstance(result, CommandResult),
        f"{spec.identifier} executor returned an invalid result",
    )
    _require(
        result.returncode in spec.allowed_returncodes,
        f"{spec.identifier} exited {result.returncode}; "
        f"expected {spec.allowed_returncodes}",
    )
    _require(
        state_provider(repository_root) == initial_state,
        f"repository state changed during {spec.identifier}",
    )
    return result


def _command(
    identifier: str,
    argv: Sequence[str],
    *,
    cwd: Path,
    environment: Mapping[str, str],
    allowed_returncodes: tuple[int, ...] = (0,),
    merge_stderr: bool = False,
) -> CommandSpec:
    return CommandSpec(
        identifier=identifier,
        argv=tuple(argv),
        cwd=cwd,
        environment=dict(environment),
        allowed_returncodes=allowed_returncodes,
        merge_stderr=merge_stderr,
    )


def _extract_json_result(result: CommandResult, label: str) -> Mapping[str, Any]:
    _require(result.stderr == b"", f"{label} emitted stderr")
    return _json_object(result.stdout, label)


def _skipped_test_identifiers(document: object) -> tuple[str, ...]:
    result: list[str] = []

    def visit(value: object) -> None:
        if isinstance(value, Mapping):
            if value.get("result") == "Skipped":
                identifier = value.get("nodeIdentifier")
                _require(
                    isinstance(identifier, str) and bool(identifier),
                    "Xcode skipped test lacks its node identifier",
                )
                result.append(identifier)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(document)
    _require(len(result) == len(set(result)), "Xcode skipped-test identities repeat")
    return tuple(sorted(result))


def _validate_xcode_summary(
    summary: Mapping[str, Any],
    test_listing: Mapping[str, Any],
    expected_skips: Sequence[str],
) -> Mapping[str, int | str]:
    try:
        counts = parse_xcresult_summary(summary)
    except G06VerificationError as error:
        raise G04ExecutionError(str(error)) from error
    _require(
        counts.get("terminal_status") == "passed"
        and counts.get("failed") == 0
        and counts.get("expected_failures") == 0
        and isinstance(counts.get("passed"), int)
        and int(counts["passed"]) > 0,
        "Xcode full test run is not an all-passing run",
    )
    actual_skips = _skipped_test_identifiers(test_listing)
    _require(
        actual_skips == tuple(sorted(expected_skips))
        and counts.get("skipped") == len(actual_skips),
        "Xcode skipped tests differ from the explicit expected identities",
    )
    return counts


def _validate_release_summary(summary: Mapping[str, Any]) -> None:
    destination = summary.get("destination")
    _require(
        summary.get("status") == "succeeded"
        and isinstance(destination, Mapping)
        and destination.get("architecture") == "arm64"
        and destination.get("platform") == "macOS"
        and all(
            type(summary.get(key)) is int and summary.get(key) == 0
            for key in ("warningCount", "errorCount", "analyzerWarningCount")
        )
        and summary.get("warnings") == []
        and summary.get("errors") == []
        and summary.get("analyzerWarnings") == [],
        "Release result is not a clean arm64 macOS build",
    )


def _production_run_record(
    *,
    repository_root: Path,
    partial_root: Path,
    source_commit: str,
    production_root: Path,
    failed_root: Path,
) -> Mapping[str, Any]:
    benchmark = _json_object(
        _read_regular(production_root / "benchmark-dry-run.json", "production benchmark"),
        "production benchmark",
    )
    failure = _json_object(
        _read_regular(failed_root / "failure.json", "injected production failure"),
        "injected production failure",
    )
    manifest_path = production_root / "artifact-manifest.json"
    manifest = _json_object(
        _read_regular(manifest_path, "production artifact manifest"),
        "production artifact manifest",
    )
    validate_schema(
        manifest,
        repository_root / PRODUCTION_MANIFEST_SCHEMA_RELATIVE,
    )
    _validate_production_manifest_closure(
        production_root=production_root,
        manifest_path=manifest_path,
        manifest=manifest,
    )
    input_bindings_path = production_root / "input-bindings.json"
    input_bindings = _json_object(
        _read_regular(input_bindings_path, "production input bindings"),
        "production input bindings",
    )
    writer_runs = benchmark.get("common_writer_runs")
    _require(
        benchmark.get("schema_version") == "1.0.0"
        and benchmark.get("status") == "pass"
        and benchmark.get("gate_status") == "pass"
        and type(benchmark.get("case_count")) is int
        and int(benchmark["case_count"]) > 0
        and benchmark.get("completed_case_count") == benchmark.get("case_count")
        and benchmark.get("artifact_semantic_reverification") is True
        and benchmark.get("resumed_from_failure") is True
        and benchmark.get("resume_checkpoint_semantics") == "recomputed"
        and benchmark.get("holdout_accessed") is False
        and isinstance(writer_runs, list)
        and bool(writer_runs),
        "production dry-run output is not a complete resumed no-holdout pass",
    )
    _require(
        failure.get("message")
        == "injected production development dry-run interruption"
        and failure.get("partial_preserved") is True
        and failure.get("holdout_accessed") is False,
        "production failure injection was not preserved with no holdout access",
    )
    _require(
        input_bindings.get("schema_version") == "1.0.0"
        and input_bindings.get("all_split_evidence_rehashed") is True
        and input_bindings.get("holdout_accessed") is False
        and input_bindings.get("holdout_media_rehashed") is False,
        "production execution bindings do not prove the no-holdout boundary",
    )
    boundary = {
        "holdout_accessed": False,
        "holdout_media_bytes_read": False,
        "validation_pixels_decoded_or_evaluated": False,
        "validation_metrics_computed": False,
        "validation_used_for_selection": False,
    }
    manifest_binding = _binding(
        partial_root,
        manifest_path,
        "production artifact manifest",
    )
    failure_binding = _binding(
        partial_root,
        failed_root / "failure.json",
        "injected production failure",
    )
    execution_binding = _binding(
        partial_root,
        input_bindings_path,
        "production execution binding",
    )
    implementation_binding = _binding(
        repository_root,
        repository_root / PRODUCTION_IMPLEMENTATION_RELATIVE,
        "production implementation",
    )
    verification_relative = Path("analysis/production-run-verification.json")
    attestation_relative = Path("analysis/data-access-attestation.json")
    verification = {
        "schema_version": "1.0.0",
        "status": "pass",
        "source_commit": source_commit,
        "semantic_reverification": True,
        "resume_recomputed": True,
        "writer_run_count": len(writer_runs),
        "data_access": boundary,
        "artifact_manifest": manifest_binding,
        "injected_failure": failure_binding,
    }
    attestation = {
        "schema_version": "1.0.0",
        "status": "pass",
        "source_commit": source_commit,
        "execution_boundary": boundary,
        "execution_binding": execution_binding,
        "implementation_binding": implementation_binding,
        "observed_input_binding_flags": {
            "all_split_evidence_rehashed": True,
            "holdout_accessed": False,
            "holdout_media_rehashed": False,
        },
    }
    _write_json_new(
        partial_root / verification_relative,
        verification,
        "production verification",
    )
    _write_json_new(
        partial_root / attestation_relative,
        attestation,
        "production data-access attestation",
    )
    return {
        "status": "pass",
        "holdout_accessed": False,
        "case_count": benchmark["case_count"],
        "writer_run_count": len(writer_runs),
        "injected_failure_preserved": True,
        "resume_recomputed": True,
        "verification": verification_relative.as_posix(),
        "data_access_attestation": attestation_relative.as_posix(),
        "data_access": boundary,
        "artifact_manifest": manifest_binding,
        "injected_failure": failure_binding,
    }


def _validate_production_manifest_closure(
    *,
    production_root: Path,
    manifest_path: Path,
    manifest: Mapping[str, Any],
) -> None:
    _require(
        manifest.get("manifest_sha256") == manifest_sha256(manifest),
        "production artifact manifest self-hash is invalid",
    )
    records = manifest.get("artifacts")
    _require(isinstance(records, list), "production artifact records are absent")
    declared: dict[str, Mapping[str, Any]] = {}
    for index, value in enumerate(records):
        _require(
            isinstance(value, Mapping),
            f"production artifact record {index} is not an object",
        )
        relative = value.get("path")
        _require(
            isinstance(relative, str),
            f"production artifact record {index} path is absent",
        )
        normalized = _safe_relative(relative, f"production artifact record {index}")
        _require(
            normalized.as_posix() not in declared,
            "production artifact manifest contains a duplicate path",
        )
        declared[normalized.as_posix()] = value
    actual: set[str] = set()
    for current_name, directory_names, file_names in os.walk(
        production_root,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        for name in directory_names:
            metadata = os.stat(current / name, follow_symlinks=False)
            _require(
                stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
                "production artifact tree contains a linked directory",
            )
        for name in file_names:
            path = current / name
            if path == manifest_path:
                continue
            metadata = os.stat(path, follow_symlinks=False)
            _require(
                stat.S_ISREG(metadata.st_mode)
                and not stat.S_ISLNK(metadata.st_mode)
                and metadata.st_nlink == 1,
                "production artifact tree contains a linked or special file",
            )
            actual.add(path.relative_to(production_root).as_posix())
    _require(
        set(declared) == actual,
        "production artifact manifest differs from the exact file closure",
    )
    for relative, record in declared.items():
        payload = _read_regular(
            production_root.joinpath(*PurePosixPath(relative).parts),
            f"production artifact {relative}",
        )
        _require(
            record.get("sha256") == hashlib.sha256(payload).hexdigest()
            and type(record.get("size_bytes")) is int
            and record.get("size_bytes") == len(payload),
            f"production artifact binding differs: {relative}",
        )


def _quality_manifest_record(
    repository_root: Path,
    partial_root: Path,
) -> Mapping[str, Any]:
    installed_path = repository_root / QUALITY_MANIFEST_RELATIVE
    installed_payload = _read_regular(
        installed_path,
        "installed quality-harness manifest",
    )
    installed_document = _json_object(
        installed_payload,
        "installed quality-harness manifest",
    )
    internal_sha256 = validate_quality_harness_implementation_manifest(
        installed_document,
        repository_root,
    )
    rebuild_paths = tuple(
        partial_root / relative for relative in finalizer.QUALITY_REBUILD_RELATIVES
    )
    rebuild_payloads = tuple(
        _read_regular(path, f"quality-harness rebuild {index}")
        for index, path in enumerate(rebuild_paths, start=1)
    )
    _require(
        rebuild_payloads[0] == rebuild_payloads[1] == installed_payload,
        "quality-harness rebuilds are not byte-identical to the installed lock",
    )
    for index, payload in enumerate(rebuild_payloads, start=1):
        document = _json_object(payload, f"quality-harness rebuild {index}")
        _require(
            validate_quality_harness_implementation_manifest(
                document,
                repository_root,
            )
            == internal_sha256,
            f"quality-harness rebuild {index} internal hash differs",
        )
    return {
        "status": "pass",
        "deterministic_rebuild_count": 2,
        "manifest_sha256": internal_sha256,
        "installed_file_sha256": hashlib.sha256(installed_payload).hexdigest(),
        "rebuild_a": _binding(
            partial_root,
            rebuild_paths[0],
            "quality-harness rebuild A",
        ),
        "rebuild_b": _binding(
            partial_root,
            rebuild_paths[1],
            "quality-harness rebuild B",
        ),
    }


def _assessment_evidence(
    tests: Mapping[str, Any],
    *,
    partial_root: Path,
) -> list[str]:
    evidence = {
        finalizer.TEST_RESULTS_RELATIVE,
        str(tests["xcode_full"]["summary"]),
        str(tests["xcode_full"]["coverage"]),
        str(tests["xcode_full"]["log"]),
        str(tests["release_build"]["summary"]),
        str(tests["release_build"]["log"]),
        str(tests["release_build"]["verification"]),
        str(tests["python"]["log"]),
        str(tests["production_dry_run"]["verification"]),
        str(tests["production_dry_run"]["data_access_attestation"]),
        str(tests["production_dry_run"]["artifact_manifest"]["path"]),
        str(tests["production_dry_run"]["injected_failure"]["path"]),
        str(tests["actual_codec_cli"]["evidence"]["path"]),
        str(tests["actual_codec_cli"]["fixture"]["path"]),
        str(tests["actual_codec_cli"]["log"]),
        str(tests["attribution_scan"]["path"]),
        str(tests["metric_oracle"]["log"]),
        str(tests["swiftlint"]["log"]),
        str(tests["static_validation"]["log"]),
        str(tests["instruction_package"]["log"]),
        str(tests["quality_harness_manifest"]["rebuild_a"]["path"]),
        str(tests["quality_harness_manifest"]["rebuild_b"]["path"]),
    }
    attestation = _json_object(
        _read_regular(
            partial_root
            / str(tests["production_dry_run"]["data_access_attestation"]),
            "production data-access attestation",
        ),
        "production data-access attestation",
    )
    evidence.add(str(attestation["execution_binding"]["path"]))
    return sorted(evidence)


@contextmanager
def _scratch_directory(path: Path | None) -> Iterator[Path]:
    if path is None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g04-current-source-") as name:
            yield Path(name).resolve(strict=True)
        return
    scratch = _canonical_absent(path, "G04 scratch root")
    scratch.mkdir()
    yield scratch


def run_g04_current_source(
    *,
    repository_root: Path,
    final_root: Path,
    expected_source_commit: str,
    p00_baseline_commit: str,
    instruction_package_root: Path,
    asset_root: Path,
    evidence_root: Path,
    sample_root: Path,
    expected_xcode_skips: Sequence[str] = (),
    python_executable: Path = Path("/usr/bin/python3"),
    swiftlint_executable: Path | None = None,
    scratch_root: Path | None = None,
    executor: CommandExecutor | None = None,
    state_provider: RepositoryStateProvider | None = None,
    publish: G04Finalizer | None = None,
    baseline_validator: BaselineValidator | None = None,
) -> Path:
    """Execute all mandatory G04 producers and publish their exact closure."""

    _require(
        COMMIT_PATTERN.fullmatch(expected_source_commit) is not None,
        "expected source commit is not a lowercase 40-character Git object ID",
    )
    _require(
        COMMIT_PATTERN.fullmatch(p00_baseline_commit) is not None,
        "P00 baseline commit is not a lowercase 40-character Git object ID",
    )
    repository_root = _canonical_directory(repository_root, "repository root")
    instruction_package_root = _canonical_directory(
        instruction_package_root,
        "instruction-package root",
    )
    asset_root = _canonical_directory(asset_root, "development asset root")
    evidence_root = _canonical_directory(evidence_root, "development evidence root")
    sample_root = _canonical_directory(sample_root, "development sample root")
    final_root = _canonical_absent(final_root, "G04 final root")
    try:
        final_relative = final_root.relative_to(repository_root)
    except ValueError as error:
        raise G04ExecutionError("G04 final root is outside the repository") from error
    _require(
        final_relative.parts[:2] == ("Artifacts", "ASH")
        and len(final_relative.parts) == 3,
        "G04 final root is not a direct Artifacts/ASH child",
    )
    partial_root = final_root.parent / f".{final_root.name}.partial"
    _canonical_absent(partial_root, "G04 partial root")
    python_executable = _canonical_executable(
        python_executable,
        "Python executable",
    )
    if swiftlint_executable is None:
        discovered = shutil.which("swiftlint", path=CANONICAL_PATH)
        _require(discovered is not None, "SwiftLint is absent from the canonical PATH")
        swiftlint_executable = Path(discovered)
    swiftlint_executable = _canonical_executable(
        swiftlint_executable,
        "SwiftLint executable",
    )
    execute = executor or _subprocess_executor
    repository_state = state_provider or _repository_state
    finalize = publish or finalizer.finalize_g04_current_source
    initial_state = repository_state(repository_root)
    _require(
        initial_state.project_commit == expected_source_commit,
        "repository HEAD differs from the expected G04 source commit",
    )
    validate_baseline = baseline_validator or _validate_git_baseline
    validate_baseline(repository_root, p00_baseline_commit, expected_source_commit)
    _require(
        repository_state(repository_root) == initial_state,
        "repository state changed during P00 baseline validation",
    )

    with _scratch_directory(scratch_root) as scratch:
        partial_root.mkdir()
        debug_derived = scratch / "debug-derived-data"
        release_derived = scratch / "release-derived-data"
        codec_output = scratch / "actual-codec"
        pycache_root = scratch / "pycache"
        native_environment = _command_environment(
            repository_root,
            python=False,
            pycache_root=pycache_root,
        )
        python_environment = _command_environment(
            repository_root,
            python=True,
            pycache_root=pycache_root,
        )

        def run(spec: CommandSpec) -> CommandResult:
            return _execute_source_bound(
                spec,
                executor=execute,
                repository_root=repository_root,
                initial_state=initial_state,
                state_provider=repository_state,
            )

        xcode_bundle = partial_root / "xcode/full-tests.xcresult"
        xcode_bundle.parent.mkdir(parents=True)
        xcode_log = run(
            _command(
                "xcode-full",
                (
                    "/usr/bin/xcodebuild",
                    "clean",
                    "test",
                    "-project",
                    "Mirmir.xcodeproj",
                    "-scheme",
                    "Mirmir",
                    "-configuration",
                    "Debug",
                    "-destination",
                    "platform=macOS,arch=arm64",
                    "-derivedDataPath",
                    os.fspath(debug_derived),
                    "-resultBundlePath",
                    os.fspath(xcode_bundle),
                    "-enableCodeCoverage",
                    "YES",
                    "-parallel-testing-enabled",
                    "NO",
                    "CODE_SIGNING_ALLOWED=NO",
                ),
                cwd=repository_root,
                environment=native_environment,
                merge_stderr=True,
            )
        ).combined
        _write_new(partial_root / "xcode/full-tests.log", xcode_log, "Xcode log")
        summary = _extract_json_result(
            run(
                _command(
                    "xcresult-test-summary",
                    (
                        "/usr/bin/xcrun",
                        "xcresulttool",
                        "get",
                        "test-results",
                        "summary",
                        "--path",
                        os.fspath(xcode_bundle),
                        "--compact",
                    ),
                    cwd=repository_root,
                    environment=native_environment,
                )
            ),
            "Xcode summary",
        )
        test_listing = _extract_json_result(
            run(
                _command(
                    "xcresult-test-list",
                    (
                        "/usr/bin/xcrun",
                        "xcresulttool",
                        "get",
                        "test-results",
                        "tests",
                        "--path",
                        os.fspath(xcode_bundle),
                        "--compact",
                    ),
                    cwd=repository_root,
                    environment=native_environment,
                )
            ),
            "Xcode test listing",
        )
        xcode_counts = _validate_xcode_summary(
            summary,
            test_listing,
            expected_xcode_skips,
        )
        coverage = _extract_json_result(
            run(
                _command(
                    "xcode-coverage",
                    (
                        "/usr/bin/xcrun",
                        "xccov",
                        "view",
                        "--report",
                        "--json",
                        os.fspath(xcode_bundle),
                    ),
                    cwd=repository_root,
                    environment=native_environment,
                )
            ),
            "Xcode coverage",
        )
        _require(bool(coverage), "Xcode coverage document is empty")
        _write_json_new(
            partial_root / "xcode/full-tests-summary.json",
            summary,
            "Xcode summary",
        )
        _write_json_new(
            partial_root / "xcode/full-coverage.json",
            coverage,
            "Xcode coverage",
        )

        release_bundle = partial_root / "xcode/release-build.xcresult"
        release_log = run(
            _command(
                "xcode-release",
                (
                    "/usr/bin/xcodebuild",
                    "clean",
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
                    os.fspath(release_derived),
                    "-resultBundlePath",
                    os.fspath(release_bundle),
                ),
                cwd=repository_root,
                environment=native_environment,
                merge_stderr=True,
            )
        ).combined
        _write_new(
            partial_root / "xcode/release-build.log",
            release_log,
            "Release build log",
        )
        release_summary = _extract_json_result(
            run(
                _command(
                    "xcresult-release-summary",
                    (
                        "/usr/bin/xcrun",
                        "xcresulttool",
                        "get",
                        "build-results",
                        "--path",
                        os.fspath(release_bundle),
                        "--compact",
                    ),
                    cwd=repository_root,
                    environment=native_environment,
                )
            ),
            "Release summary",
        )
        _validate_release_summary(release_summary)
        _write_json_new(
            partial_root / "xcode/release-build-summary.json",
            release_summary,
            "Release summary",
        )
        app = release_derived / "Build/Products/Release/Mirmir.app"
        binary = app / "Contents/MacOS/Mirmir"
        binary_payload = _read_regular(binary, "Release binary")
        binary_sha256 = hashlib.sha256(binary_payload).hexdigest()
        verification_parts = []
        for identifier, argv in (
            ("release-file", ("/usr/bin/file", os.fspath(binary))),
            ("release-lipo", ("/usr/bin/lipo", "-info", os.fspath(binary))),
            (
                "release-codesign-verify",
                (
                    "/usr/bin/codesign",
                    "--verify",
                    "--deep",
                    "--strict",
                    "--verbose=2",
                    os.fspath(app),
                ),
            ),
            (
                "release-codesign-display",
                ("/usr/bin/codesign", "-dvvv", os.fspath(app)),
            ),
        ):
            verification_parts.append(
                run(
                    _command(
                        identifier,
                        argv,
                        cwd=repository_root,
                        environment=native_environment,
                    )
                ).combined
            )
        verification_parts.insert(
            2,
            f"{binary_sha256}  {binary}\n".encode("ascii"),
        )
        verification = b"".join(verification_parts)
        _require(
            b"Mach-O 64-bit executable arm64" in verification
            and b"is architecture: arm64" in verification
            and b"Format=app bundle with Mach-O thin (arm64)" in verification
            and re.search(rb"flags=0x[0-9a-f]+\([^\n]*runtime[^\n]*\)", verification)
            is not None,
            "Release verification does not prove arm64 hardened-runtime bytes",
        )
        _write_new(
            partial_root / "xcode/release-binary-verification.log",
            verification,
            "Release binary verification",
        )

        python_result = run(
            _command(
                "python-quality-tests",
                (
                    os.fspath(python_executable),
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    "validation/quality/tests",
                    "-v",
                ),
                cwd=repository_root,
                environment=python_environment,
                merge_stderr=True,
            )
        )
        python_log = python_result.combined
        try:
            python_counts = parse_unittest_output(
                python_log.decode("utf-8", errors="strict")
            )
        except (UnicodeDecodeError, G06VerificationError) as error:
            raise G04ExecutionError("Python suite is not an all-passed no-skip run") from error
        _write_new(
            partial_root / "tests/python-unittest.log",
            python_log,
            "Python unittest log",
        )

        static_result = run(
            _command(
                "python-static-validation",
                (
                    os.fspath(python_executable),
                    "-m",
                    "compileall",
                    "-q",
                    "validation",
                ),
                cwd=repository_root,
                environment=python_environment,
                merge_stderr=True,
            )
        )
        _write_new(
            partial_root / "tests/python-compileall.log",
            static_result.combined,
            "Python static-validation log",
        )

        for identifier, relative in zip(
            ("quality-lock-a", "quality-lock-b"),
            finalizer.QUALITY_REBUILD_RELATIVES,
        ):
            output = partial_root / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            result = run(
                _command(
                    identifier,
                    (
                        os.fspath(python_executable),
                        os.fspath(
                            repository_root
                            / "validation/quality/tools/"
                            "build_quality_harness_implementation_manifest.py"
                        ),
                        "--repository-root",
                        os.fspath(repository_root),
                        "--output",
                        os.fspath(output),
                    ),
                    cwd=repository_root,
                    environment=python_environment,
                )
            )
            _require(result.stderr == b"", f"{identifier} emitted stderr")
        quality_record = _quality_manifest_record(repository_root, partial_root)

        production_output_root = partial_root / "production-run"
        production_run_id = f"g04-{expected_source_commit[:12]}"
        production_base = (
            os.fspath(python_executable),
            os.fspath(
                repository_root
                / "validation/quality/tools/run_production_development_dry_run.py"
            ),
            "--output-root",
            os.fspath(production_output_root),
            "--run-id",
            production_run_id,
            "--corpus-lock",
            os.fspath(repository_root / CORPUS_LOCK_RELATIVE),
            "--asset-root",
            os.fspath(asset_root),
            "--evidence-root",
            os.fspath(evidence_root),
            "--development-sample-lock",
            os.fspath(repository_root / DEVELOPMENT_SAMPLE_LOCK_RELATIVE),
            "--sample-root",
            os.fspath(sample_root),
        )
        failure_result = run(
            _command(
                "production-failure-injection",
                (*production_base, "--fail-after-cases", "7"),
                cwd=repository_root,
                environment=python_environment,
                allowed_returncodes=(1,),
                merge_stderr=True,
            )
        )
        try:
            failure_line = failure_result.combined.decode("utf-8", errors="strict").strip()
        except UnicodeDecodeError as error:
            raise G04ExecutionError("production failure output is not UTF-8") from error
        _require(
            failure_line.startswith("failed_run=")
            and "\n" not in failure_line,
            "production failure injection did not report one preserved run",
        )
        failed_root = Path(failure_line.removeprefix("failed_run="))
        _require(
            failed_root.parent == production_output_root
            and failed_root.name == f"{production_run_id}.failed-1",
            "production failure path differs from the deterministic namespace",
        )
        resume_result = run(
            _command(
                "production-resume",
                (*production_base, "--resume-from", os.fspath(failed_root)),
                cwd=repository_root,
                environment=python_environment,
                merge_stderr=True,
            )
        )
        production_root = production_output_root / production_run_id
        _require(
            resume_result.combined
            == f"final_run={production_root}\n".encode("utf-8"),
            "production resume did not report the deterministic final run",
        )
        production_record = _production_run_record(
            repository_root=repository_root,
            partial_root=partial_root,
            source_commit=expected_source_commit,
            production_root=production_root,
            failed_root=failed_root,
        )

        codec_result = run(
            _command(
                "actual-codec",
                (
                    os.fspath(python_executable),
                    os.fspath(
                        repository_root
                        / "validation/quality/tools/run_actual_codec_fixture.py"
                    ),
                    "--output-directory",
                    os.fspath(codec_output),
                ),
                cwd=repository_root,
                environment=python_environment,
                merge_stderr=True,
            )
        )
        del codec_result
        codec_source = codec_output / "actual-codec-fixture-lock.json"
        codec_document = _json_object(
            _read_regular(codec_source, "actual-codec evidence"),
            "actual-codec evidence",
        )
        validate_schema(codec_document, repository_root / ACTUAL_CODEC_SCHEMA_RELATIVE)
        _require(
            codec_document.get("status") == "pass",
            "actual-codec fixture did not pass",
        )
        fixture_document = codec_document.get("fixture")
        _require(
            isinstance(fixture_document, Mapping),
            "actual-codec report lacks its fixture binding",
        )
        fixture_name = _safe_relative(
            str(fixture_document.get("path", "")),
            "actual-codec fixture path",
        )
        _require(
            len(fixture_name.parts) == 1,
            "actual-codec fixture path is not one local filename",
        )
        fixture_source = codec_output / fixture_name.as_posix()
        fixture_payload = _read_regular(fixture_source, "actual-codec fixture")
        _require(
            fixture_document.get("sha256")
            == hashlib.sha256(fixture_payload).hexdigest()
            and fixture_document.get("size_bytes") == len(fixture_payload),
            "actual-codec fixture bytes differ from its report",
        )
        codec_path = partial_root / "raw/actual-codec/actual-codec-fixture-lock.json"
        _copy_regular_new(codec_source, codec_path, "actual-codec evidence")
        fixture_path = codec_path.parent / fixture_name.as_posix()
        _copy_regular_new(fixture_source, fixture_path, "actual-codec fixture")
        codec_binding = _binding(partial_root, codec_path, "actual-codec evidence")
        codec_fixture_binding = _binding(
            partial_root,
            fixture_path,
            "actual-codec fixture",
        )
        codec_log = (
            "actual codec fixture verification passed: "
            f"{codec_binding['sha256']}\n"
        ).encode("ascii")
        _write_new(
            partial_root / "tests/actual-codec-cli.log",
            codec_log,
            "actual-codec log",
        )

        metric_check = run(
            _command(
                "metric-oracle-check",
                (
                    os.fspath(python_executable),
                    os.fspath(repository_root / "validation/quality/reference/metric_oracle.py"),
                    "--check",
                    os.fspath(repository_root / METRIC_VECTORS_RELATIVE),
                ),
                cwd=repository_root,
                environment=python_environment,
                merge_stderr=True,
            )
        )
        _require(
            metric_check.combined
            == b"locked metric vectors match the independent oracle\n",
            "metric oracle did not match the locked vectors",
        )
        metric_document = _extract_json_result(
            run(
                _command(
                    "metric-oracle-output",
                    (
                        os.fspath(python_executable),
                        os.fspath(
                            repository_root
                            / "validation/quality/reference/metric_oracle.py"
                        ),
                    ),
                    cwd=repository_root,
                    environment=python_environment,
                )
            ),
            "metric-oracle output",
        )
        locked_metric = _json_object(
            _read_regular(
                repository_root / METRIC_VECTORS_RELATIVE,
                "locked metric vectors",
            ),
            "locked metric vectors",
        )
        _require(metric_document == locked_metric, "metric oracle output differs from lock")
        _write_json_new(
            partial_root / "tests/metric-oracle.log",
            metric_document,
            "metric-oracle evidence",
        )

        swiftlint_result = run(
            _command(
                "swiftlint-strict",
                (
                    os.fspath(swiftlint_executable),
                    "lint",
                    "--strict",
                    "--config",
                    ".swiftlint.yml",
                ),
                cwd=repository_root,
                environment=native_environment,
                merge_stderr=True,
            )
        )
        swiftlint_text = swiftlint_result.combined.decode("utf-8", errors="strict")
        _require(
            len(
                re.findall(
                    r"Found 0 violations, 0 serious in [1-9][0-9]* files\.",
                    swiftlint_text,
                )
            )
            == 1,
            "SwiftLint did not report one strict zero-violation run",
        )
        _write_new(
            partial_root / "tests/swiftlint-strict.log",
            swiftlint_result.combined,
            "SwiftLint log",
        )

        instruction_result = run(
            _command(
                "instruction-package-validation",
                (
                    os.fspath(python_executable),
                    "tools/validate_instruction_package.py",
                ),
                cwd=instruction_package_root,
                environment=python_environment,
                merge_stderr=True,
            )
        )
        expected_instruction = g05._instruction_validation_output(
            instruction_package_root
        )
        _require(
            instruction_result.combined == expected_instruction,
            "instruction-package validator output differs from the live package closure",
        )
        _write_new(
            partial_root / "tests/instruction-package-validation.log",
            instruction_result.combined,
            "instruction-package validation log",
        )

        diff_result = run(
            _command(
                "git-diff-check",
                ("/usr/bin/git", "diff", "--check"),
                cwd=repository_root,
                environment=native_environment,
                merge_stderr=True,
            )
        )
        _require(diff_result.combined == b"", "git diff --check emitted output")

        attribution = _extract_json_result(
            run(
                _command(
                    "attribution-scan",
                    (
                        os.fspath(python_executable),
                        "tools/scan_project_attribution.py",
                        os.fspath(repository_root),
                        "--policy",
                        "config/attribution_policy.json",
                        "--base",
                        p00_baseline_commit,
                        "--include",
                        os.fspath(partial_root),
                    ),
                    cwd=instruction_package_root,
                    environment=python_environment,
                )
            ),
            "attribution scan",
        )
        _require(
            set(attribution) == {"status", "base", "changed_file_count", "findings"}
            and attribution.get("status") == "pass"
            and attribution.get("base") == p00_baseline_commit
            and type(attribution.get("changed_file_count")) is int
            and int(attribution["changed_file_count"]) >= 0
            and attribution.get("findings") == [],
            "attribution scan is not a finding-free baseline-bound pass",
        )
        _write_json_new(
            partial_root / "attribution-scan.json",
            attribution,
            "attribution scan evidence",
        )

        xcode_record: dict[str, Any] = {
            "status": "passed",
            "total": xcode_counts["test_count"],
            "passed": xcode_counts["passed"],
            "failed": xcode_counts["failed"],
            "skipped": xcode_counts["skipped"],
            "summary": "xcode/full-tests-summary.json",
            "coverage": "xcode/full-coverage.json",
            "result_bundle": "xcode/full-tests.xcresult",
            "log": "xcode/full-tests.log",
        }
        if expected_xcode_skips:
            xcode_record["expected_skips"] = sorted(expected_xcode_skips)
        tests: dict[str, Any] = {
            "schema_version": "1.0.0",
            "source_commit": expected_source_commit,
            "status": "pass",
            "xcode_full": xcode_record,
            "release_build": {
                "status": "succeeded",
                "warnings": 0,
                "errors": 0,
                "analyzer_warnings": 0,
                "architecture": "arm64",
                "hardened_runtime": True,
                "binary_sha256": binary_sha256,
                "summary": "xcode/release-build-summary.json",
                "result_bundle": "xcode/release-build.xcresult",
                "log": "xcode/release-build.log",
                "verification": "xcode/release-binary-verification.log",
            },
            "python": {
                "status": "pass",
                "test_count": python_counts["test_count"],
                "failures": 0,
                "skips": 0,
                "log": "tests/python-unittest.log",
            },
            "production_dry_run": production_record,
            "metric_oracle": {"status": "pass", "log": "tests/metric-oracle.log"},
            "actual_codec_cli": {
                "status": "pass",
                "log": "tests/actual-codec-cli.log",
                "evidence": codec_binding,
                "fixture": codec_fixture_binding,
                "evidence_sha256": codec_binding["sha256"],
            },
            "static_validation": {
                "status": "pass",
                "log": "tests/python-compileall.log",
            },
            "instruction_package": {
                "status": "pass",
                "log": "tests/instruction-package-validation.log",
            },
            "attribution_scan": {
                "status": "pass",
                "findings": 0,
                "path": "attribution-scan.json",
            },
            "swiftlint": {
                "status": "pass",
                "violations": 0,
                "log": "tests/swiftlint-strict.log",
            },
            "quality_harness_manifest": quality_record,
        }
        _write_json_new(
            partial_root / finalizer.TEST_RESULTS_RELATIVE,
            tests,
            "G04 test results",
        )
        assessment = {
            "schema_version": "1.0.0",
            "gate": "G04",
            "status": "pass",
            "project_commit": expected_source_commit,
            "holdout_accessed": False,
            "algorithm_quality_claimed": False,
            "criteria": [
                {"criterion": criterion, "pass": True}
                for criterion in finalizer.g05_gate.G04_ASSESSMENT_CRITERIA
            ],
            "evidence": _assessment_evidence(
                tests,
                partial_root=partial_root,
            ),
            "test_results": finalizer.TEST_RESULTS_RELATIVE,
        }
        _write_json_new(
            partial_root / finalizer.ASSESSMENT_RELATIVE,
            assessment,
            "G04 gate assessment",
        )
        _require(
            repository_state(repository_root) == initial_state,
            "repository state changed before G04 finalization",
        )
        published = finalize(
            repository_root=repository_root,
            partial_root=partial_root,
            final_root=final_root,
            expected_source_commit=expected_source_commit,
        )
        _require(published == final_root, "G04 finalizer returned a different path")
        _require(
            repository_state(repository_root) == initial_state,
            "repository state changed during G04 finalization",
        )
        return published


def _arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--final-root", required=True, type=Path)
    parser.add_argument("--expected-source-commit", required=True)
    parser.add_argument("--p00-baseline-commit", required=True)
    parser.add_argument("--instruction-package-root", required=True, type=Path)
    parser.add_argument("--asset-root", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--sample-root", required=True, type=Path)
    parser.add_argument("--expected-xcode-skip", action="append", default=[])
    parser.add_argument(
        "--python-executable",
        type=Path,
        default=Path("/usr/bin/python3"),
    )
    parser.add_argument("--swiftlint-executable", type=Path)
    parser.add_argument("--scratch-root", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(argv)
    try:
        published = run_g04_current_source(
            repository_root=arguments.repository_root,
            final_root=arguments.final_root,
            expected_source_commit=arguments.expected_source_commit,
            p00_baseline_commit=arguments.p00_baseline_commit,
            instruction_package_root=arguments.instruction_package_root,
            asset_root=arguments.asset_root,
            evidence_root=arguments.evidence_root,
            sample_root=arguments.sample_root,
            expected_xcode_skips=arguments.expected_xcode_skip,
            python_executable=arguments.python_executable,
            swiftlint_executable=arguments.swiftlint_executable,
            scratch_root=arguments.scratch_root,
        )
    except (
        G04ExecutionError,
        G06VerificationError,
        QualityHarnessManifestError,
        finalizer.G04CurrentSourceError,
        OSError,
        ValueError,
    ) as error:
        print(f"G04 current-source execution failed: {error}", file=sys.stderr)
        return 2
    print(published)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
