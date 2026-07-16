from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
from unittest import mock

import pytest

from validation.calibration_v2.g05.gate import (
    G05_COMMAND_IDS,
    G05ReceiptValidation,
    LIVE_PREOPEN_RELATIVE_PATHS,
    document_bytes,
)
from validation.calibration_v2.tools import (
    inspect_p06_corrective_archive as inspect_cli,
)
from validation.calibration_v2.tools import (
    prepare_p06_corrective_diagnostics as prepare_cli,
)
from validation.calibration_v2.tools import (
    run_p06_corrective_diagnostics as run_cli,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


def write(path: Path, payload: bytes) -> run_cli._RegularSnapshot:
    path.write_bytes(payload)
    return run_cli._RegularSnapshot.capture(path, path.name)


def binding(root: Path, path: Path) -> dict[str, object]:
    payload = path.read_bytes()
    return {
        "path": path.relative_to(root).as_posix(),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def test_prepare_and_execute_are_separate_and_prepare_has_no_pixel_loader() -> None:
    prepare_source = Path(prepare_cli.__file__).read_text(encoding="utf-8")
    execute_source = Path(run_cli.__file__).read_text(encoding="utf-8")
    assert "load_development_samples" not in prepare_source
    assert "load_validation_samples" not in prepare_source
    assert "CorrectiveDiagnosticExecutor" not in prepare_source
    assert "build_corrective_preregistration" not in execute_source
    assert "--prepare-preregistration" not in execute_source
    assert "--execute" not in prepare_source
    assert execute_source.index(
        "validated_preregistration = validate_corrective_preregistration"
    ) < execute_source.index("loaded = load_development_samples")
    assert execute_source.index("loaded = load_development_samples") < execute_source.index(
        "executor = CorrectiveDiagnosticExecutor"
    )


def test_gate_semantics_requires_current_all_pass_manifest_bound_evidence(
    tmp_path: Path,
) -> None:
    root_path = (tmp_path / "gate").resolve()
    root_path.mkdir()
    (root_path / "analysis").mkdir()
    (root_path / "inputs").mkdir()
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=run_cli.REPOSITORY_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    finding_body = {
        "schema_version": "2.0.0",
        "source_commit": commit,
        "review_status": "pass",
        "open_counts": {"severity_1": 0, "severity_2": 0, "total": 0},
        "findings": [],
    }
    finding_document = {
        **finding_body,
        "register_sha256": canonical_sha256(finding_body),
    }
    assessment_document = {
        "schema_version": "2.0.0",
        "gate_id": "G05",
        "phase": "P05",
        "source_commit": commit,
        "status": "pass",
        "holdout_accessed": False,
        "finding_register_sha256": finding_document["register_sha256"],
        "mandatory_criteria": [
            {"criterion_id": f"criterion-{index}", "status": "pass"}
            for index in range(8)
        ],
    }
    upstream_document = {
        "schema_version": "1.0.0",
        "source_commit": commit,
        "status": "pass",
    }
    finding = write(
        root_path / "analysis/g05-scoped-finding-register.json",
        document_bytes(finding_document),
    )
    assessment = write(
        root_path / "analysis/g05-gate-assessment.json",
        document_bytes(assessment_document),
    )
    upstream = write(
        root_path / "inputs/upstream-bindings.json",
        document_bytes(upstream_document),
    )
    closure_relative_paths = [
        "analysis/g05-gate-assessment.json",
        "analysis/g05-scoped-finding-register.json",
        "inputs/upstream-bindings.json",
        *(f"evidence/synthetic-{index:02d}.json" for index in range(32)),
        *LIVE_PREOPEN_RELATIVE_PATHS,
    ]
    for index, relative in enumerate(closure_relative_paths[3:]):
        path = root_path / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(document_bytes({"ordinal": index, "status": "pass"}))
    command_plan_path = root_path / "inputs/g05-command-plan.json"
    command_plan_path.write_bytes(
        document_bytes(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "fixture_command_plan",
            }
        )
    )
    run_identity_path = root_path / "run-identity.json"
    run_identity_path.write_bytes(
        document_bytes(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "fixture_run_identity",
            }
        )
    )
    command_rows: list[dict[str, object]] = []
    execution_relative_paths: list[str] = []
    output_root = root_path / "outputs"
    output_root.mkdir()
    for identifier in G05_COMMAND_IDS:
        stdout_path = output_root / f"{identifier}.log"
        stderr_path = output_root / f"{identifier}.stderr.log"
        result_path = output_root / f"{identifier}.result.json"
        stdout_path.write_bytes(b"" if identifier == "diff-check" else b"pass\n")
        stderr_path.write_bytes(b"")
        result_body = {
            "schema_version": "1.0.0",
            "artifact_kind": "g05_bound_command_result",
            "command_id": identifier,
            "status": "pass",
            "started_utc": "2026-07-15T12:00:00Z",
            "ended_utc": "2026-07-15T12:00:01Z",
            "expected_exit_status": 0,
            "actual_exit_status": 0,
            "command_plan_row_sha256": "1" * 64,
            "stdout": binding(root_path, stdout_path),
            "stderr": binding(root_path, stderr_path),
            "produced_artifacts": [],
        }
        result_path.write_bytes(
            document_bytes(
                {
                    **result_body,
                    "receipt_sha256": canonical_sha256(result_body),
                }
            )
        )
        command_rows.append(
            {
                "id": identifier,
                "stdout": binding(root_path, stdout_path),
                "stderr": binding(root_path, stderr_path),
                "result": binding(root_path, result_path),
            }
        )
        execution_relative_paths.extend(
            (
                stdout_path.relative_to(root_path).as_posix(),
                stderr_path.relative_to(root_path).as_posix(),
                result_path.relative_to(root_path).as_posix(),
            )
        )
    aggregate_body = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_command_execution_aggregate",
        "status": "pass",
        "source_commit": commit,
        "command_plan": binding(root_path, command_plan_path),
        "run_identity": binding(root_path, run_identity_path),
        "commands": command_rows,
    }
    aggregate_document = {
        **aggregate_body,
        "aggregate_sha256": canonical_sha256(aggregate_body),
    }
    aggregate_path = root_path / "inputs/command-execution-aggregate.json"
    aggregate_path.write_bytes(document_bytes(aggregate_document))
    closure_relative_paths.extend(
        (
            aggregate_path.relative_to(root_path).as_posix(),
            command_plan_path.relative_to(root_path).as_posix(),
            run_identity_path.relative_to(root_path).as_posix(),
            *execution_relative_paths,
        )
    )
    receipt_document = {
        "schema_version": "1.0.0",
        "gate": "G05",
        "phase": "P05",
        "status": "pass",
        "source_commit": commit,
        "holdout_accessed": False,
        "assessment": binding(root_path, assessment.path),
        "finding_register": binding(root_path, finding.path),
        "upstream_bindings": binding(root_path, upstream.path),
        "command_execution": binding(root_path, aggregate_path),
        "suite": {"status": "pass"},
    }
    receipt_payload = document_bytes(receipt_document)
    report_payload = (
        b"# G05 Current-Source Reclosure\n\n"
        b"## Result: pass\n\nAll G05 criteria pass.\n"
    )
    receipt = write(root_path / "test-results.json", receipt_payload)
    report = write(root_path / "GATE_REPORT.md", report_payload)
    validated = G05ReceiptValidation(
        assessment=assessment_document,
        finding_register=finding_document,
        upstream_bindings=upstream_document,
        command_execution_aggregate=aggregate_document,
        reopened_relative_paths=tuple(closure_relative_paths),
    )
    root_metadata = os.lstat(root_path)
    transaction_document = {
        "schema_version": "1.0.0",
        "artifact_kind": "evidence_wrapper_publication_transaction",
        "transaction_token": "1" * 32,
        "created_utc": "2026-07-15T12:00:02Z",
        "project_commit": commit,
        "partial_name": f".{root_path.name}.partial",
        "final_name": root_path.name,
        "failure_name": f"{root_path.name}.failed",
        "gate_ids": ["G05", "P05"],
        "root_device": root_metadata.st_dev,
        "root_inode": root_metadata.st_ino,
    }
    transaction_path = root_path / "publication-transaction.json"
    transaction_path.write_bytes(document_bytes(transaction_document))
    manifest_paths = (
        "test-results.json",
        "GATE_REPORT.md",
        "publication-transaction.json",
        *validated.reopened_relative_paths,
    )
    manifest_document = {
        "schema_version": "2.0.0",
        "created_utc": "2026-07-15T12:00:03Z",
        "project_commit": commit,
        "working_tree_clean": True,
        "directories": [
            "analysis",
            "evidence",
            "inputs",
            "inputs/live-preopen",
            "outputs",
        ],
        "artifacts": [
            {
                **binding(root_path, root_path / relative),
                "producer": "fixture",
                "gate_ids": ["G05", "P05"],
                "command": "fixture",
                "platform": "fixture",
                "machine": "fixture",
            }
            for relative in sorted(manifest_paths)
        ],
    }
    manifest = write(
        root_path / "artifact-manifest.json",
        canonical_json_bytes(manifest_document) + b"\n",
    )
    root = run_cli._PinnedDirectory(root_path, "gate")
    validator_patch = mock.patch.object(
        run_cli,
        "validate_g05_receipt",
        return_value=validated,
    )
    validator_patch.start()
    try:
        semantic_snapshots = run_cli._validate_gate_semantics(
            gate_id="G05",
            root=root,
            manifest=manifest,
            receipt=receipt,
            report=report,
            expected_source_commit=commit,
        )
        assert len(semantic_snapshots) == 70
        semantic_paths = {
            snapshot.path.relative_to(root_path).as_posix()
            for snapshot in semantic_snapshots
        }
        assert semantic_paths == {
            *validated.reopened_relative_paths,
            "publication-transaction.json",
        }

        unexpected_directory = root_path / "unexpected-empty-directory"
        unexpected_directory.mkdir()
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="finalized manifest tree closure differs",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        unexpected_directory.rmdir()

        schema_incomplete_document = dict(manifest_document)
        schema_incomplete_document.pop("created_utc")
        schema_incomplete_manifest = write(
            root_path / "schema-incomplete-manifest.json",
            canonical_json_bytes(schema_incomplete_document) + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="schema validation failed",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=schema_incomplete_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )

        missing_evidence_document = {
            **manifest_document,
            "artifacts": [
                row
                for row in manifest_document["artifacts"]
                if row["path"] != LIVE_PREOPEN_RELATIVE_PATHS[-1]
            ],
        }
        missing_evidence_manifest = write(
            root_path / "missing-evidence-manifest.json",
            canonical_json_bytes(missing_evidence_document) + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="absent from its artifact manifest",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=missing_evidence_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        missing_empty_stream_document = {
            **manifest_document,
            "artifacts": [
                row
                for row in manifest_document["artifacts"]
                if row["path"] != "outputs/diff-check.log"
            ],
        }
        missing_empty_stream_manifest = write(
            root_path / "missing-empty-stream-manifest.json",
            canonical_json_bytes(missing_empty_stream_document) + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="absent from its artifact manifest",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=missing_empty_stream_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        missing_p05_gate_document = {
            **manifest_document,
            "artifacts": [
                {
                    **row,
                    "gate_ids": ["G05"],
                }
                if row["path"] == LIVE_PREOPEN_RELATIVE_PATHS[-1]
                else row
                for row in manifest_document["artifacts"]
            ],
        }
        missing_p05_gate_manifest = write(
            root_path / "missing-p05-gate-manifest.json",
            canonical_json_bytes(missing_p05_gate_document) + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="absent from its artifact manifest",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=missing_p05_gate_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        dirty_manifest_document = {
            **manifest_document,
            "working_tree_clean": False,
        }
        dirty_manifest = write(
            root_path / "dirty-manifest.json",
            canonical_json_bytes(dirty_manifest_document) + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="manifest identity",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=dirty_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        with pytest.raises(run_cli.CorrectiveDiagnosticCLIError, match="all-pass"):
            changed = dict(receipt_document)
            changed["suite"] = {"status": "fail"}
            failed_receipt = write(
                root_path / "failed-results.json",
                canonical_json_bytes(changed) + b"\n",
            )
            failed_manifest_document = dict(manifest_document)
            failed_manifest_document["artifacts"] = sorted(
                [
                    {
                        **row,
                        **binding(root_path, failed_receipt.path),
                        "gate_ids": ["G05", "P05"],
                    }
                    if row["path"] == "test-results.json"
                    else row
                    for row in manifest_document["artifacts"]
                ],
                key=lambda row: row["path"],
            )
            failed_manifest = write(
                root_path / "failed-manifest.json",
                canonical_json_bytes(failed_manifest_document) + b"\n",
            )
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=failed_manifest,
                receipt=failed_receipt,
                report=report,
                expected_source_commit=commit,
            )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="manifest identity|publication transaction",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=manifest,
                receipt=receipt,
                report=report,
                expected_source_commit="b" * 40,
            )
        legacy_schema_document = {
            **manifest_document,
            "schema_version": "1.0.0",
        }
        legacy_schema_manifest = write(
            root_path / "legacy-schema-manifest.json",
            canonical_json_bytes(legacy_schema_document) + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="manifest identity",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=legacy_schema_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        unknown_schema_document = {
            **manifest_document,
            "schema_version": "3.0.0",
        }
        unknown_schema_manifest = write(
            root_path / "unknown-schema-manifest.json",
            canonical_json_bytes(unknown_schema_document) + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="manifest identity",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=unknown_schema_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        noncanonical_manifest = write(
            root_path / "noncanonical-manifest.json",
            json.dumps(manifest_document, indent=2).encode("utf-8") + b"\n",
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="not canonical JSON",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=noncanonical_manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
        (root_path / "analysis/g05-scoped-finding-register.json").write_bytes(
            canonical_json_bytes(
                {
                    **finding_document,
                    "register_sha256": "0" * 64,
                }
            )
            + b"\n"
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="finding register",
        ):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=commit,
            )
    finally:
        validator_patch.stop()
        root.close()


def test_g05_gate_semantics_rejects_failure_namespace(tmp_path: Path) -> None:
    root_path = (tmp_path / "g05.failed").resolve()
    root_path.mkdir()
    root = run_cli._PinnedDirectory(root_path, "failed gate")
    try:
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="failure namespace",
        ):
            run_cli._validate_finalized_gate_manifest(
                gate_id="G05",
                root=root,
                manifest_document={},
                manifest_payload=b"",
                expected_source_commit="0" * 40,
            )
    finally:
        root.close()


def record(sequence: int, previous: str, **values: object) -> dict[str, object]:
    body = {
        "sequence": sequence,
        "previous_record_sha256": previous,
        **values,
    }
    return {**body, "record_sha256": canonical_sha256(body)}


def test_archive_closure_reopens_every_reference_and_inspector_reports_hash(
    tmp_path: Path,
) -> None:
    root_path = (tmp_path / "failed").resolve()
    (root_path / "evaluations").mkdir(parents=True)
    (root_path / "controls").mkdir()
    evaluation = write(root_path / "evaluations/e.json", b'{"evaluation":1}')
    control = write(root_path / "controls/c.json", b'{"control":1}')
    first = record(
        0,
        "0" * 64,
        evaluation={
            "path": "evaluations/e.json",
            "sha256": evaluation.file_sha256,
            "size_bytes": evaluation.size_bytes,
        },
        control_selection_artifacts=[
            {
                "path": "controls/c.json",
                "sha256": control.file_sha256,
                "size_bytes": control.size_bytes,
            }
        ],
    )
    second = record(
        1,
        str(first["record_sha256"]),
        evaluation={
            "path": "evaluations/e.json",
            "sha256": evaluation.file_sha256,
            "size_bytes": evaluation.size_bytes,
        },
        control_selection_artifacts=[
            {
                "path": "controls/c.json",
                "sha256": control.file_sha256,
                "size_bytes": control.size_bytes,
            }
        ],
    )
    ledger_payload = b"".join(
        canonical_json_bytes(row) + b"\n" for row in (first, second)
    )
    ledger = write(root_path / "attempts.ndjson", ledger_payload)
    failure = write(root_path / "failure.json", b'{"failed":true}\n')
    inputs = write(root_path / "input-bindings.json", b'{"inputs":true}\n')
    transaction = write(
        root_path / ".calibration-transaction.json",
        b'{"transaction":true}\n',
    )
    arguments = type(
        "Arguments",
        (),
        {
            "failed_run_root": root_path,
            "attempt_ledger_path": ledger.path,
            "failure_record_path": failure.path,
            "input_bindings_path": inputs.path,
            "transaction_intent_path": transaction.path,
        },
    )()
    result = inspect_cli.inspect(arguments)
    assert result["attempt_count"] == 2
    assert result["referenced_binding_count"] == 4
    assert result["unique_evaluation_file_count"] == 1
    assert result["unique_control_file_count"] == 1
    assert len(result["archive_closure_manifest_sha256"]) == 64

    (root_path / "controls/c.json").write_bytes(b'{"control":2}')
    with pytest.raises(run_cli.CorrectiveDiagnosticCLIError, match="differs"):
        inspect_cli.inspect(arguments)


def test_repository_binding_is_read_only_and_rejects_tracked_changes(
    tmp_path: Path,
) -> None:
    root_path = (tmp_path / "repository").resolve()
    root_path.mkdir()
    commands = (
        ("init", "-q"),
        ("config", "user.name", "Mirmir Test"),
        ("config", "user.email", "mirmir@example.invalid"),
    )
    for command in commands:
        subprocess.run(["/usr/bin/git", "-C", root_path, *command], check=True)
    source = root_path / "source.swift"
    source.write_text("let value = 1\n", encoding="utf-8")
    subprocess.run(["/usr/bin/git", "-C", root_path, "add", "source.swift"], check=True)
    subprocess.run(
        ["/usr/bin/git", "-C", root_path, "commit", "-qm", "fixture"],
        check=True,
    )

    def object_names() -> set[str]:
        return {
            path.relative_to(root_path / ".git/objects").as_posix()
            for path in (root_path / ".git/objects").rglob("*")
            if path.is_file()
        }

    before = object_names()
    root = run_cli._PinnedDirectory(root_path, "repository")
    try:
        binding = run_cli._repository_binding(root)
        assert binding["tracked_status_size_bytes"] == 0
        assert object_names() == before
        source.write_text("let value = 2\n", encoding="utf-8")
        with pytest.raises(run_cli.CorrectiveDiagnosticCLIError, match="tracked modifications"):
            run_cli._repository_binding(root)
    finally:
        root.close()


def test_repository_git_binding_ignores_caller_global_configuration() -> None:
    completed = subprocess.CompletedProcess(
        args=[],
        returncode=0,
        stdout=b"",
        stderr=b"",
    )
    with mock.patch.object(
        run_cli.subprocess,
        "run",
        return_value=completed,
    ) as invoked:
        assert run_cli._run_git(Path("/tmp/repository"), "status") == b""
    environment = invoked.call_args.kwargs["env"]
    assert invoked.call_args.args[0][0] == "/usr/bin/git"
    assert environment["HOME"] == "/var/empty"
    assert environment["GIT_CONFIG_NOSYSTEM"] == "1"
    assert environment["GIT_CONFIG_GLOBAL"] == "/dev/null"
    assert environment["GIT_TERMINAL_PROMPT"] == "0"
    assert "GIT_DIR" not in environment
    assert "GIT_WORK_TREE" not in environment
    assert "GIT_INDEX_FILE" not in environment


def test_late_failure_quarantines_success_bundle_exclusively(tmp_path: Path) -> None:
    parent = tmp_path.resolve()
    output = parent / "published"
    output.mkdir()
    (output / "evidence.json").write_bytes(b"{}\n")
    quarantine = run_cli._quarantine_published_output(
        output,
        RuntimeError("live guard changed after corrective resource cleanup"),
    )
    assert not output.exists()
    assert quarantine.is_dir()
    receipt_path = quarantine / "CLI_FAILURE_RECEIPT.json"
    receipt = json.loads(receipt_path.read_bytes())
    unsealed = dict(receipt)
    claimed = unsealed.pop("failure_receipt_sha256")
    assert claimed == canonical_sha256(unsealed)
    assert receipt["status"] == "failed_closed_untrusted"


def test_prepare_quarantine_preserves_replacement_identity(tmp_path: Path) -> None:
    parent = tmp_path.resolve()
    path = parent / "preregistration.json"
    path.write_bytes(b'{"original":true}\n')
    expected = run_cli._RegularSnapshot.capture(path, "original preregistration")
    path.unlink()
    path.write_bytes(b'{"replacement":true}\n')
    observed = run_cli._RegularSnapshot.capture(path, "replacement preregistration")
    quarantine = prepare_cli._quarantine_preregistration(
        path,
        RuntimeError("replacement detected"),
        expected,
    )
    assert not path.exists()
    moved = run_cli._RegularSnapshot.capture(quarantine, "quarantined replacement")
    assert (moved.device, moved.inode, moved.file_sha256) == (
        observed.device,
        observed.inode,
        observed.file_sha256,
    )
    receipt = json.loads(
        (quarantine.parent / (quarantine.name + ".failure.json")).read_bytes()
    )
    assert receipt["expected_identity"]["inode"] == expected.inode
    assert receipt["observed_identity"]["inode"] == observed.inode


def test_resource_cleanup_attempts_every_resource() -> None:
    closed: list[str] = []

    class Resource:
        def __init__(self, name: str, fail: bool = False) -> None:
            self.name = name
            self.fail = fail

        def close(self) -> None:
            closed.append(self.name)
            if self.fail:
                raise RuntimeError(self.name)

    with pytest.raises(run_cli.CorrectiveDiagnosticCLIError, match="cleanup"):
        run_cli._close_resources(
            (Resource("native"), Resource("writer", fail=True), Resource("cache"))
        )
    assert closed == ["cache", "writer", "native"]


def test_execute_reopens_completed_evidence_after_cleanup_guard_and_before_pin_close() -> None:
    source = Path(run_cli.__file__).read_text(encoding="utf-8")
    execute_source = source[source.index("def _execute(") :]
    cleanup = execute_source.index("_close_resources(resources)")
    post_cleanup_guard = execute_source.index(
        "live guard changed after corrective resource cleanup",
        cleanup,
    )
    completed_reopen = execute_source.index(
        "completed_summary = _completed_evidence_summary(",
        post_cleanup_guard,
    )
    final_guard = execute_source.index(
        "live guard changed during completed-evidence reopen",
        completed_reopen,
    )
    final_pin_verify = execute_source.index(
        "for pin in pins:\n                    pin.verify()",
        final_guard,
    )
    result_binding = execute_source.index(
        '"completed_evidence": completed_summary',
        final_pin_verify,
    )
    result_seal = execute_source.index(
        '"execution_result_sha256": canonical_sha256(result_body)',
        result_binding,
    )
    pin_close = execute_source.index(
        "for pin in reversed(pins):",
        result_seal,
    )
    assert (
        cleanup
        < post_cleanup_guard
        < completed_reopen
        < final_guard
        < final_pin_verify
        < result_binding
        < result_seal
        < pin_close
    )


def test_completed_evidence_post_close_reopen_rejects_replaced_native_stub(
    tmp_path: Path,
) -> None:
    from validation.calibration_v2.tests.test_corrective_diagnostic_executor import (
        FakeWriter,
        fake_metrics,
        make_executor,
    )

    writer = FakeWriter()
    executor, bound, _, _ = make_executor(tmp_path.resolve(), writer=writer)
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ):
        published = executor.run()
    binding = executor.completed_evidence_binding
    assert isinstance(binding, dict)
    summary = run_cli._published_summary(published, "synthetic-post-close")
    work_parent = run_cli._PinnedDirectory(tmp_path.resolve(), "synthetic work parent")
    try:
        completed = run_cli._completed_evidence_summary(
            binding=binding,
            work_parent=work_parent,
            published_path=published,
            published_summary=summary,
            expected_guard=bound.documents[
                "live_holdout_preopen_verification"
            ],
        )
        assert completed["status"] == "post_close_reopen_verified"
        assert completed["completed_evidence_binding"] == binding
        body = dict(completed)
        claimed = body.pop("completed_evidence_sha256")
        assert claimed == canonical_sha256(body)

        prepublication = binding["prepublication_execution_closure"]
        first_call = json.loads(
            (
                Path(binding["work_root_path"])
                / "journal"
                / "000000-call-evidence.json"
            ).read_bytes()
        )
        expected_output_manifest = (
            run_cli._native_original_output_manifest(
                first_call["evidence"]["native_record"],
                request_ordinal=0,
            )
        )
        receipt = prepublication["native_sanitation_receipts"][0]
        assert (
            run_cli._validate_native_sanitation_receipt(
                receipt,
                request_ordinal=0,
                expected_original_output_manifest=expected_output_manifest,
            )
            == receipt
        )
        empty_original_name = json.loads(json.dumps(receipt))
        empty_original_name["retained_stubs"][0]["original_name"] = ""
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="stub differs",
        ):
            run_cli._validate_native_sanitation_receipt(
                empty_original_name,
                request_ordinal=0,
                expected_original_output_manifest=expected_output_manifest,
            )
        wrong_original_manifest = json.loads(json.dumps(receipt))
        wrong_original_manifest["original_output_manifest_sha256"] = (
            canonical_sha256({"wrong": "original-output-manifest"})
        )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="header differs",
        ):
            run_cli._validate_native_sanitation_receipt(
                wrong_original_manifest,
                request_ordinal=0,
                expected_original_output_manifest=expected_output_manifest,
            )
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="header differs",
        ):
            run_cli._validate_native_sanitation_receipt(
                prepublication["native_sanitation_receipts"][1],
                request_ordinal=0,
                expected_original_output_manifest=expected_output_manifest,
            )
        stub = receipt["retained_stubs"][0]
        stub_path = Path(receipt["retained_transaction_path"]) / stub[
            "retained_name"
        ]
        stub_path.unlink()
        stub_path.write_bytes(b"replaced after resource close")
        with pytest.raises(
            run_cli.CorrectiveDiagnosticCLIError,
            match="differs after resource close",
        ):
            run_cli._completed_evidence_summary(
                binding=binding,
                work_parent=work_parent,
                published_path=published,
                published_summary=summary,
                expected_guard=bound.documents[
                    "live_holdout_preopen_verification"
                ],
            )
    finally:
        work_parent.close()
