#!/usr/bin/env python3
"""Run one exact-source deterministic R10 fixture calibration.

The command accepts no media, holdout, production, comparison, threshold, or
policy-override inputs.  It reads the complete executable fixture contract from
one exact Git commit, executes the bounded nine-candidate optimizer, reopens all
durable artifacts, and writes one deterministic receipt.
"""

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

from Scripts import r10_contracts as r10_contracts_module  # noqa: E402
from Scripts.r10_contracts import (  # noqa: E402
    R10ContractError,
    parse_evaluation_catalog_r10,
    parse_fixture_catalog_r10,
    parse_policy_catalog_r10,
)
from validation.calibration_v2 import r10_optimizer as r10_optimizer_module  # noqa: E402
from validation.calibration_v2 import r10_persistence as r10_persistence_module  # noqa: E402
from validation.calibration_v2.r10_optimizer import (  # noqa: E402
    R10AttemptDisposition,
    R10Candidate,
    R10Checkpoint,
    R10ConstraintName,
    R10EvaluationCatalog,
    R10ProcessingIdentity,
    R10RunStatus,
    canonical_json_file_bytes_r10,
    optimize_r10,
)
from validation.calibration_v2.r10_persistence import (  # noqa: E402
    R10ArtifactBinding,
    R10PersistenceError,
    R10PersistenceStore,
)


OPTIMIZER_PATH = "validation/calibration_v2/r10_optimizer.py"
PERSISTENCE_PATH = "validation/calibration_v2/r10_persistence.py"
FIXTURE_CATALOG_PATH = (
    "docs/roadmaps/evidence/r10/records/fixtures/fixture-catalog.json"
)
EVALUATION_CATALOG_PATH = (
    "docs/roadmaps/evidence/r10/records/fixtures/evaluation-catalog.json"
)
POLICY_CATALOG_PATH = (
    "docs/roadmaps/evidence/r10/records/fixtures/policy-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = (
    "docs/roadmaps/evidence/schema/r10-fixture-catalog-v1.json"
)
EVALUATION_CATALOG_SCHEMA_PATH = (
    "docs/roadmaps/evidence/schema/r10-evaluation-catalog-v1.json"
)
POLICY_CATALOG_SCHEMA_PATH = (
    "docs/roadmaps/evidence/schema/r10-policy-catalog-v1.json"
)
PHASE_EVIDENCE_PATH = "Scripts/phase_evidence.py"
CONTRACTS_PATH = "Scripts/r10_contracts.py"
RUNNER_PATH = (
    "validation/calibration_v2/tools/run_r10_fixture_calibration.py"
)

SOURCE_FILE_ROLES = (
    ("optimizer_contract", OPTIMIZER_PATH),
    ("persistence_contract", PERSISTENCE_PATH),
    ("fixture_catalog", FIXTURE_CATALOG_PATH),
    ("evaluation_catalog_raw_envelope", EVALUATION_CATALOG_PATH),
    ("policy_catalog", POLICY_CATALOG_PATH),
    ("fixture_catalog_schema", FIXTURE_CATALOG_SCHEMA_PATH),
    ("evaluation_catalog_schema", EVALUATION_CATALOG_SCHEMA_PATH),
    ("policy_catalog_schema", POLICY_CATALOG_SCHEMA_PATH),
    ("schema_validation_runtime", PHASE_EVIDENCE_PATH),
    ("fixture_calibration_runner", RUNNER_PATH),
    ("catalog_contract_parser", CONTRACTS_PATH),
)

_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
_GIT_OBJECT_PATTERN = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
_RECEIPT_NAME = "run-receipt.json"
_RECEIPT_TEMPORARY_NAME = ".run-receipt.pending"
_MAX_RECEIPT_BYTES = 16 * 1024 * 1024
_MAX_SOURCE_FILE_BYTES = 2 * 1024 * 1024
_MAX_GIT_CONTROL_BYTES = 128


class R10FixtureCalibrationError(RuntimeError):
    """The exact-source fixture run or deterministic publication is invalid."""


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
        raise R10FixtureCalibrationError(
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
            raise R10FixtureCalibrationError(
                f"{operation}_git_stdout_is_unavailable"
            )
        payload = process.stdout.read(maximum_output_bytes + 1)
    except OSError as error:
        if process is not None:
            process.kill()
            if process.stdout is not None:
                process.stdout.close()
            process.wait()
        raise R10FixtureCalibrationError(
            f"{operation}_git_execution_failed"
        ) from error
    if len(payload) > maximum_output_bytes:
        process.kill()
        process.stdout.close()
        process.wait()
        raise R10FixtureCalibrationError(
            f"{operation}_git_output_exceeds_bound"
        )
    process.stdout.close()
    returncode = process.wait()
    if returncode != 0:
        raise R10FixtureCalibrationError(f"{operation}_git_command_failed")
    if exact_output_bytes is not None and len(payload) != exact_output_bytes:
        raise R10FixtureCalibrationError(
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
        raise R10FixtureCalibrationError(
            f"{operation}_git_object_is_not_ascii"
        ) from error
    if (
        _GIT_OBJECT_PATTERN.fullmatch(value) is None
        or payload != f"{value}\n".encode("ascii")
    ):
        raise R10FixtureCalibrationError(
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
        maximum_output_bytes=_MAX_GIT_CONTROL_BYTES,
    )
    if object_type != b"blob\n":
        raise R10FixtureCalibrationError("source_file_is_not_a_blob")
    size_payload = _git_bytes(
        repository_root,
        ("cat-file", "-s", blob),
        operation="source_file_size",
        maximum_output_bytes=_MAX_GIT_CONTROL_BYTES,
    )
    if re.fullmatch(rb"[1-9][0-9]*\n", size_payload) is None:
        raise R10FixtureCalibrationError(
            "source_file_size_is_invalid"
        )
    declared_size = int(size_payload[:-1])
    if declared_size > _MAX_SOURCE_FILE_BYTES:
        raise R10FixtureCalibrationError(
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
        raise R10FixtureCalibrationError(
            "source_file_size_differs_from_preflight"
        )
    return blob, payload


def _source_snapshot(
    repository_root: Path,
    source_commit: str,
) -> tuple[str, dict[str, tuple[str, bytes]]]:
    if (
        type(source_commit) is not str
        or _COMMIT_PATTERN.fullmatch(source_commit) is None
        or source_commit == "0" * 40
    ):
        raise R10FixtureCalibrationError(
            "source_commit_must_be_one_nonzero_lowercase_40_character_oid"
        )
    try:
        root = repository_root.resolve(strict=True)
    except OSError as error:
        raise R10FixtureCalibrationError(
            "repository_root_is_unavailable"
        ) from error
    if not root.is_dir():
        raise R10FixtureCalibrationError("repository_root_is_not_a_directory")

    resolved_commit = _git_object_id(
        root,
        f"{source_commit}^{{commit}}",
        operation="source_commit",
    )
    if resolved_commit != source_commit:
        raise R10FixtureCalibrationError("source_commit_is_not_exact")
    source_tree = _git_object_id(
        root,
        f"{source_commit}^{{tree}}",
        operation="source_tree",
    )

    files: dict[str, tuple[str, bytes]] = {}
    for _role, path in SOURCE_FILE_ROLES:
        files[path] = _git_file_bytes(root, source_commit, path)
    return source_tree, files


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


def _raw_binding(
    *,
    path: str,
    payload: bytes,
) -> dict[str, object]:
    return {
        "path": path,
        "size_bytes": len(payload),
        "sha256": _sha256(payload),
    }


def _artifact_binding(binding: R10ArtifactBinding) -> dict[str, object]:
    if type(binding) is not R10ArtifactBinding:
        raise R10FixtureCalibrationError(
            "published_artifact_binding_has_wrong_type"
        )
    return {
        "path": binding.path,
        "size_bytes": binding.size_bytes,
        "sha256": binding.sha256,
    }


def _runtime_schema_validator_path() -> Path:
    validator = getattr(
        r10_contracts_module,
        "validate_json_schema_instance",
        None,
    )
    module_name = getattr(validator, "__module__", None)
    module = sys.modules.get(module_name) if type(module_name) is str else None
    module_file = getattr(module, "__file__", None)
    if type(module_file) is not str:
        raise R10FixtureCalibrationError(
            "schema_validation_runtime_path_is_unavailable"
        )
    return Path(os.path.abspath(module_file))


def _read_runtime_source_bytes(
    working_path: Path,
    expected_payload: bytes,
) -> bytes:
    if (
        type(expected_payload) is not bytes
        or not expected_payload
        or len(expected_payload) > _MAX_SOURCE_FILE_BYTES
    ):
        raise R10FixtureCalibrationError(
            "runtime_source_expected_bytes_are_invalid"
        )
    descriptor = -1
    try:
        before = os.lstat(working_path)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_size != len(expected_payload)
        ):
            raise R10FixtureCalibrationError(
                "runtime_source_identity_or_size_differs"
            )
        descriptor = os.open(
            working_path,
            os.O_RDONLY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        after_open = os.lstat(working_path)
        stable_identity = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        if (
            not stat.S_ISREG(opened.st_mode)
            or (
                opened.st_dev,
                opened.st_ino,
                opened.st_mode,
                opened.st_nlink,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
            )
            != stable_identity
            or (
                after_open.st_dev,
                after_open.st_ino,
                after_open.st_mode,
                after_open.st_nlink,
                after_open.st_size,
                after_open.st_mtime_ns,
                after_open.st_ctime_ns,
            )
            != stable_identity
        ):
            raise R10FixtureCalibrationError(
                "runtime_source_identity_or_size_differs"
            )
        chunks: list[bytes] = []
        remaining = len(expected_payload)
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise R10FixtureCalibrationError(
                    "runtime_source_is_truncated"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        trailing = os.read(descriptor, 1)
        after_read = os.fstat(descriptor)
        after_path = os.lstat(working_path)
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
            != stable_identity
            or (
                after_path.st_dev,
                after_path.st_ino,
                after_path.st_mode,
                after_path.st_nlink,
                after_path.st_size,
                after_path.st_mtime_ns,
                after_path.st_ctime_ns,
            )
            != stable_identity
        ):
            raise R10FixtureCalibrationError(
                "runtime_source_identity_or_size_differs"
            )
        return b"".join(chunks)
    except R10FixtureCalibrationError:
        raise
    except OSError as error:
        raise R10FixtureCalibrationError(
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
            OPTIMIZER_PATH,
            Path(r10_optimizer_module.__file__).resolve(strict=True),
        ),
        (
            PERSISTENCE_PATH,
            Path(r10_persistence_module.__file__).resolve(strict=True),
        ),
        (
            CONTRACTS_PATH,
            Path(os.path.abspath(r10_contracts_module.__file__)),
        ),
        (
            PHASE_EVIDENCE_PATH,
            _runtime_schema_validator_path(),
        ),
        (
            FIXTURE_CATALOG_SCHEMA_PATH,
            REPOSITORY_ROOT / FIXTURE_CATALOG_SCHEMA_PATH,
        ),
        (
            EVALUATION_CATALOG_SCHEMA_PATH,
            REPOSITORY_ROOT / EVALUATION_CATALOG_SCHEMA_PATH,
        ),
        (
            POLICY_CATALOG_SCHEMA_PATH,
            REPOSITORY_ROOT / POLICY_CATALOG_SCHEMA_PATH,
        ),
        (
            RUNNER_PATH,
            Path(os.path.abspath(__file__)),
        ),
    )
    for repository_path, working_path in runtime_paths:
        expected_payload = source_files[repository_path][1]
        try:
            working_bytes = _read_runtime_source_bytes(
                working_path,
                expected_payload,
            )
        except R10FixtureCalibrationError as error:
            raise R10FixtureCalibrationError(
                "runtime_source_differs_from_source_commit:"
                f"{repository_path}:{error}"
            ) from error
        if working_bytes != expected_payload:
            raise R10FixtureCalibrationError(
                f"runtime_source_differs_from_source_commit:{repository_path}"
            )


def _require_raw_catalog_binding(
    value: object,
    *,
    expected_path: str,
    expected_payload: bytes,
    field: str,
) -> None:
    expected = _raw_binding(path=expected_path, payload=expected_payload)
    if type(value) is not dict or value != expected:
        raise R10FixtureCalibrationError(
            f"{field}_differs_from_exact_source_bytes"
        )


def _require_catalog_relations(
    *,
    fixture_document: Mapping[str, Any],
    candidates: tuple[R10Candidate, ...],
    evaluation_document: Mapping[str, Any],
    evaluation_catalog: R10EvaluationCatalog,
    policy_document: Mapping[str, Any],
    evaluation_payload: bytes,
    policy_payload: bytes,
) -> dict[str, Mapping[str, Any]]:
    if (
        fixture_document.get("maximum_candidates") != 9
        or len(candidates) != 9
    ):
        raise R10FixtureCalibrationError(
            "fixture_candidate_bound_is_not_exactly_nine"
        )
    _require_raw_catalog_binding(
        fixture_document.get("evaluation_catalog_binding"),
        expected_path=EVALUATION_CATALOG_PATH,
        expected_payload=evaluation_payload,
        field="fixture_evaluation_catalog_binding",
    )
    _require_raw_catalog_binding(
        fixture_document.get("policy_catalog_binding"),
        expected_path=POLICY_CATALOG_PATH,
        expected_payload=policy_payload,
        field="fixture_policy_catalog_binding",
    )
    if (
        evaluation_document.get("evaluator_sha256")
        != evaluation_catalog.evaluator_sha256
    ):
        raise R10FixtureCalibrationError(
            "semantic_evaluation_binding_differs"
        )

    wrappers = fixture_document.get("candidates")
    if type(wrappers) is not list or len(wrappers) != 9:
        raise R10FixtureCalibrationError("fixture_candidate_wrappers_are_invalid")
    expected_by_id: dict[str, Mapping[str, Any]] = {}
    candidate_by_id = {
        candidate.candidate_id: candidate for candidate in candidates
    }
    for wrapper in wrappers:
        if type(wrapper) is not dict:
            raise R10FixtureCalibrationError(
                "fixture_candidate_wrapper_has_wrong_type"
            )
        candidate_document = wrapper.get("candidate")
        expected = wrapper.get("expected")
        if type(candidate_document) is not dict or type(expected) is not dict:
            raise R10FixtureCalibrationError(
                "fixture_candidate_wrapper_is_incomplete"
            )
        candidate_id = candidate_document.get("candidate_id")
        candidate = candidate_by_id.get(candidate_id)
        if (
            candidate is None
            or candidate.to_document() != candidate_document
            or wrapper.get("candidate_sha256") != candidate.candidate_sha256
            or candidate_id in expected_by_id
        ):
            raise R10FixtureCalibrationError(
                "fixture_candidate_typed_binding_differs"
            )
        expected_by_id[candidate_id] = expected
    if set(expected_by_id) != set(candidate_by_id):
        raise R10FixtureCalibrationError("fixture_candidate_set_differs")

    expected_scored = {
        candidate_id
        for candidate_id, expected in expected_by_id.items()
        if expected.get("disposition") == "scored"
    }
    evaluation_ids = {
        evaluation.candidate_id
        for evaluation in evaluation_catalog.evaluations
    }
    if (
        expected_scored
        != {
            "fixture-valid-alpha",
            "fixture-valid-beta",
            "fixture-valid-gamma",
        }
        or evaluation_ids != expected_scored
        or len(evaluation_catalog.evaluations) != 3
    ):
        raise R10FixtureCalibrationError(
            "evaluation_catalog_does_not_cover_exact_scored_set"
        )

    causal_contracts = policy_document.get("causal_variables")
    if type(causal_contracts) is not list or len(causal_contracts) != 3:
        raise R10FixtureCalibrationError(
            "policy_causal_variable_contract_is_invalid"
        )
    allowed_values: dict[str, frozenset[int]] = {}
    for contract in causal_contracts:
        if (
            type(contract) is not dict
            or type(contract.get("name")) is not str
            or type(contract.get("allowed_values")) is not list
            or any(type(value) is not int for value in contract["allowed_values"])
        ):
            raise R10FixtureCalibrationError(
                "policy_causal_variable_contract_is_invalid"
            )
        allowed_values[contract["name"]] = frozenset(
            contract["allowed_values"]
        )
    for candidate in candidates:
        variables = dict(candidate.causal_variables)
        if set(variables) != set(allowed_values) or any(
            type(value) is not int or value not in allowed_values[name]
            for name, value in variables.items()
        ):
            raise R10FixtureCalibrationError(
                "fixture_candidate_exceeds_policy_search_space"
            )

    if (
        fixture_document.get("comparison_methods_used") is not False
        or evaluation_document.get("comparison_methods_used") is not False
        or policy_document.get("comparative_metrics_used") is not False
        or policy_document.get("production_auto_authorized") is not False
        or policy_document.get("holdout_authorized") is not False
        or policy_document.get("threshold_relaxation_allowed") is not False
        or policy_document.get("post_freeze_change_allowed") is not False
        or policy_document.get("publication_scope")
        != "deterministic_fixture_policy_only"
    ):
        raise R10FixtureCalibrationError(
            "fixture_only_noncomparative_publication_boundary_differs"
        )
    return expected_by_id


def _validate_output_root(
    requested: Path,
    *,
    repository_root: Path,
) -> Path:
    if not isinstance(requested, Path):
        raise R10FixtureCalibrationError("output_root_has_wrong_type")
    raw = os.fspath(requested)
    if (
        not requested.is_absolute()
        or "\x00" in raw
        or raw != os.path.normpath(raw)
        or requested == Path(os.sep)
    ):
        raise R10FixtureCalibrationError(
            "output_root_must_be_absolute_lexically_normalized_and_nonroot"
        )
    try:
        parent = requested.parent.resolve(strict=True)
        repository = repository_root.resolve(strict=True)
    except OSError as error:
        raise R10FixtureCalibrationError(
            "output_root_parent_or_repository_is_unavailable"
        ) from error
    if not parent.is_dir():
        raise R10FixtureCalibrationError(
            "output_root_parent_is_not_a_directory"
        )
    canonical = parent / requested.name
    if requested != canonical:
        raise R10FixtureCalibrationError(
            "output_root_contains_a_symlinked_parent"
        )
    if canonical == repository or repository in canonical.parents:
        raise R10FixtureCalibrationError(
            "output_root_must_remain_outside_source_repository"
        )
    try:
        os.lstat(canonical)
    except FileNotFoundError:
        return canonical
    except OSError as error:
        raise R10FixtureCalibrationError(
            "output_root_cannot_be_inspected"
        ) from error
    raise R10FixtureCalibrationError("output_root_must_be_absent")


def _create_output_root(output_root: Path) -> tuple[int, int]:
    parent_descriptor = -1
    try:
        parent_before = os.lstat(output_root.parent)
        parent_descriptor = os.open(
            output_root.parent,
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
        )
        parent_opened = os.fstat(parent_descriptor)
        parent_after = os.lstat(output_root.parent)
        if (
            not stat.S_ISDIR(parent_before.st_mode)
            or not stat.S_ISDIR(parent_opened.st_mode)
            or stat.S_ISLNK(parent_after.st_mode)
            or (parent_before.st_dev, parent_before.st_ino)
            != (parent_opened.st_dev, parent_opened.st_ino)
            or (parent_opened.st_dev, parent_opened.st_ino)
            != (parent_after.st_dev, parent_after.st_ino)
        ):
            raise R10FixtureCalibrationError(
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
        raise R10FixtureCalibrationError(
            "output_root_conflict_during_creation"
        ) from error
    except OSError as error:
        raise R10FixtureCalibrationError(
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
        raise R10FixtureCalibrationError(
            "output_root_creation_identity_is_invalid"
        )
    return created.st_dev, created.st_ino


def _require_checkpoint_catalog_replay(
    checkpoint: R10Checkpoint,
    evaluation_catalog: R10EvaluationCatalog,
) -> None:
    if (
        checkpoint.processing_identity.evaluator_sha256
        != evaluation_catalog.evaluator_sha256
    ):
        raise R10FixtureCalibrationError(
            "checkpoint_evaluation_catalog_identity_differs"
        )
    for attempt in checkpoint.attempts:
        if attempt.disposition is not R10AttemptDisposition.SCORED:
            continue
        if (
            attempt.score is None
            or evaluation_catalog.score_for(attempt.candidate)
            != attempt.score
        ):
            raise R10FixtureCalibrationError(
                "checkpoint_score_differs_from_exact_evaluation_catalog"
            )


def _write_receipt(
    output_root: Path,
    expected_identity: tuple[int, int],
    receipt: Mapping[str, object],
) -> Path:
    payload = canonical_json_file_bytes_r10(receipt)
    if not payload or len(payload) > _MAX_RECEIPT_BYTES:
        raise R10FixtureCalibrationError("run_receipt_size_is_invalid")
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
            raise R10FixtureCalibrationError(
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
            raise R10FixtureCalibrationError("run_receipt_already_exists")

        file_descriptor = os.open(
            _RECEIPT_TEMPORARY_NAME,
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
                raise R10FixtureCalibrationError(
                    "run_receipt_write_made_no_progress"
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
            raise R10FixtureCalibrationError("run_receipt_did_not_seal")
        os.close(file_descriptor)
        file_descriptor = -1

        os.link(
            _RECEIPT_TEMPORARY_NAME,
            _RECEIPT_NAME,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        final_created = True
        os.fsync(directory_descriptor)
        os.unlink(_RECEIPT_TEMPORARY_NAME, dir_fd=directory_descriptor)
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
            raise R10FixtureCalibrationError(
                "published_run_receipt_is_not_sealed"
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
            not stat.S_ISREG(read_opened.st_mode)
            or (read_opened.st_dev, read_opened.st_ino)
            != (published.st_dev, published.st_ino)
            or read_opened.st_nlink != 1
            or read_opened.st_size != len(payload)
            or stat.S_IMODE(read_opened.st_mode) != 0o400
        ):
            raise R10FixtureCalibrationError(
                "published_run_receipt_identity_differs"
            )
        chunks: list[bytes] = []
        remaining = len(payload)
        while remaining:
            chunk = os.read(read_descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise R10FixtureCalibrationError(
                    "published_run_receipt_is_truncated"
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
        stable_identity = (
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
            != stable_identity
            or (
                read_after.st_dev,
                read_after.st_ino,
                read_after.st_mode,
                read_after.st_nlink,
                read_after.st_size,
                read_after.st_mtime_ns,
                read_after.st_ctime_ns,
            )
            != stable_identity
            or (
                published_after.st_dev,
                published_after.st_ino,
                published_after.st_mode,
                published_after.st_nlink,
                published_after.st_size,
                published_after.st_mtime_ns,
                published_after.st_ctime_ns,
            )
            != stable_identity
            or stat.S_ISLNK(output_after.st_mode)
            or (output_after.st_dev, output_after.st_ino)
            != expected_identity
        ):
            raise R10FixtureCalibrationError(
                "published_run_receipt_bytes_or_identity_differ"
            )
        publication_succeeded = True
    except R10FixtureCalibrationError:
        raise
    except OSError as error:
        raise R10FixtureCalibrationError(
            "run_receipt_publication_failed"
        ) from error
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if read_descriptor >= 0:
            os.close(read_descriptor)
        if temporary_created and directory_descriptor >= 0:
            try:
                os.unlink(
                    _RECEIPT_TEMPORARY_NAME,
                    dir_fd=directory_descriptor,
                )
            except OSError:
                pass
        if (
            final_created
            and not publication_succeeded
            and directory_descriptor >= 0
        ):
            try:
                os.unlink(
                    _RECEIPT_NAME,
                    dir_fd=directory_descriptor,
                )
                os.fsync(directory_descriptor)
            except FileNotFoundError:
                pass
            except OSError:
                pass
        if directory_descriptor >= 0:
            os.close(directory_descriptor)

    return output_root / _RECEIPT_NAME


def _verify_run_contract(
    *,
    result: object,
    candidates: tuple[R10Candidate, ...],
    expected_by_id: Mapping[str, Mapping[str, Any]],
    evaluation_catalog: R10EvaluationCatalog,
) -> dict[str, object]:
    if (
        getattr(result, "status", None) is not R10RunStatus.SUCCEEDED
        or getattr(result, "terminal_code", "unexpected") is not None
        or getattr(result, "selection", None) is None
    ):
        raise R10FixtureCalibrationError(
            "bounded_fixture_optimizer_did_not_succeed"
        )
    checkpoint = result.checkpoint
    if (
        checkpoint.candidate_count != 9
        or checkpoint.maximum_candidates != 9
        or len(checkpoint.attempts) != 9
        or result.evaluation_observation_count != 3
    ):
        raise R10FixtureCalibrationError(
            "bounded_fixture_attempt_counts_differ"
        )

    scored_ids: list[str] = []
    rejected_names: list[str] = []
    for attempt in checkpoint.attempts:
        expected = expected_by_id.get(attempt.candidate.candidate_id)
        if expected is None:
            raise R10FixtureCalibrationError(
                "optimizer_attempt_is_not_in_fixture_contract"
            )
        actual_rejected = [
            constraint.value for constraint in attempt.rejected_constraints
        ]
        if (
            attempt.disposition.value != expected.get("disposition")
            or actual_rejected != expected.get("rejected_constraints")
        ):
            raise R10FixtureCalibrationError(
                "optimizer_attempt_differs_from_fixture_expectation"
            )
        if attempt.disposition is R10AttemptDisposition.SCORED:
            scored_ids.append(attempt.candidate.candidate_id)
        else:
            rejected_names.extend(actual_rejected)
    if (
        len(scored_ids) != 3
        or len(rejected_names) != 6
        or tuple(sorted(rejected_names))
        != tuple(sorted(name.value for name in R10ConstraintName))
    ):
        raise R10FixtureCalibrationError(
            "independent_constraint_rejections_differ"
        )

    candidate_by_id = {
        candidate.candidate_id: candidate for candidate in candidates
    }
    alpha = candidate_by_id["fixture-valid-alpha"]
    beta = candidate_by_id["fixture-valid-beta"]
    gamma = candidate_by_id["fixture-valid-gamma"]
    alpha_score = evaluation_catalog.score_for(alpha)
    beta_score = evaluation_catalog.score_for(beta)
    if alpha_score != beta_score or not alpha.canonical_bytes < beta.canonical_bytes:
        raise R10FixtureCalibrationError(
            "declared_tie_break_fixture_is_not_an_exact_tie"
        )
    expected_ranking = (
        alpha.candidate_sha256,
        beta.candidate_sha256,
        gamma.candidate_sha256,
    )
    selection = result.selection
    if (
        selection.ranked_candidate_sha256_values != expected_ranking
        or selection.selected_candidate != alpha
        or selection.selected_score != alpha_score
    ):
        raise R10FixtureCalibrationError(
            "deterministic_tie_break_selection_differs"
        )

    return {
        "maximum_candidates": 9,
        "candidate_count": 9,
        "scored_count": 3,
        "rejected_count": 6,
        "independently_rejected_constraints": [
            name.value for name in R10ConstraintName
        ],
        "evaluation_observation_count": 3,
        "tie_break": {
            "equal_score_candidate_ids": [
                "fixture-valid-alpha",
                "fixture-valid-beta",
            ],
            "rule": (
                "absolute_score_dimensions_descending_then_"
                "canonical_candidate_bytes_ascending"
            ),
            "winner_candidate_id": "fixture-valid-alpha",
        },
        "execution_scope": "deterministic_fixture_policy_only",
        "comparison_methods_used": False,
        "production_auto_authorized": False,
        "holdout_authorized": False,
    }


def run_fixture_calibration(
    *,
    source_commit: str,
    output_root: Path,
    repository_root: Path = REPOSITORY_ROOT,
) -> Path:
    """Execute, durably verify, and publish one deterministic R10 fixture run."""

    safe_output_root = _validate_output_root(
        output_root,
        repository_root=repository_root,
    )
    source_tree, source_files = _source_snapshot(
        repository_root,
        source_commit,
    )
    _require_runtime_source_bytes(source_files)

    optimizer_payload = source_files[OPTIMIZER_PATH][1]
    persistence_payload = source_files[PERSISTENCE_PATH][1]
    fixture_payload = source_files[FIXTURE_CATALOG_PATH][1]
    evaluation_payload = source_files[EVALUATION_CATALOG_PATH][1]
    policy_payload = source_files[POLICY_CATALOG_PATH][1]
    try:
        fixture_document, candidates = parse_fixture_catalog_r10(
            fixture_payload
        )
        evaluation_document, evaluation_catalog = (
            parse_evaluation_catalog_r10(evaluation_payload)
        )
        policy_document = parse_policy_catalog_r10(policy_payload)
    except R10ContractError as error:
        raise R10FixtureCalibrationError(
            "exact_source_catalog_contract_rejected"
        ) from error
    if (
        type(candidates) is not tuple
        or any(type(candidate) is not R10Candidate for candidate in candidates)
        or type(evaluation_catalog) is not R10EvaluationCatalog
    ):
        raise R10FixtureCalibrationError(
            "catalog_parser_returned_wrong_typed_contract"
        )

    expected_by_id = _require_catalog_relations(
        fixture_document=fixture_document,
        candidates=candidates,
        evaluation_document=evaluation_document,
        evaluation_catalog=evaluation_catalog,
        policy_document=policy_document,
        evaluation_payload=evaluation_payload,
        policy_payload=policy_payload,
    )
    processing_identity = R10ProcessingIdentity(
        source_commit=source_commit,
        source_tree=source_tree,
        optimizer_contract_sha256=_sha256(optimizer_payload),
        persistence_contract_sha256=_sha256(persistence_payload),
        fixture_catalog_sha256=_sha256(fixture_payload),
        evaluator_sha256=evaluation_catalog.evaluator_sha256,
        policy_catalog_sha256=_sha256(policy_payload),
    )

    output_identity = _create_output_root(safe_output_root)
    checkpoint_records: list[tuple[R10ArtifactBinding, R10Checkpoint]] = []
    try:
        with R10PersistenceStore(safe_output_root) as store:

            def checkpoint_sink(checkpoint: R10Checkpoint) -> None:
                binding = store.publish_checkpoint(checkpoint)
                reopened = store.reopen_checkpoint(binding)
                if reopened != checkpoint:
                    raise R10FixtureCalibrationError(
                        "incremental_checkpoint_typed_reopen_differs"
                    )
                _require_checkpoint_catalog_replay(
                    reopened,
                    evaluation_catalog,
                )
                checkpoint_records.append((binding, reopened))

            result = optimize_r10(
                processing_identity=processing_identity,
                candidates=candidates,
                maximum_candidates=9,
                evaluation_catalog=evaluation_catalog,
                checkpoint_sink=checkpoint_sink,
            )
            execution_contract = _verify_run_contract(
                result=result,
                candidates=candidates,
                expected_by_id=expected_by_id,
                evaluation_catalog=evaluation_catalog,
            )
            if (
                len(checkpoint_records) != 10
                or [checkpoint.next_candidate_index for _, checkpoint in checkpoint_records]
                != list(range(10))
            ):
                raise R10FixtureCalibrationError(
                    "incremental_checkpoint_sequence_differs"
                )
            for binding, checkpoint in checkpoint_records:
                reopened = store.reopen_checkpoint(binding)
                if reopened != checkpoint:
                    raise R10FixtureCalibrationError(
                        "checkpoint_final_typed_reopen_differs"
                    )
                _require_checkpoint_catalog_replay(
                    reopened,
                    evaluation_catalog,
                )

            publication = store.publish_run_result(
                result,
                evaluation_catalog=evaluation_catalog,
            )
            if (
                publication.terminal is not None
                or publication.frozen_policy is None
                or publication.checkpoint != checkpoint_records[-1][0]
                or store.reopen_checkpoint(publication.checkpoint)
                != result.checkpoint
            ):
                raise R10FixtureCalibrationError(
                    "successful_publication_shape_differs"
                )
            frozen_policy = store.reopen_frozen_policy(
                publication.frozen_policy,
                evaluation_catalog=evaluation_catalog,
            )
            frozen_document = frozen_policy.to_document()
            if (
                frozen_document.get("publication_scope")
                != "deterministic_fixture_policy_only"
                or frozen_document.get("production_auto_authorized") is not False
                or frozen_document.get("comparative_metrics_used") is not False
                or frozen_policy.selection != result.selection
                or frozen_policy.processing_identity != processing_identity
            ):
                raise R10FixtureCalibrationError(
                    "frozen_fixture_policy_boundary_differs"
                )

            source_bindings = []
            for role, path in SOURCE_FILE_ROLES:
                blob, payload = source_files[path]
                source_bindings.append(
                    _file_binding(
                        role=role,
                        path=path,
                        blob=blob,
                        payload=payload,
                    )
                )
            receipt: dict[str, object] = {
                "schema_version": "1.0.0",
                "phase_id": "R10",
                "artifact_kind": "r10_fixture_calibration_run_receipt",
                "result_status": "succeeded",
                "processing_identity": processing_identity.to_document(),
                "processing_identity_sha256": (
                    processing_identity.identity_sha256
                ),
                "source_files": source_bindings,
                "raw_evaluation_catalog_binding": _raw_binding(
                    path=EVALUATION_CATALOG_PATH,
                    payload=evaluation_payload,
                ),
                "semantic_evaluator_sha256": (
                    evaluation_catalog.evaluator_sha256
                ),
                "execution_contract": execution_contract,
                "checkpoint_bindings": [
                    {
                        "artifact": _artifact_binding(binding),
                        "checkpoint_sha256": checkpoint.checkpoint_sha256,
                        "status": checkpoint.status.value,
                        "next_candidate_index": (
                            checkpoint.next_candidate_index
                        ),
                    }
                    for binding, checkpoint in checkpoint_records
                ],
                "publication": {
                    "final_checkpoint": _artifact_binding(
                        publication.checkpoint
                    ),
                    "frozen_policy": _artifact_binding(
                        publication.frozen_policy
                    ),
                    "policy_sha256": frozen_policy.policy_sha256,
                    "selection_sha256": (
                        frozen_policy.selection.selection_sha256
                    ),
                    "selected_candidate_id": (
                        frozen_policy.selection.selected_candidate.candidate_id
                    ),
                },
            }
            receipt_path = _write_receipt(
                safe_output_root,
                output_identity,
                receipt,
            )
    except (R10PersistenceError, OSError) as error:
        raise R10FixtureCalibrationError(
            "fixture_artifact_publication_failed"
        ) from error
    return receipt_path


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run the exact-source deterministic R10 fixture calibration."
        )
    )
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output-root", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_argument_parser().parse_args(argv)
    try:
        receipt = run_fixture_calibration(
            source_commit=arguments.source_commit,
            output_root=arguments.output_root,
        )
    except (
        R10FixtureCalibrationError,
        R10ContractError,
        R10PersistenceError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(receipt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
