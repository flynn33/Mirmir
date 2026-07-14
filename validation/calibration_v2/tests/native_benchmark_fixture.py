"""Schema-valid native aggregate benchmark unit fixtures."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
from typing import Dict, Mapping
from unittest import mock

from validation.calibration_v2.tools import (
    finalize_p06_runtime_correction as runtime_finalizer,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
BENCHMARK_SCHEMA_RELATIVE_PATH = (
    "validation/calibration_v2/schemas/"
    "control-aggregate-cache-native-benchmark-v1.schema.json"
)
BENCHMARK_SCHEMA_PATH = REPOSITORY_ROOT / BENCHMARK_SCHEMA_RELATIVE_PATH
BENCHMARK_TEMPLATE_PATH = (
    Path(__file__).with_name(
        "control_aggregate_cache_native_benchmark_fixture_v1.json"
    )
)
RUNTIME_MANIFEST_KIND = (
    "p06_runtime_feasibility_correction_artifact_manifest"
)
FINAL_BUNDLE_REQUIRED_BINDING = (
    "the immutable correction-r2 artifact manifest must bind this benchmark's "
    "final SHA-256 and size under the same run_id"
)
FINAL_BUNDLE_FINALIZER = (
    "validation/calibration_v2/tools/finalize_p06_runtime_correction.py"
)
FIXTURE_STARTED_UTC = "2026-07-11T00:00:00Z"
FIXTURE_FINISHED_UTC = "2026-07-11T00:00:01Z"
FIXTURE_OUTPUT_TEMPORARY_PATH = (
    ".native-aggregate-benchmark.json."
    "00000000000000000000000000000000.tmp"
)


def build_native_benchmark_fixture(
    *,
    project_commit: str,
    run_id: str,
) -> Dict[str, object]:
    """Return a deterministic schema-valid benchmark bound to one test run."""

    if re.fullmatch(r"[0-9a-f]{40}", project_commit) is None:
        raise ValueError("fixture project commit is not a lowercase Git SHA-1")
    if re.fullmatch(r"[0-9a-f-]{36}", run_id) is None:
        raise ValueError("fixture run ID does not match the benchmark UUID form")

    document = json.loads(BENCHMARK_TEMPLATE_PATH.read_bytes())
    if not isinstance(document, dict):
        raise ValueError("native benchmark fixture template is not an object")

    schema_payload = BENCHMARK_SCHEMA_PATH.read_bytes()
    document["schema_binding"] = {
        "path": BENCHMARK_SCHEMA_RELATIVE_PATH,
        "sha256": hashlib.sha256(schema_payload).hexdigest(),
        "size_bytes": len(schema_payload),
    }
    document["run_identity"] = {
        "run_id": run_id,
        "started_utc": FIXTURE_STARTED_UTC,
        "finished_utc": FIXTURE_FINISHED_UTC,
        "repository_state": {
            "head_commit": project_commit,
            "is_dirty": False,
            "binding_algorithm": (
                "unit fixture with empty tracked state and no non-Artifact "
                "untracked files"
            ),
            "untracked_artifact_exclusion": "Artifacts/**",
            "tracked_porcelain_v1_z_sha256": hashlib.sha256(b"").hexdigest(),
            "tracked_porcelain_v1_z_size_bytes": 0,
            "non_artifact_untracked_files": [],
            "non_artifact_untracked_files_sha256": canonical_sha256([]),
            "tracked_binary_diff_sha256": hashlib.sha256(b"").hexdigest(),
            "tracked_binary_diff_size_bytes": 0,
        },
        "output_recovery_actions": [],
        "output_publication_temporary_path": FIXTURE_OUTPUT_TEMPORARY_PATH,
        "final_bundle_linkage": {
            "required_artifact_manifest_kind": RUNTIME_MANIFEST_KIND,
            "required_manifest_run_id": run_id,
            "required_binding": FINAL_BUNDLE_REQUIRED_BINDING,
            "finalizer": FINAL_BUNDLE_FINALIZER,
        },
    }
    document.pop("evidence_sha256", None)
    document["evidence_sha256"] = canonical_sha256(document)
    validate_schema(document, BENCHMARK_SCHEMA_PATH)
    return document


def native_benchmark_fixture_payload(
    *,
    project_commit: str,
    run_id: str,
) -> bytes:
    """Return canonical fixture bytes with the publication newline."""

    return canonical_json_bytes(
        build_native_benchmark_fixture(
            project_commit=project_commit,
            run_id=run_id,
        )
    ) + b"\n"


def create_frozen_runtime_fixture(
    parent: Path,
    *,
    repository_root: Path,
    repository_state: Mapping[str, object],
) -> tuple[Path, str, bytes]:
    """Finalize one immutable runtime input for G06 unit tests."""

    partial = parent / ".runtime-fixture.partial"
    final = parent / "runtime-fixture"
    partial.mkdir()
    run_id = "123e4567-e89b-42d3-a456-426614174000"
    benchmark_payload = native_benchmark_fixture_payload(
        project_commit=str(repository_state["project_commit"]),
        run_id=run_id,
    )
    (partial / "native-aggregate-benchmark.json").write_bytes(
        benchmark_payload
    )
    records = {
        "schema_version": "1.0.0",
        "artifact_kind": (
            "p06_runtime_feasibility_correction_artifact_metadata"
        ),
        "records": [
            {
                "path": path,
                "producer": (
                    "pytest native aggregate benchmark"
                    if path == "native-aggregate-benchmark.json"
                    else "Mirmir P06 verification harness"
                ),
                "command": "python3 -m pytest native-benchmark",
                "platform": "macOS arm64",
                "gate_ids": ["P06", "G06"],
            }
            for path in (
                "artifact-records.json",
                "native-aggregate-benchmark.json",
            )
        ],
    }
    metadata_path = partial / "artifact-records.json"
    metadata_path.write_bytes(canonical_json_bytes(records) + b"\n")
    with mock.patch.object(
        runtime_finalizer,
        "_repository_state",
        return_value=(dict(repository_state), True),
    ):
        runtime_finalizer.finalize_runtime_correction(
            partial=partial,
            final=final,
            metadata_path=metadata_path,
            run_id=run_id,
            run_uuid=run_id,
            started_utc=FIXTURE_STARTED_UTC,
            finished_utc=FIXTURE_FINISHED_UTC,
            root_label=final.relative_to(repository_root).as_posix(),
        )
    manifest_payload = (final / "artifact-manifest.json").read_bytes()
    return (
        final,
        hashlib.sha256(manifest_payload).hexdigest(),
        benchmark_payload,
    )


def thaw_and_remove_runtime_fixture(root: Path) -> None:
    """Remove a finalized runtime fixture after restoring write access."""

    if not root.exists():
        return
    paths = [*root.rglob("*"), root]
    for path in reversed(paths):
        if path.is_symlink():
            continue
        if hasattr(os, "chflags") and hasattr(stat, "UF_IMMUTABLE"):
            try:
                flags = os.stat(path, follow_symlinks=False).st_flags
                os.chflags(
                    path,
                    flags & ~stat.UF_IMMUTABLE,
                    follow_symlinks=False,
                )
            except OSError:
                pass
        try:
            os.chmod(path, 0o755 if path.is_dir() else 0o644)
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)
