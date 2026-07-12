from __future__ import annotations

import copy
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import time
from typing import Callable, Mapping
import uuid

import numpy as np
import pytest

import validation.calibration_v2.production_evaluator as evaluator_module
from validation.calibration_v2.native_adapter.factory import (
    _SWIFT_SOURCE_PATHS,
    make_native_candidate_adapter_factory,
)
from validation.calibration_v2.production_evaluator import (
    COMMON_CONTROL_BOUNDARY_CONTRACT,
    _NativeSelectionOutputCache,
    _PreparedControlCase,
    canonical_json_bytes,
    canonical_sha256,
    search_non_ash_development,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
)
from validation.calibration_v2.runner import (
    _SHARED_BANK_COORDINATES,
    _AdapterInvocationTracker,
    corpus_lock_bundle_document,
    corpus_lock_bundle_sha256,
    parameter_domains,
)
from validation.calibration_v2.tests.test_native_adapter import _BoundStub
from validation.quality.src.mirmir_quality.arrays import PlanarFrame
from validation.quality.src.mirmir_quality.json_tools import validate_schema
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateContext,
    _round_trip_locked_bt709_video_range_nv12,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
OUTPUT_Y_SHAPE = (192, 324)
OUTPUT_CHROMA_SHAPE = (96, 162)
MAXIMUM_UNIQUE_RULES_PER_BANK = 1297
FIRST_OUTER_SWEEP_BANK_COUNT = 39
MAXIMUM_BANK_COUNT = 305
PREPARED_CASE_COUNT = 18
RULE_SCOPED_NATIVE_PROOF_FILES_PER_RULE = PREPARED_CASE_COUNT
RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE = PREPARED_CASE_COUNT
RULE_SCOPED_AGGREGATE_ORIGIN_FILES_PER_RULE = 1
RULE_SCOPED_AGGREGATE_DOCUMENT_FILES_PER_RULE = 2
RULE_SCOPED_FILES_PER_RULE = (
    RULE_SCOPED_NATIVE_PROOF_FILES_PER_RULE
    + RULE_SCOPED_AGGREGATE_ORIGIN_FILES_PER_RULE
    + RULE_SCOPED_AGGREGATE_DOCUMENT_FILES_PER_RULE
)
RULE_SCOPED_INODES_PER_RULE = (
    RULE_SCOPED_FILES_PER_RULE
    + RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE
)
BENCHMARK_SCHEMA_RELATIVE_PATH = (
    "validation/calibration_v2/schemas/"
    "control-aggregate-cache-native-benchmark-v1.schema.json"
)
IMPLEMENTATION_CLOSURE_PATHS = (
    "validation/calibration_v2/tests/test_control_aggregate_native_benchmark.py",
    BENCHMARK_SCHEMA_RELATIVE_PATH,
    "validation/calibration_v2/production_evaluator.py",
    "validation/calibration_v2/production_providers.py",
    "validation/calibration_v2/native_adapter/factory.py",
    "validation/calibration_v2/runner.py",
    "validation/calibration_v2/tests/test_native_adapter.py",
    "validation/calibration_v2/schemas/p06-runtime-correction-artifact-manifest-v1.schema.json",
    "validation/calibration_v2/tools/finalize_p06_runtime_correction.py",
    "validation/calibration_v2/tests/test_p06_runtime_correction_artifacts.py",
    "validation/quality/src/mirmir_quality/arrays.py",
    "validation/quality/src/mirmir_quality/degradation.py",
    "validation/quality/src/mirmir_quality/json_tools.py",
    "validation/quality/src/mirmir_quality/metrics.py",
    "validation/quality/src/mirmir_quality/production_dry_run.py",
    "validation/quality/locks/quality-harness-implementation-manifest.json",
    *_SWIFT_SOURCE_PATHS,
)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(
        timespec="microseconds"
    ).replace("+00:00", "Z")


def _absolute_lexical_path(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def _implementation_closure() -> Mapping[str, object]:
    if len(IMPLEMENTATION_CLOSURE_PATHS) != len(
        set(IMPLEMENTATION_CLOSURE_PATHS)
    ):
        raise AssertionError("benchmark implementation path is duplicated")
    ordered_files = []
    for relative in IMPLEMENTATION_CLOSURE_PATHS:
        path = REPOSITORY_ROOT.joinpath(*Path(relative).parts)
        payload = path.read_bytes()
        ordered_files.append(
            {
                "path": relative,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )
    return {
        "ordered_files": ordered_files,
        "ordered_files_sha256": canonical_sha256(ordered_files),
    }


def _verify_ordered_file_records_unchanged(
    records: object,
) -> None:
    if not isinstance(records, list) or not records:
        raise AssertionError("ordered bound-input records are absent")
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "id",
            "path",
            "sha256",
            "size_bytes",
        }:
            raise AssertionError("bound-input file record differs")
        relative = record["path"]
        if not isinstance(relative, str):
            raise AssertionError("bound-input path is invalid")
        path = REPOSITORY_ROOT.joinpath(*Path(relative).parts)
        payload = path.read_bytes()
        if (
            len(payload) != record["size_bytes"]
            or hashlib.sha256(payload).hexdigest() != record["sha256"]
        ):
            raise AssertionError("bound-input file changed during benchmark")


def _preflight_new_output(
    path: Path,
) -> tuple[tuple[int, int], list[Mapping[str, object]], str]:
    path = _absolute_lexical_path(path)
    parent = path.parent if path.parent != Path("") else Path(".")
    name = path.name
    if not name or name in {".", ".."}:
        raise AssertionError("benchmark output filename is invalid")
    directory_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        directory_flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    directory_descriptor = os.open(parent, directory_flags)
    try:
        identity = os.fstat(directory_descriptor)
        try:
            os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("benchmark output already exists")
        recovery_actions = []
        for entry in sorted(
            os.scandir(directory_descriptor),
            key=lambda value: value.name,
        ):
            if not _is_recognized_benchmark_temporary(name, entry.name):
                continue
            action, _ = _snapshot_benchmark_temporary_at(
                directory_descriptor,
                entry.name,
                required_link_count=1,
            )
            recovery_actions.append(action)
        temporary_name = f".{name}.{secrets.token_hex(16)}.tmp"
        try:
            os.stat(
                temporary_name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("benchmark publication temporary exists")
        return (
            (identity.st_dev, identity.st_ino),
            recovery_actions,
            temporary_name,
        )
    finally:
        os.close(directory_descriptor)


def _is_recognized_benchmark_temporary(
    output_name: str,
    temporary_name: str,
) -> bool:
    return bool(
        re.fullmatch(
            rf"\.{re.escape(output_name)}\.[0-9a-f]{{32}}\.tmp",
            temporary_name,
        )
        or re.fullmatch(
            r"\.mirmir-benchmark-[0-9a-f]{32}\.tmp",
            temporary_name,
        )
    )


def _snapshot_benchmark_temporary_at(
    directory_descriptor: int,
    name: str,
    *,
    required_link_count: int,
) -> tuple[Mapping[str, object], tuple[int, int, int, int]]:
    before = os.stat(
        name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != required_link_count
    ):
        raise AssertionError(
            "recognized benchmark temporary has invalid type or link count"
        )
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != required_link_count
        ):
            raise AssertionError(
                "recognized benchmark temporary changed while opening"
            )
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    finally:
        os.close(descriptor)
    after = os.stat(
        name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or after.st_size != size
        or after.st_mtime_ns != before.st_mtime_ns
        or after.st_nlink != required_link_count
    ):
        raise AssertionError(
            "recognized benchmark temporary changed while snapshotting"
        )
    return (
        {
            "action": "removed_recognized_stale_benchmark_temporary",
            "path": name,
            "sha256": digest.hexdigest(),
            "size_bytes": size,
        },
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
    )


def _validate_recovery_actions(
    output_name: str,
    recovery_actions: object,
) -> list[Mapping[str, object]]:
    if not isinstance(recovery_actions, list):
        raise AssertionError("benchmark recovery actions are invalid")
    validated = []
    names = set()
    for action in recovery_actions:
        if not isinstance(action, dict) or set(action) != {
            "action",
            "path",
            "sha256",
            "size_bytes",
        }:
            raise AssertionError("benchmark recovery action fields differ")
        name = action.get("path")
        size = action.get("size_bytes")
        if (
            action.get("action")
            != "removed_recognized_stale_benchmark_temporary"
            or not isinstance(name, str)
            or not _is_recognized_benchmark_temporary(output_name, name)
            or name in names
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
        ):
            raise AssertionError("benchmark recovery action is invalid")
        _require_benchmark_sha256(
            action.get("sha256"),
            "benchmark recovery temporary",
        )
        names.add(name)
        validated.append(dict(action))
    return validated


def _recognized_temporary_names_at(
    directory_descriptor: int,
    output_name: str,
) -> set[str]:
    return {
        entry.name
        for entry in os.scandir(directory_descriptor)
        if _is_recognized_benchmark_temporary(output_name, entry.name)
    }


def _verify_recorded_stale_temporaries_at(
    directory_descriptor: int,
    output_name: str,
    recovery_actions: object,
) -> Mapping[str, tuple[int, int, int, int]]:
    validated = _validate_recovery_actions(output_name, recovery_actions)
    snapshots = {}
    for action in validated:
        name = str(action["path"])
        try:
            observed, snapshot = _snapshot_benchmark_temporary_at(
                directory_descriptor,
                name,
                required_link_count=1,
            )
        except FileNotFoundError:
            continue
        if observed != action:
            raise AssertionError("recorded benchmark temporary bytes differ")
        snapshots[name] = snapshot
    return snapshots


def _assert_lexical_output_binding(
    path: Path,
    *,
    expected_parent_identity: tuple[int, int],
    expected_output_identity: tuple[int, int],
) -> None:
    path = _absolute_lexical_path(path)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_descriptor = os.open(path.parent, directory_flags)
    try:
        parent_status = os.fstat(directory_descriptor)
        if (parent_status.st_dev, parent_status.st_ino) != (
            expected_parent_identity
        ):
            raise AssertionError("benchmark output parent identity changed")
        before = os.stat(
            path.name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(before.st_mode)
            or (before.st_dev, before.st_ino) != expected_output_identity
        ):
            raise AssertionError("benchmark output inode binding changed")
        descriptor = os.open(
            path.name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != expected_output_identity
            ):
                raise AssertionError("benchmark output changed while reopening")
        finally:
            os.close(descriptor)
    finally:
        os.close(directory_descriptor)


def _complete_published_output_cleanup_at(
    directory_descriptor: int,
    output_name: str,
    *,
    recovery_actions: object,
    publication_temporary_name: str,
) -> None:
    if not re.fullmatch(
        rf"\.{re.escape(output_name)}\.[0-9a-f]{{32}}\.tmp",
        publication_temporary_name,
    ):
        raise AssertionError("benchmark publication temporary name is invalid")
    validated_actions = _validate_recovery_actions(
        output_name,
        recovery_actions,
    )
    recorded_names = {str(action["path"]) for action in validated_actions}
    if publication_temporary_name in recorded_names:
        raise AssertionError("benchmark publication temporary is recorded stale")
    recognized_names = _recognized_temporary_names_at(
        directory_descriptor,
        output_name,
    )
    expected_names = recorded_names | {publication_temporary_name}
    unexpected = recognized_names - expected_names
    if unexpected:
        raise AssertionError("unrecorded benchmark temporary is present")
    stale_snapshots = _verify_recorded_stale_temporaries_at(
        directory_descriptor,
        output_name,
        validated_actions,
    )
    final_status = os.stat(
        output_name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    if not stat.S_ISREG(final_status.st_mode):
        raise AssertionError("published benchmark output is not regular")
    publication_snapshot = None
    if publication_temporary_name in recognized_names:
        publication_status = os.stat(
            publication_temporary_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(publication_status.st_mode)
            or (publication_status.st_dev, publication_status.st_ino)
            != (final_status.st_dev, final_status.st_ino)
            or publication_status.st_nlink != 2
        ):
            raise AssertionError(
                "benchmark publication temporary is not the final hard link"
            )
        publication_snapshot = (
            publication_status.st_dev,
            publication_status.st_ino,
        )
    for name, snapshot in stale_snapshots.items():
        current = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (
            current.st_dev,
            current.st_ino,
            current.st_size,
            current.st_mtime_ns,
        ) != snapshot:
            raise AssertionError(
                "recorded benchmark temporary changed before deletion"
            )
        os.unlink(name, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)
    if publication_snapshot is not None:
        current = os.stat(
            publication_temporary_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (current.st_dev, current.st_ino) != publication_snapshot:
            raise AssertionError(
                "benchmark publication temporary changed before deletion"
            )
        os.unlink(publication_temporary_name, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)


def _complete_published_output_cleanup(
    path: Path,
    *,
    recovery_actions: object,
    publication_temporary_name: str,
) -> None:
    path = _absolute_lexical_path(path)
    parent = path.parent if path.parent != Path("") else Path(".")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(parent, directory_flags)
    try:
        parent_status = os.fstat(descriptor)
        output_status = os.stat(
            path.name,
            dir_fd=descriptor,
            follow_symlinks=False,
        )
        parent_identity = (parent_status.st_dev, parent_status.st_ino)
        output_identity = (output_status.st_dev, output_status.st_ino)
        _assert_lexical_output_binding(
            path,
            expected_parent_identity=parent_identity,
            expected_output_identity=output_identity,
        )
        _complete_published_output_cleanup_at(
            descriptor,
            path.name,
            recovery_actions=recovery_actions,
            publication_temporary_name=publication_temporary_name,
        )
        _assert_lexical_output_binding(
            path,
            expected_parent_identity=parent_identity,
            expected_output_identity=output_identity,
        )
    finally:
        os.close(descriptor)


def _read_existing_published_output_at(
    directory_descriptor: int,
    output_name: str,
) -> tuple[Mapping[str, object], tuple[int, int]] | None:
    try:
        before = os.stat(
            output_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(before.st_mode):
        raise AssertionError("published benchmark output is not regular")
    descriptor = os.open(
        output_name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino)
            != (before.st_dev, before.st_ino)
        ):
            raise AssertionError(
                "published benchmark output changed while opening"
            )
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        payload = b"".join(chunks)
    finally:
        os.close(descriptor)
    try:
        document = json.loads(payload)
    except (TypeError, ValueError) as error:
        raise AssertionError("published benchmark output is not JSON") from error
    if (
        not isinstance(document, dict)
        or canonical_json_bytes(document) + b"\n" != payload
    ):
        raise AssertionError("published benchmark output is not canonical")
    return document, (opened.st_dev, opened.st_ino)


def _resume_existing_published_output(
    path: Path,
    *,
    validate_document: Callable[
        [Mapping[str, object]], tuple[object, str]
    ],
) -> Mapping[str, object] | None:
    path = _absolute_lexical_path(path)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_descriptor = os.open(path.parent, directory_flags)
    try:
        parent_status = os.fstat(directory_descriptor)
        parent_identity = (parent_status.st_dev, parent_status.st_ino)
        reopened = _read_existing_published_output_at(
            directory_descriptor,
            path.name,
        )
        if reopened is None:
            return None
        document, output_identity = reopened
        recovery_actions, publication_temporary_name = validate_document(
            document
        )
        _assert_lexical_output_binding(
            path,
            expected_parent_identity=parent_identity,
            expected_output_identity=output_identity,
        )
        _complete_published_output_cleanup_at(
            directory_descriptor,
            path.name,
            recovery_actions=recovery_actions,
            publication_temporary_name=publication_temporary_name,
        )
        _assert_lexical_output_binding(
            path,
            expected_parent_identity=parent_identity,
            expected_output_identity=output_identity,
        )
        return document
    finally:
        os.close(directory_descriptor)


def _publish_new_durable(
    path: Path,
    payload: bytes,
    *,
    expected_parent_identity: tuple[int, int],
    recovery_actions: object,
    publication_temporary_name: str,
    crash_after_temporary_fsync: bool = False,
    crash_after_final_fsync_before_cleanup: bool = False,
) -> None:
    path = _absolute_lexical_path(path)
    parent = path.parent if path.parent != Path("") else Path(".")
    name = path.name
    if not name or name in {".", ".."}:
        raise AssertionError("benchmark output filename is invalid")
    directory_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        directory_flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    directory_descriptor = os.open(parent, directory_flags)
    opened_parent = os.fstat(directory_descriptor)
    if (opened_parent.st_dev, opened_parent.st_ino) != expected_parent_identity:
        os.close(directory_descriptor)
        raise AssertionError("benchmark output parent identity changed")
    if not re.fullmatch(
        rf"\.{re.escape(name)}\.[0-9a-f]{{32}}\.tmp",
        publication_temporary_name,
    ):
        os.close(directory_descriptor)
        raise AssertionError("benchmark publication temporary name is invalid")
    validated_recovery_actions = _validate_recovery_actions(
        name,
        recovery_actions,
    )
    if publication_temporary_name in {
        str(action["path"]) for action in validated_recovery_actions
    }:
        os.close(directory_descriptor)
        raise AssertionError("benchmark publication temporary is recorded stale")
    temporary_name = publication_temporary_name
    temporary_descriptor = None
    try:
        try:
            os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("benchmark output already exists")
        file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        temporary_descriptor = os.open(
            temporary_name,
            file_flags,
            0o600,
            dir_fd=directory_descriptor,
        )
        offset = 0
        while offset < len(payload):
            written = os.write(temporary_descriptor, payload[offset:])
            if written <= 0:
                raise AssertionError("benchmark output write made no progress")
            offset += written
        os.fsync(temporary_descriptor)
        recognized_names = _recognized_temporary_names_at(
            directory_descriptor,
            name,
        )
        expected_names = {
            str(action["path"]) for action in validated_recovery_actions
        } | {temporary_name}
        if recognized_names != expected_names:
            raise AssertionError(
                "benchmark temporary set changed before publication"
            )
        _verify_recorded_stale_temporaries_at(
            directory_descriptor,
            name,
            validated_recovery_actions,
        )
        current_publication_action, _ = _snapshot_benchmark_temporary_at(
            directory_descriptor,
            temporary_name,
            required_link_count=1,
        )
        if (
            current_publication_action["sha256"]
            != hashlib.sha256(payload).hexdigest()
            or current_publication_action["size_bytes"] != len(payload)
        ):
            raise AssertionError("benchmark publication temporary bytes differ")
        if crash_after_temporary_fsync:
            os.kill(os.getpid(), signal.SIGKILL)
        try:
            os.link(
                temporary_name,
                name,
                src_dir_fd=directory_descriptor,
                dst_dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError as error:
            raise AssertionError("benchmark output already exists") from error
        final_flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            final_flags |= os.O_NOFOLLOW
        final_descriptor = os.open(
            name,
            final_flags,
            dir_fd=directory_descriptor,
        )
        try:
            final_status = os.fstat(final_descriptor)
            if not stat.S_ISREG(final_status.st_mode):
                raise AssertionError("benchmark output is not a regular file")
            output_identity = (final_status.st_dev, final_status.st_ino)
            chunks = []
            while True:
                chunk = os.read(final_descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            if b"".join(chunks) != payload:
                raise AssertionError("benchmark output reopen differs")
        finally:
            os.close(final_descriptor)
        os.fsync(directory_descriptor)
        _assert_lexical_output_binding(
            path,
            expected_parent_identity=expected_parent_identity,
            expected_output_identity=output_identity,
        )
        if crash_after_final_fsync_before_cleanup:
            os.kill(os.getpid(), signal.SIGKILL)
        _complete_published_output_cleanup_at(
            directory_descriptor,
            name,
            recovery_actions=validated_recovery_actions,
            publication_temporary_name=temporary_name,
        )
        temporary_name = ""
        _assert_lexical_output_binding(
            path,
            expected_parent_identity=expected_parent_identity,
            expected_output_identity=output_identity,
        )
    finally:
        if temporary_descriptor is not None:
            os.close(temporary_descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name, dir_fd=directory_descriptor)
                os.fsync(directory_descriptor)
            except FileNotFoundError:
                pass
        os.close(directory_descriptor)


def _timing_summary(values: list[float]) -> Mapping[str, object]:
    if not values or any(
        not isinstance(value, float)
        or not math.isfinite(value)
        or value < 0.0
        for value in values
    ):
        raise AssertionError("benchmark timing sample is invalid")
    ordered = sorted(values)

    def nearest_rank(percentile: int) -> float:
        index = max(0, math.ceil(percentile * len(ordered) / 100.0) - 1)
        return ordered[index]

    return {
        "clock": "time.perf_counter_monotonic",
        "percentile_method": "nearest_rank_ceiling",
        "count": len(values),
        "total_seconds": float(sum(values)),
        "p50_seconds": nearest_rank(50),
        "p95_seconds": nearest_rank(95),
        "p99_seconds": nearest_rank(99),
        "raw_seconds_in_execution_order": list(values),
    }


def _run_identity_command(argv: tuple[str, ...]) -> str:
    result = subprocess.run(
        argv,
        cwd=REPOSITORY_ROOT,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise AssertionError(f"run identity command failed: {argv!r}")
    return result.stdout.decode("utf-8").rstrip("\n")


def _repository_state_binding() -> Mapping[str, object]:
    tracked_status = subprocess.run(
        (
            "git",
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=no",
        ),
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
    ).stdout
    untracked_paths_payload = subprocess.run(
        (
            "git",
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            ".",
            ":(exclude)Artifacts/**",
        ),
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
    ).stdout
    untracked_paths = sorted(
        os.fsdecode(value)
        for value in untracked_paths_payload.split(b"\0")
        if value
    )
    if len(untracked_paths) != len(set(untracked_paths)):
        raise AssertionError("non-artifact untracked path is duplicated")
    untracked_files = []
    for relative_value in untracked_paths:
        relative = Path(relative_value)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.parts[:1] == ("Artifacts",)
        ):
            raise AssertionError("non-artifact untracked path is invalid")
        path = REPOSITORY_ROOT.joinpath(*relative.parts)
        before = path.lstat()
        if stat.S_ISREG(before.st_mode):
            descriptor = os.open(
                path,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or (opened.st_dev, opened.st_ino)
                    != (before.st_dev, before.st_ino)
                ):
                    raise AssertionError(
                        "non-artifact untracked file changed while opening"
                    )
                digest = hashlib.sha256()
                size = 0
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    size += len(chunk)
                after = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            entry_kind = "regular_file"
        elif stat.S_ISLNK(before.st_mode):
            target = os.readlink(path)
            target_payload = os.fsencode(target)
            digest = hashlib.sha256(target_payload)
            size = len(target_payload)
            after = path.lstat()
            entry_kind = "symbolic_link_target"
        else:
            raise AssertionError(
                "non-artifact untracked path has unsupported file type"
            )
        if (
            (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
            or size != before.st_size
        ):
            raise AssertionError(
                "non-artifact untracked file changed while hashing"
            )
        untracked_files.append(
            {
                "path": relative.as_posix(),
                "entry_kind": entry_kind,
                "sha256": digest.hexdigest(),
                "size_bytes": size,
            }
        )
    binary_diff = subprocess.run(
        ("git", "diff", "--binary", "--no-ext-diff", "HEAD", "--"),
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
    ).stdout
    return {
        "head_commit": _run_identity_command(("git", "rev-parse", "HEAD")),
        "is_dirty": bool(tracked_status or untracked_files),
        "binding_algorithm": (
            "SHA-256 of raw NUL-delimited tracked-only `git status "
            "--porcelain=v1 --untracked-files=no`, raw tracked `git diff "
            "--binary --no-ext-diff HEAD --`, and ordered SHA-256/size/type "
            "bindings for every non-ignored untracked file outside Artifacts/**; "
            "Artifacts/** is excluded only from untracked state so immutable "
            "benchmark/finalizer output is self-reference-safe"
        ),
        "untracked_artifact_exclusion": "Artifacts/**",
        "tracked_porcelain_v1_z_sha256": hashlib.sha256(
            tracked_status
        ).hexdigest(),
        "tracked_porcelain_v1_z_size_bytes": len(tracked_status),
        "non_artifact_untracked_files": untracked_files,
        "non_artifact_untracked_files_sha256": canonical_sha256(
            untracked_files
        ),
        "tracked_binary_diff_sha256": hashlib.sha256(binary_diff).hexdigest(),
        "tracked_binary_diff_size_bytes": len(binary_diff),
    }


def _current_resume_input_bindings() -> Mapping[str, object]:
    bound = _BoundStub()
    baseline_path = (
        REPOSITORY_ROOT
        / "validation/calibration_v2/contracts/baseline-ablation-contract-v1.json"
    )
    baseline = json.loads(baseline_path.read_bytes())
    selector = baseline["non_ash_selector"]
    quality_manifest_path = (
        REPOSITORY_ROOT
        / "validation/quality/locks/quality-harness-implementation-manifest.json"
    )
    quality_manifest = json.loads(quality_manifest_path.read_bytes())
    unhashed_quality_manifest = dict(quality_manifest)
    declared_quality_manifest_sha256 = unhashed_quality_manifest.pop(
        "manifest_sha256",
        None,
    )
    if declared_quality_manifest_sha256 != canonical_sha256(
        unhashed_quality_manifest
    ):
        raise AssertionError("current quality implementation manifest differs")
    corpus_bundle = corpus_lock_bundle_document(bound)
    degradation_policy = bound.documents["degradation_policy"]
    metric_policy = bound.documents["metric_policy_seed"]
    development_sample = bound.documents["development_sample_lock"]
    corpus_lock = bound.documents["corpus_lock"]
    live_verification = dict(bound.live_holdout_preopen_verification)
    return {
        "ordered_bound_input_files": [dict(record) for record in bound.records],
        "selector_contract": selector,
        "selector_contract_sha256": canonical_sha256(selector),
        "baseline_ablation_contract_file_sha256": _sha256_file(
            baseline_path
        ),
        "degradation_policy_file_sha256": bound.record(
            "degradation_policy"
        )["sha256"],
        "degradation_policy_sha256": degradation_policy["policy_sha256"],
        "metric_policy_file_sha256": bound.record("metric_policy_seed")[
            "sha256"
        ],
        "metric_policy_sha256": metric_policy["policy_sha256"],
        "development_sample_lock_file_sha256": bound.record(
            "development_sample_lock"
        )["sha256"],
        "development_sample_manifest_sha256": development_sample[
            "manifest_sha256"
        ],
        "corpus_lock_file_sha256": bound.record("corpus_lock")["sha256"],
        "corpus_manifest_sha256": corpus_lock["manifest_sha256"],
        "corpus_lock_bundle_sha256": canonical_sha256(corpus_bundle),
        "corpus_lock_bundle_document": corpus_bundle,
        "live_holdout_preopen_verification": live_verification,
        "live_holdout_preopen_verification_sha256": canonical_sha256(
            live_verification
        ),
        "common_boundary_contract": COMMON_CONTROL_BOUNDARY_CONTRACT,
        "common_boundary_contract_sha256": canonical_sha256(
            COMMON_CONTROL_BOUNDARY_CONTRACT
        ),
        "quality_implementation_closure": {
            "implementation_manifest_file_sha256": _sha256_file(
                quality_manifest_path
            ),
            "implementation_manifest_sha256": (
                declared_quality_manifest_sha256
            ),
        },
        "_configuration_hash_file_bindings": {
            "mapping_seed_sha256": bound.record("mapping_seed")["sha256"],
            "operator_bank_seed_sha256": bound.record(
                "operator_bank_seed"
            )["sha256"],
            "metric_policy_seed_sha256": bound.record(
                "metric_policy_seed"
            )["sha256"],
            "compiler_contract_sha256": bound.record("compiler_contract")[
                "sha256"
            ],
            "calibration_plan_sha256": bound.record("calibration_plan")[
                "sha256"
            ],
            "metric_policy_sha256": metric_policy["policy_sha256"],
            "corpus_lock_bundle_sha256": canonical_sha256(corpus_bundle),
            "raw_output_contract_sha256": canonical_sha256(
                COMMON_CONTROL_BOUNDARY_CONTRACT
            ),
        },
    }


def _validate_resume_closure_bindings(
    document: Mapping[str, object],
) -> None:
    implementation_closure = document.get("implementation_closure")
    if not isinstance(implementation_closure, dict):
        raise AssertionError("published benchmark implementation closure is absent")
    ordered_implementation_files = implementation_closure.get("ordered_files")
    if (
        not isinstance(ordered_implementation_files, list)
        or implementation_closure.get("ordered_files_sha256")
        != canonical_sha256(ordered_implementation_files)
    ):
        raise AssertionError("published benchmark implementation closure differs")
    if implementation_closure != _implementation_closure():
        raise AssertionError(
            "published benchmark current implementation closure differs"
        )

    run_identity = document.get("run_identity")
    if not isinstance(run_identity, dict):
        raise AssertionError("published benchmark run identity is absent")
    repository_state = run_identity.get("repository_state")
    if not isinstance(repository_state, dict):
        raise AssertionError("published benchmark repository state is absent")
    untracked_files = repository_state.get("non_artifact_untracked_files")
    if (
        not isinstance(untracked_files, list)
        or repository_state.get("non_artifact_untracked_files_sha256")
        != canonical_sha256(untracked_files)
    ):
        raise AssertionError("published benchmark untracked-file binding differs")
    if repository_state != _repository_state_binding():
        raise AssertionError(
            "published benchmark current repository state differs"
        )

    input_closure = document.get("benchmark_input_closure")
    if not isinstance(input_closure, dict):
        raise AssertionError("published benchmark input closure is absent")
    unhashed_input_closure = dict(input_closure)
    declared_input_closure_sha256 = unhashed_input_closure.pop(
        "input_closure_sha256",
        None,
    )
    if declared_input_closure_sha256 != canonical_sha256(
        unhashed_input_closure
    ):
        raise AssertionError("published benchmark input closure SHA-256 differs")
    current_inputs = dict(_current_resume_input_bindings())
    expected_configuration_hashes = current_inputs.pop(
        "_configuration_hash_file_bindings"
    )
    for field, expected in current_inputs.items():
        if input_closure.get(field) != expected:
            raise AssertionError(
                f"published benchmark current input binding differs: {field}"
            )
    configuration_hashes = input_closure.get("configuration_hashes")
    if not isinstance(configuration_hashes, dict):
        raise AssertionError(
            "published benchmark configuration hash closure is absent"
        )
    for field, expected in expected_configuration_hashes.items():
        if configuration_hashes.get(field) != expected:
            raise AssertionError(
                "published benchmark current configuration input differs: "
                f"{field}"
            )


def _legal_pattern_frame(
    height: int,
    width: int,
    *,
    phase: int,
) -> PlanarFrame:
    y_rows, y_columns = np.indices((height, width), dtype=np.int64)
    y_codes = 16 + (
        (y_rows * 7 + y_columns * 11 + phase * 13) % 220
    )
    chroma_rows, chroma_columns = np.indices(
        (height // 2, width // 2),
        dtype=np.int64,
    )
    cb_codes = 16 + (
        (chroma_rows * 5 + chroma_columns * 17 + phase * 19) % 225
    )
    cr_codes = 16 + (
        (chroma_rows * 23 + chroma_columns * 3 + phase * 29) % 225
    )
    frame = PlanarFrame(
        y=(y_codes.astype(np.float64) - 16.0) / 219.0,
        cb=(cb_codes.astype(np.float64) - 16.0) / 224.0 - 0.5,
        cr=(cr_codes.astype(np.float64) - 16.0) / 224.0 - 0.5,
    )
    _, reopened = _round_trip_locked_bt709_video_range_nv12(frame)
    return reopened


def _prepared_cases(
    degradation_policy: Mapping[str, object],
) -> tuple[_PreparedControlCase, ...]:
    profiles = degradation_policy.get("profiles")
    if not isinstance(profiles, list):
        raise AssertionError("degradation profiles are absent")
    prepared = []
    for source_ordinal in range(6):
        route = ("direct-2x", "direct-3over2")[source_ordinal % 2]
        route_profiles = [
            profile
            for profile in profiles
            if isinstance(profile, dict)
            and profile.get("target_route") == route
            and profile.get("kind") != "synthetic_motion"
        ]
        if len(route_profiles) != 3:
            raise AssertionError("route profile cardinality differs")
        input_shape = (96, 162) if route == "direct-2x" else (128, 216)
        context = CandidateContext(
            y_shape=OUTPUT_Y_SHAPE,
            cb_shape=OUTPUT_CHROMA_SHAPE,
            cr_shape=OUTPUT_CHROMA_SHAPE,
            target_route=route,
        )
        target = _legal_pattern_frame(
            *OUTPUT_Y_SHAPE,
            phase=source_ordinal,
        )
        for profile_ordinal, profile in enumerate(route_profiles):
            prepared.append(
                _PreparedControlCase(
                    metadata={
                        "source_asset_id": f"native-benchmark-{source_ordinal}",
                        "source_family_id": f"native-family-{source_ordinal}",
                        "categories": ["native-aggregate-benchmark"],
                        "target_route": route,
                    },
                    profile=dict(profile),
                    target=target,
                    low_resolution=_legal_pattern_frame(
                        *input_shape,
                        phase=source_ordinal * 3 + profile_ordinal + 31,
                    ),
                    context=context,
                )
            )
    if len(prepared) != PREPARED_CASE_COUNT:
        raise AssertionError("native benchmark prepared-case count differs")
    return tuple(prepared)


def _aggregate_context(
    *,
    bound: _BoundStub,
    adapter_configuration: Mapping[str, object],
) -> Mapping[str, object]:
    baseline_path = (
        REPOSITORY_ROOT
        / "validation/calibration_v2/contracts/baseline-ablation-contract-v1.json"
    )
    quality_manifest_path = (
        REPOSITORY_ROOT
        / "validation/quality/locks/quality-harness-implementation-manifest.json"
    )
    baseline = json.loads(baseline_path.read_bytes())
    quality_manifest = json.loads(quality_manifest_path.read_bytes())
    selector = baseline["non_ash_selector"]
    corpus = bound.documents["corpus_lock"]
    corpus_bundle_sha256 = corpus_lock_bundle_sha256(bound)
    if (
        adapter_configuration.get("corpus_lock_bundle_sha256")
        != corpus_bundle_sha256
    ):
        raise AssertionError(
            "adapter and aggregate-context corpus-lock bundles differ"
        )
    return {
        "degradation_policy_file_sha256": bound.record(
            "degradation_policy"
        )["sha256"],
        "metric_policy_file_sha256": bound.record("metric_policy_seed")[
            "sha256"
        ],
        "metric_policy_sha256": bound.documents["metric_policy_seed"][
            "policy_sha256"
        ],
        "baseline_ablation_contract_file_sha256": _sha256_file(
            baseline_path
        ),
        "baseline_selector_contract": selector,
        "baseline_selector_contract_sha256": canonical_sha256(selector),
        "sample_lock_file_sha256": bound.record("development_sample_lock")[
            "sha256"
        ],
        "corpus_manifest_sha256": corpus["manifest_sha256"],
        "corpus_lock_bundle_sha256": corpus_bundle_sha256,
        "common_boundary_contract": COMMON_CONTROL_BOUNDARY_CONTRACT,
        "common_boundary_contract_sha256": canonical_sha256(
            COMMON_CONTROL_BOUNDARY_CONTRACT
        ),
        "native_implementation_closure": adapter_configuration["swift_cli"],
        "quality_implementation_closure": {
            "implementation_manifest_file_sha256": _sha256_file(
                quality_manifest_path
            ),
            "implementation_manifest_sha256": quality_manifest[
                "manifest_sha256"
            ],
        },
    }


def test_aggregate_context_uses_canonical_full_corpus_lock_bundle() -> None:
    bound = _BoundStub()
    expected = corpus_lock_bundle_sha256(bound)
    swift_cli = {
        "executable_sha256": "a" * 64,
        "source_manifest_sha256": "b" * 64,
    }
    context = _aggregate_context(
        bound=bound,
        adapter_configuration={
            "swift_cli": swift_cli,
            "corpus_lock_bundle_sha256": expected,
        },
    )

    assert expected == canonical_sha256(corpus_lock_bundle_document(bound))
    assert context["corpus_lock_bundle_sha256"] == expected
    assert _current_resume_input_bindings()[
        "corpus_lock_bundle_sha256"
    ] == expected
    with pytest.raises(AssertionError, match="corpus-lock bundles differ"):
        _aggregate_context(
            bound=bound,
            adapter_configuration={
                "swift_cli": swift_cli,
                "corpus_lock_bundle_sha256": "0" * 64,
            },
        )


def _maximum_formula_derivation(
    plan: Mapping[str, object],
    selector_contract: Mapping[str, object],
) -> Mapping[str, object]:
    domains = parameter_domains(plan)
    shared_bank_domain_sizes = {
        name: len(domains[name]) for name in _SHARED_BANK_COORDINATES
    }
    shared_bank_alternatives_per_sweep = sum(
        size - 1 for size in shared_bank_domain_sizes.values()
    )
    derived_first_outer_sweep_bank_count = (
        1 + shared_bank_alternatives_per_sweep
    )
    search = plan.get("search")
    if not isinstance(search, dict):
        raise AssertionError("calibration search contract is absent")
    calibration_maximum_sweeps = int(search["maximum_sweeps"])
    derived_maximum_bank_count = (
        1
        + calibration_maximum_sweeps
        * shared_bank_alternatives_per_sweep
    )
    selector_coordinates = selector_contract.get("coordinates")
    if not isinstance(selector_coordinates, dict):
        raise AssertionError("selector coordinate contract is absent")
    selector_coordinate_order = selector_coordinates["order"]
    selector_values = selector_coordinates["values"]
    selector_maximum_sweeps = int(selector_coordinates["maximum_sweeps"])
    derived_maximum_unique_rules_per_bank = (
        1
        + selector_maximum_sweeps
        * len(selector_coordinate_order)
        * (len(selector_values) - 1)
    )
    derivation = {
        "schema_version": "1.0.0",
        "ordered_shared_bank_coordinates": list(_SHARED_BANK_COORDINATES),
        "shared_bank_domain_sizes": shared_bank_domain_sizes,
        "shared_bank_alternatives_per_sweep": (
            shared_bank_alternatives_per_sweep
        ),
        "calibration_maximum_sweeps": calibration_maximum_sweeps,
        "derived_first_outer_sweep_bank_count": (
            derived_first_outer_sweep_bank_count
        ),
        "derived_maximum_bank_count": derived_maximum_bank_count,
        "selector_coordinate_order": list(selector_coordinate_order),
        "selector_coordinate_count": len(selector_coordinate_order),
        "selector_values": list(selector_values),
        "selector_value_count": len(selector_values),
        "selector_maximum_sweeps": selector_maximum_sweeps,
        "derived_maximum_unique_rules_per_bank": (
            derived_maximum_unique_rules_per_bank
        ),
    }
    derivation["derivation_sha256"] = canonical_sha256(derivation)
    if (
        derived_first_outer_sweep_bank_count
        != FIRST_OUTER_SWEEP_BANK_COUNT
        or derived_maximum_bank_count != MAXIMUM_BANK_COUNT
        or derived_maximum_unique_rules_per_bank
        != MAXIMUM_UNIQUE_RULES_PER_BANK
    ):
        raise AssertionError("benchmark maximum formula contract changed")
    return derivation


def _allocated_or_floor_bytes(path: Path, allocation_floor_bytes: int) -> int:
    status = path.stat()
    return max(int(status.st_blocks) * 512, allocation_floor_bytes)


def _modeled_allocated_block_floor_bytes(
    logical_bytes: int,
    allocation_floor_bytes: int,
    *,
    observed_allocated_or_floor_bytes: int,
) -> int:
    if logical_bytes <= 0 or allocation_floor_bytes <= 0:
        raise AssertionError("modeled document storage input is invalid")
    return max(
        observed_allocated_or_floor_bytes,
        math.ceil(logical_bytes / allocation_floor_bytes)
        * allocation_floor_bytes,
    )


def _record_with_updates_and_recomputed_sha256(
    document: Mapping[str, object],
    updates: Mapping[str, object],
    *,
    label: str,
) -> Mapping[str, object]:
    observed = dict(document)
    declared = observed.pop("record_sha256", None)
    if declared != canonical_sha256(observed):
        raise AssertionError(f"{label} record SHA-256 differs")
    if any(key not in observed for key in updates):
        raise AssertionError(f"{label} modeled field is absent")
    modeled = {**observed, **updates}
    modeled["record_sha256"] = canonical_sha256(modeled)
    return modeled


def _document_growth_size_fields(
    *,
    observed_document: Mapping[str, object],
    modeled_document: Mapping[str, object],
    allocation_floor_bytes: int,
    observed_allocated_or_floor_bytes: int,
) -> Mapping[str, object]:
    observed_payload = canonical_json_bytes(observed_document)
    modeled_payload = canonical_json_bytes(modeled_document)
    if len(modeled_payload) < len(observed_payload):
        raise AssertionError("modeled document is smaller than observation")
    return {
        "observed_document_sha256": hashlib.sha256(
            observed_payload
        ).hexdigest(),
        "modeled_document_sha256": hashlib.sha256(modeled_payload).hexdigest(),
        "observed_logical_bytes": len(observed_payload),
        "modeled_maximum_logical_bytes": len(modeled_payload),
        "observed_allocated_or_block_floor_bytes": (
            observed_allocated_or_floor_bytes
        ),
        "modeled_maximum_allocated_block_floor_bytes": (
            _modeled_allocated_block_floor_bytes(
                len(modeled_payload),
                allocation_floor_bytes,
                observed_allocated_or_floor_bytes=(
                    observed_allocated_or_floor_bytes
                ),
            )
        ),
    }


def _count_dependent_shared_document_growth_models(
    *,
    native_durability_document: Mapping[str, object],
    evidence_dependency_document: Mapping[str, object],
    selection_document: Mapping[str, object],
    observed_unique_rule_count: int,
    maximum_unique_rule_count: int,
    maximum_attempt_count: int,
    allocation_floor_bytes: int,
    observed_allocated_or_floor_bytes_by_kind: Mapping[str, int],
) -> Mapping[str, object]:
    if not 0 < observed_unique_rule_count <= maximum_unique_rule_count:
        raise AssertionError("shared-document observed rule count is invalid")
    required_kinds = {
        "native_durability_commit",
        "evidence_dependency_commit",
        "selector_selection",
    }
    if set(observed_allocated_or_floor_bytes_by_kind) != required_kinds:
        raise AssertionError("shared-document allocation bindings differ")

    observed_pending_file_count = int(
        native_durability_document.get("pending_file_count", -1)
    )
    observed_pending_directory_count = int(
        native_durability_document.get("pending_directory_count", -1)
    )
    rule_file_growth = RULE_SCOPED_NATIVE_PROOF_FILES_PER_RULE
    rule_directory_growth = (
        RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE
    )
    fixed_pending_file_count = (
        observed_pending_file_count
        - observed_unique_rule_count * rule_file_growth
    )
    fixed_pending_directory_count = (
        observed_pending_directory_count
        - observed_unique_rule_count * rule_directory_growth
    )
    if fixed_pending_file_count < 0 or fixed_pending_directory_count < 0:
        raise AssertionError("native durability fixed count is negative")
    maximum_pending_file_count = (
        fixed_pending_file_count
        + maximum_unique_rule_count * rule_file_growth
    )
    maximum_pending_directory_count = (
        fixed_pending_directory_count
        + maximum_unique_rule_count * rule_directory_growth
    )
    modeled_native = _record_with_updates_and_recomputed_sha256(
        native_durability_document,
        {
            "pending_file_count": maximum_pending_file_count,
            "pending_directory_count": maximum_pending_directory_count,
        },
        label="native durability commit",
    )
    native_model = {
        "rule_scoped_file_growth_per_rule": rule_file_growth,
        "rule_scoped_directory_growth_per_rule": rule_directory_growth,
        "observed_pending_file_count": observed_pending_file_count,
        "fixed_pending_file_count": fixed_pending_file_count,
        "maximum_pending_file_count": maximum_pending_file_count,
        "observed_pending_directory_count": observed_pending_directory_count,
        "fixed_pending_directory_count": fixed_pending_directory_count,
        "maximum_pending_directory_count": maximum_pending_directory_count,
        **_document_growth_size_fields(
            observed_document=native_durability_document,
            modeled_document=modeled_native,
            allocation_floor_bytes=allocation_floor_bytes,
            observed_allocated_or_floor_bytes=(
                observed_allocated_or_floor_bytes_by_kind[
                    "native_durability_commit"
                ]
            ),
        ),
    }

    observed_ordered_documents = evidence_dependency_document.get(
        "ordered_document_sha256_values"
    )
    observed_dependency_document_count = evidence_dependency_document.get(
        "document_count"
    )
    expected_observed_dependency_document_count = (
        1 + 2 * observed_unique_rule_count
    )
    if (
        not isinstance(observed_ordered_documents, list)
        or len(observed_ordered_documents)
        != expected_observed_dependency_document_count
        or observed_dependency_document_count
        != expected_observed_dependency_document_count
    ):
        raise AssertionError(
            "aggregate evidence dependency rule growth differs"
        )
    maximum_dependency_document_count = (
        1 + 2 * maximum_unique_rule_count
    )
    modeled_ordered_documents = [
        f"{ordinal:064x}"
        for ordinal in range(1, maximum_dependency_document_count + 1)
    ]
    modeled_evidence_dependency = (
        _record_with_updates_and_recomputed_sha256(
            evidence_dependency_document,
            {
                "ordered_document_sha256_values": modeled_ordered_documents,
                "document_count": maximum_dependency_document_count,
            },
            label="aggregate evidence dependency commit",
        )
    )
    evidence_dependency_model = {
        "fixed_document_count": 1,
        "document_growth_per_rule": 2,
        "observed_document_count": (
            expected_observed_dependency_document_count
        ),
        "maximum_document_count": maximum_dependency_document_count,
        **_document_growth_size_fields(
            observed_document=evidence_dependency_document,
            modeled_document=modeled_evidence_dependency,
            allocation_floor_bytes=allocation_floor_bytes,
            observed_allocated_or_floor_bytes=(
                observed_allocated_or_floor_bytes_by_kind[
                    "evidence_dependency_commit"
                ]
            ),
        ),
    }

    observed_attempt_count = selection_document.get(
        "development_attempt_count"
    )
    if (
        not isinstance(observed_attempt_count, int)
        or isinstance(observed_attempt_count, bool)
        or not 0 < observed_attempt_count <= maximum_attempt_count
    ):
        raise AssertionError("selector selection attempt count is invalid")
    modeled_selection = dict(selection_document)
    modeled_selection["development_attempt_count"] = maximum_attempt_count
    selection_model = {
        "observed_attempt_count": observed_attempt_count,
        "maximum_attempt_count": maximum_attempt_count,
        **_document_growth_size_fields(
            observed_document=selection_document,
            modeled_document=modeled_selection,
            allocation_floor_bytes=allocation_floor_bytes,
            observed_allocated_or_floor_bytes=(
                observed_allocated_or_floor_bytes_by_kind[
                    "selector_selection"
                ]
            ),
        ),
    }
    models = {
        "native_durability_commit": native_model,
        "evidence_dependency_commit": evidence_dependency_model,
        "selector_selection": selection_model,
    }
    return {
        **models,
        "observed_logical_bytes": sum(
            int(model["observed_logical_bytes"])
            for model in models.values()
        ),
        "modeled_maximum_logical_bytes": sum(
            int(model["modeled_maximum_logical_bytes"])
            for model in models.values()
        ),
        "observed_allocated_or_block_floor_bytes": sum(
            int(model["observed_allocated_or_block_floor_bytes"])
            for model in models.values()
        ),
        "modeled_maximum_allocated_block_floor_bytes": sum(
            int(model["modeled_maximum_allocated_block_floor_bytes"])
            for model in models.values()
        ),
    }


def _tree_totals(
    root: Path,
    *,
    allocation_floor_bytes: int,
) -> Mapping[str, int]:
    paths = (root, *tuple(root.rglob("*")))
    files = tuple(
        path
        for path in paths
        if path.is_file() and not path.is_symlink()
    )
    directories = tuple(
        path
        for path in paths
        if path.is_dir() and not path.is_symlink()
    )
    return {
        "file_count": len(files),
        "directory_count": len(directories),
        "inode_count": len(files) + len(directories),
        "size_bytes": sum(path.stat().st_size for path in files),
        "allocated_or_block_floor_bytes": sum(
            _allocated_or_floor_bytes(path, allocation_floor_bytes)
            for path in (*files, *directories)
        ),
    }


def _read_json_object(
    path: Path,
    *,
    content_addressed_filename: bool = False,
) -> Mapping[str, object]:
    payload = path.read_bytes()
    value = json.loads(payload)
    if (
        not isinstance(value, dict)
        or canonical_json_bytes(value) != payload
    ):
        raise AssertionError(f"benchmark evidence is not an object: {path}")
    if content_addressed_filename:
        declared = _require_benchmark_sha256(
            path.stem,
            "content-addressed benchmark filename",
        )
        if hashlib.sha256(payload).hexdigest() != declared:
            raise AssertionError(
                "content-addressed benchmark document hash differs"
            )
    return value


def _require_benchmark_sha256(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise AssertionError(f"{label} is not a lowercase SHA-256")
    return value


def _rule_scoped_storage(
    *,
    native_root: Path,
    evidence_root: Path,
    allocation_floor_bytes: int,
) -> Mapping[str, object]:
    proof_root = native_root / "non-ash-reconstruction-proof-v1"
    proof_paths = tuple(sorted(proof_root.rglob("origin.json")))
    native_by_rule: dict[str, list[Path]] = {}
    for path in proof_paths:
        document = _read_json_object(path)
        control_request = document.get("control_request")
        if not isinstance(control_request, dict):
            raise AssertionError("native compact proof request is absent")
        parameters = control_request.get("parameters")
        if not isinstance(parameters, dict):
            raise AssertionError("native compact proof parameters are absent")
        rule_sha256 = _require_benchmark_sha256(
            parameters.get("selected_rule_sha256"),
            "native compact proof rule",
        )
        native_by_rule.setdefault(rule_sha256, []).append(path)

    aggregate_origin_root = evidence_root / "control-aggregate-origins"
    aggregate_origin_paths = tuple(
        sorted(aggregate_origin_root.glob("*.json"))
    )
    aggregate_origin_by_rule: dict[str, Path] = {}
    aggregate_documents_by_rule: dict[str, tuple[Path, Path]] = {}
    referenced_document_paths: set[Path] = set()
    for path in aggregate_origin_paths:
        document = _read_json_object(path)
        identity = document.get("identity")
        aggregate = document.get("aggregate")
        if not isinstance(identity, dict) or not isinstance(aggregate, dict):
            raise AssertionError("aggregate origin binding is absent")
        rule_sha256 = _require_benchmark_sha256(
            identity.get("rule_sha256"),
            "aggregate origin rule",
        )
        if rule_sha256 in aggregate_origin_by_rule:
            raise AssertionError("aggregate origin rule is duplicated")
        aggregate_origin_by_rule[rule_sha256] = path
        objective_sha256 = _require_benchmark_sha256(
            aggregate.get("objective_summary_sha256"),
            "aggregate objective document",
        )
        output_sha256 = _require_benchmark_sha256(
            aggregate.get("output_manifest_sha256"),
            "aggregate output document",
        )
        document_paths = (
            evidence_root / "documents" / f"{objective_sha256}.json",
            evidence_root / "documents" / f"{output_sha256}.json",
        )
        if (
            document_paths[0] == document_paths[1]
            or not all(item.is_file() for item in document_paths)
        ):
            raise AssertionError("aggregate document binding is incomplete")
        objective = _read_json_object(
            document_paths[0],
            content_addressed_filename=True,
        )
        output = _read_json_object(
            document_paths[1],
            content_addressed_filename=True,
        )
        if (
            objective.get("artifact_kind")
            != "p06_control_objective_summary"
            or output.get("artifact_kind")
            != "p06_control_output_manifest"
        ):
            raise AssertionError("aggregate document kind differs")
        aggregate_documents_by_rule[rule_sha256] = document_paths
        referenced_document_paths.update(document_paths)

    rule_values = set(native_by_rule)
    if (
        not rule_values
        or rule_values != set(aggregate_origin_by_rule)
        or rule_values != set(aggregate_documents_by_rule)
        or len(referenced_document_paths) != len(rule_values) * 2
    ):
        raise AssertionError("rule-scoped evidence coverage differs")

    ordered_groups = []
    for rule_sha256 in sorted(rule_values):
        native_paths = native_by_rule[rule_sha256]
        native_directories = {path.parent for path in native_paths}
        aggregate_paths = (
            aggregate_origin_by_rule[rule_sha256],
            *aggregate_documents_by_rule[rule_sha256],
        )
        file_paths = (*native_paths, *aggregate_paths)
        if (
            len(native_paths) != RULE_SCOPED_NATIVE_PROOF_FILES_PER_RULE
            or len(native_directories)
            != RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE
            or len(file_paths) != RULE_SCOPED_FILES_PER_RULE
        ):
            raise AssertionError("complete rule-scoped footprint differs")
        ordered_groups.append(
            {
                "rule_sha256": rule_sha256,
                "file_count": len(file_paths),
                "directory_count": len(native_directories),
                "inode_count": len(file_paths) + len(native_directories),
                "size_bytes": sum(path.stat().st_size for path in file_paths),
                "allocated_or_block_floor_bytes": sum(
                    _allocated_or_floor_bytes(
                        path,
                        allocation_floor_bytes,
                    )
                    for path in (*file_paths, *native_directories)
                ),
            }
        )
    if any(
        group["file_count"] != RULE_SCOPED_FILES_PER_RULE
        or group["directory_count"]
        != RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE
        or group["inode_count"] != RULE_SCOPED_INODES_PER_RULE
        for group in ordered_groups
    ):
        raise AssertionError("rule-scoped file or inode formula differs")
    size_values = [int(group["size_bytes"]) for group in ordered_groups]
    allocated_values = [
        int(group["allocated_or_block_floor_bytes"])
        for group in ordered_groups
    ]
    return {
        "rule_count": len(ordered_groups),
        "native_compact_proof_file_count": len(proof_paths),
        "native_compact_proof_directory_count": len(
            {path.parent for path in proof_paths}
        ),
        "aggregate_origin_file_count": len(aggregate_origin_paths),
        "aggregate_document_file_count": len(referenced_document_paths),
        "file_count": len(ordered_groups) * RULE_SCOPED_FILES_PER_RULE,
        "directory_count": (
            len(ordered_groups)
            * RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE
        ),
        "inode_count": len(ordered_groups) * RULE_SCOPED_INODES_PER_RULE,
        "size_bytes": sum(size_values),
        "minimum_complete_rule_size_bytes": min(size_values),
        "maximum_complete_rule_size_bytes": max(size_values),
        "allocated_or_block_floor_bytes": sum(allocated_values),
        "minimum_complete_rule_allocated_or_block_floor_bytes": min(
            allocated_values
        ),
        "maximum_complete_rule_allocated_or_block_floor_bytes": max(
            allocated_values
        ),
        "ordered_rule_group_summary_sha256": canonical_sha256(
            ordered_groups
        ),
    }


def _shared_aggregate_dependency_documents(
    *,
    evidence_root: Path,
    expected_rule_count: int,
) -> Mapping[str, Mapping[str, object]]:
    origin_paths = tuple(
        sorted((evidence_root / "control-aggregate-origins").glob("*.json"))
    )
    if len(origin_paths) != expected_rule_count:
        raise AssertionError("shared-dependency origin count differs")
    native_dependency_values: set[str] = set()
    evidence_dependency_values: set[str] = set()
    aggregate_document_values: set[str] = set()
    for path in origin_paths:
        origin = _read_json_object(path)
        native_dependency_values.add(
            _require_benchmark_sha256(
                origin.get("native_dependency_evidence_sha256"),
                "native dependency evidence",
            )
        )
        evidence_dependency_values.add(
            _require_benchmark_sha256(
                origin.get("evidence_dependency_evidence_sha256"),
                "aggregate evidence dependency",
            )
        )
        aggregate = origin.get("aggregate")
        if not isinstance(aggregate, dict):
            raise AssertionError("shared-dependency aggregate is absent")
        for field in (
            "objective_summary_sha256",
            "output_manifest_sha256",
        ):
            aggregate_document_values.add(
                _require_benchmark_sha256(
                    aggregate.get(field),
                    f"shared-dependency {field}",
                )
            )
    if len(native_dependency_values) != 1 or len(evidence_dependency_values) != 1:
        raise AssertionError("shared-dependency commit cardinality differs")
    if len(aggregate_document_values) != 2 * expected_rule_count:
        raise AssertionError("shared aggregate document cardinality differs")
    native_sha256 = next(iter(native_dependency_values))
    evidence_sha256 = next(iter(evidence_dependency_values))
    documents_root = evidence_root / "documents"
    native_path = documents_root / f"{native_sha256}.json"
    evidence_path = documents_root / f"{evidence_sha256}.json"
    native_document = _read_json_object(
        native_path,
        content_addressed_filename=True,
    )
    evidence_document = _read_json_object(
        evidence_path,
        content_addressed_filename=True,
    )
    if (
        native_document.get("artifact_kind")
        != "p06_control_cache_durability_commit"
        or evidence_document.get("artifact_kind")
        != "p06_control_aggregate_evidence_dependency_commit"
    ):
        raise AssertionError("shared-dependency document kind differs")
    ordered_documents = evidence_document.get(
        "ordered_document_sha256_values"
    )
    if (
        not isinstance(ordered_documents, list)
        or ordered_documents[:1] != [native_sha256]
        or set(ordered_documents[1:]) != aggregate_document_values
        or len(ordered_documents) != 1 + 2 * expected_rule_count
    ):
        raise AssertionError("shared-dependency document closure differs")
    return {
        "native_durability_commit": {
            "sha256": native_sha256,
            "path": native_path,
            "document": native_document,
        },
        "evidence_dependency_commit": {
            "sha256": evidence_sha256,
            "path": evidence_path,
            "document": evidence_document,
        },
    }


def test_rule_scoped_storage_accounts_for_complete_21_file_39_inode_group(
    tmp_path: Path,
) -> None:
    native_root = tmp_path / "native"
    evidence_root = tmp_path / "evidence"
    rule_sha256 = "a" * 64
    for ordinal in range(PREPARED_CASE_COUNT):
        path = (
            native_root
            / "non-ash-reconstruction-proof-v1"
            / "development"
            / ("b" * 64)
            / f"{ordinal:064x}"
            / "origin.json"
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(
            canonical_json_bytes(
                {
                    "control_request": {
                        "parameters": {
                            "selected_rule_sha256": rule_sha256,
                        }
                    }
                }
            )
        )
    objective = {"artifact_kind": "p06_control_objective_summary"}
    output = {"artifact_kind": "p06_control_output_manifest"}
    objective_sha256 = canonical_sha256(objective)
    output_sha256 = canonical_sha256(output)
    documents = evidence_root / "documents"
    documents.mkdir(parents=True)
    (documents / f"{objective_sha256}.json").write_bytes(
        canonical_json_bytes(objective)
    )
    (documents / f"{output_sha256}.json").write_bytes(
        canonical_json_bytes(output)
    )
    origins = evidence_root / "control-aggregate-origins"
    origins.mkdir()
    (origins / f"{'c' * 64}.json").write_bytes(
        canonical_json_bytes(
            {
                "identity": {"rule_sha256": rule_sha256},
                "aggregate": {
                    "objective_summary_sha256": objective_sha256,
                    "output_manifest_sha256": output_sha256,
                },
            }
        )
    )

    observed = _rule_scoped_storage(
        native_root=native_root,
        evidence_root=evidence_root,
        allocation_floor_bytes=4096,
    )

    assert observed["rule_count"] == 1
    assert observed["native_compact_proof_file_count"] == 18
    assert observed["native_compact_proof_directory_count"] == 18
    assert observed["aggregate_origin_file_count"] == 1
    assert observed["aggregate_document_file_count"] == 2
    assert observed["file_count"] == 21
    assert observed["directory_count"] == 18
    assert observed["inode_count"] == 39
    assert observed["allocated_or_block_floor_bytes"] >= 39 * 4096


def test_benchmark_implementation_closure_is_ordered_and_content_bound() -> None:
    closure = _implementation_closure()
    ordered_files = closure["ordered_files"]

    assert [record["path"] for record in ordered_files] == list(
        IMPLEMENTATION_CLOSURE_PATHS
    )
    assert all(
        record["sha256"]
        == _sha256_file(REPOSITORY_ROOT / str(record["path"]))
        and record["size_bytes"]
        == (REPOSITORY_ROOT / str(record["path"])).stat().st_size
        for record in ordered_files
    )
    assert closure["ordered_files_sha256"] == canonical_sha256(ordered_files)


def test_benchmark_formula_derivation_matches_bound_contracts() -> None:
    plan = json.loads(
        (
            REPOSITORY_ROOT
            / "validation/calibration_v2/contracts/calibration-plan-v1.json"
        ).read_bytes()
    )
    baseline = json.loads(
        (
            REPOSITORY_ROOT
            / "validation/calibration_v2/contracts/"
            "baseline-ablation-contract-v1.json"
        ).read_bytes()
    )

    derivation = _maximum_formula_derivation(
        plan,
        baseline["non_ash_selector"],
    )

    assert derivation["derived_first_outer_sweep_bank_count"] == 39
    assert derivation["derived_maximum_bank_count"] == 305
    assert derivation["derived_maximum_unique_rules_per_bank"] == 1297


def test_benchmark_timing_summary_uses_reproducible_nearest_rank() -> None:
    values = [float(value) for value in range(1, 101)]

    summary = _timing_summary(values)

    assert summary["count"] == 100
    assert summary["total_seconds"] == sum(values)
    assert summary["p50_seconds"] == 50.0
    assert summary["p95_seconds"] == 95.0
    assert summary["p99_seconds"] == 99.0
    assert summary["raw_seconds_in_execution_order"] == values


def test_benchmark_utc_timestamp_uses_canonical_z_suffix() -> None:
    value = _canonical_utc_now()

    assert value.endswith("Z")
    assert "+00:00" not in value
    assert datetime.fromisoformat(value.removesuffix("Z") + "+00:00").tzinfo == (
        timezone.utc
    )


def test_repository_state_binding_is_artifact_self_reference_safe() -> None:
    binding = _repository_state_binding()
    untracked_files = binding["non_artifact_untracked_files"]

    assert binding["untracked_artifact_exclusion"] == "Artifacts/**"
    assert all(
        not str(record["path"]).startswith("Artifacts/")
        for record in untracked_files
    )
    assert binding["non_artifact_untracked_files_sha256"] == canonical_sha256(
        untracked_files
    )


def test_shared_document_growth_models_include_every_known_count_dimension() -> None:
    observed_rule_count = 2
    native_without_hash = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_control_cache_durability_commit",
        "pending_file_count": 10 + 18 * observed_rule_count,
        "pending_directory_count": 5 + 18 * observed_rule_count,
    }
    native_document = dict(native_without_hash)
    native_document["record_sha256"] = canonical_sha256(native_without_hash)
    observed_ordered_documents = [
        f"{ordinal:064x}"
        for ordinal in range(1, 2 + 2 * observed_rule_count)
    ]
    dependency_without_hash = {
        "schema_version": "1.0.0",
        "artifact_kind": (
            "p06_control_aggregate_evidence_dependency_commit"
        ),
        "ordered_document_sha256_values": observed_ordered_documents,
        "document_count": len(observed_ordered_documents),
    }
    dependency_document = dict(dependency_without_hash)
    dependency_document["record_sha256"] = canonical_sha256(
        dependency_without_hash
    )
    selection_document = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_non_ash_selector_selection",
        "development_attempt_count": 12,
    }

    models = _count_dependent_shared_document_growth_models(
        native_durability_document=native_document,
        evidence_dependency_document=dependency_document,
        selection_document=selection_document,
        observed_unique_rule_count=observed_rule_count,
        maximum_unique_rule_count=MAXIMUM_UNIQUE_RULES_PER_BANK,
        maximum_attempt_count=1513,
        allocation_floor_bytes=4096,
        observed_allocated_or_floor_bytes_by_kind={
            "native_durability_commit": 4096,
            "evidence_dependency_commit": 4096,
            "selector_selection": 4096,
        },
    )

    native = models["native_durability_commit"]
    dependency = models["evidence_dependency_commit"]
    selection = models["selector_selection"]
    assert native["fixed_pending_file_count"] == 10
    assert native["maximum_pending_file_count"] == 10 + 18 * 1297
    assert native["fixed_pending_directory_count"] == 5
    assert native["maximum_pending_directory_count"] == 5 + 18 * 1297
    assert dependency["observed_document_count"] == 5
    assert dependency["maximum_document_count"] == 1 + 2 * 1297
    assert selection["observed_attempt_count"] == 12
    assert selection["maximum_attempt_count"] == 1513
    assert models["modeled_maximum_logical_bytes"] > models[
        "observed_logical_bytes"
    ]
    assert models["modeled_maximum_allocated_block_floor_bytes"] >= models[
        "observed_allocated_or_block_floor_bytes"
    ]


def test_benchmark_schema_is_strict_and_project_bound() -> None:
    schema_path = REPOSITORY_ROOT / BENCHMARK_SCHEMA_RELATIVE_PATH
    schema = json.loads(schema_path.read_bytes())

    assert schema["additionalProperties"] is False
    assert schema["properties"]["schema_version"] == {"const": "1.1.0"}
    assert schema["properties"]["artifact_kind"] == {
        "const": "p06_control_aggregate_cache_native_benchmark"
    }
    assert "cache_preparation_records" in schema["$defs"]["coldRun"][
        "required"
    ]
    assert "cache_preparation_records" in schema["$defs"]["warmRun"][
        "required"
    ]
    run_identity_schema = schema["$defs"]["runIdentity"]
    assert run_identity_schema["properties"]["started_utc"]["pattern"] == "Z$"
    assert run_identity_schema["properties"]["finished_utc"]["pattern"] == "Z$"
    assert "output_publication_temporary_path" in run_identity_schema[
        "required"
    ]
    with pytest.raises(ValueError, match="schema validation failed"):
        validate_schema(
            {
                "schema_version": "1.1.0",
                "artifact_kind": (
                    "p06_control_aggregate_cache_native_benchmark"
                ),
                "unexpected": True,
            },
            schema_path,
        )


def _resume_binding_test_fixture(
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[dict[str, object], Mapping[str, object], Mapping[str, object]]:
    implementation_files = [
        {
            "path": "validation/calibration_v2/production_evaluator.py",
            "sha256": "1" * 64,
            "size_bytes": 101,
        },
        {
            "path": (
                "validation/calibration_v2/tests/"
                "test_control_aggregate_native_benchmark.py"
            ),
            "sha256": "2" * 64,
            "size_bytes": 202,
        },
    ]
    implementation_closure = {
        "ordered_files": implementation_files,
        "ordered_files_sha256": canonical_sha256(implementation_files),
    }
    untracked_files = [
        {
            "path": "validation/calibration_v2/example-untracked.json",
            "entry_kind": "regular_file",
            "sha256": "3" * 64,
            "size_bytes": 303,
        }
    ]
    repository_state = {
        "head_commit": "4" * 40,
        "is_dirty": True,
        "binding_algorithm": "focused resume-binding fixture",
        "untracked_artifact_exclusion": "Artifacts/**",
        "tracked_porcelain_v1_z_sha256": "5" * 64,
        "tracked_porcelain_v1_z_size_bytes": 5,
        "non_artifact_untracked_files": untracked_files,
        "non_artifact_untracked_files_sha256": canonical_sha256(
            untracked_files
        ),
        "tracked_binary_diff_sha256": "6" * 64,
        "tracked_binary_diff_size_bytes": 6,
    }
    bound_files = [
        {
            "id": "focused-bound-input",
            "path": "validation/calibration_v2/contracts/calibration-plan-v1.json",
            "sha256": "7" * 64,
            "size_bytes": 707,
        }
    ]
    current_inputs = {
        "ordered_bound_input_files": bound_files,
        "_configuration_hash_file_bindings": {},
    }
    input_closure = {
        "ordered_bound_input_files": copy.deepcopy(bound_files),
        "configuration_hashes": {},
    }
    input_closure["input_closure_sha256"] = canonical_sha256(input_closure)
    document: dict[str, object] = {
        "implementation_closure": copy.deepcopy(implementation_closure),
        "run_identity": {
            "repository_state": copy.deepcopy(repository_state),
        },
        "benchmark_input_closure": input_closure,
    }
    module = sys.modules[__name__]
    monkeypatch.setattr(
        module,
        "_implementation_closure",
        lambda: copy.deepcopy(implementation_closure),
    )
    monkeypatch.setattr(
        module,
        "_repository_state_binding",
        lambda: copy.deepcopy(repository_state),
    )
    monkeypatch.setattr(
        module,
        "_current_resume_input_bindings",
        lambda: copy.deepcopy(current_inputs),
    )
    return document, implementation_closure, repository_state


@pytest.mark.parametrize(
    "stale_path",
    (
        "validation/calibration_v2/production_evaluator.py",
        (
            "validation/calibration_v2/tests/"
            "test_control_aggregate_native_benchmark.py"
        ),
    ),
    ids=("stale-evaluator", "stale-benchmark-source"),
)
def test_resume_rejects_stale_implementation_file_hash(
    monkeypatch: pytest.MonkeyPatch,
    stale_path: str,
) -> None:
    document, _, _ = _resume_binding_test_fixture(monkeypatch)
    closure = copy.deepcopy(document["implementation_closure"])
    ordered_files = closure["ordered_files"]
    assert isinstance(ordered_files, list)
    record = next(item for item in ordered_files if item["path"] == stale_path)
    record["sha256"] = "f" * 64
    closure["ordered_files_sha256"] = canonical_sha256(ordered_files)
    document["implementation_closure"] = closure

    with pytest.raises(AssertionError, match="current implementation closure"):
        _validate_resume_closure_bindings(document)


def test_resume_rejects_stale_dirty_repository_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    document, _, _ = _resume_binding_test_fixture(monkeypatch)
    run_identity = copy.deepcopy(document["run_identity"])
    repository_state = run_identity["repository_state"]
    assert isinstance(repository_state, dict)
    repository_state["tracked_porcelain_v1_z_sha256"] = "f" * 64
    document["run_identity"] = run_identity

    with pytest.raises(AssertionError, match="current repository state"):
        _validate_resume_closure_bindings(document)


def test_resume_rejects_stale_bound_input_even_with_rehashed_input_closure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    document, _, _ = _resume_binding_test_fixture(monkeypatch)
    input_closure = copy.deepcopy(document["benchmark_input_closure"])
    bound_files = input_closure["ordered_bound_input_files"]
    assert isinstance(bound_files, list)
    bound_files[0]["sha256"] = "f" * 64
    unhashed = dict(input_closure)
    unhashed.pop("input_closure_sha256")
    input_closure["input_closure_sha256"] = canonical_sha256(unhashed)
    document["benchmark_input_closure"] = input_closure

    with pytest.raises(AssertionError, match="ordered_bound_input_files"):
        _validate_resume_closure_bindings(document)


def test_benchmark_output_publication_is_new_only_and_durable(
    tmp_path: Path,
) -> None:
    output = tmp_path / "benchmark.json"
    payload = b'{"artifact_kind":"benchmark-publication-test"}\n'
    parent_identity, recovery_actions, temporary_name = (
        _preflight_new_output(output)
    )
    assert recovery_actions == []

    _publish_new_durable(
        output,
        payload,
        expected_parent_identity=parent_identity,
        recovery_actions=recovery_actions,
        publication_temporary_name=temporary_name,
    )

    assert output.read_bytes() == payload
    with pytest.raises(AssertionError, match="already exists"):
        _preflight_new_output(output)
    with pytest.raises(AssertionError, match="already exists"):
        _publish_new_durable(
            output,
            b"replacement",
            expected_parent_identity=parent_identity,
            recovery_actions=recovery_actions,
            publication_temporary_name=temporary_name,
        )
    assert output.read_bytes() == payload


def test_interrupted_benchmark_output_publication_leaves_no_final(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    output = tmp_path / "benchmark.json"
    parent_identity, recovery_actions, temporary_name = (
        _preflight_new_output(output)
    )
    original_write = os.write
    write_count = 0

    def interrupted_write(descriptor: int, payload: bytes) -> int:
        nonlocal write_count
        write_count += 1
        if write_count == 1:
            return original_write(
                descriptor,
                payload[: max(1, len(payload) // 2)],
            )
        raise OSError("injected benchmark publication interruption")

    monkeypatch.setattr(os, "write", interrupted_write)
    with pytest.raises(OSError, match="publication interruption"):
        _publish_new_durable(
            output,
            b"complete benchmark payload",
            expected_parent_identity=parent_identity,
            recovery_actions=recovery_actions,
            publication_temporary_name=temporary_name,
        )

    assert not output.exists()
    assert not tuple(tmp_path.glob(".benchmark.json.*.tmp"))


def test_benchmark_output_parent_replacement_fails_closed(
    tmp_path: Path,
) -> None:
    parent = tmp_path / "output-parent"
    parent.mkdir()
    output = parent / "benchmark.json"
    parent_identity, recovery_actions, temporary_name = (
        _preflight_new_output(output)
    )
    assert recovery_actions == []
    parent.rename(tmp_path / "preserved-output-parent")
    parent.mkdir()

    with pytest.raises(AssertionError, match="parent identity changed"):
        _publish_new_durable(
            output,
            b"benchmark",
            expected_parent_identity=parent_identity,
            recovery_actions=recovery_actions,
            publication_temporary_name=temporary_name,
        )
    assert not output.exists()


def test_benchmark_output_parent_swap_after_open_fails_postcheck(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    parent = tmp_path / "output-parent"
    preserved_parent = tmp_path / "preserved-output-parent"
    parent.mkdir()
    output = parent / "benchmark.json"
    parent_identity, actions, temporary_name = _preflight_new_output(output)
    original_link = os.link
    swapped = False

    def swap_parent_then_link(*args: object, **kwargs: object) -> None:
        nonlocal swapped
        if not swapped:
            parent.rename(preserved_parent)
            parent.mkdir()
            swapped = True
        original_link(*args, **kwargs)

    monkeypatch.setattr(os, "link", swap_parent_then_link)
    with pytest.raises(AssertionError, match="parent identity changed"):
        _publish_new_durable(
            output,
            b"benchmark",
            expected_parent_identity=parent_identity,
            recovery_actions=actions,
            publication_temporary_name=temporary_name,
        )

    assert not output.exists()
    assert (preserved_parent / output.name).read_bytes() == b"benchmark"
    assert not tuple(preserved_parent.glob(".benchmark.json.*.tmp"))


def test_resume_parent_swap_between_read_and_cleanup_fails_closed(
    tmp_path: Path,
) -> None:
    parent = tmp_path / "output-parent"
    preserved_parent = tmp_path / "preserved-output-parent"
    parent.mkdir()
    output = parent / "benchmark.json"
    stale = parent / f".benchmark.json.{'d' * 32}.tmp"
    stale.write_bytes(b"recorded stale bytes")
    _, actions, publication_temporary_name = _preflight_new_output(output)
    output.write_bytes(
        canonical_json_bytes(
            {
                "output_recovery_actions": actions,
                "output_publication_temporary_path": (
                    publication_temporary_name
                ),
            }
        )
        + b"\n"
    )
    replacement_temporary = f".benchmark.json.{'c' * 32}.tmp"

    def swap_parent(
        document: Mapping[str, object],
    ) -> tuple[object, str]:
        parent.rename(preserved_parent)
        parent.mkdir()
        (parent / output.name).write_bytes(b"foreign output")
        (parent / replacement_temporary).write_bytes(b"foreign temporary")
        return (
            document["output_recovery_actions"],
            str(document["output_publication_temporary_path"]),
        )

    with pytest.raises(AssertionError, match="parent identity changed"):
        _resume_existing_published_output(
            output,
            validate_document=swap_parent,
        )

    assert (preserved_parent / stale.name).read_bytes() == (
        b"recorded stale bytes"
    )
    assert (parent / output.name).read_bytes() == b"foreign output"
    assert (parent / replacement_temporary).read_bytes() == b"foreign temporary"


def test_consecutive_sigkills_preserve_audit_until_published_then_resume_cleanup(
    tmp_path: Path,
) -> None:
    output = tmp_path / "benchmark.json"
    crash_before_publication_script = "\n".join(
        (
            "import sys",
            "from pathlib import Path",
            (
                "from validation.calibration_v2.tests."
                "test_control_aggregate_native_benchmark import "
                "_preflight_new_output, _publish_new_durable, "
                "canonical_json_bytes"
            ),
            "path = Path(sys.argv[1])",
            "identity, actions, temporary = _preflight_new_output(path)",
            (
                "payload = canonical_json_bytes({"
                "'output_recovery_actions': actions, "
                "'output_publication_temporary_path': temporary}) + b'\\n'"
            ),
            (
                "_publish_new_durable(path, payload, "
                "expected_parent_identity=identity, recovery_actions=actions, "
                "publication_temporary_name=temporary, "
                "crash_after_temporary_fsync=True)"
            ),
        )
    )
    for expected_temporary_count in (1, 2):
        crashed = subprocess.run(
            (
                sys.executable,
                "-c",
                crash_before_publication_script,
                str(output),
            ),
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
        )
        assert crashed.returncode == -signal.SIGKILL
        assert not output.exists()
        assert len(tuple(tmp_path.glob(".benchmark.json.*.tmp"))) == (
            expected_temporary_count
        )

    stale_payloads = {
        path.name: path.read_bytes()
        for path in tmp_path.glob(".benchmark.json.*.tmp")
    }
    crash_after_publication_script = "\n".join(
        (
            "import sys",
            "from pathlib import Path",
            (
                "from validation.calibration_v2.tests."
                "test_control_aggregate_native_benchmark import "
                "_preflight_new_output, _publish_new_durable, "
                "canonical_json_bytes"
            ),
            "path = Path(sys.argv[1])",
            "identity, actions, temporary = _preflight_new_output(path)",
            (
                "payload = canonical_json_bytes({"
                "'output_recovery_actions': actions, "
                "'output_publication_temporary_path': temporary}) + b'\\n'"
            ),
            (
                "_publish_new_durable(path, payload, "
                "expected_parent_identity=identity, recovery_actions=actions, "
                "publication_temporary_name=temporary, "
                "crash_after_final_fsync_before_cleanup=True)"
            ),
        )
    )
    crashed_after_publication = subprocess.run(
        (
            sys.executable,
            "-c",
            crash_after_publication_script,
            str(output),
        ),
        cwd=REPOSITORY_ROOT,
        check=False,
        capture_output=True,
    )
    assert crashed_after_publication.returncode == -signal.SIGKILL
    assert output.is_file()
    published_payload = output.read_bytes()
    published = json.loads(published_payload)
    assert len(tuple(tmp_path.glob(".benchmark.json.*.tmp"))) == 3
    assert published["output_recovery_actions"] == [
        {
            "action": "removed_recognized_stale_benchmark_temporary",
            "path": name,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }
        for name, payload in sorted(stale_payloads.items())
    ]

    resume_cleanup_script = "\n".join(
        (
            "import json, sys",
            "from pathlib import Path",
            (
                "from validation.calibration_v2.tests."
                "test_control_aggregate_native_benchmark import "
                "_resume_existing_published_output"
            ),
            "path = Path(sys.argv[1])",
            (
                "binding = lambda document: ("
                "document['output_recovery_actions'], "
                "document['output_publication_temporary_path'])"
            ),
            (
                "document = _resume_existing_published_output("
                "path, validate_document=binding)"
            ),
            "assert document is not None",
        )
    )
    relaunched = subprocess.run(
        (sys.executable, "-c", resume_cleanup_script, str(output)),
        cwd=REPOSITORY_ROOT,
        check=False,
        capture_output=True,
    )

    assert relaunched.returncode == 0, relaunched.stderr.decode("utf-8")
    assert output.read_bytes() == published_payload
    assert not tuple(tmp_path.glob(".benchmark.json.*.tmp"))


def test_published_cleanup_rejects_unrecorded_temporary(
    tmp_path: Path,
) -> None:
    output = tmp_path / "benchmark.json"
    parent_identity, actions, temporary_name = _preflight_new_output(output)
    payload = canonical_json_bytes(
        {
            "output_recovery_actions": actions,
            "output_publication_temporary_path": temporary_name,
        }
    ) + b"\n"
    _publish_new_durable(
        output,
        payload,
        expected_parent_identity=parent_identity,
        recovery_actions=actions,
        publication_temporary_name=temporary_name,
    )
    unrecorded = tmp_path / f".benchmark.json.{'f' * 32}.tmp"
    unrecorded.write_bytes(b"not recorded")

    with pytest.raises(AssertionError, match="unrecorded"):
        _complete_published_output_cleanup(
            output,
            recovery_actions=actions,
            publication_temporary_name=temporary_name,
        )

    assert unrecorded.read_bytes() == b"not recorded"


def test_published_cleanup_rejects_recorded_temporary_byte_change(
    tmp_path: Path,
) -> None:
    output = tmp_path / "benchmark.json"
    stale = tmp_path / f".benchmark.json.{'e' * 32}.tmp"
    stale.write_bytes(b"snapshotted bytes")
    _, actions, temporary_name = _preflight_new_output(output)
    output.write_bytes(
        canonical_json_bytes(
            {
                "output_recovery_actions": actions,
                "output_publication_temporary_path": temporary_name,
            }
        )
        + b"\n"
    )
    stale.write_bytes(b"changed bytes")

    with pytest.raises(AssertionError, match="bytes differ"):
        _complete_published_output_cleanup(
            output,
            recovery_actions=actions,
            publication_temporary_name=temporary_name,
        )

    assert stale.read_bytes() == b"changed bytes"


def _validate_cache_preparation_evidence(
    document: Mapping[str, object],
) -> None:
    configuration = document.get("configuration")
    input_closure = document.get("benchmark_input_closure")
    if not isinstance(configuration, dict) or not isinstance(
        input_closure,
        dict,
    ):
        raise AssertionError("benchmark cache preparation closure is absent")
    expected_bank = configuration.get("shared_bank_configuration_sha256")
    expected_configuration_id = input_closure.get(
        "candidate_configuration_id"
    )
    stable_records_by_stage: dict[str, list[Mapping[str, object]]] = {}
    lifecycle_hashes: dict[str, str] = {}
    for stage, expected_reused, expected_analysis, expected_operators in (
        ("cold", False, 1, 16),
        ("warm", True, 0, 0),
    ):
        stage_evidence = document.get(stage)
        if not isinstance(stage_evidence, dict):
            raise AssertionError(
                f"benchmark {stage} cache preparation evidence is absent"
            )
        records = stage_evidence.get("cache_preparation_records")
        declared_count = stage_evidence.get(
            "cache_preparation_record_count"
        )
        declared_list_sha256 = stage_evidence.get(
            "cache_preparation_records_sha256"
        )
        if (
            not isinstance(records, list)
            or declared_count != PREPARED_CASE_COUNT
            or len(records) != PREPARED_CASE_COUNT
            or declared_list_sha256 != canonical_sha256(records)
        ):
            raise AssertionError(
                f"benchmark {stage} cache preparation list differs"
            )
        identities = []
        tokens = []
        stable_records = []
        for record in records:
            if not isinstance(record, dict):
                raise AssertionError(
                    f"benchmark {stage} cache preparation record is invalid"
                )
            unhashed = dict(record)
            declared_record_sha256 = unhashed.pop("record_sha256", None)
            if declared_record_sha256 != canonical_sha256(unhashed):
                raise AssertionError(
                    f"benchmark {stage} cache preparation record hash differs"
                )
            if (
                record.get("cache_reused") is not expected_reused
                or record.get(
                    "preparation_analysis_grid_invocation_count"
                )
                != expected_analysis
                or record.get(
                    "preparation_spatial_operator_evaluation_count"
                )
                != expected_operators
                or record.get("shared_bank_configuration_sha256")
                != expected_bank
                or record.get("requesting_configuration_id")
                != expected_configuration_id
            ):
                raise AssertionError(
                    f"benchmark {stage} cache preparation contract differs"
                )
            identities.append(record.get("identity_sha256"))
            tokens.append(record.get("cache_token"))
            stable = dict(unhashed)
            stable.pop("cache_reused")
            stable.pop("preparation_analysis_grid_invocation_count")
            stable.pop("preparation_spatial_operator_evaluation_count")
            stable_records.append(stable)
        if (
            len(identities) != len(set(identities))
            or len(tokens) != len(set(tokens))
        ):
            raise AssertionError(
                f"benchmark {stage} cache preparation identities repeat"
            )
        stable_records_by_stage[stage] = stable_records
        assert isinstance(declared_list_sha256, str)
        lifecycle_hashes[stage] = declared_list_sha256
    if stable_records_by_stage["cold"] != stable_records_by_stage["warm"]:
        raise AssertionError(
            "benchmark cold/warm cache preparation content differs"
        )
    if lifecycle_hashes["cold"] == lifecycle_hashes["warm"]:
        raise AssertionError(
            "benchmark cold/warm cache lifecycle hashes must differ"
        )


def _cache_preparation_validation_fixture() -> Mapping[str, object]:
    bank = "a" * 64
    configuration_id = "native-benchmark-candidate"

    def digest(label: str, ordinal: int) -> str:
        return hashlib.sha256(f"{label}:{ordinal}".encode()).hexdigest()

    def records(reused: bool) -> list[Mapping[str, object]]:
        values = []
        for ordinal in range(PREPARED_CASE_COUNT):
            record = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_non_ash_cache_preparation_evidence",
                "identity_sha256": digest("identity", ordinal),
                "cache_token": digest("token", ordinal),
                "cache_origin_manifest_sha256": digest("origin", ordinal),
                "requesting_configuration_id": configuration_id,
                "shared_bank_configuration_sha256": bank,
                "cache_reused": reused,
                "preparation_analysis_grid_invocation_count": (
                    0 if reused else 1
                ),
                "preparation_spatial_operator_evaluation_count": (
                    0 if reused else 16
                ),
                "cache_artifact_sha256": digest("artifact", ordinal),
                "cache_artifact_size_bytes": ordinal + 1,
                "feature_tensor_q15_sha256": digest("feature", ordinal),
                "descriptor_output_frame_sha256_values": [
                    digest(f"descriptor-{descriptor}", ordinal)
                    for descriptor in range(16)
                ],
            }
            record["record_sha256"] = canonical_sha256(record)
            values.append(record)
        return values

    cold_records = records(False)
    warm_records = records(True)
    return {
        "configuration": {
            "shared_bank_configuration_sha256": bank,
        },
        "benchmark_input_closure": {
            "candidate_configuration_id": configuration_id,
        },
        "cold": {
            "cache_preparation_record_count": PREPARED_CASE_COUNT,
            "cache_preparation_records": cold_records,
            "cache_preparation_records_sha256": canonical_sha256(
                cold_records
            ),
        },
        "warm": {
            "cache_preparation_record_count": PREPARED_CASE_COUNT,
            "cache_preparation_records": warm_records,
            "cache_preparation_records_sha256": canonical_sha256(
                warm_records
            ),
        },
    }


def test_cache_preparation_semantic_validator_rejects_rehashed_tampering() -> None:
    valid = _cache_preparation_validation_fixture()
    _validate_cache_preparation_evidence(valid)

    invalid_record_hash = copy.deepcopy(valid)
    invalid_record_hash["warm"]["cache_preparation_records"][0][
        "record_sha256"
    ] = "0" * 64
    invalid_record_hash["warm"]["cache_preparation_records_sha256"] = (
        canonical_sha256(
            invalid_record_hash["warm"]["cache_preparation_records"]
        )
    )
    with pytest.raises(AssertionError, match="record hash differs"):
        _validate_cache_preparation_evidence(invalid_record_hash)

    invalid_phase = copy.deepcopy(valid)
    phase_record = invalid_phase["cold"]["cache_preparation_records"][0]
    phase_record["cache_reused"] = True
    phase_record["preparation_analysis_grid_invocation_count"] = 0
    phase_record["preparation_spatial_operator_evaluation_count"] = 0
    phase_record.pop("record_sha256")
    phase_record["record_sha256"] = canonical_sha256(phase_record)
    invalid_phase["cold"]["cache_preparation_records_sha256"] = (
        canonical_sha256(invalid_phase["cold"]["cache_preparation_records"])
    )
    with pytest.raises(AssertionError, match="contract differs"):
        _validate_cache_preparation_evidence(invalid_phase)

    invalid_content = copy.deepcopy(valid)
    content_record = invalid_content["warm"]["cache_preparation_records"][0]
    content_record["feature_tensor_q15_sha256"] = "f" * 64
    content_record.pop("record_sha256")
    content_record["record_sha256"] = canonical_sha256(content_record)
    invalid_content["warm"]["cache_preparation_records_sha256"] = (
        canonical_sha256(
            invalid_content["warm"]["cache_preparation_records"]
        )
    )
    with pytest.raises(AssertionError, match="content differs"):
        _validate_cache_preparation_evidence(invalid_content)


@pytest.mark.skipif(
    os.environ.get("MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK") != "1",
    reason="explicit native aggregate benchmark opt-in is required",
)
def test_actual_native_tracked_full_selector_cold_warm_benchmark(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    output_path = os.environ.get("MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT")
    if not output_path:
        raise AssertionError("native aggregate benchmark output path is required")
    output = _absolute_lexical_path(Path(output_path))
    try:
        output_relative = output.relative_to(REPOSITORY_ROOT)
    except ValueError as error:
        raise AssertionError(
            "native benchmark output must be inside repository Artifacts"
        ) from error
    if output_relative.parts[:1] != ("Artifacts",):
        raise AssertionError(
            "native benchmark output must be inside repository Artifacts"
        )
    benchmark_schema_path = REPOSITORY_ROOT.joinpath(
        *Path(BENCHMARK_SCHEMA_RELATIVE_PATH).parts
    )
    def validate_existing_output(
        document: Mapping[str, object],
    ) -> tuple[object, str]:
        existing_schema_binding = document.get("schema_binding")
        if existing_schema_binding != {
            "path": BENCHMARK_SCHEMA_RELATIVE_PATH,
            "sha256": _sha256_file(benchmark_schema_path),
            "size_bytes": benchmark_schema_path.stat().st_size,
        }:
            raise AssertionError("published benchmark schema binding differs")
        validate_schema(document, benchmark_schema_path)
        _validate_cache_preparation_evidence(document)
        unhashed_existing = dict(document)
        declared_existing_sha256 = unhashed_existing.pop(
            "evidence_sha256",
            None,
        )
        if declared_existing_sha256 != canonical_sha256(unhashed_existing):
            raise AssertionError("published benchmark evidence SHA-256 differs")
        _validate_resume_closure_bindings(document)
        existing_run_identity = document.get("run_identity")
        if not isinstance(existing_run_identity, dict):
            raise AssertionError("published benchmark run identity is absent")
        publication_temporary_name = existing_run_identity.get(
            "output_publication_temporary_path"
        )
        if not isinstance(publication_temporary_name, str):
            raise AssertionError(
                "published benchmark temporary binding is absent"
            )
        return (
            existing_run_identity.get("output_recovery_actions"),
            publication_temporary_name,
        )

    existing_output = _resume_existing_published_output(
        output,
        validate_document=validate_existing_output,
    )
    if existing_output is not None:
        return
    (
        output_parent_identity,
        output_recovery_actions,
        output_publication_temporary_name,
    ) = _preflight_new_output(output)
    run_id = str(uuid.uuid4())
    started_utc = _canonical_utc_now()
    repository_state_start = _repository_state_binding()
    swiftc_path = _run_identity_command(("/usr/bin/xcrun", "--find", "swiftc"))
    toolchain_identity = {
        "xcodebuild_version": _run_identity_command(
            ("/usr/bin/xcodebuild", "-version")
        ),
        "swiftc_path": swiftc_path,
        "swift_version": _run_identity_command((swiftc_path, "--version")),
        "macos_sdk_version": _run_identity_command(
            ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version")
        ),
        "macos_sdk_path": _run_identity_command(
            ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path")
        ),
    }
    implementation_closure_start = _implementation_closure()
    statvfs_before = os.statvfs(tmp_path)
    allocation_floor_bytes = int(statvfs_before.f_frsize)
    free_disk_before = shutil.disk_usage(tmp_path).free
    available_inodes_before = statvfs_before.f_favail

    factory_setup_started = time.perf_counter()
    bound = _BoundStub()
    ordered_bound_input_files = [dict(record) for record in bound.records]
    _verify_ordered_file_records_unchanged(ordered_bound_input_files)
    native_root = tmp_path / "native"
    evidence_root = tmp_path / "evidence"
    factory = make_native_candidate_adapter_factory(
        REPOSITORY_ROOT,
        cache_root=native_root,
        timeout_seconds=900.0,
        bound_inputs=bound,
    )
    vector = dict(factory.plan["search"]["initial_vector_values"])
    degradation_policy = bound.documents["degradation_policy"]
    factory_setup_seconds = time.perf_counter() - factory_setup_started
    baseline_contract = json.loads(
        (
            REPOSITORY_ROOT
            / "validation/calibration_v2/contracts/"
            "baseline-ablation-contract-v1.json"
        ).read_bytes()
    )
    selector_contract = baseline_contract["non_ash_selector"]
    maximum_attempt_count = int(
        selector_contract["candidate_evaluation_budget"]
    )
    formula_derivation = _maximum_formula_derivation(
        factory.plan,
        selector_contract,
    )

    prepared_cases_started = time.perf_counter()
    prepared = _prepared_cases(degradation_policy)
    prepared_cases_seconds = time.perf_counter() - prepared_cases_started
    prepared_case_bindings = [
        {"ordinal": ordinal, **item.public_evidence()}
        for ordinal, item in enumerate(prepared)
    ]
    prepared_case_bindings_sha256 = canonical_sha256(
        prepared_case_bindings
    )

    cold_adapter_setup_started = time.perf_counter()
    source_adapter = factory(vector, "development")
    tracker = _AdapterInvocationTracker(source_adapter, [], [], [])
    adapter = tracker.adapter()
    store = ContentAddressedEvidenceStore(evidence_root)
    aggregate_identity_context = _aggregate_context(
        bound=bound,
        adapter_configuration=adapter.configuration,
    )
    if (
        aggregate_identity_context["baseline_selector_contract"]
        != selector_contract
    ):
        raise AssertionError("benchmark selector contract changed during setup")
    cold_adapter_setup_seconds = (
        time.perf_counter() - cold_adapter_setup_started
    )
    cold_cache_preparation_started = time.perf_counter()
    cache = _NativeSelectionOutputCache(
        adapter=adapter,
        prepared=prepared,
        split="development",
        shared_bank_configuration_sha256=str(
            adapter.configuration["shared_bank_configuration_sha256"]
        ),
        degradation_policy_sha256=str(
            degradation_policy["policy_sha256"]
        ),
        evidence_store=store,
        aggregate_identity_context=aggregate_identity_context,
    )
    cold_cache_preparation_seconds = (
        time.perf_counter() - cold_cache_preparation_started
    )
    cold_preparation_records = (
        source_adapter.callable.non_ash_cache_preparation_records()
    )
    metric_calls = 0
    scalar_metric = evaluator_module.corpus_metric_bundle

    def counted_metric(
        target: PlanarFrame,
        output: PlanarFrame,
        *,
        writer_y_psnr_contribution_db: object = None,
    ) -> Mapping[str, object]:
        nonlocal metric_calls
        metric_calls += 1
        return scalar_metric(
            target,
            output,
            writer_y_psnr_contribution_db=(
                writer_y_psnr_contribution_db
            ),
        )

    monkeypatch.setattr(evaluator_module, "corpus_metric_bundle", counted_metric)
    bank = str(adapter.configuration["shared_bank_configuration_sha256"])
    route_execution_contract = {
        "routes": ["direct-2x", "direct-3over2"],
        "coordinate_policy_by_route": {
            route: adapter.configuration["route_luts"][route][
                "coordinate_policy"
            ]
            for route in ("direct-2x", "direct-3over2")
        },
        "analysis_grid_source_step_by_route": {
            route: adapter.configuration["route_luts"][route][
                "analysis_grid_source_step"
            ]
            for route in ("direct-2x", "direct-3over2")
        },
        "temporal_mode": factory.plan["fixed_choices"]["temporal_mode"],
        "comparison_domain": "engine_raw",
        "execution_device": "CPU native Swift control evaluation",
        "metal_execution": False,
    }
    route_execution_contract["contract_sha256"] = canonical_sha256(
        route_execution_contract
    )
    cold_rule_evaluator_seconds = []

    def timed_cold_evaluator(
        rule: Mapping[str, object],
    ) -> object:
        started = time.perf_counter()
        try:
            return cache.non_ash(rule)
        finally:
            cold_rule_evaluator_seconds.append(
                time.perf_counter() - started
            )

    try:
        cold_started = time.perf_counter()
        cold_selection = search_non_ash_development(
            shared_bank_configuration_sha256=bank,
            degradation_policy_sha256=str(
                degradation_policy["policy_sha256"]
            ),
            selector_contract=selector_contract,
            development_evaluator=timed_cold_evaluator,
            cached_16_operator_output_manifest_sha256=cache.manifest_sha256,
            evidence_store=store,
        )
        cache.commit_pending_aggregate_origins()
        cold_search_commit_seconds = time.perf_counter() - cold_started
        cold_metric_calls = metric_calls
        cold_native_calls = source_adapter.callable.non_ash_cache_records_count()
        cold_control_calls = source_adapter.callable.control_runtime_records_count()
        cold_ledger_sha256 = cold_selection["document"][
            "development_attempt_ledger_sha256"
        ]
        cold_ledger_document = store.reopen(cold_ledger_sha256)
        cold_ledger_bytes = canonical_json_bytes(cold_ledger_document)
    finally:
        cold_close_started = time.perf_counter()
        source_adapter.callable.close()
        cold_close_seconds = time.perf_counter() - cold_close_started

    cold_native_storage = _tree_totals(
        native_root,
        allocation_floor_bytes=allocation_floor_bytes,
    )
    cold_evidence_storage = _tree_totals(
        evidence_root,
        allocation_floor_bytes=allocation_floor_bytes,
    )
    cold_rule_scoped_storage = _rule_scoped_storage(
        native_root=native_root,
        evidence_root=evidence_root,
        allocation_floor_bytes=allocation_floor_bytes,
    )

    warm_prepared_cases_started = time.perf_counter()
    warm_prepared = _prepared_cases(degradation_policy)
    warm_prepared_cases_seconds = (
        time.perf_counter() - warm_prepared_cases_started
    )
    warm_adapter_setup_started = time.perf_counter()
    warm_source_adapter = factory(vector, "development")
    warm_tracker = _AdapterInvocationTracker(
        warm_source_adapter,
        [],
        [],
        [],
    )
    warm_adapter = warm_tracker.adapter()
    warm_store = ContentAddressedEvidenceStore(evidence_root)
    warm_aggregate_identity_context = _aggregate_context(
        bound=bound,
        adapter_configuration=warm_adapter.configuration,
    )
    warm_adapter_setup_seconds = (
        time.perf_counter() - warm_adapter_setup_started
    )
    warm_cache_preparation_started = time.perf_counter()
    warm_cache = _NativeSelectionOutputCache(
        adapter=warm_adapter,
        prepared=warm_prepared,
        split="development",
        shared_bank_configuration_sha256=str(
            warm_adapter.configuration[
                "shared_bank_configuration_sha256"
            ]
        ),
        degradation_policy_sha256=str(
            degradation_policy["policy_sha256"]
        ),
        evidence_store=warm_store,
        aggregate_identity_context=warm_aggregate_identity_context,
    )
    warm_cache_preparation_seconds = (
        time.perf_counter() - warm_cache_preparation_started
    )
    warm_preparation_records = (
        warm_source_adapter.callable.non_ash_cache_preparation_records()
    )
    warm_rule_evaluator_seconds = []

    def timed_warm_evaluator(
        rule: Mapping[str, object],
    ) -> object:
        started = time.perf_counter()
        try:
            return warm_cache.non_ash(rule)
        finally:
            warm_rule_evaluator_seconds.append(
                time.perf_counter() - started
            )

    try:
        warm_started = time.perf_counter()
        warm_selection = search_non_ash_development(
            shared_bank_configuration_sha256=bank,
            degradation_policy_sha256=str(
                degradation_policy["policy_sha256"]
            ),
            selector_contract=selector_contract,
            development_evaluator=timed_warm_evaluator,
            cached_16_operator_output_manifest_sha256=(
                warm_cache.manifest_sha256
            ),
            evidence_store=warm_store,
        )
        warm_cache.commit_pending_aggregate_origins()
        warm_search_commit_seconds = time.perf_counter() - warm_started
        warm_native_calls = (
            warm_source_adapter.callable.non_ash_cache_records_count()
        )
        warm_control_calls = (
            warm_source_adapter.callable.control_runtime_records_count()
        )
    finally:
        warm_close_started = time.perf_counter()
        warm_source_adapter.callable.close()
        warm_close_seconds = time.perf_counter() - warm_close_started

    warm_native_storage = _tree_totals(
        native_root,
        allocation_floor_bytes=allocation_floor_bytes,
    )
    warm_evidence_storage = _tree_totals(
        evidence_root,
        allocation_floor_bytes=allocation_floor_bytes,
    )
    free_disk_after = shutil.disk_usage(tmp_path).free
    available_inodes_after = os.statvfs(tmp_path).f_favail
    finished_utc = _canonical_utc_now()
    implementation_closure_end = _implementation_closure()
    _verify_ordered_file_records_unchanged(ordered_bound_input_files)
    repository_state_end = _repository_state_binding()

    observed_unique_rules = cold_native_calls // PREPARED_CASE_COUNT
    if observed_unique_rules <= 0:
        raise AssertionError("native benchmark observed no unique rules")
    shared_dependency_documents = _shared_aggregate_dependency_documents(
        evidence_root=evidence_root,
        expected_rule_count=observed_unique_rules,
    )
    selection_sha256 = _require_benchmark_sha256(
        cold_selection.get("sha256"),
        "non-ASH selector selection",
    )
    selection_document = cold_selection.get("document")
    if not isinstance(selection_document, dict):
        raise AssertionError("non-ASH selector selection document is absent")
    selection_path = (
        evidence_root / "documents" / f"{selection_sha256}.json"
    )
    if _read_json_object(
        selection_path,
        content_addressed_filename=True,
    ) != selection_document:
        raise AssertionError("non-ASH selector selection document differs")
    native_dependency_binding = shared_dependency_documents[
        "native_durability_commit"
    ]
    evidence_dependency_binding = shared_dependency_documents[
        "evidence_dependency_commit"
    ]
    ledger_path = (
        evidence_root / "documents" / f"{cold_ledger_sha256}.json"
    )
    count_dependent_document_paths = {
        ledger_path,
        native_dependency_binding["path"],
        evidence_dependency_binding["path"],
        selection_path,
    }
    if len(count_dependent_document_paths) != 4:
        raise AssertionError(
            "count-dependent shared document paths are not distinct"
        )
    count_dependent_shared_document_growth_models = (
        _count_dependent_shared_document_growth_models(
            native_durability_document=native_dependency_binding["document"],
            evidence_dependency_document=evidence_dependency_binding[
                "document"
            ],
            selection_document=selection_document,
            observed_unique_rule_count=observed_unique_rules,
            maximum_unique_rule_count=MAXIMUM_UNIQUE_RULES_PER_BANK,
            maximum_attempt_count=maximum_attempt_count,
            allocation_floor_bytes=allocation_floor_bytes,
            observed_allocated_or_floor_bytes_by_kind={
                "native_durability_commit": _allocated_or_floor_bytes(
                    native_dependency_binding["path"],
                    allocation_floor_bytes,
                ),
                "evidence_dependency_commit": _allocated_or_floor_bytes(
                    evidence_dependency_binding["path"],
                    allocation_floor_bytes,
                ),
                "selector_selection": _allocated_or_floor_bytes(
                    selection_path,
                    allocation_floor_bytes,
                ),
            },
        )
    )
    maximum_native_calls_per_bank = (
        MAXIMUM_UNIQUE_RULES_PER_BANK * PREPARED_CASE_COUNT
    )
    maximum_native_calls_first_outer_sweep = (
        maximum_native_calls_per_bank * FIRST_OUTER_SWEEP_BANK_COUNT
    )
    maximum_native_calls_all_banks = (
        maximum_native_calls_per_bank * MAXIMUM_BANK_COUNT
    )
    maximum_rule_scoped_files_per_bank = (
        MAXIMUM_UNIQUE_RULES_PER_BANK * RULE_SCOPED_FILES_PER_RULE
    )
    maximum_rule_scoped_files_all_banks = (
        maximum_rule_scoped_files_per_bank * MAXIMUM_BANK_COUNT
    )
    maximum_rule_scoped_files_first_outer_sweep = (
        maximum_rule_scoped_files_per_bank * FIRST_OUTER_SWEEP_BANK_COUNT
    )
    maximum_rule_scoped_inodes_per_bank = (
        MAXIMUM_UNIQUE_RULES_PER_BANK * RULE_SCOPED_INODES_PER_RULE
    )
    maximum_rule_scoped_inodes_all_banks = (
        maximum_rule_scoped_inodes_per_bank * MAXIMUM_BANK_COUNT
    )
    maximum_rule_scoped_inodes_first_outer_sweep = (
        maximum_rule_scoped_inodes_per_bank * FIRST_OUTER_SWEEP_BANK_COUNT
    )
    observed_total_size_bytes = int(cold_native_storage["size_bytes"]) + int(
        cold_evidence_storage["size_bytes"]
    )
    observed_total_file_count = int(cold_native_storage["file_count"]) + int(
        cold_evidence_storage["file_count"]
    )
    observed_total_directory_count = int(
        cold_native_storage["directory_count"]
    ) + int(cold_evidence_storage["directory_count"])
    observed_total_inode_count = int(cold_native_storage["inode_count"]) + int(
        cold_evidence_storage["inode_count"]
    )
    fixed_observed_size_bytes = observed_total_size_bytes - int(
        cold_rule_scoped_storage["size_bytes"]
    )
    fixed_observed_file_count = observed_total_file_count - int(
        cold_rule_scoped_storage["file_count"]
    )
    fixed_observed_directory_count = observed_total_directory_count - int(
        cold_rule_scoped_storage["directory_count"]
    )
    fixed_observed_inode_count = observed_total_inode_count - int(
        cold_rule_scoped_storage["inode_count"]
    )
    observed_total_allocated_or_floor_bytes = int(
        cold_native_storage["allocated_or_block_floor_bytes"]
    ) + int(cold_evidence_storage["allocated_or_block_floor_bytes"])
    fixed_observed_allocated_or_floor_bytes = (
        observed_total_allocated_or_floor_bytes
        - int(cold_rule_scoped_storage["allocated_or_block_floor_bytes"])
    )
    maximum_complete_rule_size_bytes = int(
        cold_rule_scoped_storage["maximum_complete_rule_size_bytes"]
    )
    maximum_complete_rule_allocated_or_floor_bytes = int(
        cold_rule_scoped_storage[
            "maximum_complete_rule_allocated_or_block_floor_bytes"
        ]
    )
    observed_attempt_records = cold_ledger_document.get("records")
    if not isinstance(observed_attempt_records, list):
        raise AssertionError("benchmark attempt ledger records are absent")
    maximum_attempt_record = {
        "ordinal": maximum_attempt_count - 1,
        "split": "development",
        "rule_sha256": "f" * 64,
        "rule_serialization": [
            -384
            for _ in selector_contract["coordinates"]["order"]
        ],
        "objective_summary_sha256": "f" * 64,
        "output_manifest_sha256": "f" * 64,
    }
    maximum_attempt_record_size_bytes = len(
        canonical_json_bytes(maximum_attempt_record)
    )
    if any(
        len(canonical_json_bytes(record))
        > maximum_attempt_record_size_bytes
        for record in observed_attempt_records
    ):
        raise AssertionError("observed attempt record exceeds structural bound")
    empty_ledger = dict(cold_ledger_document)
    empty_ledger["records"] = []
    maximum_attempt_ledger_logical_bytes = (
        len(canonical_json_bytes(empty_ledger))
        + maximum_attempt_count * maximum_attempt_record_size_bytes
        + maximum_attempt_count
        - 1
    )
    observed_attempt_ledger_logical_bytes = len(cold_ledger_bytes)
    observed_attempt_ledger_allocated_or_floor_bytes = (
        _allocated_or_floor_bytes(ledger_path, allocation_floor_bytes)
    )
    maximum_attempt_ledger_allocated_block_floor_bytes = (
        _modeled_allocated_block_floor_bytes(
            maximum_attempt_ledger_logical_bytes,
            allocation_floor_bytes,
            observed_allocated_or_floor_bytes=(
                observed_attempt_ledger_allocated_or_floor_bytes
            ),
        )
    )
    observed_count_dependent_shared_logical_bytes = int(
        count_dependent_shared_document_growth_models[
            "observed_logical_bytes"
        ]
    )
    modeled_count_dependent_shared_logical_bytes = int(
        count_dependent_shared_document_growth_models[
            "modeled_maximum_logical_bytes"
        ]
    )
    observed_count_dependent_shared_allocated_bytes = int(
        count_dependent_shared_document_growth_models[
            "observed_allocated_or_block_floor_bytes"
        ]
    )
    modeled_count_dependent_shared_allocated_bytes = int(
        count_dependent_shared_document_growth_models[
            "modeled_maximum_allocated_block_floor_bytes"
        ]
    )
    projected_non_rule_logical_bytes = (
        fixed_observed_size_bytes
        - observed_attempt_ledger_logical_bytes
        + maximum_attempt_ledger_logical_bytes
        - observed_count_dependent_shared_logical_bytes
        + modeled_count_dependent_shared_logical_bytes
    )
    projected_non_rule_allocated_or_floor_bytes = (
        fixed_observed_allocated_or_floor_bytes
        - observed_attempt_ledger_allocated_or_floor_bytes
        + maximum_attempt_ledger_allocated_block_floor_bytes
        - observed_count_dependent_shared_allocated_bytes
        + modeled_count_dependent_shared_allocated_bytes
    )
    empirical_projected_logical_bytes_per_bank = (
        projected_non_rule_logical_bytes
        + MAXIMUM_UNIQUE_RULES_PER_BANK * maximum_complete_rule_size_bytes
    )
    empirical_projected_logical_bytes_all_banks = (
        empirical_projected_logical_bytes_per_bank * MAXIMUM_BANK_COUNT
    )
    empirical_projected_logical_bytes_first_outer_sweep = (
        empirical_projected_logical_bytes_per_bank
        * FIRST_OUTER_SWEEP_BANK_COUNT
    )
    empirical_projected_allocated_bytes_per_bank = (
        projected_non_rule_allocated_or_floor_bytes
        + MAXIMUM_UNIQUE_RULES_PER_BANK
        * maximum_complete_rule_allocated_or_floor_bytes
    )
    empirical_projected_allocated_bytes_all_banks = (
        empirical_projected_allocated_bytes_per_bank * MAXIMUM_BANK_COUNT
    )
    empirical_projected_allocated_bytes_first_outer_sweep = (
        empirical_projected_allocated_bytes_per_bank
        * FIRST_OUTER_SWEEP_BANK_COUNT
    )
    structural_files_per_bank = (
        fixed_observed_file_count + maximum_rule_scoped_files_per_bank
    )
    structural_files_all_banks = (
        structural_files_per_bank * MAXIMUM_BANK_COUNT
    )
    structural_files_first_outer_sweep = (
        structural_files_per_bank * FIRST_OUTER_SWEEP_BANK_COUNT
    )
    structural_directories_per_bank = (
        fixed_observed_directory_count
        + MAXIMUM_UNIQUE_RULES_PER_BANK
        * RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE
    )
    structural_directories_all_banks = (
        structural_directories_per_bank * MAXIMUM_BANK_COUNT
    )
    structural_directories_first_outer_sweep = (
        structural_directories_per_bank * FIRST_OUTER_SWEEP_BANK_COUNT
    )
    empirical_structural_inodes_per_bank = (
        fixed_observed_inode_count + maximum_rule_scoped_inodes_per_bank
    )
    empirical_structural_inodes_all_banks = (
        empirical_structural_inodes_per_bank * MAXIMUM_BANK_COUNT
    )
    empirical_structural_inodes_first_outer_sweep = (
        empirical_structural_inodes_per_bank
        * FIRST_OUTER_SWEEP_BANK_COUNT
    )

    def time_projection(
        search_seconds: float,
        fixed_per_bank_seconds: float,
    ) -> Mapping[str, float]:
        seconds_per_observed_rule = search_seconds / observed_unique_rules
        projected_search_seconds_per_maximum_bank = (
            seconds_per_observed_rule * MAXIMUM_UNIQUE_RULES_PER_BANK
        )
        selector_component_seconds_per_maximum_bank = (
            fixed_per_bank_seconds
            + projected_search_seconds_per_maximum_bank
        )
        first_outer_sweep_seconds = (
            factory_setup_seconds
            + selector_component_seconds_per_maximum_bank
            * FIRST_OUTER_SWEEP_BANK_COUNT
        )
        all_banks_seconds = (
            factory_setup_seconds
            + selector_component_seconds_per_maximum_bank
            * MAXIMUM_BANK_COUNT
        )
        return {
            "observed_search_commit_seconds": search_seconds,
            "seconds_per_observed_unique_rule": seconds_per_observed_rule,
            "fixed_setup_and_close_seconds_per_bank": fixed_per_bank_seconds,
            "projected_search_seconds_per_maximum_bank": (
                projected_search_seconds_per_maximum_bank
            ),
            "selector_component_seconds_per_maximum_bank": (
                selector_component_seconds_per_maximum_bank
            ),
            "selector_component_hours_per_maximum_bank": (
                selector_component_seconds_per_maximum_bank / 3600.0
            ),
            "first_outer_sweep_bank_count": FIRST_OUTER_SWEEP_BANK_COUNT,
            "first_outer_sweep_seconds": first_outer_sweep_seconds,
            "first_outer_sweep_hours": first_outer_sweep_seconds / 3600.0,
            "first_outer_sweep_days": first_outer_sweep_seconds / 86_400.0,
            "all_banks_seconds": all_banks_seconds,
            "all_banks_days": all_banks_seconds / 86_400.0,
        }

    cold_fixed_per_bank_seconds = (
        cold_adapter_setup_seconds
        + cold_cache_preparation_seconds
        + cold_close_seconds
    )
    warm_fixed_per_bank_seconds = (
        warm_adapter_setup_seconds
        + warm_cache_preparation_seconds
        + warm_close_seconds
    )
    cold_time_projection = time_projection(
        cold_search_commit_seconds,
        cold_fixed_per_bank_seconds,
    )
    warm_time_projection = time_projection(
        warm_search_commit_seconds,
        warm_fixed_per_bank_seconds,
    )
    cold_rule_timing = _timing_summary(cold_rule_evaluator_seconds)
    warm_rule_timing = _timing_summary(warm_rule_evaluator_seconds)
    lifecycle_stage_seconds = {
        "one_time_factory_and_bound_input_setup": factory_setup_seconds,
        "cold_prepared_case_construction_benchmark_only": (
            prepared_cases_seconds
        ),
        "cold_adapter_configuration_session_setup": (
            cold_adapter_setup_seconds
        ),
        "cold_operator_cache_preparation": cold_cache_preparation_seconds,
        "cold_search_and_commit": cold_search_commit_seconds,
        "cold_close": cold_close_seconds,
        "warm_prepared_case_reconstruction_benchmark_only": (
            warm_prepared_cases_seconds
        ),
        "warm_adapter_configuration_session_setup": (
            warm_adapter_setup_seconds
        ),
        "warm_operator_cache_import": warm_cache_preparation_seconds,
        "warm_search_and_commit": warm_search_commit_seconds,
        "warm_close": warm_close_seconds,
    }
    lifecycle_timing = _timing_summary(
        list(lifecycle_stage_seconds.values())
    )
    implementation_closure = implementation_closure_start
    schema_binding = {
        "path": BENCHMARK_SCHEMA_RELATIVE_PATH,
        "sha256": _sha256_file(benchmark_schema_path),
        "size_bytes": benchmark_schema_path.stat().st_size,
    }
    configuration_hash_fields = (
        "mapping_seed_sha256",
        "operator_bank_seed_sha256",
        "metric_policy_seed_sha256",
        "candidate_lut_runtime_manifest_sha256",
        "mapping_sha256",
        "operator_bank_sha256",
        "metric_policy_sha256",
        "compiler_inputs_sha256",
        "compiler_contract_sha256",
        "calibration_plan_sha256",
        "corpus_lock_bundle_sha256",
        "shared_bank_configuration_sha256",
        "raw_output_contract_sha256",
        "full_control_configuration_sha256",
    )
    configuration_hashes = {
        field: _require_benchmark_sha256(
            adapter.configuration.get(field),
            f"adapter configuration {field}",
        )
        for field in configuration_hash_fields
    }
    corpus_bundle_document = corpus_lock_bundle_document(bound)
    live_holdout_preopen_verification = dict(
        bound.live_holdout_preopen_verification
    )
    benchmark_input_closure = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_control_aggregate_native_benchmark_inputs",
        "candidate_id": adapter.candidate_id,
        "candidate_configuration_id": adapter.configuration[
            "configuration_id"
        ],
        "candidate_configuration_sha256": adapter.configuration_sha256,
        "serialized_candidate_vector": dict(vector),
        "serialized_candidate_vector_sha256": adapter.configuration[
            "serialized_candidate_vector_sha256"
        ],
        "configuration_hashes": configuration_hashes,
        "selector_contract": selector_contract,
        "selector_contract_sha256": aggregate_identity_context[
            "baseline_selector_contract_sha256"
        ],
        "baseline_ablation_contract_file_sha256": (
            aggregate_identity_context[
                "baseline_ablation_contract_file_sha256"
            ]
        ),
        "degradation_policy_file_sha256": aggregate_identity_context[
            "degradation_policy_file_sha256"
        ],
        "degradation_policy_sha256": degradation_policy["policy_sha256"],
        "metric_policy_file_sha256": aggregate_identity_context[
            "metric_policy_file_sha256"
        ],
        "metric_policy_sha256": aggregate_identity_context[
            "metric_policy_sha256"
        ],
        "development_sample_lock_file_sha256": (
            aggregate_identity_context["sample_lock_file_sha256"]
        ),
        "development_sample_manifest_sha256": bound.documents[
            "development_sample_lock"
        ]["manifest_sha256"],
        "corpus_lock_file_sha256": bound.record("corpus_lock")["sha256"],
        "corpus_manifest_sha256": aggregate_identity_context[
            "corpus_manifest_sha256"
        ],
        "corpus_lock_bundle_sha256": aggregate_identity_context[
            "corpus_lock_bundle_sha256"
        ],
        "corpus_lock_bundle_document": corpus_bundle_document,
        "live_holdout_preopen_verification": (
            live_holdout_preopen_verification
        ),
        "live_holdout_preopen_verification_sha256": canonical_sha256(
            live_holdout_preopen_verification
        ),
        "common_boundary_contract": aggregate_identity_context[
            "common_boundary_contract"
        ],
        "common_boundary_contract_sha256": aggregate_identity_context[
            "common_boundary_contract_sha256"
        ],
        "quality_implementation_closure": aggregate_identity_context[
            "quality_implementation_closure"
        ],
        "ordered_bound_input_files": [
            dict(record) for record in bound.records
        ],
    }
    benchmark_input_closure["input_closure_sha256"] = canonical_sha256(
        benchmark_input_closure
    )
    uname = platform.uname()
    evidence = {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_control_aggregate_cache_native_benchmark",
        "schema_binding": schema_binding,
        "run_identity": {
            "run_id": run_id,
            "started_utc": started_utc,
            "finished_utc": finished_utc,
            "repository_state": repository_state_start,
            "output_recovery_actions": output_recovery_actions,
            "output_publication_temporary_path": (
                output_publication_temporary_name
            ),
            "final_bundle_linkage": {
                "required_artifact_manifest_kind": (
                    "p06_runtime_feasibility_correction_artifact_manifest"
                ),
                "required_manifest_run_id": run_id,
                "required_binding": (
                    "the immutable correction-r2 artifact manifest must bind "
                    "this benchmark's final SHA-256 and size under the same "
                    "run_id"
                ),
                "finalizer": (
                    "validation/calibration_v2/tools/"
                    "finalize_p06_runtime_correction.py"
                ),
            },
        },
        "toolchain_identity": toolchain_identity,
        "execution_contract": route_execution_contract,
        "prepared_case_bindings": prepared_case_bindings,
        "prepared_case_bindings_sha256": prepared_case_bindings_sha256,
        "native_swift_execution": True,
        "production_corpus_accessed": False,
        "production_corpus_performance_claim": False,
        "holdout_accessed": False,
        "holdout_statement": (
            "No holdout media, holdout pixels, or holdout split capability "
            "was accessed; the bound-input stub read only preregistered "
            "no-pixel holdout control documents."
        ),
        "geometry": {
            "prepared_case_count": PREPARED_CASE_COUNT,
            "output_y_shape": list(OUTPUT_Y_SHAPE),
            "output_chroma_shape": list(OUTPUT_CHROMA_SHAPE),
            "direct_2x_input_y_shape": [96, 162],
            "direct_3over2_input_y_shape": [128, 216],
        },
        "configuration": {
            "shared_bank_configuration_sha256": bank,
            "native_executable_sha256": adapter.configuration["swift_cli"][
                "executable_sha256"
            ],
            "native_source_manifest_sha256": adapter.configuration["swift_cli"][
                "source_manifest_sha256"
            ],
        },
        "implementation_closure": implementation_closure,
        "benchmark_input_closure": benchmark_input_closure,
        "formula_derivation": formula_derivation,
        "runtime_environment": {
            "host": uname.node,
            "system": uname.system,
            "release": uname.release,
            "version": uname.version,
            "machine": uname.machine,
            "processor": uname.processor,
            "platform": platform.platform(),
            "python_version": platform.python_version(),
            "python_build": list(platform.python_build()),
            "python_compiler": platform.python_compiler(),
            "python_executable": sys.executable,
        },
        "reproduction": {
            "working_directory": "<repository-root>",
            "environment": {
                "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK": "1",
                "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT": (
                    "<repository-relative-output.json>"
                ),
            },
            "argv": [
                "python3",
                "-m",
                "pytest",
                "-q",
                (
                    "validation/calibration_v2/tests/"
                    "test_control_aggregate_native_benchmark.py"
                ),
            ],
            "shell_command": (
                "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK=1 "
                "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
                "<repository-relative-output.json> python3 -m pytest -q "
                "validation/calibration_v2/tests/"
                "test_control_aggregate_native_benchmark.py"
            ),
        },
        "cold": {
            "scope": "new native root and new evidence root",
            "adapter_configuration_session_setup_seconds": (
                cold_adapter_setup_seconds
            ),
            "operator_cache_preparation_seconds": (
                cold_cache_preparation_seconds
            ),
            "search_and_commit_seconds": cold_search_commit_seconds,
            "close_seconds": cold_close_seconds,
            "observed_selector_component_seconds": (
                cold_fixed_per_bank_seconds + cold_search_commit_seconds
            ),
            "metric_call_count": cold_metric_calls,
            "native_call_count": cold_native_calls,
            "control_call_count": cold_control_calls,
            "cache_preparation_record_count": len(cold_preparation_records),
            "cache_preparation_records": [
                dict(record) for record in cold_preparation_records
            ],
            "cache_preparation_records_sha256": canonical_sha256(
                cold_preparation_records
            ),
            "native_storage": cold_native_storage,
            "evidence_storage": cold_evidence_storage,
        },
        "warm": {
            "scope": (
                "new adapter/session, new evidence-store instance, and new "
                "operator-cache instance in the same Python process, reopening "
                "the persisted native and aggregate roots"
            ),
            "prepared_case_reconstruction_seconds_benchmark_only": (
                warm_prepared_cases_seconds
            ),
            "adapter_configuration_session_setup_seconds": (
                warm_adapter_setup_seconds
            ),
            "operator_cache_import_seconds": warm_cache_preparation_seconds,
            "search_and_commit_seconds": warm_search_commit_seconds,
            "close_seconds": warm_close_seconds,
            "observed_selector_component_seconds": (
                warm_fixed_per_bank_seconds + warm_search_commit_seconds
            ),
            "metric_call_count": metric_calls - cold_metric_calls,
            "native_recombination_call_count": warm_native_calls,
            "control_call_count": warm_control_calls,
            "cache_preparation_record_count": len(warm_preparation_records),
            "cache_preparation_records": [
                dict(record) for record in warm_preparation_records
            ],
            "cache_preparation_records_sha256": canonical_sha256(
                warm_preparation_records
            ),
            "native_storage": warm_native_storage,
            "evidence_storage": warm_evidence_storage,
        },
        "setup_timing": {
            "one_time_factory_and_bound_input_setup_seconds": (
                factory_setup_seconds
            ),
            "prepared_case_construction_seconds_benchmark_only": (
                prepared_cases_seconds
            ),
            "prepared_case_construction_is_production_p06_component": False,
        },
        "timing_telemetry": {
            "cold_unique_rule_evaluator": cold_rule_timing,
            "warm_restart_unique_rule_evaluator": warm_rule_timing,
            "lifecycle_stage_seconds": lifecycle_stage_seconds,
            "lifecycle_stage_summary": lifecycle_timing,
        },
        "observed": {
            "development_attempt_count": cold_selection["document"][
                "development_attempt_count"
            ],
            "unique_rule_count": observed_unique_rules,
            "origin_file_count": len(
                tuple(store._control_aggregate_origins.glob("*.json"))
            ),
            "rule_scoped_storage": cold_rule_scoped_storage,
            "total_storage": {
                "size_bytes": observed_total_size_bytes,
                "allocated_or_block_floor_bytes": (
                    observed_total_allocated_or_floor_bytes
                ),
                "file_count": observed_total_file_count,
                "directory_count": observed_total_directory_count,
                "inode_count": observed_total_inode_count,
            },
            "observed_non_rule_scoped_overhead": {
                "size_bytes": fixed_observed_size_bytes,
                "allocated_or_block_floor_bytes": (
                    fixed_observed_allocated_or_floor_bytes
                ),
                "file_count": fixed_observed_file_count,
                "directory_count": fixed_observed_directory_count,
                "inode_count": fixed_observed_inode_count,
            },
            "attempt_ledger_growth_model": {
                "observed_attempt_count": len(observed_attempt_records),
                "maximum_attempt_count": maximum_attempt_count,
                "observed_logical_bytes": (
                    observed_attempt_ledger_logical_bytes
                ),
                "maximum_record_logical_bytes": (
                    maximum_attempt_record_size_bytes
                ),
                "modeled_maximum_logical_bytes": (
                    maximum_attempt_ledger_logical_bytes
                ),
                "observed_allocated_or_block_floor_bytes": (
                    observed_attempt_ledger_allocated_or_floor_bytes
                ),
                "modeled_maximum_allocated_block_floor_bytes": (
                    maximum_attempt_ledger_allocated_block_floor_bytes
                ),
            },
            "count_dependent_shared_document_growth_models": (
                count_dependent_shared_document_growth_models
            ),
        },
        "maximum_formulas": {
            "unique_rules_per_bank": MAXIMUM_UNIQUE_RULES_PER_BANK,
            "native_calls_per_bank": maximum_native_calls_per_bank,
            "first_outer_sweep_bank_count": FIRST_OUTER_SWEEP_BANK_COUNT,
            "native_calls_first_outer_sweep": (
                maximum_native_calls_first_outer_sweep
            ),
            "bank_count": MAXIMUM_BANK_COUNT,
            "native_calls_all_banks": maximum_native_calls_all_banks,
            "rule_scoped_native_proof_files_per_rule": (
                RULE_SCOPED_NATIVE_PROOF_FILES_PER_RULE
            ),
            "rule_scoped_aggregate_origin_files_per_rule": (
                RULE_SCOPED_AGGREGATE_ORIGIN_FILES_PER_RULE
            ),
            "rule_scoped_aggregate_document_files_per_rule": (
                RULE_SCOPED_AGGREGATE_DOCUMENT_FILES_PER_RULE
            ),
            "rule_scoped_files_per_rule": RULE_SCOPED_FILES_PER_RULE,
            "rule_scoped_files_per_bank": (
                maximum_rule_scoped_files_per_bank
            ),
            "rule_scoped_files_all_banks": (
                maximum_rule_scoped_files_all_banks
            ),
            "rule_scoped_files_first_outer_sweep": (
                maximum_rule_scoped_files_first_outer_sweep
            ),
            "rule_scoped_native_proof_directories_per_rule": (
                RULE_SCOPED_NATIVE_PROOF_DIRECTORIES_PER_RULE
            ),
            "rule_scoped_inodes_per_rule": RULE_SCOPED_INODES_PER_RULE,
            "rule_scoped_inodes_per_bank": (
                maximum_rule_scoped_inodes_per_bank
            ),
            "rule_scoped_inodes_all_banks": (
                maximum_rule_scoped_inodes_all_banks
            ),
            "rule_scoped_inodes_first_outer_sweep": (
                maximum_rule_scoped_inodes_first_outer_sweep
            ),
            "native_calls_per_bank_formula": "1297 * 18 = 23346",
            "native_calls_first_outer_sweep_formula": (
                "23346 * 39 = 910494"
            ),
            "native_calls_all_banks_formula": "23346 * 305 = 7120530",
            "rule_scoped_files_per_rule_formula": "18 + 1 + 2 = 21",
            "rule_scoped_files_per_bank_formula": "1297 * 21 = 27237",
            "rule_scoped_files_first_outer_sweep_formula": (
                "27237 * 39 = 1062243"
            ),
            "rule_scoped_files_all_banks_formula": (
                "27237 * 305 = 8307285"
            ),
            "rule_scoped_inodes_per_rule_formula": "21 + 18 = 39",
            "rule_scoped_inodes_per_bank_formula": "1297 * 39 = 50583",
            "rule_scoped_inodes_first_outer_sweep_formula": (
                "50583 * 39 = 1972737"
            ),
            "rule_scoped_inodes_all_banks_formula": (
                "50583 * 305 = 15427815"
            ),
        },
        "empirical_storage_projection": {
            "method": (
                "observed non-rule overhead with the development attempt "
                "ledger replaced by its 1513-record structural model and all "
                "known count-dependent shared documents replaced by their "
                "1297-rule or 1513-attempt models, plus 1297 times the largest "
                "observed complete 21-file/39-inode rule footprint; allocated "
                "estimates use observed st_blocks with one filesystem-fragment "
                "floor for every file and directory"
            ),
            "projection_is_capacity_guarantee": False,
            "projection_limitations": (
                "empirical extrapolation; content variation outside the known "
                "rule-count and attempt-count dimensions, filesystem metadata "
                "behavior, contention, and future format changes are not bounded"
            ),
            "allocation_floor_bytes": allocation_floor_bytes,
            "maximum_complete_rule_size_bytes": (
                maximum_complete_rule_size_bytes
            ),
            "maximum_complete_rule_allocated_or_block_floor_bytes": (
                maximum_complete_rule_allocated_or_floor_bytes
            ),
            "logical_bytes_per_maximum_bank": (
                empirical_projected_logical_bytes_per_bank
            ),
            "first_outer_sweep_bank_count": FIRST_OUTER_SWEEP_BANK_COUNT,
            "logical_bytes_first_outer_sweep": (
                empirical_projected_logical_bytes_first_outer_sweep
            ),
            "logical_bytes_all_banks": (
                empirical_projected_logical_bytes_all_banks
            ),
            "allocated_bytes_per_maximum_bank": (
                empirical_projected_allocated_bytes_per_bank
            ),
            "allocated_bytes_first_outer_sweep": (
                empirical_projected_allocated_bytes_first_outer_sweep
            ),
            "allocated_bytes_all_banks": (
                empirical_projected_allocated_bytes_all_banks
            ),
            "files_per_maximum_bank": structural_files_per_bank,
            "files_first_outer_sweep": structural_files_first_outer_sweep,
            "files_all_banks": structural_files_all_banks,
            "directories_per_maximum_bank": (
                structural_directories_per_bank
            ),
            "directories_first_outer_sweep": (
                structural_directories_first_outer_sweep
            ),
            "directories_all_banks": structural_directories_all_banks,
            "inodes_per_maximum_bank": (
                empirical_structural_inodes_per_bank
            ),
            "inodes_first_outer_sweep": (
                empirical_structural_inodes_first_outer_sweep
            ),
            "inodes_all_banks": (
                empirical_structural_inodes_all_banks
            ),
        },
        "empirical_linear_time_projection": {
            "method": (
                "measured search-and-commit seconds divided by observed "
                "unique rules and scaled to 1297, plus observed adapter, "
                "operator-cache preparation/import, and close once per bank; "
                "the one-time factory setup is added once"
            ),
            "projection_is_runtime_guarantee": False,
            "projection_scope": (
                "non-ASH selector component only; not total P06 calibration"
            ),
            "cold": cold_time_projection,
            "warm": warm_time_projection,
        },
        "capacity_headroom": {
            "free_disk_bytes_before": free_disk_before,
            "free_disk_bytes_after": free_disk_after,
            "available_inodes_before": available_inodes_before,
            "available_inodes_after": available_inodes_after,
            "empirical_all_banks_logical_byte_headroom_before": (
                free_disk_before
                - empirical_projected_logical_bytes_all_banks
            ),
            "empirical_first_outer_sweep_logical_byte_headroom_before": (
                free_disk_before
                - empirical_projected_logical_bytes_first_outer_sweep
            ),
            "empirical_all_banks_allocated_byte_headroom_before": (
                free_disk_before
                - empirical_projected_allocated_bytes_all_banks
            ),
            "empirical_first_outer_sweep_allocated_byte_headroom_before": (
                free_disk_before
                - empirical_projected_allocated_bytes_first_outer_sweep
            ),
            "empirical_all_banks_inode_headroom_before": (
                available_inodes_before
                - empirical_structural_inodes_all_banks
            ),
            "empirical_first_outer_sweep_inode_headroom_before": (
                available_inodes_before
                - empirical_structural_inodes_first_outer_sweep
            ),
        },
    }
    evidence["evidence_sha256"] = canonical_sha256(evidence)

    warm_ledger_sha256 = warm_selection["document"][
        "development_attempt_ledger_sha256"
    ]
    assert warm_selection == cold_selection
    assert warm_ledger_sha256 == cold_ledger_sha256
    assert canonical_json_bytes(warm_store.reopen(warm_ledger_sha256)) == (
        cold_ledger_bytes
    )
    assert implementation_closure_end == implementation_closure_start
    assert repository_state_end == repository_state_start
    assert started_utc.endswith("Z") and finished_utc.endswith("Z")
    parsed_started_utc = datetime.fromisoformat(
        started_utc.removesuffix("Z") + "+00:00"
    )
    parsed_finished_utc = datetime.fromisoformat(
        finished_utc.removesuffix("Z") + "+00:00"
    )
    assert parsed_started_utc <= parsed_finished_utc
    assert warm_aggregate_identity_context == aggregate_identity_context
    assert warm_cache.manifest_sha256 == cache.manifest_sha256
    assert len(prepared_case_bindings) == PREPARED_CASE_COUNT
    assert prepared_case_bindings_sha256 == canonical_sha256(
        prepared_case_bindings
    )
    unhashed_execution_contract = dict(route_execution_contract)
    declared_execution_contract_sha256 = unhashed_execution_contract.pop(
        "contract_sha256"
    )
    assert declared_execution_contract_sha256 == canonical_sha256(
        unhashed_execution_contract
    )
    assert route_execution_contract["metal_execution"] is False
    assert len(cold_preparation_records) == PREPARED_CASE_COUNT
    assert len(warm_preparation_records) == PREPARED_CASE_COUNT
    assert cache.preparation_evidence_sha256 == canonical_sha256(
        cold_preparation_records
    )
    assert warm_cache.preparation_evidence_sha256 == canonical_sha256(
        warm_preparation_records
    )
    assert (
        cache.preparation_evidence_sha256
        != warm_cache.preparation_evidence_sha256
    )
    assert evidence["cold"]["cache_preparation_records"] == list(
        cold_preparation_records
    )
    assert evidence["warm"]["cache_preparation_records"] == list(
        warm_preparation_records
    )
    assert all(
        record.get("cache_reused") is False
        and record.get("preparation_analysis_grid_invocation_count") == 1
        and record.get("preparation_spatial_operator_evaluation_count") == 16
        for record in cold_preparation_records
    )
    assert all(
        record.get("cache_reused") is True
        and record.get("preparation_analysis_grid_invocation_count") == 0
        and record.get("preparation_spatial_operator_evaluation_count") == 0
        for record in warm_preparation_records
    )
    assert cold_metric_calls == cold_native_calls
    assert metric_calls == cold_metric_calls
    assert len(cold_rule_evaluator_seconds) == observed_unique_rules
    assert len(warm_rule_evaluator_seconds) == observed_unique_rules
    assert cold_rule_timing == _timing_summary(cold_rule_evaluator_seconds)
    assert warm_rule_timing == _timing_summary(warm_rule_evaluator_seconds)
    assert lifecycle_timing == _timing_summary(
        list(lifecycle_stage_seconds.values())
    )
    assert cold_native_calls % PREPARED_CASE_COUNT == 0
    assert warm_native_calls == cold_native_calls
    assert cold_control_calls == cold_native_calls
    assert warm_control_calls == warm_native_calls
    assert observed_unique_rules <= MAXIMUM_UNIQUE_RULES_PER_BANK
    assert observed_unique_rules > 0
    assert cold_rule_scoped_storage["rule_count"] == observed_unique_rules
    assert cold_rule_scoped_storage["file_count"] == (
        observed_unique_rules * RULE_SCOPED_FILES_PER_RULE
    )
    assert cold_rule_scoped_storage["inode_count"] == (
        observed_unique_rules * RULE_SCOPED_INODES_PER_RULE
    )
    assert fixed_observed_size_bytes >= 0
    assert fixed_observed_file_count >= 0
    assert fixed_observed_directory_count >= 0
    assert fixed_observed_inode_count >= 0
    assert fixed_observed_allocated_or_floor_bytes >= 0
    native_growth_model = count_dependent_shared_document_growth_models[
        "native_durability_commit"
    ]
    evidence_dependency_growth_model = (
        count_dependent_shared_document_growth_models[
            "evidence_dependency_commit"
        ]
    )
    selector_selection_growth_model = (
        count_dependent_shared_document_growth_models["selector_selection"]
    )
    assert native_growth_model["observed_document_sha256"] == (
        native_dependency_binding["sha256"]
    )
    assert evidence_dependency_growth_model[
        "observed_document_sha256"
    ] == evidence_dependency_binding["sha256"]
    assert selector_selection_growth_model[
        "observed_document_sha256"
    ] == selection_sha256
    assert evidence_dependency_growth_model["observed_document_count"] == (
        1 + 2 * observed_unique_rules
    )
    assert evidence_dependency_growth_model["maximum_document_count"] == (
        1 + 2 * MAXIMUM_UNIQUE_RULES_PER_BANK
    )
    assert selector_selection_growth_model["observed_attempt_count"] == len(
        observed_attempt_records
    )
    assert selector_selection_growth_model["maximum_attempt_count"] == (
        maximum_attempt_count
    )
    assert projected_non_rule_logical_bytes == (
        fixed_observed_size_bytes
        - observed_attempt_ledger_logical_bytes
        + maximum_attempt_ledger_logical_bytes
        - observed_count_dependent_shared_logical_bytes
        + modeled_count_dependent_shared_logical_bytes
    )
    assert projected_non_rule_allocated_or_floor_bytes == (
        fixed_observed_allocated_or_floor_bytes
        - observed_attempt_ledger_allocated_or_floor_bytes
        + maximum_attempt_ledger_allocated_block_floor_bytes
        - observed_count_dependent_shared_allocated_bytes
        + modeled_count_dependent_shared_allocated_bytes
    )
    assert len(observed_attempt_records) == cold_selection["document"][
        "development_attempt_count"
    ]
    assert len(observed_attempt_records) <= maximum_attempt_count
    assert maximum_attempt_ledger_logical_bytes >= (
        observed_attempt_ledger_logical_bytes
    )
    assert maximum_native_calls_per_bank == 23_346
    assert maximum_native_calls_first_outer_sweep == 910_494
    assert maximum_native_calls_all_banks == 7_120_530
    assert maximum_rule_scoped_files_per_bank == 27_237
    assert maximum_rule_scoped_files_first_outer_sweep == 1_062_243
    assert maximum_rule_scoped_files_all_banks == 8_307_285
    assert maximum_rule_scoped_inodes_per_bank == 50_583
    assert maximum_rule_scoped_inodes_first_outer_sweep == 1_972_737
    assert maximum_rule_scoped_inodes_all_banks == 15_427_815
    assert warm_native_storage == cold_native_storage
    assert warm_evidence_storage == cold_evidence_storage
    unhashed_inputs = dict(benchmark_input_closure)
    declared_input_sha256 = unhashed_inputs.pop("input_closure_sha256")
    assert declared_input_sha256 == canonical_sha256(unhashed_inputs)
    assert benchmark_input_closure["selector_contract_sha256"] == (
        canonical_sha256(selector_contract)
    )
    assert configuration_hashes["raw_output_contract_sha256"] == (
        aggregate_identity_context["common_boundary_contract_sha256"]
    )
    assert configuration_hashes["corpus_lock_bundle_sha256"] == (
        aggregate_identity_context["corpus_lock_bundle_sha256"]
    )
    assert configuration_hashes["corpus_lock_bundle_sha256"] == (
        canonical_sha256(corpus_bundle_document)
    )
    assert benchmark_input_closure[
        "live_holdout_preopen_verification_sha256"
    ] == canonical_sha256(live_holdout_preopen_verification)
    unhashed_derivation = dict(formula_derivation)
    declared_derivation_sha256 = unhashed_derivation.pop(
        "derivation_sha256"
    )
    assert declared_derivation_sha256 == canonical_sha256(
        unhashed_derivation
    )
    unhashed_evidence = dict(evidence)
    declared_evidence_sha256 = unhashed_evidence.pop("evidence_sha256")
    assert declared_evidence_sha256 == canonical_sha256(unhashed_evidence)
    assert _implementation_closure() == implementation_closure_start
    _verify_ordered_file_records_unchanged(ordered_bound_input_files)
    assert _repository_state_binding() == repository_state_start
    validate_schema(evidence, benchmark_schema_path)
    _validate_cache_preparation_evidence(evidence)
    assert _implementation_closure() == implementation_closure_start
    _verify_ordered_file_records_unchanged(ordered_bound_input_files)
    assert _repository_state_binding() == repository_state_start
    evidence_payload = canonical_json_bytes(evidence) + b"\n"
    _publish_new_durable(
        output,
        evidence_payload,
        expected_parent_identity=output_parent_identity,
        recovery_actions=output_recovery_actions,
        publication_temporary_name=(
            output_publication_temporary_name
        ),
    )
