#!/usr/bin/env python3
"""Validate the retained ASH Logging trace against its telemetry snapshot."""

from __future__ import annotations

import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path


STAGES = (
    "media_probe",
    "reader_setup",
    "frame_read",
    "canonicalize",
    "analyze_luma",
    "analyze_chroma",
    "motion_estimate",
    "state_pack",
    "dispatch_decode",
    "reconstruct_luma",
    "reconstruct_chroma",
    "temporal_fuse",
    "telemetry_reduce",
    "writer_backpressure",
    "writer_append",
    "audio_process",
    "writer_finish",
    "reopen_verify",
    "frame_total",
    "job_total",
)
SUBSYSTEM = "com.mirmir.ash.engine"
CATEGORY = "ASH"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_xml(path: Path) -> tuple[ET.Element, dict[str, str]]:
    root = ET.parse(path).getroot()
    values: dict[str, str] = {}
    for element in root.iter():
        identifier = element.get("id")
        if identifier is None:
            continue
        value = (element.text or "").strip()
        if not value:
            value = element.get("fmt") or ""
        values[identifier] = value
    return root, values


def resolved(element: ET.Element | None, values: dict[str, str]) -> str | None:
    if element is None:
        return None
    reference = element.get("ref")
    if reference is not None:
        return values.get(reference)
    return (element.text or "").strip() or element.get("fmt")


def direct_value(row: ET.Element, tag: str, values: dict[str, str]) -> str | None:
    return resolved(row.find(tag), values)


def validate(raw_path: Path, interval_path: Path, telemetry_path: Path) -> dict[str, object]:
    raw_root, raw_values = parse_xml(raw_path)
    interval_root, interval_values = parse_xml(interval_path)
    telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))

    raw_counts: dict[str, Counter[str]] = defaultdict(Counter)
    raw_processes: set[str] = set()
    unexpected_names: set[str] = set()
    unexpected_event_types: set[str] = set()
    for row in raw_root.iter("row"):
        subsystem = direct_value(row, "subsystem", raw_values)
        category = direct_value(row, "category", raw_values)
        if subsystem != SUBSYSTEM or category != CATEGORY:
            continue
        name = direct_value(row, "signpost-name", raw_values)
        event_type = direct_value(row, "event-type", raw_values)
        process = direct_value(row, "process", raw_values)
        if process:
            raw_processes.add(process)
        if name not in STAGES:
            unexpected_names.add(name or "<missing>")
            continue
        if event_type not in ("Begin", "End"):
            unexpected_event_types.add(event_type or "<missing>")
            continue
        raw_counts[name][event_type] += 1

    interval_counts: Counter[str] = Counter()
    interval_duration_ns: dict[str, int] = defaultdict(int)
    interval_processes: set[str] = set()
    nonpositive_intervals: Counter[str] = Counter()
    for row in interval_root.iter("row"):
        subsystem = direct_value(row, "subsystem", interval_values)
        category = direct_value(row, "category", interval_values)
        if subsystem != SUBSYSTEM or category != CATEGORY:
            continue
        name = direct_value(row, "string", interval_values)
        process = direct_value(row, "process", interval_values)
        if process:
            interval_processes.add(process)
        if name not in STAGES:
            unexpected_names.add(name or "<missing>")
            continue
        duration_text = direct_value(row, "duration", interval_values)
        try:
            duration_ns = int(duration_text or "")
        except ValueError:
            duration_ns = 0
        interval_counts[name] += 1
        interval_duration_ns[name] += duration_ns
        if duration_ns <= 0:
            nonpositive_intervals[name] += 1

    telemetry_rows = telemetry.get("stages", [])
    telemetry_names = [row.get("name") for row in telemetry_rows]
    telemetry_by_name = {row.get("name"): row for row in telemetry_rows}
    failures: list[str] = []

    if telemetry_names != list(STAGES):
        failures.append("telemetry stage catalog or order differs from the locked 20-stage catalog")
    if telemetry.get("result", {}).get("status") != "success":
        failures.append("telemetry terminal status is not success")
    if telemetry.get("result", {}).get("balanced_intervals") is not True:
        failures.append("telemetry reports unbalanced intervals")
    if telemetry.get("result", {}).get("failures"):
        failures.append("telemetry result includes failures")
    if telemetry.get("errors"):
        failures.append("telemetry includes runtime errors")
    if telemetry.get("dropped_event_count") != 0:
        failures.append("telemetry dropped events")
    if telemetry.get("dropped_timing_sample_count") != 0:
        failures.append("telemetry dropped timing samples")
    if unexpected_names:
        failures.append("trace contains unexpected ASH signpost names")
    if unexpected_event_types:
        failures.append("trace contains unexpected ASH signpost event types")
    if nonpositive_intervals:
        failures.append("trace contains non-positive ASH intervals")
    if len(raw_processes) != 1 or raw_processes != interval_processes:
        failures.append("raw and completed-interval tables do not identify one matching process")

    stage_rows: list[dict[str, object]] = []
    for name in STAGES:
        telemetry_row = telemetry_by_name.get(name, {})
        expected = telemetry_row.get("count")
        begin_count = raw_counts[name]["Begin"]
        end_count = raw_counts[name]["End"]
        completed_count = interval_counts[name]
        counts_match = (
            isinstance(expected, int)
            and expected == begin_count == end_count == completed_count
        )
        if not counts_match:
            failures.append(f"{name}: telemetry/begin/end/completed counts differ")
        if expected == 0 and (begin_count or end_count or completed_count):
            failures.append(f"{name}: a zero-count stage emitted trace rows")
        telemetry_total_ms = telemetry_row.get("cpu_ms", {}).get("total", 0)
        trace_total_ms = interval_duration_ns[name] / 1_000_000
        stage_rows.append(
            {
                "name": name,
                "telemetry_count": expected,
                "begin_count": begin_count,
                "end_count": end_count,
                "completed_interval_count": completed_count,
                "counts_match": counts_match,
                "telemetry_cpu_total_ms": telemetry_total_ms,
                "trace_interval_total_ms": round(trace_total_ms, 6),
                "trace_minus_telemetry_ms": round(trace_total_ms - telemetry_total_ms, 6),
            }
        )

    for required_singleton in ("frame_total", "job_total"):
        if telemetry_by_name.get(required_singleton, {}).get("count") != 1:
            failures.append(f"{required_singleton}: expected exactly one interval")

    return {
        "schema_version": "1.0",
        "status": "pass" if not failures else "fail",
        "subsystem": SUBSYSTEM,
        "category": CATEGORY,
        "processes": sorted(raw_processes),
        "stage_catalog_count": len(STAGES),
        "unexpected_names": sorted(unexpected_names),
        "unexpected_event_types": sorted(unexpected_event_types),
        "nonpositive_intervals": dict(sorted(nonpositive_intervals.items())),
        "failures": failures,
        "stages": stage_rows,
        "inputs": {
            "raw_xml": {
                "path": f"runtime/{raw_path.name}",
                "sha256": sha256(raw_path),
            },
            "interval_xml": {
                "path": f"runtime/{interval_path.name}",
                "sha256": sha256(interval_path),
            },
            "telemetry_json": {
                "path": f"runtime/{telemetry_path.name}",
                "sha256": sha256(telemetry_path),
            },
        },
    }


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: validate_signposts.py RAW_XML INTERVAL_XML TELEMETRY_JSON",
            file=sys.stderr,
        )
        return 2
    result = validate(*(Path(argument).resolve() for argument in sys.argv[1:]))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
