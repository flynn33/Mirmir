#!/usr/bin/env python3
"""Stage the caller-owned, non-media inputs for one current-source G05 run.

This command creates the deterministic hidden ``.<final-name>.partial`` sibling,
writes the exact canonical command plan, and captures only the three caller-stage
commands required by ``run_g05_current_source.py``: strict SwiftLint, instruction
package validation, and ``git diff --check``.  It does not execute P05 evidence,
quality-lock, attribution, media, corpus, validation, or holdout commands.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import sys
from typing import Any, Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.tools import run_g05_current_source as g05  # noqa: E402


STAGED_COMMAND_IDS = ("swiftlint", "instruction-package", "diff-check")


class G05StagingError(RuntimeError):
    """The requested current-source G05 staging transaction is unsafe."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise G05StagingError(message)


def _mkdir_new(path: Path, label: str) -> Path:
    g05._canonical_absent_leaf(path, label)
    try:
        os.mkdir(path, 0o755)
    except OSError as error:
        raise G05StagingError(f"{label} cannot be created exclusively") from error
    created = g05._canonical_directory(path, label)
    metadata = os.lstat(created)
    _require(
        stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
        f"{label} is not a canonical directory",
    )
    parent_descriptor = os.open(
        created.parent,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
    return created


def _create_initial_directories(partial_root: Path) -> None:
    _mkdir_new(partial_root, "G05 partial root")
    for relative in g05._initial_staged_directories():
        _mkdir_new(
            partial_root / relative,
            f"G05 initial directory {relative}",
        )


def _command_plan(
    *,
    repository_root: Path,
    partial_root: Path,
    instruction_package_root: Path,
    source_commit: str,
    p00_baseline_commit: str,
) -> Mapping[str, Any]:
    contracts = g05._command_contracts(
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=p00_baseline_commit,
    )
    document: Mapping[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_current_source_command_plan",
        "source_commit": source_commit,
        "commands": [contracts[identifier] for identifier in g05.COMMAND_IDS],
    }
    g05._validate_schema_document(
        document,
        g05.COMMAND_PLAN_SCHEMA,
        "G05 command plan",
    )
    return document


def _capture_staged_commands(
    *,
    command_plan: Mapping[str, Any],
    partial_root: Path,
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> None:
    for identifier in STAGED_COMMAND_IDS:
        payload = g05._execute_bound_command(
            command_plan=command_plan,
            instruction_package_root=instruction_package_root,
            identifier=identifier,
        )
        row = g05._command_row(command_plan, identifier)
        output = partial_root / str(row["output_path"])
        g05._write_new(output, payload, f"{identifier} staged stdout")
        g05._validate_command_output(
            identifier=identifier,
            output_path=output,
            partial_root=partial_root,
            instruction_package_root=instruction_package_root,
            p00_baseline_commit=p00_baseline_commit,
        )


def stage_g05_current_source(
    *,
    repository_root: Path,
    partial_root: Path,
    final_root: Path,
    expected_source_commit: str,
    instruction_package_root: Path,
    p00_baseline_commit: str,
) -> Path:
    """Create and strict-reopen the exact initial G05 staging closure."""

    source_commit = g05._require_commit(expected_source_commit)
    baseline_commit = g05._require_commit(p00_baseline_commit)
    repository_root = g05._canonical_directory(repository_root, "repository root")
    instruction_package_root = g05._canonical_directory(
        instruction_package_root,
        "instruction-package root",
    )
    partial_root = g05._canonical_absent_leaf(partial_root, "G05 partial root")
    final_root = g05._canonical_absent_leaf(final_root, "G05 final root")
    _require(
        partial_root == final_root.parent / f".{final_root.name}.partial",
        "G05 partial root is not the deterministic hidden final sibling",
    )
    try:
        relative_final = final_root.relative_to(repository_root)
    except ValueError as error:
        raise G05StagingError("G05 final root is outside the repository") from error
    _require(
        relative_final.parts[:2] == ("Artifacts", "ASH")
        and len(relative_final.parts) == 3,
        "G05 final root is not a direct Artifacts/ASH child",
    )
    initial_state_sha256 = g05._validate_repository_state(
        repository_root,
        source_commit,
    )
    g05._validate_baseline_commit(
        repository_root,
        baseline_commit,
        source_commit,
    )
    _create_initial_directories(partial_root)
    command_plan = _command_plan(
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        source_commit=source_commit,
        p00_baseline_commit=baseline_commit,
    )
    g05._write_json_new(
        partial_root / "inputs/g05-command-plan.json",
        command_plan,
        "G05 structured command plan",
    )
    _capture_staged_commands(
        command_plan=command_plan,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        p00_baseline_commit=baseline_commit,
    )
    reopened = g05._validate_command_plan(
        repository_root=repository_root,
        partial_root=partial_root,
        instruction_package_root=instruction_package_root,
        source_commit=source_commit,
        p00_baseline_commit=baseline_commit,
        attribution_output_required=False,
        p05_output_required=False,
        quality_output_required=False,
    )
    _require(reopened == command_plan, "G05 staged command plan changed on reopen")
    g05._require_file_closure(
        partial_root,
        g05._initial_staged_paths(),
        "initial G05 staged closure",
        exact=True,
        expected_directories=g05._initial_staged_directories(),
    )
    _require(
        g05._validate_repository_state(repository_root, source_commit)
        == initial_state_sha256,
        "repository state changed during G05 staging",
    )
    return partial_root


def _arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--partial-root", required=True, type=Path)
    parser.add_argument("--final-root", required=True, type=Path)
    parser.add_argument("--expected-source-commit", required=True)
    parser.add_argument("--instruction-package-root", required=True, type=Path)
    parser.add_argument("--p00-baseline-commit", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(argv)
    try:
        partial_root = stage_g05_current_source(
            repository_root=arguments.repository_root,
            partial_root=arguments.partial_root,
            final_root=arguments.final_root,
            expected_source_commit=arguments.expected_source_commit,
            instruction_package_root=arguments.instruction_package_root,
            p00_baseline_commit=arguments.p00_baseline_commit,
        )
    except (
        G05StagingError,
        g05.G05CurrentSourceError,
        g05.G05SetupError,
        OSError,
        ValueError,
    ) as error:
        print(f"G05 current-source staging failed: {error}", file=sys.stderr)
        return 2
    print(partial_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
