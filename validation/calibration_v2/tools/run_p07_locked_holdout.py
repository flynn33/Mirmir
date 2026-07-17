#!/usr/bin/env python3
"""Run the concrete one-use P07 holdout transaction."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import stat
import subprocess
import sys
import tempfile
from typing import Mapping
from typing import Callable


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.native_adapter.factory import (  # noqa: E402
    make_native_candidate_adapter_factory,
)
from validation.calibration_v2.current_source_gate_closure_v2 import (  # noqa: E402
    reopen_staged_current_source_gate_receipts_v2,
)
from validation.calibration_v2.p07.execution import (  # noqa: E402
    P07ExecutionError,
    P07HoldoutExecutor,
    SUPPORT_ROOT_IDS,
    _P07TransactionWorkspace,
    _decode_json,
    _existing_and_future_paths_overlap,
    _normalized_absolute,
    _open_directory_nofollow,
    _paths_overlap,
    _pre_guard_failure_staging_path,
    _read_json,
    _read_regular_file,
    _validate_existing_path,
    _snapshot_descriptor_tree,
    _transaction_directory_path,
    _verify_directory_path_identity,
    build_p07_frame_loader,
)
from validation.calibration_v2.p07.production import (  # noqa: E402
    P07ProductionEvaluator,
)
from validation.calibration_v2.release_lock import (  # noqa: E402
    p06_release_bundle_sha256,
)
from validation.calibration_v2.runner import (  # noqa: E402
    LiveHoldoutPreopenBinding,
    bind_preregistered_inputs,
)
from validation.quality.src.mirmir_quality.holdout import (  # noqa: E402
    P06V3HoldoutAccessGuard,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_sha256,
    manifest_sha256,
    validate_schema,
)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_v3_configuration_lock(
    *,
    release_root: Path,
    release_manifest_path: Path,
    expected_release_manifest_sha256: str,
) -> tuple[Mapping[str, object], Mapping[str, object]]:
    """Bind the only P07 configuration lock to the exact P06 V3 manifest row."""

    _, bundle = _read_json(release_manifest_path, "P06 V3 release bundle")
    if p06_release_bundle_sha256(bundle) != expected_release_manifest_sha256:
        raise ValueError("P06 V3 release manifest differs from explicit expected hash")
    artifacts = bundle.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("P06 V3 artifact bindings are absent")
    rows = [
        row
        for row in artifacts
        if isinstance(row, dict) and row.get("id") == "configuration_lock"
    ]
    if len(rows) != 1 or rows[0].get("path") != "configuration-lock-v2.json":
        raise ValueError("P06 V3 configuration-lock binding is not exact")
    payload, configuration = _read_json(
        release_root / "configuration-lock-v2.json",
        "P06 V3 configuration lock",
    )
    row = rows[0]
    if (
        hashlib.sha256(payload).hexdigest() != row.get("sha256")
        or len(payload) != row.get("size_bytes")
    ):
        raise ValueError("P06 V3 configuration-lock bytes differ from release")
    return bundle, configuration


def _publish_startup_nonopening_failure(
    *,
    output_directory: Path,
    error: BaseException,
) -> Path:
    """Persist failures that occur before a configuration can drive the executor."""

    digest = hashlib.sha256(
        os.fspath(output_directory).encode("utf-8", "strict")
    ).hexdigest()[:32]
    directory = output_directory.parent / f".p07-startup-failure-{digest}"
    document = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_runner_startup_failure",
        "status": "failed_before_holdout_intent",
        "requested_output_directory": os.fspath(output_directory),
        "failure_type": type(error).__name__,
        "failure_message_sha256": hashlib.sha256(
            str(error).encode("utf-8", "strict")
        ).hexdigest(),
        "holdout_intent_recorded": False,
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = canonical_sha256(document)
    payload = json.dumps(
        document,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        metadata = os.stat(directory, follow_symlinks=False)
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise P07ExecutionError("P07 startup-failure archive is unsafe")
        if {entry.name for entry in directory.iterdir()} != {"startup-failure.json"}:
            raise P07ExecutionError("P07 startup-failure archive has foreign state")
        existing = directory / "startup-failure.json"
        existing_metadata = os.stat(existing, follow_symlinks=False)
        if (
            stat.S_ISLNK(existing_metadata.st_mode)
            or not stat.S_ISREG(existing_metadata.st_mode)
            or existing_metadata.st_nlink != 1
            or existing.read_bytes() != payload
        ):
            raise P07ExecutionError("P07 startup-failure archive is unsafe")
        return existing
    target = directory / "startup-failure.json"
    descriptor = os.open(
        target,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise P07ExecutionError(
                    "P07 startup-failure publication made no progress"
                )
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory_descriptor = os.open(
        directory,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
    if target.read_bytes() != payload:
        raise P07ExecutionError("P07 startup-failure publication changed")
    parent_descriptor = os.open(
        directory.parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
    return target


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate the complete P06 release, build/test the P07 loader, "
            "open the sealed holdout once, and publish JSON-only G07 evidence."
        )
    )
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--holdout-root", required=True, type=Path)
    parser.add_argument("--sampling-plan-path", required=True, type=Path)
    parser.add_argument("--expected-sampling-plan-file-sha256", required=True)
    parser.add_argument("--no-pixel-attestation-path", required=True, type=Path)
    parser.add_argument("--expected-no-pixel-attestation-file-sha256", required=True)
    parser.add_argument("--expected-loader-executable-sha256", required=True)
    parser.add_argument("--p06-release-root", required=True, type=Path)
    parser.add_argument("--p06-release-manifest-path", required=True, type=Path)
    parser.add_argument("--expected-p06-release-manifest-sha256", required=True)
    parser.add_argument("--g04-root", required=True, type=Path)
    parser.add_argument("--g05-root", required=True, type=Path)
    parser.add_argument("--g05-instruction-package-root", required=True, type=Path)
    parser.add_argument("--g05-baseline-commit", required=True)
    parser.add_argument("--g06-root", required=True, type=Path)
    parser.add_argument("--g06-execution-run-name", required=True)
    parser.add_argument(
        "--support-root",
        required=True,
        action="append",
        metavar="ID=PATH",
    )
    parser.add_argument("--p07-cache-root", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--p04-quality-root", required=True, type=Path)
    parser.add_argument("--expected-corpus-manifest-sha256", required=True)
    parser.add_argument("--live-ledger-path", required=True, type=Path)
    parser.add_argument("--live-anchor-path", required=True, type=Path)
    parser.add_argument("--live-preopen-receipt-path", required=True, type=Path)
    parser.add_argument("--expected-live-ledger-root-identity-sha256", required=True)
    parser.add_argument("--expected-live-anchor-root-identity-sha256", required=True)
    parser.add_argument("--expected-live-preopen-receipt-file-sha256", required=True)
    parser.add_argument("--repository-sealed-copy-path", required=True, type=Path)
    parser.add_argument("--expected-repository-sealed-copy-sha256", required=True)
    parser.add_argument("--repository-attestation-path", required=True, type=Path)
    parser.add_argument("--expected-repository-attestation-sha256", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=900.0)
    parser.add_argument(
        "--preopen-verify-only",
        action="store_true",
        help=(
            "complete release/loader/native-LUT/analytic verification and exit "
            "before constructing the one-use holdout guard"
        ),
    )
    return parser.parse_args()


def _support_roots(values: list[str]) -> Mapping[str, Path]:
    result = {}
    for value in values:
        identifier, separator, raw_path = value.partition("=")
        if not separator or not identifier or not raw_path or identifier in result:
            raise ValueError("support roots must be unique ID=PATH values")
        result[identifier] = Path(raw_path)
    if set(result) != set(SUPPORT_ROOT_IDS):
        raise ValueError(
            "support root IDs must be exact: {}".format(
                ", ".join(sorted(SUPPORT_ROOT_IDS))
            )
        )
    return result


def _verify_fresh_source_gate_semantics(
    *,
    arguments: argparse.Namespace,
    repository_root: Path,
    release_bundle: Mapping[str, object],
) -> Mapping[str, object]:
    payload, authority = _read_json(
        arguments.p06_release_root / "p07-production-execution-authority-v2.json",
        "P07 production execution authority V2",
    )
    if (
        hashlib.sha256(payload).hexdigest()
        != release_bundle.get("authorized_execution_bindings_sha256")
        or authority.get("artifact_sha256")
        != canonical_sha256(
            {
                key: value
                for key, value in authority.items()
                if key != "artifact_sha256"
            }
        )
    ):
        raise ValueError("P07 production execution authority differs from P06 V3")
    fresh = reopen_staged_current_source_gate_receipts_v2(
        repository_root=repository_root,
        release_root=arguments.p06_release_root.resolve(strict=True),
        g04_root=arguments.g04_root.resolve(strict=True),
        g05_root=arguments.g05_root.resolve(strict=True),
        g05_instruction_package_root=(
            arguments.g05_instruction_package_root.resolve(strict=True)
        ),
        g05_baseline_commit=arguments.g05_baseline_commit,
        g06_root=arguments.g06_root.resolve(strict=True),
        g06_execution_run_name=arguments.g06_execution_run_name,
    )
    if fresh != authority.get("source_gate_semantics"):
        raise ValueError("fresh G04/G05/G06 semantics differ from P06 authority")
    return fresh


def _loader_verification(
    *,
    repository_root: Path,
    cache_root: Path,
    expected_executable_sha256: str,
    reuse_existing: bool = False,
) -> tuple[Path, Mapping[str, object]]:
    source = repository_root / "validation/calibration_v2/p07/P07HoldoutFrameLoader.swift"
    executable = cache_root / "p07-holdout-frame-loader-a"
    reproducibility_executable = cache_root / "p07-holdout-frame-loader-b"
    if reuse_existing:
        _validate_existing_path(
            executable,
            label="first persisted P07 loader build",
            kind="file",
        )
        _validate_existing_path(
            reproducibility_executable,
            label="second persisted P07 loader build",
            kind="file",
        )
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p07-loader-recovery-build-"
        ) as temporary_name:
            temporary_root = Path(temporary_name).resolve()
            clean_executable = temporary_root / "p07-holdout-frame-loader-a"
            clean_reproducibility_executable = (
                temporary_root / "p07-holdout-frame-loader-b"
            )
            build = build_p07_frame_loader(
                source_path=source,
                output_path=clean_executable,
                repository_root=repository_root,
            )
            reproducibility_build = build_p07_frame_loader(
                source_path=source,
                output_path=clean_reproducibility_executable,
                repository_root=repository_root,
            )
            if (
                _read_regular_file(
                    clean_executable,
                    "clean recovery P07 loader build",
                )
                != _read_regular_file(
                    executable,
                    "persisted recovery P07 loader build",
                )
                or _read_regular_file(
                    clean_reproducibility_executable,
                    "clean reproducibility P07 loader build",
                )
                != _read_regular_file(
                    reproducibility_executable,
                    "persisted reproducibility P07 loader build",
                )
            ):
                raise ValueError(
                    "persisted P07 loader builds differ from clean recovery builds"
                )
    else:
        build = build_p07_frame_loader(
            source_path=source,
            output_path=executable,
            repository_root=repository_root,
        )
        reproducibility_build = build_p07_frame_loader(
            source_path=source,
            output_path=reproducibility_executable,
            repository_root=repository_root,
        )
    if (
        build.get("manifest_sha256") != manifest_sha256(build)
        or build.get("executable_sha256") != expected_executable_sha256
        or _sha256_file(executable) != expected_executable_sha256
    ):
        raise ValueError("P07 loader build differs from its explicit expected hash")
    if (
        reproducibility_build != build
        or _read_regular_file(executable, "first P07 loader build")
        != _read_regular_file(
            reproducibility_executable,
            "second P07 loader build",
        )
        or _sha256_file(reproducibility_executable)
        != expected_executable_sha256
    ):
        raise ValueError("P07 loader builds differ across clean output paths")

    records = []
    for _ in range(2):
        with tempfile.TemporaryDirectory(prefix="mirmir-p07-loader-self-test-") as name:
            root = Path(name).resolve()
            completed = subprocess.run(
                [
                    str(executable),
                    "self-test",
                    "--output-directory",
                    str(root),
                ],
                cwd=repository_root,
                check=False,
                capture_output=True,
                timeout=300,
            )
            if completed.returncode != 0:
                raise ValueError(
                    "P07 loader self-test failed: {}".format(
                        completed.stderr.decode("utf-8", "replace").strip()
                    )
                )
            document = _decode_json(completed.stdout, "P07 loader self-test")
            payload = _read_regular_file(root / "self-test.nv12", "P07 loader self-test crop")
            if (
                len(payload) != document.get("nv12_size_bytes")
                or hashlib.sha256(payload).hexdigest() != document.get("nv12_sha256")
                or document.get("manifest_sha256") != manifest_sha256(document)
            ):
                raise ValueError("P07 loader self-test hash/reopen evidence differs")
            records.append(document)
    if records[0] != records[1]:
        raise ValueError("P07 loader self-tests are not byte-deterministic")
    return executable, {
        "build": build,
        "reproducibility_build": reproducibility_build,
        "builds_byte_identical": True,
        "self_tests": records,
        "self_tests_byte_identical": True,
    }


def _validate_cache_before_write(
    *,
    cache_root: Path,
    protected_roots: list[Path],
) -> None:
    _validate_existing_path(cache_root, label="P07 cache root", kind="directory")
    if any(cache_root.iterdir()):
        raise ValueError("P07 cache root must be fresh and empty before preopen build")
    for root in protected_roots:
        resolved = root.resolve(strict=True)
        if _paths_overlap(cache_root, resolved):
            raise ValueError("P07 cache root overlaps a protected evidence/data root")


def _validate_source_tree_direction(
    *,
    cache_root: Path,
    source_root: Path,
) -> None:
    cache = cache_root.resolve(strict=True)
    source = source_root.resolve(strict=True)
    if _paths_overlap(cache, source):
        raise ValueError(
            "P07 cache root must be strictly outside the source repository"
        )


def _validate_cache_output_isolation(
    *,
    cache_root: Path,
    output_directory: Path,
) -> None:
    output = _normalized_absolute(output_directory, "P07 output directory")
    if _existing_and_future_paths_overlap(cache_root, output):
        raise ValueError("P07 cache root overlaps the output directory")


def _pin_external_cache_root(
    cache_root: Path,
) -> tuple[int, os.stat_result]:
    descriptor, identity = _open_directory_nofollow(
        cache_root,
        "external P07 cache root",
    )
    _snapshot_descriptor_tree(descriptor, "external P07 cache root")
    return descriptor, identity


def _verify_external_cache_root(
    cache_root: Path,
    descriptor: int,
    identity: os.stat_result,
) -> Mapping[str, object]:
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (identity.st_dev, identity.st_ino):
        raise ValueError("pinned external P07 cache descriptor changed")
    _verify_directory_path_identity(
        cache_root,
        identity,
        "external P07 cache root",
    )
    return _snapshot_descriptor_tree(descriptor, "external P07 cache root")


def _advance_external_cache_snapshot(
    previous: Mapping[str, object],
    current: Mapping[str, object],
) -> Mapping[str, object]:
    previous_rows = {
        str(row["path"]): row
        for row in previous.get("entries", [])
        if isinstance(row, dict) and isinstance(row.get("path"), str)
    }
    current_rows = {
        str(row["path"]): row
        for row in current.get("entries", [])
        if isinstance(row, dict) and isinstance(row.get("path"), str)
    }
    if previous.get("root") != current.get("root"):
        raise ValueError("external P07 cache root identity changed")
    for path, before in previous_rows.items():
        after = current_rows.get(path)
        if after is None:
            raise ValueError("external P07 cache entry disappeared: {}".format(path))
        if any(
            before.get(field) != after.get(field)
            for field in ("kind", "device", "inode")
        ):
            raise ValueError("external P07 cache entry identity changed: {}".format(path))
        if before.get("kind") == "file" and before != after:
            raise ValueError("external P07 cache file changed: {}".format(path))
    return current


def _preopen_summary(evaluator: P07ProductionEvaluator) -> Mapping[str, object]:
    summary = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_preopen_production_verification",
        "status": "pass",
        "configuration_sha256": evaluator.locked.configuration_sha256,
        "p06_release_bundle_manifest_sha256": (
            evaluator.locked.release_bundle_manifest_sha256
        ),
        "release_native_executable_sha256": (
            evaluator.locked.release_native_executable.sha256
        ),
        "release_native_source_manifest_sha256": (
            evaluator.locked.release_native_executable.source_manifest_sha256
        ),
        "release_lut_independent_recompile": evaluator.release_lut_recompile,
        "loader_preopen_verification": evaluator.loader_verification,
        "p00_continuity_evidence": evaluator.p00_continuity,
        "analytic_fixture_row_count": len(evaluator.analytic_rows),
        "analytic_fixture_rows_sha256": canonical_sha256(
            list(evaluator.analytic_rows)
        ),
        "analytic_runtime_case_count": len(evaluator.analytic_runtime_cases),
        "analytic_runtime_cases_sha256": canonical_sha256(
            list(evaluator.analytic_runtime_cases)
        ),
        "analytic_p06_comparison": evaluator.analytic_comparison,
        "preopen_cache_snapshot": evaluator.preopen_cache_snapshot,
        "holdout_guard_constructed": False,
        "holdout_accessed": False,
    }
    summary["manifest_sha256"] = canonical_sha256(summary)
    validate_schema(
        summary,
        REPOSITORY_ROOT
        / "validation/calibration_v2/schemas/"
        "p07-preopen-production-verification-v1.schema.json",
    )
    return summary


def _run_selected_mode(
    *,
    preopen_verify_only: bool,
    evaluator: P07ProductionEvaluator,
    live_runner: Callable[[], Mapping[str, object]],
) -> Mapping[str, object]:
    if preopen_verify_only:
        return _preopen_summary(evaluator)
    return live_runner()


class _RecoveryBoundInputs:
    def __init__(self, records: list[Mapping[str, object]]) -> None:
        self._records = {
            str(record["id"]): dict(record)
            for record in records
            if isinstance(record, dict)
            and isinstance(record.get("id"), str)
        }

    def record(self, identifier: str) -> Mapping[str, object]:
        try:
            return self._records[identifier]
        except KeyError as error:
            raise P07ExecutionError(
                "P07 recovery direct-input record is absent: {}".format(
                    identifier
                )
            ) from error


def _live_binding(
    arguments: argparse.Namespace,
    *,
    live_ledger_path: Path,
    live_anchor_path: Path,
    live_preopen_receipt_path: Path,
    repository_sealed_copy_path: Path,
    repository_attestation_path: Path,
) -> LiveHoldoutPreopenBinding:
    return LiveHoldoutPreopenBinding(
        live_ledger_path=live_ledger_path,
        live_anchor_path=live_anchor_path,
        live_preopen_receipt_path=live_preopen_receipt_path,
        expected_live_ledger_root_identity_sha256=(
            arguments.expected_live_ledger_root_identity_sha256
        ),
        expected_live_anchor_root_identity_sha256=(
            arguments.expected_live_anchor_root_identity_sha256
        ),
        expected_live_preopen_receipt_sha256=(
            arguments.expected_live_preopen_receipt_file_sha256
        ),
        repository_sealed_copy_path=repository_sealed_copy_path,
        expected_repository_sealed_copy_sha256=(
            arguments.expected_repository_sealed_copy_sha256
        ),
        repository_attestation_path=repository_attestation_path,
        expected_repository_attestation_sha256=(
            arguments.expected_repository_attestation_sha256
        ),
    )


def _make_executor(
    arguments: argparse.Namespace,
    *,
    repository_root: Path,
    p07_cache_root: Path,
    support_roots: Mapping[str, Path],
    live_binding: LiveHoldoutPreopenBinding,
) -> P07HoldoutExecutor:
    executor = P07HoldoutExecutor(
        repository_root=repository_root,
        holdout_root=arguments.holdout_root.resolve(strict=True),
        sampling_plan_path=arguments.sampling_plan_path.resolve(strict=True),
        expected_sampling_plan_sha256=(
            arguments.expected_sampling_plan_file_sha256
        ),
        no_pixel_attestation_path=(
            arguments.no_pixel_attestation_path.resolve(strict=True)
        ),
        expected_no_pixel_attestation_sha256=(
            arguments.expected_no_pixel_attestation_file_sha256
        ),
        loader_executable=(
            p07_cache_root / "p07-holdout-frame-loader-a"
        ),
        expected_loader_sha256=arguments.expected_loader_executable_sha256,
        p06_release_root=arguments.p06_release_root.resolve(strict=True),
        p06_release_manifest_path=(
            arguments.p06_release_manifest_path.resolve(strict=True)
        ),
        support_evidence_roots={
            identifier: path.resolve(strict=True)
            for identifier, path in support_roots.items()
        },
        p07_cache_root=p07_cache_root,
        live_holdout_preopen_binding=live_binding,
        publication_command=shlex.join(
            [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]
        ),
        publication_platform=platform.platform(),
    )
    executor.expected_release_manifest_sha256 = (
        arguments.expected_p06_release_manifest_sha256
    )
    return executor


def _read_recovery_transaction_intent(
    output_directory: Path,
) -> Mapping[str, object] | None:
    parent_descriptor, parent_identity = _open_directory_nofollow(
        output_directory.parent,
        "P07 recovery output parent",
    )
    workspace = None
    try:
        workspace = _P07TransactionWorkspace.open_existing(
            output_directory=output_directory,
            parent_descriptor=parent_descriptor,
            parent_identity=parent_identity,
        )
        if workspace is None:
            return None
        return dict(workspace.intent)
    finally:
        if workspace is not None:
            workspace.close()
        os.close(parent_descriptor)


def _terminal_identity_document(
    output_directory: Path,
) -> Mapping[str, object] | None:
    directories = (
        output_directory,
        output_directory.with_name(output_directory.name + ".failed"),
        _pre_guard_failure_staging_path(output_directory),
    )
    for directory in directories:
        for name in (
            "p07-execution-result.json",
            "failed-version-archive.json",
        ):
            path = directory / name
            if os.path.lexists(path):
                _, document = _read_json(path, "P07 recovery terminal identity")
                return document
    return None


def _recovery_mode(
    *,
    output_directory: Path,
    live_ledger_path: Path,
    live_anchor_path: Path,
) -> tuple[str, Mapping[str, object] | None]:
    transaction_path = _transaction_directory_path(output_directory)
    if os.path.lexists(transaction_path):
        intent = _read_recovery_transaction_intent(output_directory)
        if intent is None:
            raise P07ExecutionError(
                "P07 recovery transaction path is not an owned transaction"
            )
        try:
            _, ledger = _read_json(
                live_ledger_path,
                "P07 recovery guard ledger state",
            )
        except BaseException:
            return "terminal_or_consumed", intent
        if ledger.get("state") == "sealed" and not os.path.lexists(
            live_anchor_path
        ):
            return "resume_pre_guard", intent
        return "terminal_or_consumed", intent
    terminal = _terminal_identity_document(output_directory)
    if terminal is not None:
        return "terminal_or_consumed", None
    return "fresh", None


def _recovery_bound_inputs(
    *,
    repository_root: Path,
    output_directory: Path,
    transaction_intent: Mapping[str, object] | None,
) -> _RecoveryBoundInputs:
    records = (
        transaction_intent.get("direct_input_bindings")
        if transaction_intent is not None
        else None
    )
    if not isinstance(records, list):
        terminal = _terminal_identity_document(output_directory)
        records = (
            terminal.get("direct_input_bindings")
            if terminal is not None
            else None
        )
    if not isinstance(records, list):
        _, plan = _read_json(
            repository_root
            / "validation/calibration_v2/contracts/calibration-plan-v1.json",
            "P07 recovery calibration plan",
        )
        declared = plan.get("input_bindings")
        if not isinstance(declared, list):
            raise P07ExecutionError(
                "P07 recovery calibration input bindings are absent"
            )
        records = [
            {"id": row.get("id"), "path": row.get("path")}
            for row in declared
            if isinstance(row, dict)
        ]
    bound = _RecoveryBoundInputs(records)
    for identifier in (
        "degradation_policy",
        "quality_harness_implementation_manifest",
        "corpus_lock",
    ):
        bound.record(identifier)
    return bound


def _run_terminal_or_consumed_recovery(
    *,
    arguments: argparse.Namespace,
    repository_root: Path,
    executor: P07HoldoutExecutor,
    transaction_intent: Mapping[str, object] | None,
    configuration_lock: Mapping[str, object],
    live_ledger_path: Path,
    live_anchor_path: Path,
) -> Mapping[str, object]:
    output_directory = arguments.output_directory.resolve(strict=False)
    guard = P06V3HoldoutAccessGuard(
        arguments.expected_corpus_manifest_sha256,
        ledger_path=live_ledger_path,
        anchor_path=live_anchor_path,
        release_root=arguments.p06_release_root.resolve(strict=True),
    )

    def unreachable_evaluator(*unused: object) -> Mapping[str, object]:
        del unused
        raise P07ExecutionError(
            "P07 terminal recovery unexpectedly requested a new holdout evaluation"
        )

    return executor.execute_once(
        configuration_lock=configuration_lock,
        guard=guard,
        evaluator=unreachable_evaluator,
        output_directory=output_directory,
    )


def _publish_runner_pre_guard_failure(
    *,
    executor: P07HoldoutExecutor,
    output_directory: Path,
    configuration_lock: Mapping[str, object],
    error: BaseException,
) -> None:
    executor._validate_output_isolation(output_directory)
    parent_descriptor, parent_identity = _open_directory_nofollow(
        output_directory.parent,
        "P07 runner failure output parent",
    )
    try:
        executor._publish_pre_guard_failure(
            output_directory=output_directory,
            output_parent_pin=(parent_descriptor, parent_identity),
            configuration_lock=configuration_lock,
            error=error,
        )
    finally:
        os.close(parent_descriptor)
        cache_descriptor = getattr(executor, "_p07_cache_descriptor", None)
        if isinstance(cache_descriptor, int):
            os.close(cache_descriptor)
            executor._p07_cache_descriptor = None
            executor._p07_cache_identity = None


def _protected_directories(
    paths: list[Path],
) -> tuple[Path, ...]:
    result = []
    seen = set()
    for path in paths:
        resolved = path.resolve(strict=True)
        value = os.fspath(resolved)
        if value not in seen:
            seen.add(value)
            result.append(resolved)
    return tuple(result)


def _main(arguments: argparse.Namespace) -> int:
    repository_root = arguments.repository_root.resolve(strict=True)
    if not arguments.p07_cache_root.is_absolute():
        raise ValueError("P07 cache root must be an absolute path")
    _validate_existing_path(
        arguments.p07_cache_root,
        label="P07 cache root",
        kind="directory",
    )
    p07_cache_root = arguments.p07_cache_root.resolve(strict=True)
    live_ledger_path = arguments.live_ledger_path.resolve(strict=True)
    live_anchor_path = arguments.live_anchor_path.resolve(strict=False)
    live_preopen_receipt_path = arguments.live_preopen_receipt_path.resolve(
        strict=True
    )
    repository_sealed_copy_path = arguments.repository_sealed_copy_path.resolve(
        strict=True
    )
    repository_attestation_path = arguments.repository_attestation_path.resolve(
        strict=True
    )
    support_roots = _support_roots(arguments.support_root)
    output_directory = arguments.output_directory.resolve(strict=False)
    protected_roots = _protected_directories(
        [
            output_directory.parent,
            arguments.holdout_root,
            arguments.p06_release_root,
            arguments.p04_quality_root,
            repository_root,
            arguments.sampling_plan_path.parent,
            arguments.no_pixel_attestation_path.parent,
            live_ledger_path.parent,
            live_anchor_path.parent,
            live_preopen_receipt_path.parent,
            repository_sealed_copy_path.parent,
            repository_attestation_path.parent,
            arguments.g04_root,
            arguments.g05_root,
            arguments.g05_instruction_package_root,
            arguments.g06_root,
            *support_roots.values(),
        ]
    )
    live_binding = _live_binding(
        arguments,
        live_ledger_path=live_ledger_path,
        live_anchor_path=live_anchor_path,
        live_preopen_receipt_path=live_preopen_receipt_path,
        repository_sealed_copy_path=repository_sealed_copy_path,
        repository_attestation_path=repository_attestation_path,
    )
    executor = _make_executor(
        arguments,
        repository_root=repository_root,
        p07_cache_root=p07_cache_root,
        support_roots=support_roots,
        live_binding=live_binding,
    )
    release_bundle, configuration_lock = _read_v3_configuration_lock(
        release_root=arguments.p06_release_root.resolve(strict=True),
        release_manifest_path=arguments.p06_release_manifest_path.resolve(
            strict=True
        ),
        expected_release_manifest_sha256=(
            arguments.expected_p06_release_manifest_sha256
        ),
    )
    recovery_mode, transaction_intent = _recovery_mode(
        output_directory=output_directory,
        live_ledger_path=live_ledger_path,
        live_anchor_path=live_anchor_path,
    )
    if recovery_mode == "terminal_or_consumed":
        result = _run_terminal_or_consumed_recovery(
            arguments=arguments,
            repository_root=repository_root,
            executor=executor,
            transaction_intent=transaction_intent,
            configuration_lock=configuration_lock,
            live_ledger_path=live_ledger_path,
            live_anchor_path=live_anchor_path,
        )
        print(
            json.dumps(
                result,
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 0

    cache_descriptor: int | None = None
    evaluator: P07ProductionEvaluator | None = None
    try:
        try:
            if recovery_mode == "fresh":
                _validate_cache_before_write(
                    cache_root=p07_cache_root,
                    protected_roots=list(protected_roots),
                )
            else:
                for protected_root in protected_roots:
                    if _paths_overlap(p07_cache_root, protected_root):
                        raise ValueError(
                            "P07 recovery cache root overlaps a protected root"
                        )
            _validate_source_tree_direction(
                cache_root=p07_cache_root,
                source_root=repository_root,
            )
            _validate_cache_output_isolation(
                cache_root=p07_cache_root,
                output_directory=output_directory,
            )
            cache_descriptor, cache_identity = _pin_external_cache_root(
                p07_cache_root
            )
            if _sha256_file(arguments.sampling_plan_path) != (
                arguments.expected_sampling_plan_file_sha256
            ):
                raise ValueError(
                    "sampling-plan file differs from explicit expected hash"
                )
            if _sha256_file(arguments.no_pixel_attestation_path) != (
                arguments.expected_no_pixel_attestation_file_sha256
            ):
                raise ValueError(
                    "no-pixel attestation differs from explicit expected hash"
                )
            if p06_release_bundle_sha256(release_bundle) != (
                arguments.expected_p06_release_manifest_sha256
            ):
                raise ValueError(
                    "P06 release manifest differs from explicit expected hash"
                )
            _verify_fresh_source_gate_semantics(
                arguments=arguments,
                repository_root=repository_root,
                release_bundle=release_bundle,
            )

            bound = bind_preregistered_inputs(
                repository_root,
                live_holdout_preopen_binding=live_binding,
            )
            bound.verify_unchanged()
            corpus_manifest_sha256 = str(
                bound.documents["corpus_lock"]["manifest_sha256"]
            )
            if (
                corpus_manifest_sha256
                != arguments.expected_corpus_manifest_sha256
            ):
                raise ValueError(
                    "corpus manifest differs from explicit expected hash"
                )

            cache_snapshot = _verify_external_cache_root(
                p07_cache_root,
                cache_descriptor,
                cache_identity,
            )
            loader, loader_verification = _loader_verification(
                repository_root=repository_root,
                cache_root=p07_cache_root,
                expected_executable_sha256=(
                    arguments.expected_loader_executable_sha256
                ),
                reuse_existing=(recovery_mode == "resume_pre_guard"),
            )
            if loader != executor.loader_executable:
                raise P07ExecutionError(
                    "P07 executor and verified loader paths differ"
                )
            cache_snapshot = _advance_external_cache_snapshot(
                cache_snapshot,
                _verify_external_cache_root(
                    p07_cache_root,
                    cache_descriptor,
                    cache_identity,
                ),
            )
            preflight = executor.preflight()
            if p06_release_bundle_sha256(preflight.release_bundle) != (
                arguments.expected_p06_release_manifest_sha256
            ):
                raise ValueError(
                    "support-aware P06 preflight changed the release identity"
                )

            native_factory = make_native_candidate_adapter_factory(
                repository_root,
                cache_root=p07_cache_root / "current-source-extra-parity",
                timeout_seconds=arguments.timeout_seconds,
                bound_inputs=bound,
                verify_bound_inputs=True,
            )
            cache_snapshot = _advance_external_cache_snapshot(
                cache_snapshot,
                _verify_external_cache_root(
                    p07_cache_root,
                    cache_descriptor,
                    cache_identity,
                ),
            )
            evaluator = P07ProductionEvaluator.prepare(
                preflight=preflight,
                release_root=arguments.p06_release_root.resolve(strict=True),
                calibration_run_support_root=(
                    support_roots["calibration_run"].resolve(strict=True)
                ),
                production_writer_support_root=(
                    support_roots["production_writer"].resolve(strict=True)
                ),
                bound_inputs=bound,
                native_factory=native_factory,
                p07_cache_root=p07_cache_root,
                loader_verification=loader_verification,
                protected_roots=protected_roots,
                expected_cache_root_identity=(
                    cache_identity.st_dev,
                    cache_identity.st_ino,
                ),
            )
            cache_snapshot = _advance_external_cache_snapshot(
                cache_snapshot,
                _verify_external_cache_root(
                    p07_cache_root,
                    cache_descriptor,
                    cache_identity,
                ),
            )
        except BaseException as error:
            _publish_runner_pre_guard_failure(
                executor=executor,
                output_directory=output_directory,
                configuration_lock=configuration_lock,
                error=error,
            )
            raise

        def run_live() -> Mapping[str, object]:
            assert cache_descriptor is not None
            assert evaluator is not None
            _verify_external_cache_root(
                p07_cache_root,
                cache_descriptor,
                cache_identity,
            )
            guard = P06V3HoldoutAccessGuard(
                arguments.expected_corpus_manifest_sha256,
                ledger_path=live_ledger_path,
                anchor_path=live_anchor_path,
                release_root=arguments.p06_release_root.resolve(strict=True),
            )
            live_result = executor.execute_once(
                configuration_lock=configuration_lock,
                guard=guard,
                evaluator=evaluator,
                output_directory=output_directory,
            )
            _verify_external_cache_root(
                p07_cache_root,
                cache_descriptor,
                cache_identity,
            )
            return live_result

        assert evaluator is not None
        if arguments.preopen_verify_only:
            try:
                result = _run_selected_mode(
                    preopen_verify_only=True,
                    evaluator=evaluator,
                    live_runner=run_live,
                )
            except BaseException as error:
                _publish_runner_pre_guard_failure(
                    executor=executor,
                    output_directory=output_directory,
                    configuration_lock=configuration_lock,
                    error=error,
                )
                raise
        else:
            result = _run_selected_mode(
                preopen_verify_only=False,
                evaluator=evaluator,
                live_runner=run_live,
            )
        print(
            json.dumps(
                result,
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 0
    finally:
        if evaluator is not None:
            evaluator.close()
        if cache_descriptor is not None:
            os.close(cache_descriptor)
        executor_cache_descriptor = getattr(
            executor,
            "_p07_cache_descriptor",
            None,
        )
        if isinstance(executor_cache_descriptor, int):
            os.close(executor_cache_descriptor)
            executor._p07_cache_descriptor = None
            executor._p07_cache_identity = None


def main() -> int:
    arguments = _arguments()
    try:
        return _main(arguments)
    except BaseException as error:
        anchor_path = Path(arguments.live_anchor_path)
        output_directory = Path(arguments.output_directory).resolve(strict=False)
        durable_executor_failure = any(
            os.path.lexists(path)
            for path in (
                output_directory / "failed-version-archive.json",
                output_directory.with_name(output_directory.name + ".failed")
                / "failed-version-archive.json",
                _pre_guard_failure_staging_path(output_directory)
                / "failed-version-archive.json",
            )
        )
        if not os.path.lexists(anchor_path) and not durable_executor_failure:
            _publish_startup_nonopening_failure(
                output_directory=output_directory,
                error=error,
            )
        raise


if __name__ == "__main__":
    raise SystemExit(main())
