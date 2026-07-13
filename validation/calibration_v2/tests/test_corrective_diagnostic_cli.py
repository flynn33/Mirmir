from __future__ import annotations

import json
from pathlib import Path
import subprocess
from unittest import mock

import pytest

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
    commit = "a" * 40
    receipt_document = {
        "schema_version": "1.0.0",
        "gate": "G05",
        "phase": "P05",
        "source_commit": commit,
        "status": "pass",
        "holdout_accessed": False,
        "upstream_gates": {"G04": "pass"},
        "suite": {"status": "pass"},
    }
    receipt_payload = canonical_json_bytes(receipt_document) + b"\n"
    report_payload = (
        b"# G05 Current-Source Reclosure\n\n"
        b"## Result: pass\n\nAll G05 criteria pass.\n"
    )
    receipt = write(root_path / "test-results.json", receipt_payload)
    report = write(root_path / "GATE_REPORT.md", report_payload)
    manifest_document = {
        "schema_version": "1.0.0",
        "project_commit": commit,
        "working_tree_clean": True,
        "artifacts": [
            {
                "path": "test-results.json",
                "sha256": receipt.file_sha256,
                "size_bytes": receipt.size_bytes,
                "gate_ids": ["G05"],
            },
            {
                "path": "GATE_REPORT.md",
                "sha256": report.file_sha256,
                "size_bytes": report.size_bytes,
                "gate_ids": ["G05"],
            },
        ],
    }
    manifest = write(
        root_path / "artifact-manifest.json",
        canonical_json_bytes(manifest_document) + b"\n",
    )
    root = run_cli._PinnedDirectory(root_path, "gate")
    try:
        run_cli._validate_gate_semantics(
            gate_id="G05",
            root=root,
            manifest=manifest,
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
            failed_manifest_document["artifacts"] = [
                {
                    "path": "failed-results.json",
                    "sha256": failed_receipt.file_sha256,
                    "size_bytes": failed_receipt.size_bytes,
                    "gate_ids": ["G05"],
                },
                manifest_document["artifacts"][1],
            ]
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
        with pytest.raises(run_cli.CorrectiveDiagnosticCLIError, match="all-pass"):
            run_cli._validate_gate_semantics(
                gate_id="G05",
                root=root,
                manifest=manifest,
                receipt=receipt,
                report=report,
                expected_source_commit="b" * 40,
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
