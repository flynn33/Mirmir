#!/usr/bin/env python3
"""Prepare one no-pixel preregistration for P06 corrective diagnostics."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Mapping
import uuid


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.corrective_diagnostics import (  # noqa: E402
    canonical_artifact_file_bytes,
)
from validation.calibration_v2.corrective_preregistration import (  # noqa: E402
    build_corrective_preregistration,
    validate_corrective_preregistration,
    verify_attempt_ledger_payload,
)
from validation.calibration_v2.native_adapter.factory import (  # noqa: E402
    make_native_corrective_diagnostic_capability,
)
from validation.calibration_v2.production_providers import (  # noqa: E402
    production_writer_capability,
)
from validation.calibration_v2.runner import bind_preregistered_inputs  # noqa: E402
from validation.calibration_v2.tools import (  # noqa: E402
    run_p06_corrective_diagnostics as core,
)
from validation.calibration_v2.tools.run_p06_production_calibration import (  # noqa: E402
    _live_holdout_preopen_binding,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    canonical_sha256,
)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build and bind the corrective native/writer runtimes and publish "
            "one canonical preregistration without opening development, "
            "validation, or holdout pixels."
        )
    )
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--open-split-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--work-parent", required=True, type=Path)
    parser.add_argument("--native-cache-root", required=True, type=Path)
    parser.add_argument("--writer-root", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--candidate-vector-path", required=True, type=Path)
    parser.add_argument("--expected-candidate-vector-file-sha256", required=True)
    parser.add_argument("--preregistration-output-path", required=True, type=Path)
    parser.add_argument("--failed-run-root", required=True, type=Path)
    parser.add_argument("--attempt-ledger-path", required=True, type=Path)
    parser.add_argument("--expected-attempt-ledger-sha256", required=True)
    parser.add_argument("--expected-attempt-count", required=True, type=int)
    parser.add_argument("--expected-attempt-tail-record-sha256", required=True)
    parser.add_argument("--failed-failure-record-path", required=True, type=Path)
    parser.add_argument("--expected-failed-failure-record-sha256", required=True)
    parser.add_argument("--failed-input-bindings-path", required=True, type=Path)
    parser.add_argument("--expected-failed-input-bindings-sha256", required=True)
    parser.add_argument("--failed-transaction-intent-path", required=True, type=Path)
    parser.add_argument("--expected-failed-transaction-intent-sha256", required=True)
    parser.add_argument("--expected-archive-referenced-binding-count", required=True, type=int)
    parser.add_argument("--expected-archive-unique-evaluation-file-count", required=True, type=int)
    parser.add_argument("--expected-archive-unique-control-file-count", required=True, type=int)
    parser.add_argument("--expected-archive-closure-manifest-sha256", required=True)
    parser.add_argument("--expected-source-sequence", required=True, type=int)
    parser.add_argument("--expected-source-record-sha256", required=True)
    parser.add_argument("--expected-source-candidate-vector-sha256", required=True)
    parser.add_argument("--expected-carry-forward-sequence", required=True, type=int)
    parser.add_argument("--expected-carry-forward-record-sha256", required=True)
    for gate in ("g04", "g05"):
        parser.add_argument(f"--{gate}-artifact-root", required=True, type=Path)
        parser.add_argument(f"--{gate}-manifest-path", required=True, type=Path)
        parser.add_argument(f"--expected-{gate}-manifest-sha256", required=True)
        parser.add_argument(f"--{gate}-receipt-path", required=True, type=Path)
        parser.add_argument(f"--expected-{gate}-receipt-sha256", required=True)
        parser.add_argument(f"--{gate}-report-path", required=True, type=Path)
        parser.add_argument(f"--expected-{gate}-report-sha256", required=True)
    parser.add_argument("--calibration-plan-path", required=True, type=Path)
    parser.add_argument("--expected-calibration-plan-file-sha256", required=True)
    parser.add_argument("--coordinate-model-contract-path", required=True, type=Path)
    parser.add_argument("--expected-coordinate-model-contract-file-sha256", required=True)
    parser.add_argument("--video-profile-contract-path", required=True, type=Path)
    parser.add_argument("--expected-video-profile-contract-file-sha256", required=True)
    parser.add_argument("--live-ledger-path", required=True, type=Path)
    parser.add_argument("--live-anchor-path", required=True, type=Path)
    parser.add_argument("--live-preopen-receipt-path", required=True, type=Path)
    parser.add_argument("--expected-live-ledger-root-identity-sha256", required=True)
    parser.add_argument("--expected-live-anchor-root-identity-sha256", required=True)
    parser.add_argument("--expected-live-preopen-receipt-sha256", required=True)
    parser.add_argument("--repository-sealed-copy-path", required=True, type=Path)
    parser.add_argument("--expected-repository-sealed-copy-sha256", required=True)
    parser.add_argument("--repository-attestation-path", required=True, type=Path)
    parser.add_argument("--expected-repository-attestation-sha256", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=900.0)
    return parser.parse_args()


def _quarantine_preregistration(
    path: Path,
    error: BaseException,
    expected: core._RegularSnapshot | None,
) -> Path:
    parent = core._PinnedDirectory(path.parent, "preregistration quarantine parent")
    name = f".{path.name}.untrusted-{uuid.uuid4().hex}"
    try:
        observed = core._RegularSnapshot.capture(
            path,
            "observed preregistration before quarantine",
        )
        core._rename_directory_exclusive(
            parent.descriptor,
            path.name,
            name,
        )
        moved = core._RegularSnapshot.capture(
            path.parent / name,
            "quarantined preregistration",
        )
        core._require(
            (moved.device, moved.inode, moved.file_sha256, moved.size_bytes)
            == (
                observed.device,
                observed.inode,
                observed.file_sha256,
                observed.size_bytes,
            ),
            "preregistration identity changed during quarantine",
        )
        body = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_corrective_preregistration_untrusted_quarantine",
            "status": "failed_closed_untrusted",
            "original_path": os.fspath(path),
            "quarantine_path": os.fspath(path.parent / name),
            "error_type": f"{type(error).__module__}.{type(error).__qualname__}",
            "error_message": str(error),
            "expected_identity": (
                None
                if expected is None
                else {
                    "device": expected.device,
                    "inode": expected.inode,
                    "file_sha256": expected.file_sha256,
                    "size_bytes": expected.size_bytes,
                }
            ),
            "observed_identity": {
                "device": observed.device,
                "inode": observed.inode,
                "file_sha256": observed.file_sha256,
                "size_bytes": observed.size_bytes,
            },
        }
        receipt = {**body, "failure_receipt_sha256": canonical_sha256(body)}
        core._write_new_file_at(
            parent.descriptor,
            name + ".failure.json",
            canonical_artifact_file_bytes(receipt),
        )
        os.fsync(parent.descriptor)
        return path.parent / name
    finally:
        parent.close()


def _execute(
    arguments: argparse.Namespace,
    *,
    preregistered_utc: datetime,
) -> Mapping[str, object]:
    core._require(
        isinstance(arguments.run_id, str)
        and re.fullmatch(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", arguments.run_id)
        is not None,
        "run ID is invalid",
    )
    core._require_distinct_roots(
        (
            arguments.output_root,
            arguments.work_parent,
            arguments.native_cache_root,
            arguments.writer_root,
        )
    )
    output = core._lexical_absolute(arguments.output_root, "future output root")
    preregistration_path = core._lexical_absolute(
        arguments.preregistration_output_path,
        "preregistration output path",
    )
    core._require(not os.path.lexists(output), "future output root already exists")
    core._require(
        not os.path.lexists(preregistration_path),
        "preregistration output already exists",
    )
    core._require(
        preregistration_path != output,
        "preregistration output path equals the future diagnostic output root",
    )

    pins: list[core._PinnedDirectory] = []
    snapshots: list[tuple[core._RegularSnapshot, str]] = []
    resources: list[object] = []
    live_binding = None
    initial_guard = None
    preregistration_written = False
    published_snapshot: core._RegularSnapshot | None = None
    primary: BaseException | None = None
    primary_traceback = None
    result: Mapping[str, object] | None = None
    try:
        repository = core._PinnedDirectory(arguments.repository_root, "repository root")
        open_split = core._PinnedDirectory(arguments.open_split_root, "open split root")
        output_parent = core._PinnedDirectory(output.parent, "future output parent")
        work = core._PinnedDirectory(arguments.work_parent, "work parent")
        native_cache = core._PinnedDirectory(arguments.native_cache_root, "native cache root")
        writer_root = core._PinnedDirectory(arguments.writer_root, "writer root")
        failed_root = core._PinnedDirectory(arguments.failed_run_root, "failed run root")
        g04_root = core._PinnedDirectory(arguments.g04_artifact_root, "G04 artifact root")
        g05_root = core._PinnedDirectory(arguments.g05_artifact_root, "G05 artifact root")
        preregistration_parent = core._PinnedDirectory(
            preregistration_path.parent,
            "preregistration output parent",
        )
        pins.extend(
            (
                repository,
                open_split,
                output_parent,
                work,
                native_cache,
                writer_root,
                failed_root,
                g04_root,
                g05_root,
                preregistration_parent,
            )
        )
        core._require(
            repository.path == REPOSITORY_ROOT.resolve(strict=True),
            "repository root differs from the loaded preparation source tree",
        )
        repository_state = core._repository_binding(repository)

        candidate_file = core._RegularSnapshot.capture(
            arguments.candidate_vector_path,
            "audited candidate vector",
        )
        snapshots.append((candidate_file, "audited candidate vector"))
        core._require(
            candidate_file.file_sha256
            == core._require_sha256(
                arguments.expected_candidate_vector_file_sha256,
                "expected audited candidate vector",
            ),
            "audited candidate vector differs from its explicit file hash",
        )
        candidate_vector = core._strict_json_object(
            candidate_file.payload,
            "audited candidate vector",
        )
        core._require(
            candidate_file.payload == canonical_json_bytes(candidate_vector) + b"\n",
            "audited candidate vector file is not canonical object JSON plus LF",
        )

        ledger = core._descendant_file(
            failed_root,
            arguments.attempt_ledger_path,
            "archived attempt ledger",
            arguments.expected_attempt_ledger_sha256,
        )
        records = verify_attempt_ledger_payload(ledger.payload)
        core._require(
            len(records) == arguments.expected_attempt_count
            and records[-1]["record_sha256"]
            == core._require_sha256(
                arguments.expected_attempt_tail_record_sha256,
                "expected attempt-ledger tail",
            ),
            "archived attempt-ledger count or tail differs",
        )
        failure_record = core._descendant_file(
            failed_root,
            arguments.failed_failure_record_path,
            "archived failure record",
            arguments.expected_failed_failure_record_sha256,
        )
        failed_input_bindings = core._descendant_file(
            failed_root,
            arguments.failed_input_bindings_path,
            "archived input bindings",
            arguments.expected_failed_input_bindings_sha256,
        )
        transaction_intent = core._descendant_file(
            failed_root,
            arguments.failed_transaction_intent_path,
            "archived transaction intent",
            arguments.expected_failed_transaction_intent_sha256,
        )
        snapshots.extend(
            (
                (ledger, "archived attempt ledger"),
                (failure_record, "archived failure record"),
                (failed_input_bindings, "archived input bindings"),
                (transaction_intent, "archived transaction intent"),
            )
        )
        closure, closure_snapshots = core._archive_closure(
            failed_root=failed_root,
            records=records,
            core_files={
                "attempt_ledger": ledger,
                "failure_record": failure_record,
                "input_bindings": failed_input_bindings,
                "transaction_intent": transaction_intent,
            },
        )
        snapshots.extend(closure_snapshots)
        core._require(
            closure["referenced_binding_count"]
            == arguments.expected_archive_referenced_binding_count
            and closure["unique_evaluation_file_count"]
            == arguments.expected_archive_unique_evaluation_file_count
            and closure["unique_control_file_count"]
            == arguments.expected_archive_unique_control_file_count
            and closure["archive_closure_manifest_sha256"]
            == core._require_sha256(
                arguments.expected_archive_closure_manifest_sha256,
                "expected archive closure manifest",
            ),
            "archive closure differs from explicit counts or hash",
        )

        gate_rows = {}
        for gate, root in (("g04", g04_root), ("g05", g05_root)):
            gate_id = gate.upper()
            manifest = core._descendant_file(
                root,
                getattr(arguments, f"{gate}_manifest_path"),
                f"{gate_id} artifact manifest",
                getattr(arguments, f"expected_{gate}_manifest_sha256"),
            )
            receipt = core._descendant_file(
                root,
                getattr(arguments, f"{gate}_receipt_path"),
                f"{gate_id} receipt",
                getattr(arguments, f"expected_{gate}_receipt_sha256"),
            )
            report = core._descendant_file(
                root,
                getattr(arguments, f"{gate}_report_path"),
                f"{gate_id} report",
                getattr(arguments, f"expected_{gate}_report_sha256"),
            )
            semantic_snapshots = core._validate_gate_semantics(
                gate_id=gate_id,
                root=root,
                manifest=manifest,
                receipt=receipt,
                report=report,
                expected_source_commit=str(repository_state["git_head_commit"]),
            )
            snapshots.extend(
                (snapshot, f"{gate_id} gate semantic binding")
                for snapshot in semantic_snapshots
            )
            snapshots.extend(
                (
                    (manifest, f"{gate_id} artifact manifest"),
                    (receipt, f"{gate_id} receipt"),
                    (report, f"{gate_id} report"),
                )
            )
            gate_rows[gate] = {
                "artifact_root": root.binding(),
                "manifest": manifest.binding(),
                "receipt": receipt.binding(),
                "report": report.binding(),
            }

        coordinate = core._RegularSnapshot.capture(
            arguments.coordinate_model_contract_path,
            "coordinate-model contract",
        )
        video = core._RegularSnapshot.capture(
            arguments.video_profile_contract_path,
            "video-profile contract",
        )
        core._require(
            coordinate.file_sha256
            == core._require_sha256(
                arguments.expected_coordinate_model_contract_file_sha256,
                "expected coordinate-model contract",
            )
            and video.file_sha256
            == core._require_sha256(
                arguments.expected_video_profile_contract_file_sha256,
                "expected video-profile contract",
            ),
            "corrective contract file differs from explicit hash",
        )
        snapshots.extend(
            ((coordinate, "coordinate-model contract"), (video, "video-profile contract"))
        )
        coordinate_document = core._strict_json_object(
            coordinate.payload,
            "coordinate-model contract",
        )
        video_document = core._strict_json_object(video.payload, "video-profile contract")

        live_binding = _live_holdout_preopen_binding(arguments)
        initial_guard = core._fresh_unopened_guard(live_binding)
        bound = bind_preregistered_inputs(
            repository.path,
            live_holdout_preopen_binding=live_binding,
        )
        core._require(
            bound.live_holdout_preopen_verification == initial_guard,
            "bound live guard differs from fresh verification",
        )
        bound.verify_unchanged()
        plan_record = bound.record("calibration_plan")
        plan_path = repository.path.joinpath(
            *PurePosixPath(str(plan_record["path"])).parts
        )
        core._require(
            arguments.calibration_plan_path == plan_path,
            "explicit calibration plan path differs from bound inputs",
        )
        plan_snapshot = core._RegularSnapshot.capture(plan_path, "calibration plan")
        core._require(
            plan_snapshot.file_sha256
            == plan_record["sha256"]
            == core._require_sha256(
                arguments.expected_calibration_plan_file_sha256,
                "expected calibration plan",
            ),
            "calibration plan differs from explicit or bound hash",
        )
        snapshots.append((plan_snapshot, "calibration plan"))
        plan = bound.documents["calibration_plan"]

        native = make_native_corrective_diagnostic_capability(
            repository.path,
            cache_root=native_cache.path,
            bound_inputs=bound,
            vector=candidate_vector,
            timeout_seconds=float(arguments.timeout_seconds),
        )
        resources.append(native)
        writer = production_writer_capability(writer_root.path)
        resources.append(writer)
        runtime = core._runtime_binding(
            native=native,
            writer=writer,
            bound=bound,
            coordinate=coordinate,
            coordinate_document=coordinate_document,
            video=video,
            video_document=video_document,
        )
        sample_lock = bound.documents["development_sample_lock"]
        corpus = bound.documents["corpus_lock"]
        samples = sample_lock["samples"]
        core._require(
            isinstance(samples, list) and len(samples) == 6,
            "development sample lock does not contain exactly six samples",
        )
        bindings = {
            "repository": repository_state,
            "g04": gate_rows["g04"],
            "g05": gate_rows["g05"],
            "calibration_plan": {
                "file": plan_snapshot.binding(),
                "document_sha256": canonical_sha256(plan),
            },
            "failed_run": {
                "archive_root": failed_root.binding(),
                "attempt_ledger": ledger.binding(),
                "failure_record": failure_record.binding(),
                "input_bindings": failed_input_bindings.binding(),
                "transaction_intent": transaction_intent.binding(),
                "attempt_count": len(records),
                "tail_record_sha256": records[-1]["record_sha256"],
                **closure,
            },
            "live_holdout": core._live_binding_document(arguments, initial_guard),
            "development_corpus": {
                "open_split_root": open_split.binding(),
                "corpus_lock_file_sha256": bound.record("corpus_lock")["sha256"],
                "corpus_lock_manifest_sha256": corpus["manifest_sha256"],
                "development_sample_lock_file_sha256": bound.record(
                    "development_sample_lock"
                )["sha256"],
                "development_sample_lock_manifest_sha256": sample_lock[
                    "manifest_sha256"
                ],
                "development_sample_count": len(samples),
                "development_sample_bindings_sha256": canonical_sha256(samples),
            },
            "runtime": runtime,
            "execution_roots": {
                "run_id": arguments.run_id,
                "output_root_lexical_path": os.fspath(output),
                "output_parent": output_parent.binding(),
                "work_parent": work.binding(),
                "native_cache_root": native_cache.binding(),
                "writer_root": writer_root.binding(),
            },
        }
        preregistration = build_corrective_preregistration(
            preregistered_utc=preregistered_utc.isoformat(
                timespec="microseconds"
            ).replace("+00:00", "Z"),
            bindings=bindings,
            candidate_vector=candidate_vector,
            plan=plan,
            attempt_ledger_payload=ledger.payload,
            expected_source_sequence=arguments.expected_source_sequence,
            expected_source_record_sha256=arguments.expected_source_record_sha256,
            expected_source_candidate_vector_sha256=(
                arguments.expected_source_candidate_vector_sha256
            ),
            expected_carry_forward_sequence=(
                arguments.expected_carry_forward_sequence
            ),
            expected_carry_forward_record_sha256=(
                arguments.expected_carry_forward_record_sha256
            ),
        )
        for pin in pins:
            pin.verify()
        for snapshot, label in snapshots:
            snapshot.verify(label)
        bound.verify_unchanged()
        core._require(
            core._fresh_unopened_guard(live_binding) == initial_guard,
            "live guard changed before preregistration publication",
        )
        payload = canonical_artifact_file_bytes(preregistration)
        core._write_new_file_at(
            preregistration_parent.descriptor,
            preregistration_path.name,
            payload,
        )
        os.fsync(preregistration_parent.descriptor)
        preregistration_written = True
        reopened = core._RegularSnapshot.capture(
            preregistration_path,
            "published preregistration",
        )
        published_snapshot = reopened
        validate_corrective_preregistration(
            preregistration,
            artifact_payload=reopened.payload,
            expected_artifact_file_sha256=reopened.file_sha256,
            expected_bindings=bindings,
            plan=plan,
            attempt_ledger_payload=ledger.payload,
            expected_source_sequence=arguments.expected_source_sequence,
            expected_source_record_sha256=arguments.expected_source_record_sha256,
            expected_source_candidate_vector_sha256=(
                arguments.expected_source_candidate_vector_sha256
            ),
            expected_carry_forward_sequence=(
                arguments.expected_carry_forward_sequence
            ),
            expected_carry_forward_record_sha256=(
                arguments.expected_carry_forward_record_sha256
            ),
            execution_not_before_utc=preregistered_utc,
        )
        for snapshot, label in snapshots:
            snapshot.verify(label)
        bound.verify_unchanged()
        core._require(
            core._fresh_unopened_guard(live_binding) == initial_guard,
            "live guard changed during no-pixel preregistration",
        )
        result = {
            "schema_version": "1.0.0",
            "status": "corrective_diagnostics_preregistered",
            "preregistration_path": os.fspath(preregistration_path),
            "preregistration_file_sha256": reopened.file_sha256,
            "preregistration_sha256": preregistration["artifact_sha256"],
            "validation_accessed": False,
            "holdout_accessed": False,
            "development_pixels_accessed": False,
        }
    except BaseException as error:
        primary = error
        primary_traceback = error.__traceback__
    finally:
        if live_binding is not None and initial_guard is not None:
            try:
                core._require(
                    core._fresh_unopened_guard(live_binding) == initial_guard,
                    "live guard changed while closing preregistration",
                )
            except BaseException as guard_error:
                if primary is None:
                    primary = guard_error
                    primary_traceback = guard_error.__traceback__
                else:
                    core._attach_secondary(primary, "final_guard_error", guard_error)
        try:
            core._close_resources(resources)
        except BaseException as cleanup_error:
            if primary is None:
                primary = cleanup_error
                primary_traceback = cleanup_error.__traceback__
            else:
                core._attach_secondary(primary, "cleanup_error", cleanup_error)
        if live_binding is not None and initial_guard is not None:
            try:
                core._require(
                    core._fresh_unopened_guard(live_binding) == initial_guard,
                    "live guard changed after preregistration cleanup",
                )
            except BaseException as guard_error:
                if primary is None:
                    primary = guard_error
                    primary_traceback = guard_error.__traceback__
                else:
                    core._attach_secondary(
                        primary,
                        "post_cleanup_guard_error",
                        guard_error,
                    )
        for pin in pins:
            try:
                pin.verify()
            except BaseException as pin_verify_error:
                if primary is None:
                    primary = pin_verify_error
                    primary_traceback = pin_verify_error.__traceback__
                else:
                    core._attach_secondary(
                        primary,
                        "pin_verify_error",
                        pin_verify_error,
                    )
        if published_snapshot is not None:
            try:
                published_snapshot.verify("published preregistration")
            except BaseException as published_verify_error:
                if primary is None:
                    primary = published_verify_error
                    primary_traceback = published_verify_error.__traceback__
                else:
                    core._attach_secondary(
                        primary,
                        "published_verify_error",
                        published_verify_error,
                    )
        for pin in reversed(pins):
            try:
                pin.close()
            except BaseException as pin_error:
                if primary is None:
                    primary = pin_error
                    primary_traceback = pin_error.__traceback__
                else:
                    core._attach_secondary(primary, "pin_close_error", pin_error)
        if primary is not None and preregistration_written and os.path.lexists(
            preregistration_path
        ):
            try:
                quarantine = _quarantine_preregistration(
                    preregistration_path,
                    primary,
                    published_snapshot,
                )
                setattr(primary, "untrusted_quarantine_path", quarantine)
            except BaseException as quarantine_error:
                core._attach_secondary(primary, "quarantine_error", quarantine_error)
    if primary is not None:
        raise primary.with_traceback(primary_traceback)
    assert result is not None
    return result


def main() -> int:
    result = _execute(
        _arguments(),
        preregistered_utc=datetime.now(timezone.utc),
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


if __name__ == "__main__":
    raise SystemExit(main())
