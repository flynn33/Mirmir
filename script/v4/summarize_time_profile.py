#!/usr/bin/env python3
"""Export a privacy-safe Mirmir hot-path summary from an Instruments trace."""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from typing import Any
import xml.etree.ElementTree as ET


@dataclass(frozen=True)
class Frame:
    symbol: str
    image: str


CATEGORY_PATTERNS = {
    "analysis": ("ASHVideoAnalyzer",),
    "reconstruction": ("ASHSpatialOperatorBank", "ASHSpatialReferencePipeline"),
    "selection_and_decode": (
        "ASHSpatialDevelopmentSelector",
        "ASHCode.",
        "ASHLUT",
    ),
    "metal_submission": ("ASHMetal", "PreparedDeterministicMetalUpscaler"),
    "copy_and_allocation": (
        "ASHNV12FrameCodec",
        "NV12FrameAttachments",
        "memcpy",
        "memmove",
        "swift_alloc",
        "malloc",
        "CVPixelBuffer",
        "Data.write",
        "DeterministicMetalBackendTests.write",
    ),
    "benchmark_harness": ("DeterministicMetalBackendTests", "XCTest"),
}


def tree_identity(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    byte_count = 0
    for child in sorted(candidate for candidate in path.rglob("*") if candidate.is_file()):
        relative = child.relative_to(path).as_posix().encode("utf-8")
        size = child.stat().st_size
        byte_count += size
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(size.to_bytes(8, "big"))
        with child.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    return byte_count, digest.hexdigest()


def referenced_id(element: ET.Element | None) -> str | None:
    if element is None:
        return None
    return element.get("id") or element.get("ref")


def top_rows(values: dict[Frame, int], limit: int) -> list[dict[str, Any]]:
    ordered = sorted(
        (
            item
            for item in values.items()
            if item[0].symbol not in {"unknown", "<deduplicated_symbol>"}
        ),
        key=lambda item: (-item[1], item[0].image, item[0].symbol),
    )
    return [
        {
            "symbol": frame.symbol,
            "image": frame.image,
            "sampledMilliseconds": nanoseconds / 1_000_000.0,
        }
        for frame, nanoseconds in ordered[:limit]
    ]


def summarize(xml_path: Path, process_name: str, app_image: str) -> dict[str, Any]:
    root = ET.parse(xml_path).getroot()
    processes: dict[str, str] = {}
    binaries: dict[str, str] = {}
    frames: dict[str, Frame] = {}
    backtraces: dict[str, tuple[str, ...]] = {}
    weights: dict[str, int] = {}
    matching_processes: set[str] = set()
    inclusive: dict[Frame, int] = defaultdict(int)
    leaf: dict[Frame, int] = defaultdict(int)
    sample_count = 0
    sampled_nanoseconds = 0

    for row in root.iter("row"):
        for process in row.iter("process"):
            identifier = process.get("id")
            if identifier is not None and process.get("fmt") is not None:
                processes[identifier] = process.get("fmt", "")
        for binary in row.iter("binary"):
            identifier = binary.get("id")
            if identifier is not None:
                binaries[identifier] = binary.get("name", "unknown")
        for frame_element in row.iter("frame"):
            identifier = frame_element.get("id")
            if identifier is None:
                continue
            binary_element = frame_element.find("binary")
            binary_identifier = referenced_id(binary_element)
            frames[identifier] = Frame(
                symbol=frame_element.get("name", "unknown"),
                image=binaries.get(binary_identifier or "", "unknown"),
            )
        for backtrace in row.iter("backtrace"):
            identifier = backtrace.get("id")
            if identifier is not None:
                backtraces[identifier] = tuple(
                    referenced_id(frame) or "" for frame in backtrace.findall("frame")
                )
        for weight in row.iter("weight"):
            identifier = weight.get("id")
            if identifier is not None and weight.text is not None:
                weights[identifier] = int(weight.text)

        process_element = row.find("process")
        process_identifier = referenced_id(process_element)
        process_description = processes.get(process_identifier or "", "")
        if not process_description.startswith(f"{process_name} ("):
            continue
        matching_processes.add(process_identifier or process_description)
        weight_identifier = referenced_id(row.find("weight"))
        weight = weights.get(weight_identifier or "", 0)
        backtrace_identifier = referenced_id(row.find("backtrace"))
        stack = backtraces.get(backtrace_identifier or "", ())
        if not stack or weight <= 0:
            continue
        resolved = [frames[identifier] for identifier in stack if identifier in frames]
        if not resolved:
            continue
        sample_count += 1
        sampled_nanoseconds += weight
        leaf[resolved[0]] += weight
        for frame in set(resolved):
            inclusive[frame] += weight

    app_inclusive = {
        frame: duration
        for frame, duration in inclusive.items()
        if frame.image == app_image
    }
    category_nanoseconds = {
        category: sum(
            duration
            for frame, duration in inclusive.items()
            if any(pattern in frame.symbol for pattern in patterns)
        )
        for category, patterns in CATEGORY_PATTERNS.items()
    }
    return {
        "processName": process_name,
        "processInstanceCount": len(matching_processes),
        "sampleCount": sample_count,
        "sampledCPUMilliseconds": sampled_nanoseconds / 1_000_000.0,
        "topAppInclusiveSymbols": top_rows(app_inclusive, 40),
        "topAllLeafSymbols": top_rows(leaf, 30),
        "categoryInclusiveMilliseconds": {
            category: duration / 1_000_000.0
            for category, duration in sorted(category_nanoseconds.items())
        },
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--process-name", default="Mirmir")
    parser.add_argument("--app-image", default="Mirmir")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    trace = arguments.input.expanduser().resolve()
    if not trace.is_dir():
        raise SystemExit(f"Expected an Instruments trace bundle: {trace}")
    output = arguments.output.expanduser().resolve()
    if output.exists():
        raise SystemExit(f"Refusing to overwrite existing output: {output}")

    with tempfile.TemporaryDirectory(prefix="mirmir-v4-time-profile-") as temporary:
        exported = Path(temporary) / "time-profile.xml"
        subprocess.run(
            [
                "xcrun",
                "xctrace",
                "export",
                "--input",
                str(trace),
                "--xpath",
                '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
                "--output",
                str(exported),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        result = summarize(exported, arguments.process_name, arguments.app_image)

    byte_count, identity = tree_identity(trace)
    payload = {
        "schemaVersion": "mirmir-v4-time-profile-summary-v1",
        "sourceTrace": {
            "byteCount": byte_count,
            "treeSHA256": identity,
            "retention": (
                "Raw system-wide trace retained locally only; summary excludes device "
                "identifiers, process identifiers, paths, and unrelated process details."
            ),
        },
        **result,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
