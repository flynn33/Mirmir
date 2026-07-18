"""Semantic current-source reopening and receipt staging for G04/G05/G06."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
from typing import Mapping, Sequence, Tuple

from validation.calibration_v2.calibration_persistence_v2 import (
    FileBindingV2,
    canonical_json_file_bytes_v2,
)
from validation.calibration_v2.production_candidate_provider_v2 import (
    SourceGateEvidenceV2,
)
from validation.calibration_v2.tools.run_g05_current_source import (
    reopen_finalized_g04_current_source,
    reopen_finalized_g05_current_source,
)
from validation.calibration_v2.tools.run_g06_verification import (
    G06VerificationRunner,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


class CurrentSourceGateClosureV2Error(ValueError):
    """The live Git source or one finalized gate closure differs."""


def _git(repository_root: Path, arguments: Sequence[str]) -> bytes:
    completed = subprocess.run(
        ("git", "-C", str(repository_root), *arguments),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise CurrentSourceGateClosureV2Error(
            "current Git source cannot be reopened"
        )
    return completed.stdout


def current_source_git_identity_v2(
    repository_root: Path,
) -> Tuple[str, bytes]:
    """Return exact HEAD plus porcelain bytes; callers require empty status."""

    root = Path(repository_root).resolve(strict=True)
    head = _git(root, ("rev-parse", "--verify", "HEAD")).decode(
        "ascii",
        errors="strict",
    ).strip()
    if re.fullmatch(r"[0-9a-f]{40}", head) is None:
        raise CurrentSourceGateClosureV2Error(
            "current Git HEAD is not one exact commit"
        )
    status = _git(
        root,
        ("status", "--porcelain=v1", "-z", "--untracked-files=all"),
    )
    return head, status


def _tree_binding(root: Path) -> Mapping[str, object]:
    supplied = Path(root)
    root_metadata = os.stat(supplied, follow_symlinks=False)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(
        root_metadata.st_mode
    ):
        raise CurrentSourceGateClosureV2Error(
            "source-gate tree root is not one real directory"
        )
    resolved = supplied.resolve(strict=True)
    rows = []
    for current_name, directory_names, file_names in os.walk(
        resolved,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = current / name
            metadata = os.stat(path, follow_symlinks=False)
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(
                metadata.st_mode
            ):
                raise CurrentSourceGateClosureV2Error(
                    "source-gate tree contains a linked directory"
                )
            rows.append(
                {
                    "path": path.relative_to(resolved).as_posix(),
                    "entry_kind": "directory",
                }
            )
        for name in file_names:
            path = current / name
            metadata = os.stat(path, follow_symlinks=False)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_ISLNK(metadata.st_mode)
                or metadata.st_nlink != 1
            ):
                raise CurrentSourceGateClosureV2Error(
                    "source-gate tree contains a linked or special file"
                )
            payload = path.read_bytes()
            rows.append(
                {
                    "path": path.relative_to(resolved).as_posix(),
                    "entry_kind": "regular_file",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
    rows.sort(key=lambda row: (str(row["path"]), str(row["entry_kind"])))
    return {
        "algorithm": "canonical-sorted-gate-tree-v2",
        "entry_count": len(rows),
        "tree_sha256": canonical_sha256(rows),
    }


def _publish_receipt(
    *,
    artifact_root: Path,
    gate_id: str,
    document: Mapping[str, object],
) -> SourceGateEvidenceV2:
    root = Path(os.path.abspath(os.fspath(artifact_root)))
    root.mkdir(parents=True, exist_ok=True)
    if root.is_symlink() or not root.is_dir():
        raise CurrentSourceGateClosureV2Error(
            "source-gate receipt root is unsafe"
        )
    directory = root / "source-gates"
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    if directory.is_symlink() or not directory.is_dir():
        raise CurrentSourceGateClosureV2Error(
            "source-gate receipt directory is unsafe"
        )
    payload = canonical_json_file_bytes_v2(document)
    target = directory / f"{gate_id}.json"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(target, flags, 0o600)
    except FileExistsError:
        existing = target.read_bytes()
        if existing != payload:
            raise CurrentSourceGateClosureV2Error(
                f"published {gate_id} source-gate receipt changed"
            )
    else:
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise CurrentSourceGateClosureV2Error(
                        "source-gate receipt write made no progress"
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
    reopened = target.read_bytes()
    digest = hashlib.sha256(reopened).hexdigest()
    if reopened != payload:
        raise CurrentSourceGateClosureV2Error(
            "source-gate receipt failed exact reopen"
        )
    return SourceGateEvidenceV2(
        gate_id,
        FileBindingV2(
            f"source-gates/{gate_id}.json",
            digest,
            len(reopened),
        ),
    )


def reopen_and_stage_current_source_gates_v2(
    *,
    repository_root: Path,
    artifact_root: Path,
    g04_root: Path,
    g05_root: Path,
    g05_instruction_package_root: Path,
    g05_baseline_commit: str,
    g06_root: Path,
    g06_execution_run_name: str,
) -> Tuple[SourceGateEvidenceV2, ...]:
    """Semantically reopen all three gates under one unchanged clean HEAD."""

    repository = Path(repository_root).resolve(strict=True)
    before_commit, before_status = current_source_git_identity_v2(repository)
    if before_status:
        raise CurrentSourceGateClosureV2Error(
            "current source working tree is not clean"
        )
    g04 = reopen_finalized_g04_current_source(
        root=g04_root,
        source_commit=before_commit,
    )
    g05 = reopen_finalized_g05_current_source(
        repository_root=repository,
        final_root=g05_root,
        instruction_package_root=g05_instruction_package_root,
        source_commit=before_commit,
        baseline_commit=g05_baseline_commit,
    )
    g06_runner = G06VerificationRunner(
        repository_root=repository,
        output_root=Path(g06_root).resolve(strict=True).parent,
        run_id=Path(g06_root).name,
    )
    g06 = g06_runner.verify_published_release_evidence(
        Path(g06_root),
        execution_run_name=g06_execution_run_name,
        expected_source_commit=before_commit,
    )
    semantics = {"G04": g04, "G05": g05, "G06": g06}
    roots = {"G04": Path(g04_root), "G05": Path(g05_root), "G06": Path(g06_root)}
    gates = []
    for gate_id in ("G04", "G05", "G06"):
        semantic = semantics[gate_id]
        if (
            semantic.get("gate_id") != gate_id
            or semantic.get("source_commit") != before_commit
            or semantic.get("working_tree_clean") is not True
            or semantic.get("holdout_accessed") is not False
        ):
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} semantic result is not passing current source"
            )
        receipt = {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_current_source_gate_receipt_v2",
            "gate_id": gate_id,
            "status": "pass",
            "source_commit": before_commit,
            "working_tree_clean": True,
            "holdout_accessed": False,
            "semantic_reopen": dict(semantic),
            "gate_tree": _tree_binding(roots[gate_id]),
        }
        gates.append(
            _publish_receipt(
                artifact_root=artifact_root,
                gate_id=gate_id,
                document=receipt,
            )
        )
    after_commit, after_status = current_source_git_identity_v2(repository)
    if after_commit != before_commit or after_status != before_status:
        raise CurrentSourceGateClosureV2Error(
            "current source changed during gate reopening"
        )
    return tuple(gates)


def staged_current_source_gate_receipt_projection_v2(
    *,
    repository_root: Path,
    release_root: Path,
) -> Mapping[str, object]:
    """Project the three sealed receipt identities against the current clean HEAD."""

    repository = Path(repository_root).resolve(strict=True)
    release = Path(release_root).resolve(strict=True)
    before_commit, before_status = current_source_git_identity_v2(repository)
    if before_status:
        raise CurrentSourceGateClosureV2Error(
            "current source working tree is not clean"
        )
    rows = []
    exact_fields = {
        "schema_version",
        "artifact_kind",
        "gate_id",
        "status",
        "source_commit",
        "working_tree_clean",
        "holdout_accessed",
        "semantic_reopen",
        "gate_tree",
    }
    for gate_id in ("G04", "G05", "G06"):
        path = release / "source-gates" / f"{gate_id}.json"
        try:
            metadata = os.stat(path, follow_symlinks=False)
        except OSError as error:
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} staged source-gate receipt is absent"
            ) from error
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_size <= 0
        ):
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} staged source-gate receipt is not singular"
            )
        payload = path.read_bytes()
        try:
            receipt = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} staged source-gate receipt is invalid JSON"
            ) from error
        if (
            not isinstance(receipt, dict)
            or set(receipt) != exact_fields
            or payload != canonical_json_file_bytes_v2(receipt)
            or receipt.get("schema_version") != "2.0.0"
            or receipt.get("artifact_kind")
            != "p06_current_source_gate_receipt_v2"
            or receipt.get("gate_id") != gate_id
            or receipt.get("status") != "pass"
            or receipt.get("source_commit") != before_commit
            or receipt.get("working_tree_clean") is not True
            or receipt.get("holdout_accessed") is not False
        ):
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} staged source-gate receipt is not a passing current-source receipt"
            )
        semantic = receipt.get("semantic_reopen")
        if (
            not isinstance(semantic, dict)
            or semantic.get("gate_id") != gate_id
            or semantic.get("source_commit") != before_commit
            or semantic.get("working_tree_clean") is not True
            or semantic.get("holdout_accessed") is not False
        ):
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} semantic reopening is not passing current source"
            )
        gate_tree = receipt.get("gate_tree")
        if (
            not isinstance(gate_tree, dict)
            or set(gate_tree) != {"algorithm", "entry_count", "tree_sha256"}
            or gate_tree.get("algorithm") != "canonical-sorted-gate-tree-v2"
            or not isinstance(gate_tree.get("entry_count"), int)
            or isinstance(gate_tree.get("entry_count"), bool)
            or int(gate_tree["entry_count"]) <= 0
            or re.fullmatch(r"(?!0{64})[0-9a-f]{64}", str(gate_tree.get("tree_sha256", "")))
            is None
        ):
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} source-gate tree binding is invalid"
            )
        rows.append(
            {
                "gate_id": gate_id,
                "receipt_path": f"source-gates/{gate_id}.json",
                "receipt_sha256": hashlib.sha256(payload).hexdigest(),
                "receipt_size_bytes": len(payload),
                "gate_tree": dict(gate_tree),
                "semantic_reopen_sha256": canonical_sha256(semantic),
            }
        )
    after_commit, after_status = current_source_git_identity_v2(repository)
    if after_commit != before_commit or after_status != before_status:
        raise CurrentSourceGateClosureV2Error(
            "current source changed while reopening staged gate receipts"
        )
    core = {
        "schema_version": "2.0.0",
        "artifact_kind": "p06_current_source_gate_semantics_v2",
        "status": "pass",
        "source_commit": before_commit,
        "working_tree_clean": True,
        "holdout_accessed": False,
        "gates": rows,
    }
    return {**core, "manifest_sha256": canonical_sha256(core)}


def reopen_staged_current_source_gate_receipts_v2(
    *,
    repository_root: Path,
    release_root: Path,
    g04_root: Path,
    g05_root: Path,
    g05_instruction_package_root: Path,
    g05_baseline_commit: str,
    g06_root: Path,
    g06_execution_run_name: str,
) -> Mapping[str, object]:
    """Freshly reopen actual gate trees and match the P06-sealed receipt projection."""

    repository = Path(repository_root).resolve(strict=True)
    before_commit, before_status = current_source_git_identity_v2(repository)
    if before_status:
        raise CurrentSourceGateClosureV2Error(
            "current source working tree is not clean"
        )
    semantics = {
        "G04": reopen_finalized_g04_current_source(
            root=g04_root,
            source_commit=before_commit,
        ),
        "G05": reopen_finalized_g05_current_source(
            repository_root=repository,
            final_root=g05_root,
            instruction_package_root=g05_instruction_package_root,
            source_commit=before_commit,
            baseline_commit=g05_baseline_commit,
        ),
    }
    g06_runner = G06VerificationRunner(
        repository_root=repository,
        output_root=Path(g06_root).resolve(strict=True).parent,
        run_id=Path(g06_root).name,
    )
    semantics["G06"] = g06_runner.verify_published_release_evidence(
        Path(g06_root),
        execution_run_name=g06_execution_run_name,
        expected_source_commit=before_commit,
    )
    roots = {
        "G04": Path(g04_root),
        "G05": Path(g05_root),
        "G06": Path(g06_root),
    }
    for gate_id in ("G04", "G05", "G06"):
        semantic = semantics[gate_id]
        if (
            semantic.get("gate_id") != gate_id
            or semantic.get("source_commit") != before_commit
            or semantic.get("working_tree_clean") is not True
            or semantic.get("holdout_accessed") is not False
        ):
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} fresh semantic reopening is not passing current source"
            )
    projection = staged_current_source_gate_receipt_projection_v2(
        repository_root=repository,
        release_root=release_root,
    )
    rows = projection.get("gates")
    if not isinstance(rows, list) or len(rows) != 3:
        raise CurrentSourceGateClosureV2Error(
            "sealed source-gate projection is incomplete"
        )
    for gate_id, row in zip(("G04", "G05", "G06"), rows):
        if (
            not isinstance(row, dict)
            or row.get("semantic_reopen_sha256")
            != canonical_sha256(semantics[gate_id])
            or row.get("gate_tree") != _tree_binding(roots[gate_id])
        ):
            raise CurrentSourceGateClosureV2Error(
                f"{gate_id} fresh semantics or gate tree differ from P06"
            )
    after_commit, after_status = current_source_git_identity_v2(repository)
    if after_commit != before_commit or after_status != before_status:
        raise CurrentSourceGateClosureV2Error(
            "current source changed during fresh P07 gate reopening"
        )
    return projection


__all__ = [
    "CurrentSourceGateClosureV2Error",
    "current_source_git_identity_v2",
    "reopen_and_stage_current_source_gates_v2",
    "reopen_staged_current_source_gate_receipts_v2",
    "staged_current_source_gate_receipt_projection_v2",
]
