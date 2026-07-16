#!/usr/bin/env python3
"""Aggregate one exported Instruments time-profile table without third-party modules."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def numeric_text(element: ET.Element | None, registry: dict[str, int]) -> int:
    if element is None:
        return 0
    reference = element.get("ref")
    if reference is not None:
        return registry[reference]
    value = int((element.text or "0").strip())
    identifier = element.get("id")
    if identifier is not None:
        registry[identifier] = value
    return value


def resolve_child(
    parent: ET.Element,
    tag: str,
    registry: dict[str, ET.Element],
) -> ET.Element | None:
    child = parent.find(tag)
    if child is None:
        return None
    reference = child.get("ref")
    return registry.get(reference) if reference is not None else child


def classify_memory_leaf(name: str) -> str | None:
    lowered = name.lower()
    if re.search(r"(?:memmove|memcpy|bcopy)", lowered):
        return "memory_copy"
    if re.search(
        r"(?:malloc|calloc|realloc|free|dealloc|allocobject|slowalloc|xzm_|szone_|nanov2_)",
        lowered,
    ):
        return "allocator_or_release"
    if any(
        token in name
        for token in (
            "_ContiguousArrayBuffer._consumeAndCreateNew",
            "ContiguousArray._createNewBuffer",
            "Array.init(repeating:",
            "_allocateUninitializedArray",
        )
    ):
        return "array_storage"
    return None


def make_anchor(source_path: str | None, line: int | None, repository_root: Path) -> str | None:
    if source_path is None or line is None or line <= 0:
        return None
    path = Path(source_path)
    try:
        relative = path.relative_to(repository_root)
    except ValueError:
        return None
    return f"{relative}:{line}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile_xml", type=Path)
    parser.add_argument("toc_xml", type=Path)
    parser.add_argument("--repository-root", required=True, type=Path)
    args = parser.parse_args()

    profile_root = ET.parse(args.profile_xml).getroot()
    toc_root = ET.parse(args.toc_xml).getroot()

    binary_registry: dict[str, ET.Element] = {}
    path_registry: dict[str, ET.Element] = {}
    frame_registry: dict[str, ET.Element] = {}
    backtrace_registry: dict[str, ET.Element] = {}
    for element in profile_root.iter():
        identifier = element.get("id")
        if identifier is None:
            continue
        if element.tag == "binary":
            binary_registry[identifier] = element
        elif element.tag == "path":
            path_registry[identifier] = element
        elif element.tag == "frame":
            frame_registry[identifier] = element
        elif element.tag == "backtrace":
            backtrace_registry[identifier] = element

    def resolve_frame(frame_element: ET.Element) -> dict[str, object]:
        reference = frame_element.get("ref")
        frame = frame_registry[reference] if reference is not None else frame_element
        binary = resolve_child(frame, "binary", binary_registry)
        source = frame.find("source")
        source_path: str | None = None
        source_line: int | None = None
        if source is not None:
            source_line = int(source.get("line", "0"))
            path_element = resolve_child(source, "path", path_registry)
            if path_element is not None:
                source_path = (path_element.text or "").strip()
        return {
            "name": frame.get("name", "<unnamed>"),
            "binary_name": binary.get("name") if binary is not None else None,
            "binary_path": binary.get("path") if binary is not None else None,
            "source_path": source_path,
            "source_line": source_line,
            "anchor": make_anchor(source_path, source_line, args.repository_root),
        }

    def is_source_backed_production(frame: dict[str, object]) -> bool:
        binary_name = frame["binary_name"]
        source_path = frame["source_path"]
        if binary_name != "Mirmir.debug.dylib" or not isinstance(source_path, str):
            return False
        try:
            relative = Path(source_path).relative_to(args.repository_root)
        except ValueError:
            return False
        return bool(relative.parts and relative.parts[0] == "Mirmir")

    def is_product_binary(frame: dict[str, object]) -> bool:
        return frame["binary_name"] in {"Mirmir.debug.dylib", "Mirmir"}

    weight_registry: dict[str, int] = {}
    time_registry: dict[str, int] = {}
    total_samples = 0
    total_weight_ns = 0
    sample_times: list[int] = []
    weight_distribution: Counter[int] = Counter()
    production_stack_samples = 0
    production_stack_weight_ns = 0
    product_binary_stack_samples = 0
    product_binary_stack_weight_ns = 0
    product_binary_leaf_samples = 0
    product_binary_leaf_weight_ns = 0
    inclusive_samples: Counter[str] = Counter()
    inclusive_weights: Counter[str] = Counter()
    leaf_samples: Counter[str] = Counter()
    leaf_weights: Counter[str] = Counter()
    symbol_anchors: dict[str, set[str]] = defaultdict(set)
    product_inclusive_samples: Counter[str] = Counter()
    product_inclusive_weights: Counter[str] = Counter()
    product_leaf_samples: Counter[str] = Counter()
    product_leaf_weights: Counter[str] = Counter()
    product_symbol_anchors: dict[str, set[str]] = defaultdict(set)
    memory_groups: dict[tuple[str, str, str, str], dict[str, int]] = defaultdict(
        lambda: {"samples": 0, "weight_ns": 0}
    )
    memory_totals: dict[str, dict[str, int]] = defaultdict(
        lambda: {"samples": 0, "weight_ns": 0}
    )
    memory_anywhere_totals: dict[str, dict[str, int]] = defaultdict(
        lambda: {"samples": 0, "weight_ns": 0}
    )
    memory_anywhere_groups: dict[tuple[str, str, str], dict[str, int]] = defaultdict(
        lambda: {"samples": 0, "weight_ns": 0}
    )
    memory_anywhere_caller_union: dict[tuple[str, str], dict[str, int]] = defaultdict(
        lambda: {"samples": 0, "weight_ns": 0}
    )
    memory_anywhere_union = {"samples": 0, "weight_ns": 0}

    for row in profile_root.iter("row"):
        backtrace = row.find("backtrace")
        if backtrace is None:
            continue
        backtrace_reference = backtrace.get("ref")
        if backtrace_reference is not None:
            backtrace = backtrace_registry[backtrace_reference]
        weight = numeric_text(row.find("weight"), weight_registry)
        sample_time = numeric_text(row.find("sample-time"), time_registry)
        frames = [resolve_frame(element) for element in backtrace.findall("frame")]
        if not frames:
            continue

        total_samples += 1
        total_weight_ns += weight
        sample_times.append(sample_time)
        weight_distribution[weight] += 1

        production_frames = [frame for frame in frames if is_source_backed_production(frame)]
        product_binary_frames = [frame for frame in frames if is_product_binary(frame)]
        if production_frames:
            production_stack_samples += 1
            production_stack_weight_ns += weight
        if product_binary_frames:
            product_binary_stack_samples += 1
            product_binary_stack_weight_ns += weight

        symbols_in_sample: set[str] = set()
        for frame in production_frames:
            symbol = str(frame["name"])
            symbols_in_sample.add(symbol)
            anchor = frame["anchor"]
            if isinstance(anchor, str):
                symbol_anchors[symbol].add(anchor)
        for symbol in symbols_in_sample:
            inclusive_samples[symbol] += 1
            inclusive_weights[symbol] += weight

        product_symbols_in_sample: set[str] = set()
        for frame in product_binary_frames:
            symbol = str(frame["name"])
            product_symbols_in_sample.add(symbol)
            anchor = frame["anchor"]
            if isinstance(anchor, str):
                product_symbol_anchors[symbol].add(anchor)
        for symbol in product_symbols_in_sample:
            product_inclusive_samples[symbol] += 1
            product_inclusive_weights[symbol] += weight

        leaf = frames[0]
        if is_source_backed_production(leaf):
            symbol = str(leaf["name"])
            leaf_samples[symbol] += 1
            leaf_weights[symbol] += weight
        if is_product_binary(leaf):
            product_binary_leaf_samples += 1
            product_binary_leaf_weight_ns += weight
            symbol = str(leaf["name"])
            product_leaf_samples[symbol] += 1
            product_leaf_weights[symbol] += weight

        category = classify_memory_leaf(str(leaf["name"]))
        if category is not None:
            nearest = production_frames[0] if production_frames else None
            caller_name = str(nearest["name"]) if nearest is not None else "<no-source-backed-production-frame>"
            caller_anchor = (
                str(nearest["anchor"])
                if nearest is not None and nearest["anchor"] is not None
                else "<no-source-anchor>"
            )
            key = (category, str(leaf["name"]), caller_name, caller_anchor)
            memory_groups[key]["samples"] += 1
            memory_groups[key]["weight_ns"] += weight
            memory_totals[category]["samples"] += 1
            memory_totals[category]["weight_ns"] += weight

        names = [str(frame["name"]) for frame in frames]
        anywhere_flags = {
            "malloc_library": any(frame["binary_name"] == "libsystem_malloc.dylib" for frame in frames),
            "move_or_copy_primitive": any(
                re.search(r"(?:memmove|memcpy|bcopy)", name.lower()) for name in names
            ),
            "set_or_zero_primitive": any(
                re.search(r"(?:memset|bzero)", name.lower()) for name in names
            ),
            "swift_alloc_or_dealloc": any(
                re.search(r"(?:swift_allocObject|swift_slowAlloc|swift_dealloc)", name)
                for name in names
            ),
        }
        matched_anywhere = [name for name, matched in anywhere_flags.items() if matched]
        if matched_anywhere:
            memory_anywhere_union["samples"] += 1
            memory_anywhere_union["weight_ns"] += weight
            nearest = production_frames[0] if production_frames else None
            caller_name = str(nearest["name"]) if nearest is not None else "<no-source-backed-production-frame>"
            caller_anchor = (
                str(nearest["anchor"])
                if nearest is not None and nearest["anchor"] is not None
                else "<no-source-anchor>"
            )
            caller_union = memory_anywhere_caller_union[(caller_name, caller_anchor)]
            caller_union["samples"] += 1
            caller_union["weight_ns"] += weight
            for name in matched_anywhere:
                memory_anywhere_totals[name]["samples"] += 1
                memory_anywhere_totals[name]["weight_ns"] += weight
                group = memory_anywhere_groups[(name, caller_name, caller_anchor)]
                group["samples"] += 1
                group["weight_ns"] += weight

    symbols = []
    for symbol in sorted(inclusive_weights, key=lambda item: (-inclusive_weights[item], item)):
        symbols.append(
            {
                "symbol": symbol,
                "inclusive_stack_presence_samples": inclusive_samples[symbol],
                "inclusive_stack_presence_weight_ns": inclusive_weights[symbol],
                "inclusive_stack_presence_weight_ms": inclusive_weights[symbol] / 1_000_000,
                "inclusive_share_of_total_weight_percent": round(
                    100.0 * inclusive_weights[symbol] / total_weight_ns, 6
                ),
                "exact_leaf_samples": leaf_samples[symbol],
                "exact_leaf_weight_ns": leaf_weights[symbol],
                "exact_leaf_weight_ms": leaf_weights[symbol] / 1_000_000,
                "exact_leaf_share_of_total_weight_percent": round(
                    100.0 * leaf_weights[symbol] / total_weight_ns, 6
                ),
                "anchors": sorted(symbol_anchors[symbol]),
            }
        )

    product_symbols = []
    for symbol in sorted(
        product_inclusive_weights,
        key=lambda item: (-product_inclusive_weights[item], item),
    ):
        product_symbols.append(
            {
                "symbol": symbol,
                "inclusive_stack_presence_samples": product_inclusive_samples[symbol],
                "inclusive_stack_presence_weight_ns": product_inclusive_weights[symbol],
                "inclusive_stack_presence_weight_ms": product_inclusive_weights[symbol] / 1_000_000,
                "inclusive_share_of_total_weight_percent": round(
                    100.0 * product_inclusive_weights[symbol] / total_weight_ns, 6
                ),
                "exact_leaf_samples": product_leaf_samples[symbol],
                "exact_leaf_weight_ns": product_leaf_weights[symbol],
                "exact_leaf_weight_ms": product_leaf_weights[symbol] / 1_000_000,
                "exact_leaf_share_of_total_weight_percent": round(
                    100.0 * product_leaf_weights[symbol] / total_weight_ns, 6
                ),
                "anchors": sorted(product_symbol_anchors[symbol]),
            }
        )

    memory_stack_groups = []
    for key, values in sorted(
        memory_groups.items(),
        key=lambda item: (-item[1]["weight_ns"], item[0]),
    ):
        category, leaf_name, caller_name, caller_anchor = key
        memory_stack_groups.append(
            {
                "category": category,
                "sampled_leaf": leaf_name,
                "nearest_source_backed_production_symbol": caller_name,
                "nearest_source_anchor": caller_anchor,
                "samples": values["samples"],
                "weight_ns": values["weight_ns"],
                "weight_ms": values["weight_ns"] / 1_000_000,
                "share_of_total_weight_percent": round(
                    100.0 * values["weight_ns"] / total_weight_ns, 6
                ),
            }
        )

    memory_anywhere_stack_groups = []
    for key, values in sorted(
        memory_anywhere_groups.items(),
        key=lambda item: (-item[1]["weight_ns"], item[0]),
    ):
        category, caller_name, caller_anchor = key
        memory_anywhere_stack_groups.append(
            {
                "category": category,
                "nearest_source_backed_production_symbol": caller_name,
                "nearest_source_anchor": caller_anchor,
                "samples": values["samples"],
                "weight_ns": values["weight_ns"],
                "weight_ms": values["weight_ns"] / 1_000_000,
                "share_of_total_weight_percent": round(
                    100.0 * values["weight_ns"] / total_weight_ns, 6
                ),
            }
        )

    memory_anywhere_caller_unions = []
    for key, values in sorted(
        memory_anywhere_caller_union.items(),
        key=lambda item: (-item[1]["weight_ns"], item[0]),
    ):
        caller_name, caller_anchor = key
        memory_anywhere_caller_unions.append(
            {
                "nearest_source_backed_production_symbol": caller_name,
                "nearest_source_anchor": caller_anchor,
                "samples": values["samples"],
                "weight_ns": values["weight_ns"],
                "weight_ms": values["weight_ns"] / 1_000_000,
                "share_of_total_weight_percent": round(
                    100.0 * values["weight_ns"] / total_weight_ns, 6
                ),
            }
        )

    summary = toc_root.find("./run/info/summary")
    environment = {
        item.get("key"): item.get("value")
        for item in toc_root.findall("./run/info/target/environment/item")
    }
    output = {
        "schema_version": "1.0.0",
        "method": {
            "input_table": "time-profile",
            "inclusive_definition": "Each sample contributes its weight once to every distinct source-backed production symbol present in its backtrace.",
            "leaf_definition": "A sample contributes leaf weight only when backtrace frame zero is a source-backed production symbol.",
            "memory_stack_definition": "A stack is counted when frame zero matches the explicit memory-copy, allocator/release, or array-storage classifier in this script; it is grouped by the nearest source-backed production frame.",
            "production_symbol_definition": "A frame from Mirmir.debug.dylib with a source path under the repository Mirmir directory.",
            "product_binary_symbol_definition": "Any frame from Mirmir.debug.dylib or the Mirmir executable, including compiler-generated frames without a positive source line.",
            "memory_stack_anywhere_definition": "Overlapping sample sets whose backtraces contain a malloc-library frame, a move/copy primitive, a set/zero primitive, or a Swift allocation/deallocation primitive; union values are deduplicated by sample.",
        },
        "measurement_boundary": {
            "configuration": "Debug",
            "coverage_runtime_attached": bool(environment.get("LLVM_PROFILE_FILE")),
            "xctest_injected": bool(environment.get("XCTestBundleInjectPath")),
            "target_type": toc_root.find("./run/info/target/process").get("type"),
            "template": summary.findtext("template-name") if summary is not None else None,
            "configured_time_limit": summary.findtext("time-limit") if summary is not None else None,
            "trace_duration_seconds": float(summary.findtext("duration", "0")) if summary is not None else None,
            "end_reason": summary.findtext("end-reason") if summary is not None else None,
            "sample_time_span_seconds": (
                (max(sample_times) - min(sample_times)) / 1_000_000_000 if sample_times else 0
            ),
            "generalization": "None. These weights describe only this attached capture window."
        },
        "inputs": {
            "profile_xml": str(args.profile_xml),
            "profile_xml_sha256": sha256(args.profile_xml),
            "toc_xml": str(args.toc_xml),
            "toc_xml_sha256": sha256(args.toc_xml),
        },
        "totals": {
            "samples": total_samples,
            "weight_ns": total_weight_ns,
            "weight_ms": total_weight_ns / 1_000_000,
            "production_stack_samples": production_stack_samples,
            "production_stack_weight_ns": production_stack_weight_ns,
            "production_stack_weight_ms": production_stack_weight_ns / 1_000_000,
            "production_stack_share_of_total_weight_percent": round(
                100.0 * production_stack_weight_ns / total_weight_ns, 6
            ),
            "product_binary_stack_samples": product_binary_stack_samples,
            "product_binary_stack_weight_ns": product_binary_stack_weight_ns,
            "product_binary_stack_weight_ms": product_binary_stack_weight_ns / 1_000_000,
            "product_binary_leaf_samples": product_binary_leaf_samples,
            "product_binary_leaf_weight_ns": product_binary_leaf_weight_ns,
            "product_binary_leaf_weight_ms": product_binary_leaf_weight_ns / 1_000_000,
            "product_binary_leaf_share_of_total_weight_percent": round(
                100.0 * product_binary_leaf_weight_ns / total_weight_ns, 6
            ),
            "source_backed_production_symbol_count": len(symbols),
            "product_binary_symbol_count": len(product_symbols),
            "sample_weight_distribution_ns": {
                str(weight): count for weight, count in sorted(weight_distribution.items())
            },
        },
        "production_symbols": symbols,
        "product_binary_symbols": product_symbols,
        "memory_related_totals": {
            category: {
                **values,
                "weight_ms": values["weight_ns"] / 1_000_000,
                "share_of_total_weight_percent": round(
                    100.0 * values["weight_ns"] / total_weight_ns, 6
                ),
            }
            for category, values in sorted(memory_totals.items())
        },
        "memory_related_stack_groups": memory_stack_groups,
        "memory_stack_anywhere_totals": {
            category: {
                **values,
                "weight_ms": values["weight_ns"] / 1_000_000,
                "share_of_total_weight_percent": round(
                    100.0 * values["weight_ns"] / total_weight_ns, 6
                ),
            }
            for category, values in sorted(memory_anywhere_totals.items())
        },
        "memory_stack_anywhere_deduplicated_union": {
            **memory_anywhere_union,
            "weight_ms": memory_anywhere_union["weight_ns"] / 1_000_000,
            "share_of_total_weight_percent": round(
                100.0 * memory_anywhere_union["weight_ns"] / total_weight_ns, 6
            ),
        },
        "memory_stack_anywhere_groups": memory_anywhere_stack_groups,
        "memory_stack_anywhere_caller_unions": memory_anywhere_caller_unions,
        "limitations": [
            "Sample weights are not wall-clock duration and inclusive symbol percentages are not mutually exclusive.",
            "The Debug configuration, coverage runtime, injected test bundle, and profiler attachment can perturb execution.",
            "The classifier reports sampled stacks only; absence of a sample does not prove absence of allocation or copying.",
            "Source anchors are the locations carried by this trace and can differ after source edits.",
            "No result is generalized beyond this attached capture window."
        ],
    }
    print(json.dumps(output, indent=2, sort_keys=False))


if __name__ == "__main__":
    main()
