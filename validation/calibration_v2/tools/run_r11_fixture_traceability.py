#!/usr/bin/env python3
"""Run the exact-source deterministic R11 traceability fixture."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from typing import Any, Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import phase_evidence as phase_evidence_module  # noqa: E402
from Scripts import r11_contracts as r11_contracts_module  # noqa: E402
from Scripts.phase_evidence import (  # noqa: E402
    decode_json,
    validate_json_schema_instance,
)
from Scripts.r11_contracts import (  # noqa: E402
    R11ContractError,
    parse_fixture_catalog_r11,
)
from validation.calibration_v2 import r11_traceability as r11_core_module  # noqa: E402
from validation.calibration_v2.r11_traceability import (  # noqa: E402
    R11BoundaryState,
    R11ClaimDisposition,
    R11ClaimToken,
    R11EvidenceIdentity,
    R11ExecutionReceipt,
    R11Observation,
    R11ObservationAggregate,
    R11SourceIdentity,
    R11TraceabilityError,
    R11_IDENTITY_COMPONENT_ORDER,
    R11_OBSERVATION_STATE_ORDER,
    aggregate_observations_r11,
    canonical_json_file_bytes_r11,
    decide_claim_r11,
    reopen_execution_receipt_r11,
)


CORE_PATH = "validation/calibration_v2/r11_traceability.py"
CONTRACTS_PATH = "Scripts/r11_contracts.py"
PHASE_EVIDENCE_PATH = "Scripts/phase_evidence.py"
FIXTURE_CATALOG_PATH = (
    "docs/roadmaps/evidence/r11/records/fixtures/fixture-catalog.json"
)
FIXTURE_SCHEMA_PATH = (
    "docs/roadmaps/evidence/schema/r11-fixture-catalog-v1.json"
)
RUN_RECEIPT_SCHEMA_PATH = (
    "docs/roadmaps/evidence/schema/r11-traceability-run-receipt-v1.json"
)
RUNNER_PATH = (
    "validation/calibration_v2/tools/run_r11_fixture_traceability.py"
)
PREREGISTRATION_PATH = (
    "docs/roadmaps/evidence/r11/records/preregistration.json"
)

SOURCE_FILE_ROLES = (
    ("traceability_core", CORE_PATH),
    ("catalog_contract_parser", CONTRACTS_PATH),
    ("schema_validation_runtime", PHASE_EVIDENCE_PATH),
    ("fixture_catalog", FIXTURE_CATALOG_PATH),
    ("fixture_catalog_schema", FIXTURE_SCHEMA_PATH),
    ("traceability_run_receipt_schema", RUN_RECEIPT_SCHEMA_PATH),
    ("traceability_fixture_runner", RUNNER_PATH),
    ("traceability_preregistration", PREREGISTRATION_PATH),
)

PREDECESSOR_BINDING = {
    "phase_id": "R10",
    "phase_result": "passed",
    "acceptance": "accepted",
    "acceptance_scope": "declared_software_function_only",
    "accepted_source": {
        "commit": "3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b",
        "tree": "37951da694ab4fbca6f8c663bb2883e5084b861c",
    },
    "functional_phase_acceptance": {
        "path": (
            "docs/roadmaps/evidence/r10/records/"
            "functional-phase-acceptance.json"
        ),
        "size_bytes": 3631,
        "sha256": (
            "f7f75fd69691dcca632f2ae8c220cfb34662bb1ecff6769c84602f3a21368785"
        ),
    },
}

COMPARISON_POLICY = {
    "comparison_method": "absent_not_required",
    "comparison_success_case": "absent",
    "acceptance_dependency": "none",
}

LIMITATIONS = {
    "comparison_methods_used": False,
    "comparison_requirement": "absent_not_required",
    "hardware_observation": "not_observed",
    "simulator_observation": "not_observed",
    "operator_observation": "not_observed",
    "product_qualification": "blocked",
    "production_auto_mode": "blocked",
    "market_position": "blocked",
    "market_leading_claim": "blocked",
}

_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
_GIT_OBJECT_PATTERN = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
_RECEIPT_NAME = "traceability-run-receipt.json"
_TEMPORARY_NAME = ".traceability-run-receipt.pending"
_MAX_SOURCE_FILE_BYTES = 8 * 1024 * 1024
_MAX_RECEIPT_BYTES = 16 * 1024 * 1024
_MAX_CONTROL_BYTES = 128


class R11FixtureTraceabilityError(RuntimeError):
    """The exact-source R11 fixture execution or publication is invalid."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _git_bytes(
    repository_root: Path,
    arguments: Sequence[str],
    *,
    operation: str,
    maximum_output_bytes: int,
    exact_output_bytes: int | None = None,
) -> bytes:
    if (
        type(maximum_output_bytes) is not int
        or maximum_output_bytes < 1
        or maximum_output_bytes > _MAX_SOURCE_FILE_BYTES
        or (
            exact_output_bytes is not None
            and (
                type(exact_output_bytes) is not int
                or exact_output_bytes < 0
                or exact_output_bytes > maximum_output_bytes
            )
        )
    ):
        raise R11FixtureTraceabilityError(
            f"{operation}_git_output_bound_is_invalid"
        )
    executable = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [
                executable,
                "-C",
                os.fspath(repository_root),
                "--no-pager",
                *arguments,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if process.stdout is None:
            raise R11FixtureTraceabilityError(
                f"{operation}_git_stdout_is_unavailable"
            )
        payload = process.stdout.read(maximum_output_bytes + 1)
    except OSError as error:
        if process is not None:
            process.kill()
            if process.stdout is not None:
                process.stdout.close()
            process.wait()
        raise R11FixtureTraceabilityError(
            f"{operation}_git_execution_failed"
        ) from error
    if len(payload) > maximum_output_bytes:
        process.kill()
        process.stdout.close()
        process.wait()
        raise R11FixtureTraceabilityError(
            f"{operation}_git_output_exceeds_bound"
        )
    process.stdout.close()
    returncode = process.wait()
    if returncode != 0:
        raise R11FixtureTraceabilityError(
            f"{operation}_git_command_failed"
        )
    if exact_output_bytes is not None and len(payload) != exact_output_bytes:
        raise R11FixtureTraceabilityError(
            f"{operation}_git_output_size_differs"
        )
    return payload


def _git_object_id(
    repository_root: Path,
    expression: str,
    *,
    operation: str,
) -> str:
    payload = _git_bytes(
        repository_root,
        ("rev-parse", "--verify", "--end-of-options", expression),
        operation=operation,
        maximum_output_bytes=65,
    )
    try:
        value = payload.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise R11FixtureTraceabilityError(
            f"{operation}_git_object_is_not_ascii"
        ) from error
    if (
        _GIT_OBJECT_PATTERN.fullmatch(value) is None
        or payload != f"{value}\n".encode("ascii")
    ):
        raise R11FixtureTraceabilityError(
            f"{operation}_git_object_is_invalid"
        )
    return value


def _git_file_bytes(
    repository_root: Path,
    source_commit: str,
    repository_path: str,
) -> tuple[str, bytes]:
    expression = f"{source_commit}:{repository_path}"
    blob = _git_object_id(
        repository_root,
        expression,
        operation="source_file_blob",
    )
    object_type = _git_bytes(
        repository_root,
        ("cat-file", "-t", blob),
        operation="source_file_type",
        maximum_output_bytes=_MAX_CONTROL_BYTES,
    )
    if object_type != b"blob\n":
        raise R11FixtureTraceabilityError("source_file_is_not_a_blob")
    size_payload = _git_bytes(
        repository_root,
        ("cat-file", "-s", blob),
        operation="source_file_size",
        maximum_output_bytes=_MAX_CONTROL_BYTES,
    )
    if re.fullmatch(rb"[1-9][0-9]*\n", size_payload) is None:
        raise R11FixtureTraceabilityError("source_file_size_is_invalid")
    declared_size = int(size_payload[:-1])
    if declared_size > _MAX_SOURCE_FILE_BYTES:
        raise R11FixtureTraceabilityError(
            "source_file_size_exceeds_bound"
        )
    payload = _git_bytes(
        repository_root,
        (
            "show",
            "--no-ext-diff",
            "--no-textconv",
            "--format=",
            expression,
        ),
        operation="source_file_show",
        maximum_output_bytes=declared_size,
        exact_output_bytes=declared_size,
    )
    if len(payload) != declared_size:
        raise R11FixtureTraceabilityError(
            "source_file_size_differs_from_preflight"
        )
    return blob, payload


def _source_snapshot(
    repository_root: Path,
    source_commit: str,
) -> tuple[Path, str, dict[str, tuple[str, bytes]]]:
    if (
        type(source_commit) is not str
        or _COMMIT_PATTERN.fullmatch(source_commit) is None
        or source_commit == "0" * 40
    ):
        raise R11FixtureTraceabilityError(
            "source_commit_must_be_one_nonzero_lowercase_40_character_oid"
        )
    try:
        root = repository_root.resolve(strict=True)
    except OSError as error:
        raise R11FixtureTraceabilityError(
            "repository_root_is_unavailable"
        ) from error
    if not root.is_dir():
        raise R11FixtureTraceabilityError(
            "repository_root_is_not_a_directory"
        )
    resolved_commit = _git_object_id(
        root,
        f"{source_commit}^{{commit}}",
        operation="source_commit",
    )
    if resolved_commit != source_commit:
        raise R11FixtureTraceabilityError("source_commit_is_not_exact")
    source_tree = _git_object_id(
        root,
        f"{source_commit}^{{tree}}",
        operation="source_tree",
    )
    files: dict[str, tuple[str, bytes]] = {}
    for _role, path in SOURCE_FILE_ROLES:
        if path in files:
            raise R11FixtureTraceabilityError(
                "source_file_role_paths_are_not_unique"
            )
        files[path] = _git_file_bytes(root, source_commit, path)
    return root, source_tree, files


def _runtime_file_bytes(path: Path, expected_size: int) -> bytes:
    descriptor = -1
    try:
        before = os.lstat(path)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_size != expected_size
            or expected_size < 1
            or expected_size > _MAX_SOURCE_FILE_BYTES
        ):
            raise R11FixtureTraceabilityError(
                "runtime_source_identity_or_size_differs"
            )
        descriptor = os.open(
            path,
            os.O_RDONLY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        after_open = os.lstat(path)
        stable = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        if (
            (
                opened.st_dev,
                opened.st_ino,
                opened.st_mode,
                opened.st_nlink,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
            )
            != stable
            or (
                after_open.st_dev,
                after_open.st_ino,
                after_open.st_mode,
                after_open.st_nlink,
                after_open.st_size,
                after_open.st_mtime_ns,
                after_open.st_ctime_ns,
            )
            != stable
        ):
            raise R11FixtureTraceabilityError(
                "runtime_source_identity_or_size_differs"
            )
        chunks: list[bytes] = []
        remaining = expected_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise R11FixtureTraceabilityError(
                    "runtime_source_is_truncated"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        trailing = os.read(descriptor, 1)
        after_read = os.fstat(descriptor)
        after_path = os.lstat(path)
        if (
            trailing
            or (
                after_read.st_dev,
                after_read.st_ino,
                after_read.st_mode,
                after_read.st_nlink,
                after_read.st_size,
                after_read.st_mtime_ns,
                after_read.st_ctime_ns,
            )
            != stable
            or (
                after_path.st_dev,
                after_path.st_ino,
                after_path.st_mode,
                after_path.st_nlink,
                after_path.st_size,
                after_path.st_mtime_ns,
                after_path.st_ctime_ns,
            )
            != stable
        ):
            raise R11FixtureTraceabilityError(
                "runtime_source_identity_or_size_differs"
            )
        return b"".join(chunks)
    except R11FixtureTraceabilityError:
        raise
    except OSError as error:
        raise R11FixtureTraceabilityError(
            "runtime_source_bytes_are_unavailable"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _require_runtime_source_bytes(
    source_files: Mapping[str, tuple[str, bytes]],
) -> None:
    runtime_paths = (
        (
            CORE_PATH,
            Path(os.path.abspath(r11_core_module.__file__)),
        ),
        (
            CONTRACTS_PATH,
            Path(os.path.abspath(r11_contracts_module.__file__)),
        ),
        (
            PHASE_EVIDENCE_PATH,
            Path(os.path.abspath(phase_evidence_module.__file__)),
        ),
        (
            FIXTURE_SCHEMA_PATH,
            REPOSITORY_ROOT / FIXTURE_SCHEMA_PATH,
        ),
        (
            RUNNER_PATH,
            Path(os.path.abspath(__file__)),
        ),
    )
    for repository_path, runtime_path in runtime_paths:
        expected = source_files[repository_path][1]
        try:
            runtime = _runtime_file_bytes(runtime_path, len(expected))
        except R11FixtureTraceabilityError as error:
            raise R11FixtureTraceabilityError(
                "runtime_source_differs_from_source_commit:"
                f"{repository_path}:{error}"
            ) from error
        if runtime != expected:
            raise R11FixtureTraceabilityError(
                f"runtime_source_differs_from_source_commit:{repository_path}"
            )


def _decode_json_object(
    payload: bytes,
    *,
    label: str,
) -> dict[str, Any]:
    if (
        type(payload) is not bytes
        or not payload
        or len(payload) > _MAX_SOURCE_FILE_BYTES
        or not payload.endswith(b"\n")
        or b"\x00" in payload
        or b"\r" in payload
    ):
        raise R11FixtureTraceabilityError(
            f"{label}_bytes_are_outside_boundary"
        )
    try:
        value = decode_json(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise R11FixtureTraceabilityError(
            f"{label}_json_is_invalid"
        ) from error
    if type(value) is not dict:
        raise R11FixtureTraceabilityError(
            f"{label}_must_be_one_json_object"
        )
    return value


def _exact_content_binding(
    *,
    identifier: str,
    path: str,
    payload: bytes,
) -> dict[str, object]:
    return {
        "id": identifier,
        "path": path,
        "size_bytes": len(payload),
        "sha256": _sha256(payload),
    }


def _one_declared_binding(
    value: object,
    *,
    identifier: str,
    label: str,
) -> dict[str, Any]:
    if type(value) is not list:
        raise R11FixtureTraceabilityError(
            f"preregistration_{label}_bindings_have_wrong_type"
        )
    matches = [
        item
        for item in value
        if type(item) is dict and item.get("id") == identifier
    ]
    if len(matches) != 1:
        raise R11FixtureTraceabilityError(
            f"preregistration_{label}_binding_is_not_unique"
        )
    return matches[0]


def _validate_preregistration_trust_anchor(
    source_files: Mapping[str, tuple[str, bytes]],
) -> dict[str, Any]:
    try:
        preregistration_payload = source_files[PREREGISTRATION_PATH][1]
        run_schema_payload = source_files[RUN_RECEIPT_SCHEMA_PATH][1]
        fixture_payload = source_files[FIXTURE_CATALOG_PATH][1]
        core_payload = source_files[CORE_PATH][1]
    except (KeyError, TypeError, IndexError) as error:
        raise R11FixtureTraceabilityError(
            "preregistration_trust_anchor_source_is_incomplete"
        ) from error

    frozen_size = getattr(
        r11_contracts_module,
        "PREREGISTRATION_SIZE_BYTES",
        None,
    )
    frozen_sha256 = getattr(
        r11_contracts_module,
        "PREREGISTRATION_RAW_SHA256",
        None,
    )
    if (
        type(frozen_size) is not int
        or frozen_size < 1
        or frozen_size > _MAX_SOURCE_FILE_BYTES
        or type(frozen_sha256) is not str
        or re.fullmatch(r"(?!0{64}$)[0-9a-f]{64}", frozen_sha256) is None
    ):
        raise R11FixtureTraceabilityError(
            "preregistration_frozen_identity_is_invalid"
        )
    if (
        len(preregistration_payload) != frozen_size
        or _sha256(preregistration_payload) != frozen_sha256
    ):
        raise R11FixtureTraceabilityError(
            "exact_source_preregistration_identity_differs"
        )

    schema_identities = getattr(
        r11_contracts_module,
        "SCHEMA_IDENTITIES",
        None,
    )
    preregistration_schema_path = getattr(
        r11_contracts_module,
        "PREREGISTRATION_SCHEMA_PATH",
        None,
    )
    schema_identity = (
        schema_identities.get("preregistration")
        if type(schema_identities) is dict
        else None
    )
    if (
        not isinstance(preregistration_schema_path, Path)
        or preregistration_schema_path.is_absolute()
        or preregistration_schema_path.as_posix()
        != "docs/roadmaps/evidence/schema/r11-preregistration-v1.json"
        or type(schema_identity) is not tuple
        or len(schema_identity) != 2
        or type(schema_identity[0]) is not int
        or schema_identity[0] < 1
        or schema_identity[0] > _MAX_SOURCE_FILE_BYTES
        or type(schema_identity[1]) is not str
        or re.fullmatch(
            r"(?!0{64}$)[0-9a-f]{64}",
            schema_identity[1],
        )
        is None
    ):
        raise R11FixtureTraceabilityError(
            "preregistration_schema_frozen_identity_is_invalid"
        )
    schema_payload = _runtime_file_bytes(
        REPOSITORY_ROOT / preregistration_schema_path,
        schema_identity[0],
    )
    if _sha256(schema_payload) != schema_identity[1]:
        raise R11FixtureTraceabilityError(
            "preregistration_schema_identity_differs"
        )
    schema = _decode_json_object(
        schema_payload,
        label="preregistration_schema",
    )
    preregistration = _decode_json_object(
        preregistration_payload,
        label="exact_source_preregistration",
    )
    errors = validate_json_schema_instance(schema, preregistration)
    if errors:
        raise R11FixtureTraceabilityError(
            "exact_source_preregistration_schema_rejected:"
            + ";".join(errors)
        )

    schema_bindings = preregistration.get("schema_bindings")
    preregistration_schema_binding = _one_declared_binding(
        schema_bindings,
        identifier="preregistration",
        label="schema",
    )
    if preregistration_schema_binding != _exact_content_binding(
        identifier="preregistration",
        path=preregistration_schema_path.as_posix(),
        payload=schema_payload,
    ):
        raise R11FixtureTraceabilityError(
            "preregistration_schema_binding_differs"
        )
    run_schema_binding = _one_declared_binding(
        schema_bindings,
        identifier="traceability_run_receipt",
        label="schema",
    )
    if run_schema_binding != _exact_content_binding(
        identifier="traceability_run_receipt",
        path=RUN_RECEIPT_SCHEMA_PATH,
        payload=run_schema_payload,
    ):
        raise R11FixtureTraceabilityError(
            "preregistration_traceability_run_receipt_binding_differs"
        )

    fixture_binding = preregistration.get("fixture_catalog_binding")
    expected_fixture_binding = {
        "path": FIXTURE_CATALOG_PATH,
        "size_bytes": len(fixture_payload),
        "sha256": _sha256(fixture_payload),
    }
    if fixture_binding != expected_fixture_binding:
        raise R11FixtureTraceabilityError(
            "preregistration_fixture_catalog_binding_differs"
        )

    core_binding = _one_declared_binding(
        preregistration.get("implementation_contract_bindings"),
        identifier="traceability_core",
        label="implementation",
    )
    if core_binding != _exact_content_binding(
        identifier="traceability_core",
        path=CORE_PATH,
        payload=core_payload,
    ):
        raise R11FixtureTraceabilityError(
            "preregistration_traceability_core_binding_differs"
        )
    return preregistration


def _file_binding(
    *,
    role: str,
    path: str,
    blob: str,
    payload: bytes,
) -> dict[str, object]:
    return {
        "role": role,
        "path": path,
        "git_blob": blob,
        "size_bytes": len(payload),
        "sha256": _sha256(payload),
    }


def _validate_output_root(
    requested: Path,
    *,
    repository_root: Path,
) -> Path:
    if not isinstance(requested, Path):
        raise R11FixtureTraceabilityError("output_root_has_wrong_type")
    raw = os.fspath(requested)
    if (
        not requested.is_absolute()
        or "\x00" in raw
        or raw != os.path.normpath(raw)
        or requested == Path(os.sep)
    ):
        raise R11FixtureTraceabilityError(
            "output_root_must_be_absolute_lexically_normalized_and_nonroot"
        )
    try:
        parent = requested.parent.resolve(strict=True)
        repository = repository_root.resolve(strict=True)
    except OSError as error:
        raise R11FixtureTraceabilityError(
            "output_root_parent_or_repository_is_unavailable"
        ) from error
    if not parent.is_dir():
        raise R11FixtureTraceabilityError(
            "output_root_parent_is_not_a_directory"
        )
    canonical = parent / requested.name
    if requested != canonical:
        raise R11FixtureTraceabilityError(
            "output_root_contains_a_symlinked_parent"
        )
    if canonical == repository or repository in canonical.parents:
        raise R11FixtureTraceabilityError(
            "output_root_must_remain_outside_source_repository"
        )
    try:
        os.lstat(canonical)
    except FileNotFoundError:
        return canonical
    except OSError as error:
        raise R11FixtureTraceabilityError(
            "output_root_cannot_be_inspected"
        ) from error
    raise R11FixtureTraceabilityError("output_root_must_be_absent")


def _create_output_root(output_root: Path) -> tuple[int, int]:
    parent_descriptor = -1
    try:
        before = os.lstat(output_root.parent)
        parent_descriptor = os.open(
            output_root.parent,
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(parent_descriptor)
        after = os.lstat(output_root.parent)
        if (
            not stat.S_ISDIR(before.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or stat.S_ISLNK(after.st_mode)
            or (before.st_dev, before.st_ino)
            != (opened.st_dev, opened.st_ino)
            or (opened.st_dev, opened.st_ino)
            != (after.st_dev, after.st_ino)
        ):
            raise R11FixtureTraceabilityError(
                "output_root_parent_identity_changed"
            )
        os.mkdir(output_root.name, 0o700, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
        created = os.stat(
            output_root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except FileExistsError as error:
        raise R11FixtureTraceabilityError(
            "output_root_conflict_during_creation"
        ) from error
    except OSError as error:
        raise R11FixtureTraceabilityError(
            "output_root_cannot_be_created"
        ) from error
    finally:
        if parent_descriptor >= 0:
            os.close(parent_descriptor)
    if (
        not stat.S_ISDIR(created.st_mode)
        or stat.S_ISLNK(created.st_mode)
        or stat.S_IMODE(created.st_mode) != 0o700
    ):
        raise R11FixtureTraceabilityError(
            "output_root_creation_identity_is_invalid"
        )
    return created.st_dev, created.st_ino


def _actual_identity(
    fixture_identity: R11EvidenceIdentity,
    *,
    source_commit: str,
    source_tree: str,
) -> R11EvidenceIdentity:
    if type(fixture_identity) is not R11EvidenceIdentity:
        raise R11FixtureTraceabilityError(
            "fixture_identity_has_wrong_type"
        )
    return R11EvidenceIdentity(
        source=R11SourceIdentity(
            commit=source_commit,
            tree=source_tree,
        ),
        software=fixture_identity.software,
        subject=fixture_identity.subject,
        input=fixture_identity.input,
        preprocessing=fixture_identity.preprocessing,
        toolchain=fixture_identity.toolchain,
        execution=fixture_identity.execution,
    )


def _rebind_observations(
    fixture_observations: tuple[R11Observation, ...],
    *,
    identity: R11EvidenceIdentity,
) -> tuple[R11Observation, ...]:
    if (
        type(fixture_observations) is not tuple
        or not fixture_observations
        or any(
            type(observation) is not R11Observation
            for observation in fixture_observations
        )
    ):
        raise R11FixtureTraceabilityError(
            "fixture_observations_have_wrong_type"
        )
    return tuple(
        R11Observation(
            observation_id=observation.observation_id,
            identity=identity,
            state=observation.state,
            value=observation.value,
            reason_code=observation.reason_code,
            failure_code=observation.failure_code,
        )
        for observation in fixture_observations
    )


def _build_execution_receipt(
    *,
    fixture_identity: R11EvidenceIdentity,
    fixture_observations: tuple[R11Observation, ...],
    fixture_aggregate: R11ObservationAggregate,
    source_commit: str,
    source_tree: str,
) -> R11ExecutionReceipt:
    if type(fixture_aggregate) is not R11ObservationAggregate:
        raise R11FixtureTraceabilityError(
            "fixture_aggregate_has_wrong_type"
        )
    actual_identity = _actual_identity(
        fixture_identity,
        source_commit=source_commit,
        source_tree=source_tree,
    )
    observations = _rebind_observations(
        fixture_observations,
        identity=actual_identity,
    )
    aggregate = aggregate_observations_r11(
        identity=actual_identity,
        expected_observation_ids=fixture_aggregate.expected_observation_ids,
        observations=observations,
    )
    decision = decide_claim_r11(
        requested_claim=R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT,
        aggregate=aggregate,
    )
    if (
        decision.disposition is not R11ClaimDisposition.NO_MARKET_CLAIM
        or decision.product_qualification is not R11BoundaryState.BLOCKED
        or decision.production_auto_mode is not R11BoundaryState.BLOCKED
        or decision.market_position is not R11BoundaryState.BLOCKED
        or decision.market_leading_claim is not R11BoundaryState.BLOCKED
    ):
        raise R11FixtureTraceabilityError(
            "claim_authority_boundary_expanded"
        )
    receipt = R11ExecutionReceipt(
        identity=actual_identity,
        observations=observations,
        aggregate=aggregate,
        claim_decision=decision,
    )
    payload = canonical_json_file_bytes_r11(receipt.to_document())
    if (
        reopen_execution_receipt_r11(
            payload,
            expected_sha256=_sha256(payload),
        )
        != receipt
    ):
        raise R11FixtureTraceabilityError(
            "execution_receipt_typed_reopen_differs"
        )
    return receipt


def _build_outer_receipt(
    *,
    source_commit: str,
    source_tree: str,
    source_files: Mapping[str, tuple[str, bytes]],
    execution_receipt: R11ExecutionReceipt,
) -> dict[str, object]:
    nested = execution_receipt.to_document()
    nested_payload = canonical_json_file_bytes_r11(nested)
    return {
        "schema_version": "1.0.0",
        "roadmap_version": "1.0.1",
        "phase_id": "R11",
        "artifact_kind": "r11_traceability_run_receipt",
        "source": {
            "commit": source_commit,
            "tree": source_tree,
        },
        "source_files": [
            _file_binding(
                role=role,
                path=path,
                blob=source_files[path][0],
                payload=source_files[path][1],
            )
            for role, path in SOURCE_FILE_ROLES
        ],
        "predecessor_binding": {
            **PREDECESSOR_BINDING,
            "accepted_source": dict(
                PREDECESSOR_BINDING["accepted_source"]
            ),
            "functional_phase_acceptance": dict(
                PREDECESSOR_BINDING["functional_phase_acceptance"]
            ),
        },
        "execution_receipt": nested,
        "execution_receipt_sha256": _sha256(nested_payload),
        "comparison_policy": dict(COMPARISON_POLICY),
        "result_status": "succeeded",
        "limitations": dict(LIMITATIONS),
    }


def _validate_outer_receipt(
    receipt: object,
    *,
    schema: Mapping[str, Any],
    source_commit: str,
    source_tree: str,
    expected_source_files: list[dict[str, object]],
) -> R11ExecutionReceipt:
    errors = validate_json_schema_instance(schema, receipt)
    if errors:
        raise R11FixtureTraceabilityError(
            "traceability_run_receipt_schema_rejected:"
            + ";".join(errors)
        )
    if type(receipt) is not dict:
        raise R11FixtureTraceabilityError(
            "traceability_run_receipt_has_wrong_type"
        )
    if (
        receipt.get("source")
        != {"commit": source_commit, "tree": source_tree}
        or receipt.get("source_files") != expected_source_files
        or receipt.get("predecessor_binding") != PREDECESSOR_BINDING
        or receipt.get("comparison_policy") != COMPARISON_POLICY
        or receipt.get("limitations") != LIMITATIONS
        or receipt.get("result_status") != "succeeded"
    ):
        raise R11FixtureTraceabilityError(
            "traceability_run_receipt_exact_boundary_differs"
        )
    nested = receipt.get("execution_receipt")
    if type(nested) is not dict:
        raise R11FixtureTraceabilityError(
            "execution_receipt_document_is_absent"
        )
    nested_payload = canonical_json_file_bytes_r11(nested)
    if receipt.get("execution_receipt_sha256") != _sha256(nested_payload):
        raise R11FixtureTraceabilityError(
            "execution_receipt_binding_differs"
        )
    reopened = reopen_execution_receipt_r11(
        nested_payload,
        expected_sha256=_sha256(nested_payload),
    )
    if (
        reopened.identity.source.commit != source_commit
        or reopened.identity.source.tree != source_tree
        or reopened.claim_decision.disposition
        is not R11ClaimDisposition.NO_MARKET_CLAIM
        or reopened.claim_decision.production_auto_mode
        is not R11BoundaryState.BLOCKED
        or reopened.claim_decision.market_leading_claim
        is not R11BoundaryState.BLOCKED
    ):
        raise R11FixtureTraceabilityError(
            "execution_receipt_identity_or_authority_differs"
        )
    return reopened


def _write_receipt(
    output_root: Path,
    expected_identity: tuple[int, int],
    receipt: Mapping[str, object],
) -> Path:
    payload = canonical_json_file_bytes_r11(receipt)
    if not payload or len(payload) > _MAX_RECEIPT_BYTES:
        raise R11FixtureTraceabilityError(
            "traceability_run_receipt_size_is_invalid"
        )
    directory_descriptor = -1
    file_descriptor = -1
    read_descriptor = -1
    temporary_created = False
    final_created = False
    publication_succeeded = False
    try:
        before = os.lstat(output_root)
        directory_descriptor = os.open(
            output_root,
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(directory_descriptor)
        after = os.lstat(output_root)
        if (
            not stat.S_ISDIR(before.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or stat.S_ISLNK(after.st_mode)
            or (before.st_dev, before.st_ino) != expected_identity
            or (opened.st_dev, opened.st_ino) != expected_identity
            or (after.st_dev, after.st_ino) != expected_identity
        ):
            raise R11FixtureTraceabilityError(
                "output_root_identity_changed_before_receipt"
            )
        try:
            os.stat(
                _RECEIPT_NAME,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise R11FixtureTraceabilityError(
                "traceability_run_receipt_already_exists"
            )
        file_descriptor = os.open(
            _TEMPORARY_NAME,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=directory_descriptor,
        )
        temporary_created = True
        offset = 0
        while offset < len(payload):
            written = os.write(file_descriptor, payload[offset:])
            if written <= 0:
                raise R11FixtureTraceabilityError(
                    "traceability_run_receipt_write_made_no_progress"
                )
            offset += written
        os.fchmod(file_descriptor, 0o400)
        os.fsync(file_descriptor)
        sealed = os.fstat(file_descriptor)
        if (
            not stat.S_ISREG(sealed.st_mode)
            or sealed.st_nlink != 1
            or sealed.st_size != len(payload)
            or stat.S_IMODE(sealed.st_mode) != 0o400
        ):
            raise R11FixtureTraceabilityError(
                "traceability_run_receipt_did_not_seal"
            )
        os.close(file_descriptor)
        file_descriptor = -1
        os.link(
            _TEMPORARY_NAME,
            _RECEIPT_NAME,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        final_created = True
        os.fsync(directory_descriptor)
        os.unlink(_TEMPORARY_NAME, dir_fd=directory_descriptor)
        temporary_created = False
        os.fsync(directory_descriptor)
        published = os.stat(
            _RECEIPT_NAME,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(published.st_mode)
            or published.st_nlink != 1
            or published.st_size != len(payload)
            or stat.S_IMODE(published.st_mode) != 0o400
        ):
            raise R11FixtureTraceabilityError(
                "published_traceability_run_receipt_is_not_sealed"
            )
        read_descriptor = os.open(
            _RECEIPT_NAME,
            os.O_RDONLY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=directory_descriptor,
        )
        read_opened = os.fstat(read_descriptor)
        if (
            (read_opened.st_dev, read_opened.st_ino)
            != (published.st_dev, published.st_ino)
            or read_opened.st_size != len(payload)
            or stat.S_IMODE(read_opened.st_mode) != 0o400
        ):
            raise R11FixtureTraceabilityError(
                "published_traceability_run_receipt_identity_differs"
            )
        chunks: list[bytes] = []
        remaining = len(payload)
        while remaining:
            chunk = os.read(read_descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise R11FixtureTraceabilityError(
                    "published_traceability_run_receipt_is_truncated"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        trailing = os.read(read_descriptor, 1)
        read_after = os.fstat(read_descriptor)
        published_after = os.stat(
            _RECEIPT_NAME,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        output_after = os.lstat(output_root)
        stable = (
            published.st_dev,
            published.st_ino,
            published.st_mode,
            published.st_nlink,
            published.st_size,
            published.st_mtime_ns,
            published.st_ctime_ns,
        )
        if (
            trailing
            or b"".join(chunks) != payload
            or (
                read_opened.st_dev,
                read_opened.st_ino,
                read_opened.st_mode,
                read_opened.st_nlink,
                read_opened.st_size,
                read_opened.st_mtime_ns,
                read_opened.st_ctime_ns,
            )
            != stable
            or (
                read_after.st_dev,
                read_after.st_ino,
                read_after.st_mode,
                read_after.st_nlink,
                read_after.st_size,
                read_after.st_mtime_ns,
                read_after.st_ctime_ns,
            )
            != stable
            or (
                published_after.st_dev,
                published_after.st_ino,
                published_after.st_mode,
                published_after.st_nlink,
                published_after.st_size,
                published_after.st_mtime_ns,
                published_after.st_ctime_ns,
            )
            != stable
            or stat.S_ISLNK(output_after.st_mode)
            or (output_after.st_dev, output_after.st_ino)
            != expected_identity
        ):
            raise R11FixtureTraceabilityError(
                "published_traceability_run_receipt_bytes_or_identity_differ"
            )
        publication_succeeded = True
    except R11FixtureTraceabilityError:
        raise
    except OSError as error:
        raise R11FixtureTraceabilityError(
            "traceability_run_receipt_publication_failed"
        ) from error
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if read_descriptor >= 0:
            os.close(read_descriptor)
        if temporary_created and directory_descriptor >= 0:
            try:
                os.unlink(_TEMPORARY_NAME, dir_fd=directory_descriptor)
            except OSError:
                pass
        if (
            final_created
            and not publication_succeeded
            and directory_descriptor >= 0
        ):
            try:
                os.unlink(_RECEIPT_NAME, dir_fd=directory_descriptor)
                os.fsync(directory_descriptor)
            except OSError:
                pass
        if directory_descriptor >= 0:
            os.close(directory_descriptor)
    return output_root / _RECEIPT_NAME


def _read_published_receipt(path: Path) -> bytes:
    descriptor = -1
    try:
        before = os.lstat(path)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_size < 1
            or before.st_size > _MAX_RECEIPT_BYTES
            or stat.S_IMODE(before.st_mode) != 0o400
        ):
            raise R11FixtureTraceabilityError(
                "published_receipt_identity_or_size_is_invalid"
            )
        descriptor = os.open(
            path,
            os.O_RDONLY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino)
            != (before.st_dev, before.st_ino)
            or opened.st_size != before.st_size
            or stat.S_IMODE(opened.st_mode) != 0o400
        ):
            raise R11FixtureTraceabilityError(
                "published_receipt_open_identity_differs"
            )
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise R11FixtureTraceabilityError(
                    "published_receipt_is_truncated"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        trailing = os.read(descriptor, 1)
        after = os.fstat(descriptor)
        after_path = os.lstat(path)
        if (
            trailing
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
            )
            or (
                after_path.st_dev,
                after_path.st_ino,
                after_path.st_size,
                after_path.st_mtime_ns,
            )
            != (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
            )
        ):
            raise R11FixtureTraceabilityError(
                "published_receipt_changed_during_reopen"
            )
        return b"".join(chunks)
    except R11FixtureTraceabilityError:
        raise
    except OSError as error:
        raise R11FixtureTraceabilityError(
            "published_receipt_cannot_be_reopened"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def run_fixture_traceability(
    *,
    source_commit: str,
    output_root: Path,
    repository_root: Path = REPOSITORY_ROOT,
) -> Path:
    """Execute, validate, publish, and typed-reopen one R11 fixture receipt."""

    safe_output = _validate_output_root(
        output_root,
        repository_root=repository_root,
    )
    root, source_tree, source_files = _source_snapshot(
        repository_root,
        source_commit,
    )
    _validate_preregistration_trust_anchor(source_files)
    _require_runtime_source_bytes(source_files)
    fixture_payload = source_files[FIXTURE_CATALOG_PATH][1]
    try:
        (
            fixture_document,
            fixture_identity,
            fixture_observations,
            fixture_aggregate,
        ) = parse_fixture_catalog_r11(fixture_payload)
    except R11ContractError as error:
        raise R11FixtureTraceabilityError(
            "exact_source_fixture_catalog_rejected"
        ) from error
    _require_runtime_source_bytes(source_files)
    if (
        type(fixture_document) is not dict
        or type(fixture_identity) is not R11EvidenceIdentity
        or type(fixture_observations) is not tuple
        or type(fixture_aggregate) is not R11ObservationAggregate
    ):
        raise R11FixtureTraceabilityError(
            "fixture_parser_return_shape_differs"
        )
    execution_receipt = _build_execution_receipt(
        fixture_identity=fixture_identity,
        fixture_observations=fixture_observations,
        fixture_aggregate=fixture_aggregate,
        source_commit=source_commit,
        source_tree=source_tree,
    )
    receipt = _build_outer_receipt(
        source_commit=source_commit,
        source_tree=source_tree,
        source_files=source_files,
        execution_receipt=execution_receipt,
    )
    schema = _decode_json_object(
        source_files[RUN_RECEIPT_SCHEMA_PATH][1],
        label="traceability_run_receipt_schema",
    )
    expected_bindings = receipt["source_files"]
    if type(expected_bindings) is not list:
        raise R11FixtureTraceabilityError(
            "source_file_bindings_have_wrong_type"
        )
    _validate_outer_receipt(
        receipt,
        schema=schema,
        source_commit=source_commit,
        source_tree=source_tree,
        expected_source_files=expected_bindings,
    )
    output_identity = _create_output_root(safe_output)
    receipt_path = _write_receipt(
        safe_output,
        output_identity,
        receipt,
    )
    published_payload = _read_published_receipt(receipt_path)
    published = _decode_json_object(
        published_payload,
        label="published_traceability_run_receipt",
    )
    reopened = _validate_outer_receipt(
        published,
        schema=schema,
        source_commit=source_commit,
        source_tree=source_tree,
        expected_source_files=expected_bindings,
    )
    if (
        published != receipt
        or reopened != execution_receipt
        or canonical_json_file_bytes_r11(published) != published_payload
    ):
        raise R11FixtureTraceabilityError(
            "published_traceability_run_receipt_reopen_differs"
        )
    _require_runtime_source_bytes(source_files)
    if root != repository_root.resolve(strict=True):
        raise R11FixtureTraceabilityError(
            "repository_root_identity_changed"
        )
    return receipt_path


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run the exact-source deterministic R11 traceability fixture."
        )
    )
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output-root", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_argument_parser().parse_args(argv)
    try:
        receipt_path = run_fixture_traceability(
            source_commit=arguments.source_commit,
            output_root=arguments.output_root,
        )
    except (
        R11ContractError,
        R11FixtureTraceabilityError,
        R11TraceabilityError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(receipt_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
