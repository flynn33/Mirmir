#!/usr/bin/env python3
"""Build a bounded, integrity-checked diagnostic from a live P06 ledger."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import sqlite3
import stat
import subprocess
import sys
import time
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = "1.0.0"
ARTIFACT_KIND = "p06_failure_pattern_analysis"
ZERO_HASH = "0" * 64
CORE_NINE = (
    "check:analysis_grid_route_quality",
    "container_decoded:bootstrap:y_vs_conventional",
    "container_decoded:bootstrap:y_vs_fixed",
    "container_decoded:bootstrap:y_vs_non_ash",
    "container_decoded:chroma_displacement",
    "engine_raw:bootstrap:y_vs_conventional",
    "engine_raw:bootstrap:y_vs_fixed",
    "engine_raw:bootstrap:y_vs_non_ash",
    "engine_raw:chroma_displacement",
)
DOMAINS = ("engine_raw", "container_decoded")
BOOTSTRAP_NAMES = ("y_vs_fixed", "y_vs_non_ash", "y_vs_conventional")
EVALUATED_STATUSES = ("feasible", "infeasible")
PLAN_SOURCE_PATH = "validation/calibration_v2/contracts/calibration-plan-v1.json"
TOLERANCE_SOURCE_PATH = (
    "validation/calibration_v2/contracts/metric-performance-tolerances-v1.json"
)
SQL_SOURCE_PATH = "analysis/ash-failure-patterns/queries/p06_failure_analysis.sql"
CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH = (
    "validation/calibration_v2/contracts/candidate-evidence-policy-v1.json"
)
CORRECTIVE_SOURCE_PATH = "validation/calibration_v2/corrective_preregistration.py"
RUNNER_SOURCE_PATH = "validation/calibration_v2/runner.py"
BOUND_RUN_SOURCE_PATHS = {
    CORRECTIVE_SOURCE_PATH,
    RUNNER_SOURCE_PATH,
    PLAN_SOURCE_PATH,
    TOLERANCE_SOURCE_PATH,
    CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH,
}
ANALYSIS_SOURCE_PATHS = (
    "analysis/ash-failure-patterns/analyze_p06_failures.py",
    "analysis/ash-failure-patterns/build_p06_failure_report.py",
    "analysis/ash-failure-patterns/code-path-map.md",
    SQL_SOURCE_PATH,
    "analysis/ash-failure-patterns/README.md",
    "analysis/ash-failure-patterns/test_failure_analysis.py",
    CORRECTIVE_SOURCE_PATH,
    RUNNER_SOURCE_PATH,
    PLAN_SOURCE_PATH,
    TOLERANCE_SOURCE_PATH,
    CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH,
)


class AnalysisError(ValueError):
    """Raised when the bounded source window is not independently valid."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise AnalysisError(message)


def _canonical_json_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _git_head(repository_root: Path) -> str:
    try:
        value = subprocess.check_output(
            ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise AnalysisError(f"cannot resolve repository HEAD: {repository_root}") from error
    _require(
        len(value) == 40
        and value == value.lower()
        and all(character in "0123456789abcdef" for character in value),
        f"repository HEAD is invalid: {repository_root}",
    )
    return value


def _self_hash(document: Mapping[str, object]) -> str:
    unhashed = dict(document)
    unhashed.pop("analysis_sha256", None)
    return _sha256(_canonical_json_bytes(unhashed))


def _metadata_identity(metadata: os.stat_result) -> tuple[int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
    )


def stable_read_regular_file(
    path: Path,
    *,
    attempts: int = 8,
    retry_delay_seconds: float = 0.05,
) -> tuple[bytes, os.stat_result]:
    """Read one unchanged regular-file inode without following symbolic links."""

    _require(attempts > 0, "stable read attempt count must be positive")
    for attempt in range(attempts):
        before = os.stat(path, follow_symlinks=False)
        _require(
            stat.S_ISREG(before.st_mode) and not path.is_symlink(),
            f"source is symbolic or not a regular file: {path}",
        )
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            _require(
                (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
                f"source inode changed while opening: {path}",
            )
            chunks: list[bytes] = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            after_read = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        after_path = os.stat(path, follow_symlinks=False)
        if (
            _metadata_identity(before)
            == _metadata_identity(opened)
            == _metadata_identity(after_read)
            == _metadata_identity(after_path)
        ):
            return b"".join(chunks), before
        if attempt + 1 < attempts:
            time.sleep(retry_delay_seconds)
    raise AnalysisError(f"source did not remain stable while reading: {path}")


def _safe_relative_path(value: object, required_parent: str) -> PurePosixPath:
    _require(isinstance(value, str) and bool(value), "artifact path is absent")
    path = PurePosixPath(value)
    _require(
        not path.is_absolute()
        and path.as_posix() == value
        and all(part not in {"", ".", ".."} for part in path.parts)
        and bool(path.parts)
        and path.parts[0] == required_parent,
        f"artifact path is outside {required_parent}: {value!r}",
    )
    return path


def _artifact_source_identity(path: Path) -> str:
    """Return the canonical project-relative identity for an Artifacts path."""

    parts = path.parts
    indices = [index for index, part in enumerate(parts) if part == "Artifacts"]
    _require(bool(indices), "live evidence path has no Artifacts project boundary")
    relative = PurePosixPath(*parts[indices[-1] :])
    _require(
        all(part not in {"", ".", ".."} for part in relative.parts),
        "live evidence identity is not normalized",
    )
    return relative.as_posix()


def _named_queries_from_bytes(payload: bytes) -> Mapping[str, str]:
    """Parse SQL sections introduced by exact ``-- name: identifier`` markers."""

    sections: dict[str, list[str]] = {}
    current: str | None = None
    for raw_line in payload.decode("utf-8").splitlines():
        if raw_line.startswith("-- name: "):
            name = raw_line.removeprefix("-- name: ").strip()
            _require(name and name.replace("_", "").isalnum(), "invalid SQL query name")
            _require(name not in sections, f"duplicate SQL query name: {name}")
            current = name
            sections[current] = []
            continue
        if current is not None:
            sections[current].append(raw_line)
    queries = {name: "\n".join(lines).strip() for name, lines in sections.items()}
    _require(bool(queries), "SQL source contains no named queries")
    _require(all(query.endswith(";") for query in queries.values()), "SQL query lacks semicolon")
    return queries


def load_named_queries(path: Path) -> Mapping[str, str]:
    """Load named SQL queries from one stable regular-file snapshot."""

    payload, _ = stable_read_regular_file(path)
    return _named_queries_from_bytes(payload)


def _query_rows(connection: sqlite3.Connection, query: str) -> list[dict[str, object]]:
    cursor = connection.execute(query)
    columns = [str(item[0]) for item in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def _pearson(left: Sequence[object], right: Sequence[object]) -> float:
    _require(len(left) == len(right) and len(left) >= 2, "correlation inputs differ")
    x = [_json_number(value, "correlation value") for value in left]
    y = [_json_number(value, "correlation value") for value in right]
    x_mean = sum(x) / len(x)
    y_mean = sum(y) / len(y)
    numerator = sum((a - x_mean) * (b - y_mean) for a, b in zip(x, y))
    x_scale = math.sqrt(sum((value - x_mean) ** 2 for value in x))
    y_scale = math.sqrt(sum((value - y_mean) ** 2 for value in y))
    _require(x_scale > 0.0 and y_scale > 0.0, "correlation input is constant")
    return numerator / (x_scale * y_scale)


def _json_number(value: object, description: str) -> float:
    _require(
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value)),
        f"{description} is not finite",
    )
    return float(value)


def _artifact_binding(
    path: Path,
    declared: Mapping[str, object],
) -> tuple[bytes, os.stat_result]:
    payload, metadata = stable_read_regular_file(path)
    _require(
        declared.get("size_bytes") == len(payload),
        f"artifact size differs: {path}",
    )
    _require(
        declared.get("sha256") == _sha256(payload),
        f"artifact hash differs: {path}",
    )
    return payload, metadata


def _create_connection() -> sqlite3.Connection:
    connection = sqlite3.connect(":memory:")
    connection.executescript(
        """
        PRAGMA trusted_schema = OFF;
        CREATE TABLE attempts (
            sequence INTEGER PRIMARY KEY,
            sweep INTEGER NOT NULL,
            phase TEXT NOT NULL,
            coordinate TEXT,
            value_text TEXT,
            status TEXT NOT NULL,
            cache_hit INTEGER NOT NULL,
            canonical_failure_count INTEGER,
            core_nine INTEGER NOT NULL,
            failure_signature TEXT,
            evaluation_sha256 TEXT
        );
        CREATE TABLE failures (
            sequence INTEGER NOT NULL,
            reason TEXT NOT NULL,
            PRIMARY KEY (sequence, reason)
        );
        CREATE TABLE metrics (
            sequence INTEGER NOT NULL,
            domain TEXT NOT NULL,
            metric TEXT NOT NULL,
            value REAL NOT NULL,
            threshold REAL NOT NULL,
            direction TEXT NOT NULL,
            unit TEXT NOT NULL,
            PRIMARY KEY (sequence, domain, metric)
        );
        CREATE TABLE route_predicates (
            sequence INTEGER NOT NULL,
            route TEXT NOT NULL,
            predicate TEXT NOT NULL,
            value REAL NOT NULL,
            threshold REAL NOT NULL,
            direction TEXT NOT NULL,
            unit TEXT NOT NULL,
            passed INTEGER NOT NULL,
            PRIMARY KEY (sequence, route, predicate)
        );
        CREATE TABLE state_observations (
            sequence INTEGER NOT NULL,
            route TEXT NOT NULL,
            coordinate INTEGER NOT NULL,
            one_count INTEGER NOT NULL,
            zero_count INTEGER NOT NULL,
            PRIMARY KEY (sequence, route, coordinate)
        );
        CREATE TABLE attempt_errors (
            sequence INTEGER NOT NULL,
            error TEXT NOT NULL,
            PRIMARY KEY (sequence, error)
        );
        """
    )
    return connection


def _insert_metric(
    connection: sqlite3.Connection,
    *,
    sequence: int,
    domain: str,
    metric: str,
    value: object,
    threshold: object,
    direction: str,
    unit: str,
) -> None:
    connection.execute(
        "INSERT INTO metrics VALUES (?, ?, ?, ?, ?, ?, ?)",
        (
            sequence,
            domain,
            metric,
            _json_number(value, metric),
            _json_number(threshold, f"{metric} threshold"),
            direction,
            unit,
        ),
    )


def _route_predicate_rows(
    route_record: Mapping[str, object],
    quality: Mapping[str, object],
) -> Iterable[tuple[str, float, float, str, str, bool]]:
    route = str(route_record["target_route"])
    per_source = route_record["per_source_engine_raw_y_psnr_delta_vs_conventional"]
    _require(isinstance(per_source, list) and bool(per_source), "route per-source rows are absent")
    minimum_y = min(
        _json_number(row["delta_db"], "route per-source Y delta")
        for row in per_source
        if isinstance(row, dict)
    )
    severe = quality["severe_regression"]
    ringing = quality["ringing"]
    alias = quality["alias"]
    chroma = quality["chroma_displacement"]
    definitions = (
        (
            "minimum_per_source_y_psnr_delta_db",
            minimum_y,
            float(severe["per_asset_y_psnr_delta_db_minimum"]),
            "greater_than_or_equal",
            "dB",
        ),
        (
            "maximum_ringing_excursion",
            float(route_record["maximum_ringing_excursion"]),
            float(ringing["absolute_overshoot_maximum"]),
            "less_than_or_equal",
            "ratio",
        ),
        (
            "maximum_ringing_increase",
            float(route_record["maximum_ringing_increase"]),
            float(ringing["increase_over_best_conventional_maximum"]),
            "less_than_or_equal",
            "ratio",
        ),
        (
            "maximum_alias_ratio",
            float(route_record["maximum_alias_ratio"]),
            float(alias["forbidden_band_energy_ratio_maximum"]),
            "less_than_or_equal",
            "ratio",
        ),
        (
            "maximum_alias_increase",
            float(route_record["maximum_alias_increase"]),
            float(alias["increase_over_best_conventional_maximum"]),
            "less_than_or_equal",
            "ratio",
        ),
        (
            "maximum_chroma_displacement_pixels",
            float(route_record["maximum_chroma_displacement_pixels"]),
            float(chroma["absolute_pixels_maximum"]),
            "less_than_or_equal",
            "pixels",
        ),
        (
            "maximum_chroma_displacement_increase_pixels",
            float(route_record["maximum_chroma_displacement_increase_pixels"]),
            float(chroma["increase_over_best_conventional_pixels_maximum"]),
            "less_than_or_equal",
            "pixels",
        ),
    )
    for predicate, value, threshold, direction, unit in definitions:
        passed = value >= threshold if direction == "greater_than_or_equal" else value <= threshold
        yield route, value, threshold, direction, unit, passed


def _read_source_snapshot(
    repository_root: Path,
    bound_repository_root: Path,
) -> tuple[dict[str, bytes], list[dict[str, object]]]:
    """Capture every analysis source once and derive hashes from those exact bytes."""

    payloads: dict[str, bytes] = {}
    rows: list[dict[str, object]] = []
    for relative in ANALYSIS_SOURCE_PATHS:
        repository_role = (
            "bound_run" if relative in BOUND_RUN_SOURCE_PATHS else "analysis"
        )
        root = bound_repository_root if repository_role == "bound_run" else repository_root
        payload, _ = stable_read_regular_file(root / relative)
        payloads[relative] = payload
        rows.append(
            {
                "path": relative,
                "repository_role": repository_role,
                "sha256": _sha256(payload),
                "size_bytes": len(payload),
            }
        )
    return payloads, rows


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and value == value.lower()
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_input_bindings_document(
    input_bindings: object,
    source_payloads: Mapping[str, bytes],
) -> Mapping[str, object]:
    """Validate the run bundle and the exact policy bytes consumed by this analysis."""

    _require(isinstance(input_bindings, dict), "input bindings are not an object")
    _require(
        set(input_bindings)
        == {"bundle_sha256", "records", "live_holdout_preopen_verification"},
        "input binding fields differ",
    )
    records = input_bindings["records"]
    live_verification = input_bindings["live_holdout_preopen_verification"]
    _require(isinstance(records, list) and bool(records), "input binding records are absent")
    _require(isinstance(live_verification, dict), "live holdout verification is absent")
    seen_ids: set[str] = set()
    seen_paths: set[str] = set()
    records_by_id: dict[str, Mapping[str, object]] = {}
    for raw_record in records:
        _require(isinstance(raw_record, dict), "input binding record is not an object")
        _require(
            set(raw_record) == {"id", "path", "sha256", "size_bytes"},
            "input binding record fields differ",
        )
        identifier = raw_record["id"]
        path_value = raw_record["path"]
        _require(isinstance(identifier, str) and bool(identifier), "input binding id is absent")
        _require(
            isinstance(path_value, str) and bool(path_value),
            "input binding path is absent",
        )
        relative = PurePosixPath(path_value)
        _require(
            not relative.is_absolute()
            and relative.as_posix() == path_value
            and all(part not in {"", ".", ".."} for part in relative.parts),
            f"input binding path is not normalized: {path_value!r}",
        )
        _require(identifier not in seen_ids, f"duplicate input binding id: {identifier}")
        _require(path_value not in seen_paths, f"duplicate input binding path: {path_value}")
        _require(_is_sha256(raw_record["sha256"]), "input binding hash is invalid")
        size_value = raw_record["size_bytes"]
        _require(
            isinstance(size_value, int)
            and not isinstance(size_value, bool)
            and size_value >= 0,
            "input binding size is invalid",
        )
        seen_ids.add(identifier)
        seen_paths.add(path_value)
        records_by_id[identifier] = raw_record

    declared_bundle = input_bindings["bundle_sha256"]
    _require(_is_sha256(declared_bundle), "input bundle hash is invalid")
    computed_bundle = _sha256(
        _canonical_json_bytes(
            {
                "repository_file_bindings": records,
                "live_holdout_preopen_verification": live_verification,
            }
        )
    )
    _require(declared_bundle == computed_bundle, "input bundle hash differs")
    required_live_fields = {
        "access_count",
        "access_status",
        "artifact_kind",
        "corpus_binding_sha256",
        "live_anchor_root_identity_sha256",
        "live_ledger_root_identity_sha256",
        "live_ledger_sha256",
        "live_preopen_receipt_sha256",
        "open_intent_anchor_present",
        "pixel_content_included",
        "repository_attestation_sha256",
        "repository_sealed_copy_sha256",
        "schema_version",
        "verification_receipt_sha256",
        "verification_status",
    }
    _require(set(live_verification) == required_live_fields, "live holdout fields differ")
    _require(
        live_verification.get("artifact_kind") == "live_holdout_preopen_verification"
        and live_verification.get("schema_version") == "1.0.0"
        and live_verification.get("verification_status") == "pass"
        and live_verification.get("access_status") == "unopened"
        and live_verification.get("access_count") == 0
        and live_verification.get("open_intent_anchor_present") is False
        and live_verification.get("pixel_content_included") is False,
        "live holdout verification is not an unopened metadata-only proof",
    )
    for field in required_live_fields:
        if field.endswith("_sha256"):
            _require(_is_sha256(live_verification[field]), f"live holdout hash is invalid: {field}")

    plan_document = json.loads(source_payloads[PLAN_SOURCE_PATH])
    _require(
        plan_document.get("status") == "preregistered_not_executed"
        and plan_document.get("data_separation", {}).get("holdout_may_be_opened_in_p06")
        is False,
        "captured calibration plan is not sealed for P06",
    )
    declared_bindings = plan_document.get("input_bindings")
    _require(
        isinstance(declared_bindings, list) and bool(declared_bindings),
        "captured calibration plan has no input bindings",
    )
    expected_paths = {"calibration_plan": PLAN_SOURCE_PATH}
    for declared in declared_bindings:
        _require(isinstance(declared, dict), "plan input binding is not an object")
        identifier = declared.get("id")
        path_value = declared.get("path")
        _require(
            isinstance(identifier, str)
            and bool(identifier)
            and isinstance(path_value, str)
            and bool(path_value),
            "plan input binding identity is absent",
        )
        _require(identifier not in expected_paths, f"duplicate plan input id: {identifier}")
        expected_paths[identifier] = path_value

    _require(
        expected_paths.get("candidate_evidence_policy")
        == CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH,
        "candidate evidence policy path differs",
    )
    candidate_policy = json.loads(
        source_payloads[CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH]
    )
    source_evidence = candidate_policy.get("source_evidence")
    _require(
        isinstance(source_evidence, dict) and bool(source_evidence),
        "candidate evidence policy has no source evidence",
    )
    declared_candidate_hashes: dict[str, str] = {}
    for source_id, source_record in source_evidence.items():
        _require(
            isinstance(source_id, str)
            and bool(source_id)
            and isinstance(source_record, dict),
            "candidate evidence source is invalid",
        )
        identifier = f"candidate_evidence_source_{source_id}"
        path_value = source_record.get("path")
        file_hash = source_record.get("file_sha256")
        _require(
            isinstance(path_value, str)
            and bool(path_value)
            and _is_sha256(file_hash),
            "candidate evidence source binding is invalid",
        )
        _require(identifier not in expected_paths, f"duplicate candidate source id: {identifier}")
        expected_paths[identifier] = path_value
        declared_candidate_hashes[identifier] = file_hash

    _require(
        set(records_by_id) == set(expected_paths),
        "input binding record set differs from the captured plan",
    )
    for identifier, expected_path in expected_paths.items():
        record = records_by_id[identifier]
        _require(record["path"] == expected_path, f"input binding path differs: {identifier}")
        _require(
            PurePosixPath(expected_path).suffix == ".json",
            f"bound repository input is not metadata JSON: {identifier}",
        )
        if identifier in declared_candidate_hashes:
            _require(
                record["sha256"] == declared_candidate_hashes[identifier],
                f"candidate evidence source hash differs: {identifier}",
            )

    required_policy_paths = {
        "calibration_plan": PLAN_SOURCE_PATH,
        "metric_performance_tolerances": TOLERANCE_SOURCE_PATH,
        "candidate_evidence_policy": CANDIDATE_EVIDENCE_POLICY_SOURCE_PATH,
    }
    verified_policy_bindings: list[dict[str, object]] = []
    for identifier, expected_path in required_policy_paths.items():
        record = records_by_id.get(identifier)
        _require(record is not None, f"required input binding is absent: {identifier}")
        _require(record["path"] == expected_path, f"bound policy path differs: {identifier}")
        payload = source_payloads.get(expected_path)
        _require(payload is not None, f"policy source snapshot is absent: {expected_path}")
        _require(record["size_bytes"] == len(payload), f"bound policy size differs: {identifier}")
        _require(record["sha256"] == _sha256(payload), f"bound policy hash differs: {identifier}")
        verified_policy_bindings.append(dict(record))

    return {
        "bundle_sha256": declared_bundle,
        "record_count": len(records),
        "policy_bindings": verified_policy_bindings,
    }


def validate_repository_input_files(
    repository_root: Path,
    records: Sequence[Mapping[str, object]],
) -> int:
    """Match every metadata-only run input record to the current repository bytes."""

    for record in records:
        relative = PurePosixPath(str(record["path"]))
        _require(relative.suffix == ".json", "bound input is not metadata JSON")
        payload, _ = stable_read_regular_file(repository_root.joinpath(*relative.parts))
        _require(record["size_bytes"] == len(payload), f"repository input size differs: {record['id']}")
        _require(record["sha256"] == _sha256(payload), f"repository input hash differs: {record['id']}")
    return len(records)


def build_analysis(
    *,
    repository_root: Path,
    bound_repository_root: Path,
    partial_root: Path,
    sql_path: Path,
    cutoff_sequence: int | None = None,
) -> Mapping[str, object]:
    """Validate a stable complete ledger prefix and derive bounded datasets."""

    expected_sql_path = repository_root / SQL_SOURCE_PATH
    _require(sql_path == expected_sql_path, "SQL source path differs from the bound report query")
    source_payloads, source_file_rows = _read_source_snapshot(
        repository_root,
        bound_repository_root,
    )
    analysis_repository_head = _git_head(repository_root)
    bound_repository_head = _git_head(bound_repository_root)
    plan = json.loads(source_payloads[PLAN_SOURCE_PATH])
    tolerances = json.loads(source_payloads[TOLERANCE_SOURCE_PATH])
    queries = _named_queries_from_bytes(source_payloads[SQL_SOURCE_PATH])

    sys.path.insert(0, str(bound_repository_root))
    from validation.calibration_v2 import corrective_preregistration as corrective_module
    from validation.calibration_v2 import runner as runner_module

    imported_modules = (
        (corrective_module, CORRECTIVE_SOURCE_PATH),
        (runner_module, RUNNER_SOURCE_PATH),
    )
    for module, relative in imported_modules:
        _require(
            Path(str(module.__file__)).resolve(strict=True)
            == (bound_repository_root / relative).resolve(strict=True),
            f"imported evaluator module is outside the repository: {relative}",
        )
    corrective_module = importlib.reload(corrective_module)
    runner_module = importlib.reload(runner_module)
    for module, relative in (
        (corrective_module, CORRECTIVE_SOURCE_PATH),
        (runner_module, RUNNER_SOURCE_PATH),
    ):
        _require(
            Path(str(module.__file__)).resolve(strict=True)
            == (bound_repository_root / relative).resolve(strict=True),
            f"reloaded evaluator module is outside the repository: {relative}",
        )
        current_payload, _ = stable_read_regular_file(bound_repository_root / relative)
        _require(
            current_payload == source_payloads[relative],
            f"evaluator source changed across import: {relative}",
        )
    verify_attempt_ledger_payload = corrective_module.verify_attempt_ledger_payload
    candidate_vector_sha256 = runner_module.candidate_vector_sha256
    canonical_development_failure_reasons = (
        runner_module.canonical_development_failure_reasons
    )
    development_search_rank_sha256 = runner_module.development_search_rank_sha256
    evaluation_feasible = runner_module.evaluation_feasible
    summarize_evaluation = runner_module.summarize_evaluation

    ledger_path = partial_root / "attempts.ndjson"
    observed_ledger_payload, ledger_metadata = stable_read_regular_file(ledger_path)
    observed_records = verify_attempt_ledger_payload(observed_ledger_payload)
    _require(bool(observed_records), "attempt ledger is empty")
    if cutoff_sequence is None:
        records = observed_records
        ledger_payload = observed_ledger_payload
    else:
        _require(
            isinstance(cutoff_sequence, int)
            and not isinstance(cutoff_sequence, bool)
            and 0 <= cutoff_sequence < len(observed_records),
            "requested cutoff is outside the stable observed ledger",
        )
        lines = observed_ledger_payload.splitlines(keepends=True)
        ledger_payload = b"".join(lines[: cutoff_sequence + 1])
        records = verify_attempt_ledger_payload(ledger_payload)

    input_bindings_payload, _ = stable_read_regular_file(partial_root / "input-bindings.json")
    input_bindings = json.loads(input_bindings_payload)
    verified_input_bindings = validate_input_bindings_document(
        input_bindings,
        source_payloads,
    )
    repository_input_file_count = validate_repository_input_files(
        bound_repository_root,
        input_bindings["records"],
    )
    _require(
        repository_input_file_count == verified_input_bindings["record_count"],
        "repository input verification count differs",
    )
    connection = _create_connection()
    evaluation_cache: dict[
        str,
        tuple[Mapping[str, object], Mapping[str, object], str, int],
    ] = {}
    evaluation_file_count = 0
    summary_verification_count = 0

    for record in records:
        sequence = int(record["sequence"])
        status = str(record["status"])
        _require(
            status
            in {
                "feasible",
                "infeasible",
                "constraint_failure",
                "evaluation_failure",
            },
            f"attempt status is unsupported: {status}",
        )
        canonical_failures_value = record.get("canonical_failure_reasons")
        canonical_failures = (
            tuple(str(value) for value in canonical_failures_value)
            if isinstance(canonical_failures_value, list)
            else ()
        )
        raw_failures_value = record.get("failure_reasons")
        raw_failures = (
            tuple(str(value) for value in raw_failures_value)
            if isinstance(raw_failures_value, list)
            else ()
        )
        failure_signature = " | ".join(canonical_failures) if canonical_failures else None
        connection.execute(
            "INSERT INTO attempts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                sequence,
                int(record["sweep"]),
                str(record["phase"]),
                record.get("coordinate"),
                None if record.get("value") is None else json.dumps(record["value"]),
                status,
                int(record.get("cache_hit") is True),
                record.get("canonical_failure_count"),
                int(canonical_failures == CORE_NINE),
                failure_signature,
                (
                    record.get("evaluation", {}).get("sha256")
                    if isinstance(record.get("evaluation"), dict)
                    else None
                ),
            ),
        )
        for failure in canonical_failures:
            connection.execute(
                "INSERT INTO failures VALUES (?, ?)",
                (sequence, failure),
            )
        if status not in EVALUATED_STATUSES:
            for error in raw_failures:
                connection.execute(
                    "INSERT INTO attempt_errors VALUES (?, ?)",
                    (sequence, error),
                )

        evaluation_binding = record.get("evaluation")
        if status not in EVALUATED_STATUSES:
            _require(
                evaluation_binding is None and not canonical_failures,
                "non-evaluable attempt contains evaluation-derived fields",
            )
            continue
        _require(isinstance(evaluation_binding, dict), "evaluated attempt lacks evaluation")
        relative = _safe_relative_path(evaluation_binding.get("path"), "evaluations")
        evaluation_path = partial_root.joinpath(*relative.parts)
        declared_hash = str(evaluation_binding.get("sha256"))
        cached = evaluation_cache.get(declared_hash)
        if cached is None:
            evaluation_payload, _ = _artifact_binding(evaluation_path, evaluation_binding)
            _require(
                evaluation_path.stem == declared_hash,
                "evaluation filename does not equal its content hash",
            )
            evaluation = json.loads(evaluation_payload)
            _require(evaluation.get("split") == "development", "analysis crossed split boundary")
            summary = summarize_evaluation(evaluation, tolerances)
            evaluation_cache[declared_hash] = (
                evaluation,
                summary,
                relative.as_posix(),
                len(evaluation_payload),
            )
            evaluation_file_count += 1
        else:
            evaluation, summary, cached_path, cached_size = cached
            _require(
                relative.as_posix() == cached_path
                and evaluation_binding.get("size_bytes") == cached_size,
                "reused evaluation binding differs from its verified artifact",
            )

        _require(
            record.get("candidate_vector_sha256")
            == candidate_vector_sha256(record["candidate_vector"], plan),
            "candidate vector hash differs",
        )
        _require(
            evaluation.get("candidate_vector_sha256")
            == record.get("candidate_vector_sha256"),
            "evaluation candidate binding differs",
        )
        _require(
            _sha256(_canonical_json_bytes(summary)) == record.get("summary_sha256"),
            "summary hash differs",
        )
        feasible, recomputed_failures = evaluation_feasible(
            evaluation,
            summary,
            tolerances,
        )
        _require(
            feasible == (status == "feasible"),
            "ledger evaluated status differs from recomputed feasibility",
        )
        _require(recomputed_failures == raw_failures, "recomputed failure order differs")
        _require(
            canonical_development_failure_reasons(recomputed_failures)
            == canonical_failures,
            "canonical failure set differs",
        )
        _require(
            len(canonical_failures) == record.get("canonical_failure_count"),
            "canonical failure count differs",
        )
        result = (evaluation, summary, feasible, recomputed_failures)
        _require(
            development_search_rank_sha256(
                result,
                record["candidate_vector"],
                plan,
            )
            == record.get("development_search_rank_sha256"),
            "development search rank hash differs",
        )
        summary_verification_count += 1

        lower_bounds = tolerances["quality"]["y_psnr_paired_delta_lower_bound_db"]
        bootstrap_thresholds = {
            "y_vs_fixed": lower_bounds["full_spatial_ash_vs_best_fixed_same_bank"],
            "y_vs_non_ash": lower_bounds[
                "full_spatial_ash_vs_non_ash_same_bank_selector"
            ],
            "y_vs_conventional": lower_bounds[
                "full_spatial_ash_vs_best_conventional_baseline"
            ],
        }
        chroma = tolerances["quality"]["chroma_displacement"]
        for domain in DOMAINS:
            domain_summary = summary[domain]
            for name in BOOTSTRAP_NAMES:
                _insert_metric(
                    connection,
                    sequence=sequence,
                    domain=domain,
                    metric=f"bootstrap_ci_low:{name}",
                    value=domain_summary["bootstraps"][name]["ci_low"],
                    threshold=bootstrap_thresholds[name],
                    direction="strictly_greater_than",
                    unit="dB",
                )
            _insert_metric(
                connection,
                sequence=sequence,
                domain=domain,
                metric="maximum_chroma_displacement_pixels",
                value=domain_summary["maximum_chroma_displacement_pixels"],
                threshold=chroma["absolute_pixels_maximum"],
                direction="less_than_or_equal",
                unit="pixels",
            )
            _insert_metric(
                connection,
                sequence=sequence,
                domain=domain,
                metric="maximum_chroma_displacement_increase_pixels",
                value=domain_summary["maximum_chroma_displacement_increase_pixels"],
                threshold=chroma[
                    "increase_over_best_conventional_pixels_maximum"
                ],
                direction="less_than_or_equal",
                unit="pixels",
            )

        state_routes = evaluation["checks"]["evidence"]["state_causality"]["routes"]
        _require(isinstance(state_routes, list), "state causality evidence is absent")
        for route_record in state_routes:
            _require(isinstance(route_record, dict), "state route record is not an object")
            route = str(route_record["target_route"])
            observations = route_record["active_coordinate_observations"]
            _require(isinstance(observations, list), "state coordinate observations are absent")
            for observation in observations:
                _require(isinstance(observation, dict), "state observation is not an object")
                connection.execute(
                    "INSERT INTO state_observations VALUES (?, ?, ?, ?, ?)",
                    (
                        sequence,
                        route,
                        int(observation["coordinate"]),
                        int(observation["one_count"]),
                        int(observation["zero_count"]),
                    ),
                )

        route_records = evaluation["checks"]["evidence"]["analysis_grid"][
            "route_quality"
        ]["routes"]
        _require(isinstance(route_records, list), "route quality evidence is absent")
        for route_record in route_records:
            _require(isinstance(route_record, dict), "route quality record is not an object")
            route_name = str(route_record["target_route"])
            route_definitions = list(_route_predicate_rows(route_record, tolerances["quality"]))
            predicate_names = (
                "minimum_per_source_y_psnr_delta_db",
                "maximum_ringing_excursion",
                "maximum_ringing_increase",
                "maximum_alias_ratio",
                "maximum_alias_increase",
                "maximum_chroma_displacement_pixels",
                "maximum_chroma_displacement_increase_pixels",
            )
            _require(len(route_definitions) == len(predicate_names), "route predicate count differs")
            for predicate_name, definition in zip(predicate_names, route_definitions):
                route, value, threshold, direction, unit, passed = definition
                _require(route == route_name, "route predicate binding differs")
                connection.execute(
                    "INSERT INTO route_predicates VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        sequence,
                        route,
                        predicate_name,
                        value,
                        threshold,
                        direction,
                        unit,
                        int(passed),
                    ),
                )

    connection.commit()
    datasets = {
        name: _query_rows(connection, query)
        for name, query in queries.items()
    }
    connection.close()

    matrix = datasets["candidate_metric_matrix"]
    unique_matrix = datasets["unique_evaluation_metric_matrix"]

    def correlations_for(rows: Sequence[Mapping[str, object]]) -> Mapping[str, float]:
        return {
            "raw_vs_container_conventional_ci_low": _pearson(
                [row["engine_raw_conventional_ci_low_db"] for row in rows],
                [row["container_conventional_ci_low_db"] for row in rows],
            ),
            "raw_vs_container_chroma_displacement": _pearson(
                [row["engine_raw_chroma_pixels"] for row in rows],
                [row["container_chroma_pixels"] for row in rows],
            ),
            "raw_conventional_ci_low_vs_chroma_displacement": _pearson(
                [row["engine_raw_conventional_ci_low_db"] for row in rows],
                [row["engine_raw_chroma_pixels"] for row in rows],
            ),
        }

    correlations = {
        "attempt_weighted": correlations_for(matrix),
        "unique_evaluation": correlations_for(unique_matrix),
    }

    final_record = records[-1]
    final_line = ledger_payload.splitlines()[-1]
    evaluated_attempt_count = sum(
        1 for record in records if record.get("status") in EVALUATED_STATUSES
    )
    feasible_attempt_count = sum(
        1 for record in records if record.get("status") == "feasible"
    )
    core_nine_count = sum(
        1
        for record in records
        if tuple(record.get("canonical_failure_reasons") or ()) == CORE_NINE
    )
    _require(
        _git_head(repository_root) == analysis_repository_head
        and _git_head(bound_repository_root) == bound_repository_head,
        "repository HEAD changed during analysis",
    )
    document: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "artifact_kind": ARTIFACT_KIND,
        "captured_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "scope": {
            "split": "development",
            "analysis_repository_head": analysis_repository_head,
            "bound_repository_head": bound_repository_head,
            "holdout_accessed": False,
            "media_payload_accessed": False,
            "ledger_path": _artifact_source_identity(ledger_path),
            "ledger_inode": ledger_metadata.st_ino,
            "ledger_size_bytes": len(ledger_payload),
            "observed_live_ledger_size_bytes": len(observed_ledger_payload),
            "observed_live_last_sequence": int(observed_records[-1]["sequence"]),
            "ledger_mtime_ns": ledger_metadata.st_mtime_ns,
            "ledger_prefix_sha256": _sha256(ledger_payload),
            "cutoff_sequence": int(final_record["sequence"]),
            "cutoff_record_sha256": final_record["record_sha256"],
            "cutoff_previous_record_sha256": final_record[
                "previous_record_sha256"
            ],
            "cutoff_raw_line_sha256": _sha256(final_line),
            "input_bindings_sha256": _sha256(input_bindings_payload),
            "input_bundle_sha256": verified_input_bindings["bundle_sha256"],
        },
        "validation": {
            "canonical_ndjson": True,
            "sequence_continuous": True,
            "record_hash_chain_valid": True,
            "candidate_vector_bindings_valid": True,
            "evaluation_artifact_bindings_valid": True,
            "summary_bindings_valid": True,
            "development_search_rank_bindings_valid": True,
            "input_bundle_internal_consistency_valid": True,
            "policy_source_bindings_valid": True,
            "repository_input_files_match_bundle": True,
            "evaluator_source_import_match_valid": True,
            "source_snapshot_stable": True,
            "attempt_count": len(records),
            "evaluation_attempt_count": evaluated_attempt_count,
            "unique_evaluation_file_count": evaluation_file_count,
            "summary_verification_count": summary_verification_count,
            "repository_input_file_count": repository_input_file_count,
        },
        "headline": {
            "attempt_count": len(records),
            "evaluated_attempt_count": evaluated_attempt_count,
            "feasible_attempt_count": feasible_attempt_count,
            "core_nine_attempt_count": core_nine_count,
            "core_nine_evaluated_fraction": (
                core_nine_count / evaluated_attempt_count
                if evaluated_attempt_count
                else 0.0
            ),
            "constraint_failure_count": sum(
                1 for record in records if record.get("status") == "constraint_failure"
            ),
            "evaluation_failure_count": sum(
                1 for record in records if record.get("status") == "evaluation_failure"
            ),
            "cache_hit_count": sum(1 for record in records if record.get("cache_hit") is True),
        },
        "metric_definitions": {
            "evaluated_attempt": (
                "an attempt with a complete candidate evaluation and either feasible or "
                "infeasible status"
            ),
            "failure_frequency": "attempts carrying one canonical failure divided by all evaluated attempts",
            "core_nine": list(CORE_NINE),
            "bootstrap_ci_low": (
                "lower bound of the preregistered 95% paired source-asset bootstrap; "
                "10,000 replicates and seed 20260710; strict pass threshold greater than 0 dB"
            ),
            "chroma_displacement": (
                "maximum absolute Cb/Cr edge displacement from the luma edge; "
                "pass threshold at most 0.25 luma pixels"
            ),
            "coordinate_response_span": (
                "maximum within-sweep metric range while one declared coordinate varies; "
                "descriptive local sensitivity under that sweep's incumbent context"
            ),
        },
        "correlations": {
            "method": "Pearson product-moment correlation",
            "observation_grains": {
                "attempt_weighted": "candidate attempt",
                "unique_evaluation": "unique evaluation artifact",
            },
            "causal_interpretation_allowed": False,
            "values": correlations,
        },
        "datasets": datasets,
        "queries": queries,
        "source_files": source_file_rows,
        "bound_policy_inputs": verified_input_bindings["policy_bindings"],
    }
    document["analysis_sha256"] = _self_hash(document)
    return document


def _parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--bound-repository-root", required=True, type=Path)
    parser.add_argument("--partial-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cutoff-sequence", type=int)
    parser.add_argument(
        "--sql",
        type=Path,
        default=Path("analysis/ash-failure-patterns/queries/p06_failure_analysis.sql"),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    repository_root = arguments.repository_root.resolve(strict=True)
    bound_repository_root = arguments.bound_repository_root.resolve(strict=True)
    partial_root = arguments.partial_root.resolve(strict=True)
    sql_path = arguments.sql
    if not sql_path.is_absolute():
        sql_path = repository_root / sql_path
    output = arguments.output
    if not output.is_absolute():
        output = repository_root / output
    document = build_analysis(
        repository_root=repository_root,
        bound_repository_root=bound_repository_root,
        partial_root=partial_root,
        sql_path=sql_path,
        cutoff_sequence=arguments.cutoff_sequence,
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = _canonical_json_bytes(document) + b"\n"
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            _require(written > 0, "analysis output write made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    print(
        json.dumps(
            {
                "analysis_sha256": document["analysis_sha256"],
                "attempt_count": document["validation"]["attempt_count"],
                "cutoff_sequence": document["scope"]["cutoff_sequence"],
                "output": str(output),
                "status": "pass",
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
