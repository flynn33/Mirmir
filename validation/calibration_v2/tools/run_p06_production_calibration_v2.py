#!/usr/bin/env python3
"""Retired P06 V2 production-calibration command and retained helpers."""

from __future__ import annotations

if __name__ == "__main__":
    raise SystemExit(2)

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import stat
import sys
from typing import Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.calibration_selection_persistence_v2 import (  # noqa: E402
    CalibrationSelectionPersistenceAdapterV2,
)
from validation.calibration_v2.current_source_gate_closure_v2 import (  # noqa: E402
    current_source_git_identity_v2,
    reopen_and_stage_current_source_gates_v2,
)
from validation.calibration_v2.production_candidate_provider_v2 import (  # noqa: E402
    production_candidate_evaluation_provider_v2,
)
from validation.calibration_v2.production_coordinator_v2 import (  # noqa: E402
    P06ProductionCoordinatorV2,
    RunArtifactProvenanceV2,
)
from validation.calibration_v2.production_factory import (  # noqa: E402
    make_production_calibration_assembly_from_bound_inputs,
)
from validation.calibration_v2.production_native_candidate_source_v2 import (  # noqa: E402
    production_apple_native_candidate_measurement_source_v2,
)
from validation.calibration_v2.production_release_resources_v3 import (  # noqa: E402
    export_p08_release_resources_v3,
)
from validation.calibration_v2.production_release_v3 import (  # noqa: E402
    build_p06_release_transaction_v3,
)
from validation.calibration_v2.runner import (  # noqa: E402
    LiveHoldoutPreopenBinding,
    bind_preregistered_inputs_v2,
)


def _read_regular(path: Path) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise ValueError(f"required anchor file is absent: {path}") from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        raise ValueError(f"required anchor path is not a singular regular file: {path}")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError("anchor file changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    ):
        raise ValueError("anchor file changed while reading")
    return b"".join(chunks)


def _require_sha256(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ValueError(f"{label} must be one lowercase SHA-256")
    return value


def _reject_duplicate_pairs(
    pairs: Sequence[tuple[str, object]],
) -> Mapping[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"live preopen receipt has duplicate key: {key}")
        result[key] = value
    return result


def _receipt(path: Path) -> tuple[Mapping[str, object], str]:
    payload = _read_regular(path)
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                ValueError(f"live preopen receipt has non-finite value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("live preopen receipt is invalid JSON") from error
    if not isinstance(value, dict):
        raise ValueError("live preopen receipt is not an object")
    for field in (
        "live_ledger_root_identity_sha256",
        "live_anchor_root_identity_sha256",
        "repository_sealed_copy_sha256",
        "repository_attestation_sha256",
    ):
        _require_sha256(value.get(field), f"live preopen receipt {field}")
    return value, hashlib.sha256(payload).hexdigest()


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Freshly reopen G04/G05/G06, execute the concrete Apple-native "
            "schema-2 P06 calibration, atomically publish the 23-role schema-3 "
            "release over exact selected-candidate bytes, fully replay all six "
            "support roots, and export the exact six P08 files."
        )
    )
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--open-split-root", required=True, type=Path)
    parser.add_argument("--calibration-output-root", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--release-root", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--native-cache-root", required=True, type=Path)
    parser.add_argument("--writer-root", required=True, type=Path)
    parser.add_argument("--dispatch-measurement-root", required=True, type=Path)
    parser.add_argument("--p08-resource-root", required=True, type=Path)
    parser.add_argument("--p08-resource-receipt", required=True, type=Path)
    parser.add_argument("--g04-root", required=True, type=Path)
    parser.add_argument("--g05-root", required=True, type=Path)
    parser.add_argument("--g05-instruction-package-root", required=True, type=Path)
    parser.add_argument("--g05-baseline-commit", required=True)
    parser.add_argument("--g06-root", required=True, type=Path)
    parser.add_argument("--g06-execution-run-name", required=True)
    parser.add_argument("--locked-utc")
    parser.add_argument("--live-ledger-path", required=True, type=Path)
    parser.add_argument("--live-anchor-path", required=True, type=Path)
    parser.add_argument("--live-preopen-receipt-path", required=True, type=Path)
    parser.add_argument(
        "--expected-live-ledger-root-identity-sha256",
        required=True,
    )
    parser.add_argument(
        "--expected-live-anchor-root-identity-sha256",
        required=True,
    )
    parser.add_argument(
        "--expected-live-preopen-receipt-sha256",
        required=True,
    )
    parser.add_argument("--repository-sealed-copy-path", required=True, type=Path)
    parser.add_argument(
        "--expected-repository-sealed-copy-sha256",
        required=True,
    )
    parser.add_argument("--repository-attestation-path", required=True, type=Path)
    parser.add_argument(
        "--expected-repository-attestation-sha256",
        required=True,
    )
    parser.add_argument("--timeout-seconds", type=float, default=900.0)
    return parser.parse_args()


def _live_holdout_preopen_binding(
    arguments: argparse.Namespace,
) -> LiveHoldoutPreopenBinding:
    expected = {
        "live_ledger_root_identity_sha256": _require_sha256(
            arguments.expected_live_ledger_root_identity_sha256,
            "expected live ledger-root identity",
        ),
        "live_anchor_root_identity_sha256": _require_sha256(
            arguments.expected_live_anchor_root_identity_sha256,
            "expected live anchor-root identity",
        ),
        "live_preopen_receipt_sha256": _require_sha256(
            arguments.expected_live_preopen_receipt_sha256,
            "expected live preopen receipt file hash",
        ),
        "repository_sealed_copy_sha256": _require_sha256(
            arguments.expected_repository_sealed_copy_sha256,
            "expected repository sealed-copy hash",
        ),
        "repository_attestation_sha256": _require_sha256(
            arguments.expected_repository_attestation_sha256,
            "expected repository attestation hash",
        ),
    }
    receipt, receipt_sha256 = _receipt(arguments.live_preopen_receipt_path)
    if receipt_sha256 != expected["live_preopen_receipt_sha256"]:
        raise ValueError("live preopen receipt differs from its explicit hash")
    for field in (
        "live_ledger_root_identity_sha256",
        "live_anchor_root_identity_sha256",
        "repository_sealed_copy_sha256",
        "repository_attestation_sha256",
    ):
        if receipt.get(field) != expected[field]:
            raise ValueError(
                f"live preopen receipt differs from explicit anchor: {field}"
            )
    if hashlib.sha256(_read_regular(arguments.repository_sealed_copy_path)).hexdigest() \
            != expected["repository_sealed_copy_sha256"]:
        raise ValueError("repository sealed copy differs from its explicit hash")
    if hashlib.sha256(_read_regular(arguments.repository_attestation_path)).hexdigest() \
            != expected["repository_attestation_sha256"]:
        raise ValueError("repository attestation differs from its explicit hash")
    return LiveHoldoutPreopenBinding(
        live_ledger_path=arguments.live_ledger_path,
        live_anchor_path=arguments.live_anchor_path,
        live_preopen_receipt_path=arguments.live_preopen_receipt_path,
        expected_live_ledger_root_identity_sha256=expected[
            "live_ledger_root_identity_sha256"
        ],
        expected_live_anchor_root_identity_sha256=expected[
            "live_anchor_root_identity_sha256"
        ],
        expected_live_preopen_receipt_sha256=expected[
            "live_preopen_receipt_sha256"
        ],
        repository_sealed_copy_path=arguments.repository_sealed_copy_path,
        expected_repository_sealed_copy_sha256=expected[
            "repository_sealed_copy_sha256"
        ],
        repository_attestation_path=arguments.repository_attestation_path,
        expected_repository_attestation_sha256=expected[
            "repository_attestation_sha256"
        ],
    )


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00",
        "Z",
    )


def main() -> int:
    """Reject the retired authorization path without parsing or file access."""

    return 2

    arguments = _arguments()
    if not arguments.run_id or "/" in arguments.run_id or arguments.run_id in {".", ".."}:
        raise ValueError("run ID is unsafe")
    live_binding = _live_holdout_preopen_binding(arguments)
    artifact_root = arguments.calibration_output_root / arguments.run_id
    source_gates = reopen_and_stage_current_source_gates_v2(
        repository_root=arguments.repository_root,
        artifact_root=artifact_root,
        g04_root=arguments.g04_root,
        g05_root=arguments.g05_root,
        g05_instruction_package_root=arguments.g05_instruction_package_root,
        g05_baseline_commit=arguments.g05_baseline_commit,
        g06_root=arguments.g06_root,
        g06_execution_run_name=arguments.g06_execution_run_name,
    )
    project_commit, repository_status = current_source_git_identity_v2(
        arguments.repository_root
    )
    if repository_status:
        raise ValueError("repository changed after current-source gate reopening")
    native_bound, evaluation_bound = bind_preregistered_inputs_v2(
        arguments.repository_root,
        live_holdout_preopen_binding=live_binding,
    )
    assembly = make_production_calibration_assembly_from_bound_inputs(
        repository_root=arguments.repository_root,
        bound_inputs=native_bound,
        evidence_root=arguments.evidence_root,
        native_cache_root=arguments.native_cache_root,
        writer_root=arguments.writer_root,
        dispatch_measurement_root=arguments.dispatch_measurement_root,
        timeout_seconds=arguments.timeout_seconds,
    )
    authority = CalibrationSelectionPersistenceAdapterV2(artifact_root)
    plan = authority.plan
    non_ash_profile = authority.calibration.non_ash_profile
    source = production_apple_native_candidate_measurement_source_v2(
        assembly=assembly,
        open_split_root=arguments.open_split_root,
        artifact_root=artifact_root,
        evaluation_bound_inputs=evaluation_bound,
        plan=plan,
        non_ash_profile=non_ash_profile,
    )
    provider = production_candidate_evaluation_provider_v2(
        measurement_source=source,
        native_factory=assembly.adapter_factory,
        metric_tolerances=evaluation_bound.documents[
            "metric_performance_tolerances"
        ],
        source_gates=source_gates,
        artifact_root=artifact_root,
        plan=plan,
    )
    provenance = RunArtifactProvenanceV2(
        created_utc=_utc_now(),
        project_commit=project_commit,
        producer=(
            "validation.calibration_v2.tools."
            "run_p06_production_calibration_v2"
        ),
        command=shlex.join(sys.argv),
        platform=platform.platform(),
        machine=platform.machine(),
    )
    coordinator = P06ProductionCoordinatorV2(
        artifact_root=artifact_root,
        run_id=arguments.run_id,
        provider=provider,
        provenance=provenance,
        _control_producer_capability_provider=(
            provider.control_producer_capabilities
        ),
    )
    result = coordinator.run()
    locked_utc = arguments.locked_utc or _utc_now()
    bundle = build_p06_release_transaction_v3(
        repository_root=arguments.repository_root,
        calibration_run_root=artifact_root,
        release_root=arguments.release_root,
        native_cache_root=arguments.native_cache_root,
        open_split_root=arguments.open_split_root,
        evidence_root=arguments.evidence_root,
        writer_root=arguments.writer_root,
        dispatch_measurement_root=arguments.dispatch_measurement_root,
        locked_utc=locked_utc,
        bound_inputs=native_bound,
        assembly=assembly,
        run_result=result,
        source_gates=source_gates,
        provenance=provenance,
    )
    export_receipt = export_p08_release_resources_v3(
        release_root=arguments.release_root,
        resource_root=arguments.p08_resource_root,
        receipt_path=arguments.p08_resource_receipt,
        support_evidence_roots={
            "open_split": arguments.open_split_root,
            "calibration_evidence": arguments.evidence_root.parent,
            "native_cache": arguments.native_cache_root.parent,
            "production_writer": arguments.writer_root.parent,
            "dispatch_measurement": arguments.dispatch_measurement_root.parent,
            "calibration_run": artifact_root.parent,
        },
    )
    print(
        json.dumps(
            {
                "schema_version": "2.0.0",
                "status": "p06_v3_release_locked_and_p08_resources_exported",
                "calibration_run_root": os.fspath(artifact_root.resolve(strict=True)),
                "release_root": os.fspath(arguments.release_root.resolve(strict=True)),
                "p08_resource_root": os.fspath(
                    arguments.p08_resource_root.resolve(strict=True)
                ),
                "configuration_id": bundle["configuration_id"],
                "release_bundle_artifact_sha256": bundle["artifact_sha256"],
                "p08_resource_set_sha256": export_receipt[
                    "resource_set_sha256"
                ],
                "holdout_accessed": False,
            },
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
