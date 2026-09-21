#!/usr/bin/env python3
"""Select the best deterministic-engine-v4 candidate from simulator evidence."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import statistics
import sys
from typing import Any, Mapping


SCHEMA_CONTRACT = "mirmir-ash-v4-m7-simulation-selection-contract-v1"
SCHEMA_REPORT = "mirmir-ash-v4-m7-simulation-selection-report-v1"
LOCKED_CANDIDATES = (
    "candidate_v4",
    "uniform_priors",
    "randomized_state_message",
    "temporal_hysteresis_off",
    "motion_history_off",
)


class SelectionError(ValueError):
    """Raised when simulator evidence cannot produce a trustworthy selection."""


def load_quality_module():
    path = Path(__file__).with_name("quality_gate_v4.py")
    spec = importlib.util.spec_from_file_location("m7_simulation_quality_gate_v4", path)
    if spec is None or spec.loader is None:
        raise SelectionError("cannot load the quality evaluator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    module_directory = str(path.parent)
    inserted = module_directory not in sys.path
    if inserted:
        sys.path.insert(0, module_directory)
    try:
        spec.loader.exec_module(module)
    finally:
        if inserted:
            sys.path.remove(module_directory)
    return module


def load_derivation_module():
    path = Path(__file__).with_name("derive_m7_quality_contract_v4.py")
    spec = importlib.util.spec_from_file_location("m7_quality_contract_derivation_v4", path)
    if spec is None or spec.loader is None:
        raise SelectionError("cannot load the P05 contract derivation tool")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SelectionError(message)


def require_number(value: Any, label: str, *, positive: bool = False) -> float:
    require(isinstance(value, (int, float)) and not isinstance(value, bool), f"{label} is not numeric")
    number = float(value)
    require(math.isfinite(number), f"{label} is not finite")
    require(number > 0 if positive else number >= 0, f"{label} is out of range")
    return number


def validate_contract(contract: Mapping[str, Any]) -> None:
    require(contract.get("schemaVersion") == SCHEMA_CONTRACT, "unsupported selection contract")
    required = {
        "schemaVersion",
        "baselineVariant",
        "candidateVariants",
        "eligibleCorpusKinds",
        "quality",
        "timing",
        "selectionOrder",
    }
    require(set(contract) == required, "selection contract field set differs")
    baseline = contract["baselineVariant"]
    candidates = contract["candidateVariants"]
    require(isinstance(baseline, str) and baseline, "baseline variant is invalid")
    require(
        isinstance(candidates, list)
        and candidates
        and all(isinstance(item, str) and item for item in candidates)
        and len(candidates) == len(set(candidates))
        and baseline not in candidates,
        "candidate variant set is invalid",
    )
    require(tuple(candidates) == LOCKED_CANDIDATES, "candidate variant roster differs")
    require(
        contract["eligibleCorpusKinds"] == ["synthetic_diagnostic"],
        "eligible corpus kinds differ",
    )
    quality = contract["quality"]
    timing = contract["timing"]
    require(
        isinstance(quality, dict)
        and set(quality)
        == {
            "minimumIndex",
            "minimumPairedBootstrap95PercentLowerBound",
        },
        "quality threshold field set differs",
    )
    require(
        isinstance(timing, dict)
        and set(timing)
        == {
            "maximumMedianRatio",
            "maximumP95Ratio",
            "maximumTotalRatio",
        },
        "timing threshold field set differs",
    )
    require(
        contract["selectionOrder"]
        == [
            "qualityLowerConfidenceBoundDescending",
            "qualityIndexDescending",
            "totalProcessingTimeRatioAscending",
            "p95ProcessingTimeRatioAscending",
            "medianProcessingTimeRatioAscending",
            "candidateIDAscending",
        ],
        "selection order differs",
    )
    minimum_index = require_number(quality.get("minimumIndex"), "minimum quality index")
    minimum_lower = require_number(
        quality.get("minimumPairedBootstrap95PercentLowerBound"),
        "minimum quality confidence bound",
    )
    require(minimum_index == 105.0, "minimum quality index differs from the M7 target")
    require(
        minimum_lower == 105.0,
        "minimum quality confidence bound differs from the M7 target",
    )
    for field in ("maximumMedianRatio", "maximumP95Ratio", "maximumTotalRatio"):
        ratio = require_number(timing.get(field), field, positive=True)
        require(ratio == 0.8, f"{field} differs from the M7 target")


def report_metrics(
    report: Mapping[str, Any],
    variants: tuple[str, ...],
) -> tuple[dict[str, dict[str, dict[str, float]]], dict[str, list[str]]]:
    per_clip = report.get("perClip")
    require(isinstance(per_clip, list) and per_clip, "quality report has no per-clip metrics")
    metrics: dict[str, dict[str, dict[str, float]]] = {}
    clips_by_cohort: dict[str, list[str]] = {}
    for item in per_clip:
        require(isinstance(item, dict), "per-clip record is not an object")
        clip_id = item.get("clipID")
        cohort = item.get("cohort")
        components = item.get("components")
        require(isinstance(clip_id, str) and clip_id and clip_id not in metrics, "clip identity is invalid")
        require(isinstance(cohort, str) and cohort, f"clip cohort is invalid: {clip_id}")
        require(
            isinstance(components, dict) and set(components) == set(variants),
            f"clip variant set differs: {clip_id}",
        )
        normalized: dict[str, dict[str, float]] = {}
        for variant, values in components.items():
            require(isinstance(values, dict) and values, f"component set is empty: {clip_id} {variant}")
            normalized[variant] = {
                component: require_number(value, f"{clip_id}.{variant}.{component}")
                for component, value in values.items()
            }
        metrics[clip_id] = normalized
        clips_by_cohort.setdefault(cohort, []).append(clip_id)
    for clips in clips_by_cohort.values():
        clips.sort()
    return metrics, clips_by_cohort


def bootstrap_interval(
    quality: Any,
    report: Mapping[str, Any],
    metrics: dict[str, dict[str, dict[str, float]]],
    clips_by_cohort: dict[str, list[str]],
    variant: str,
    weights: dict[str, float],
) -> dict[str, float | int]:
    bootstrap = report["contract"]["bootstrap"]
    count = int(bootstrap["replicateCount"])
    require(count >= 1000, "bootstrap replicate count is too small")
    rng = quality.SplitMix64(int(bootstrap["seedUnsignedDecimal"]))
    values: list[float] = []
    for _ in range(count):
        sampled = {
            cohort: [clips[rng.index(len(clips))] for _ in clips]
            for cohort, clips in sorted(clips_by_cohort.items())
        }
        _, _, _, quality_index = quality.aggregate_ratios(
            metrics,
            clips_by_cohort,
            variant,
            weights,
            sampled,
        )
        values.append(quality_index)
    values.sort()
    lower_index = math.floor(0.025 * count)
    return {
        "lower": values[lower_index],
        "upper": values[count - 1 - lower_index],
        "replicateCount": count,
        "lowerOrderStatisticIndex": lower_index,
    }


def build_selection(
    contract: Mapping[str, Any],
    report: Mapping[str, Any],
    *,
    contract_sha256: str,
    quality_report_sha256: str,
    capture_binding_sha256: str,
    canonical_quality_contract_sha256: str,
    p05_discovery_sha256: str,
    p05_binding_sha256: str,
) -> dict[str, Any]:
    validate_contract(contract)
    require(report.get("schemaVersion") == "mirmir-ash-v4-quality-report-v1", "unsupported quality report")
    corpus = report.get("corpus")
    require(isinstance(corpus, dict), "quality report corpus is absent")
    require(
        corpus.get("corpusKind") in contract["eligibleCorpusKinds"],
        "quality corpus is not eligible for simulator selection",
    )
    baseline = contract["baselineVariant"]
    candidates = tuple(contract["candidateVariants"])
    variants = (baseline, *candidates)
    summaries = report.get("quality", {}).get("summaries")
    timings = report.get("timingDiagnostic", {}).get("variants")
    require(isinstance(summaries, dict) and set(summaries) == set(variants), "quality variant set differs")
    require(isinstance(timings, dict) and set(timings) == set(variants), "timing variant set differs")

    quality = load_quality_module()
    metrics, clips_by_cohort = report_metrics(report, variants)
    weights = {
        item["id"]: require_number(item["weight"], f"weight.{item['id']}")
        for item in report["contract"]["components"]
    }
    require(math.isclose(sum(weights.values()), 1.0, abs_tol=1e-15), "quality weights do not sum to one")

    baseline_timing = timings[baseline]
    baseline_median = require_number(baseline_timing.get("medianMilliseconds"), "baseline median", positive=True)
    baseline_p95 = require_number(baseline_timing.get("p95Milliseconds"), "baseline p95", positive=True)
    baseline_total = require_number(baseline_timing.get("totalMilliseconds"), "baseline total", positive=True)
    minimum_quality = float(contract["quality"]["minimumIndex"])
    minimum_lower = float(contract["quality"]["minimumPairedBootstrap95PercentLowerBound"])
    maximum_median = float(contract["timing"]["maximumMedianRatio"])
    maximum_p95 = float(contract["timing"]["maximumP95Ratio"])
    maximum_total = float(contract["timing"]["maximumTotalRatio"])

    candidate_results: list[dict[str, Any]] = []
    for variant in candidates:
        quality_index = require_number(summaries[variant].get("qualityIndex"), f"{variant} quality index")
        interval = bootstrap_interval(
            quality,
            report,
            metrics,
            clips_by_cohort,
            variant,
            weights,
        )
        timing = timings[variant]
        median_ratio = require_number(timing.get("medianMilliseconds"), f"{variant} median") / baseline_median
        p95_ratio = require_number(timing.get("p95Milliseconds"), f"{variant} p95") / baseline_p95
        total_ratio = require_number(timing.get("totalMilliseconds"), f"{variant} total") / baseline_total
        gates = {
            "qualityIndexPass": quality_index >= minimum_quality,
            "qualityLowerConfidenceBoundPass": float(interval["lower"]) >= minimum_lower,
            "medianProcessingTimePass": median_ratio <= maximum_median,
            "p95ProcessingTimePass": p95_ratio <= maximum_p95,
            "totalProcessingTimePass": total_ratio <= maximum_total,
        }
        candidate_results.append(
            {
                "candidateID": variant,
                "eligible": all(gates.values()),
                "gates": gates,
                "quality": {
                    "index": quality_index,
                    "gainPercentVersusP05": quality_index - 100.0,
                    "pairedBootstrap95PercentCI": interval,
                },
                "timing": {
                    "medianRatioVersusP05": median_ratio,
                    "p95RatioVersusP05": p95_ratio,
                    "totalRatioVersusP05": total_ratio,
                    "totalReductionPercentVersusP05": (1.0 - total_ratio) * 100.0,
                },
            }
        )

    eligible = [item for item in candidate_results if item["eligible"]]
    selected = min(
        eligible,
        key=lambda item: (
            -float(item["quality"]["pairedBootstrap95PercentCI"]["lower"]),
            -float(item["quality"]["index"]),
            float(item["timing"]["totalRatioVersusP05"]),
            float(item["timing"]["p95RatioVersusP05"]),
            float(item["timing"]["medianRatioVersusP05"]),
            item["candidateID"],
        ),
    ) if eligible else None
    ranked = sorted(
        candidate_results,
        key=lambda item: (
            not item["eligible"],
            -float(item["quality"]["pairedBootstrap95PercentCI"]["lower"]),
            -float(item["quality"]["index"]),
            float(item["timing"]["totalRatioVersusP05"]),
            float(item["timing"]["p95RatioVersusP05"]),
            float(item["timing"]["medianRatioVersusP05"]),
            item["candidateID"],
        ),
    )
    for rank, item in enumerate(ranked, start=1):
        item["rank"] = rank

    identities = report.get("identities")
    require(isinstance(identities, dict), "quality report identities are absent")
    source_commit = identities.get("sourceCommit")
    require(
        isinstance(source_commit, str)
        and len(source_commit) == 40
        and all(character in "0123456789abcdef" for character in source_commit),
        "quality source commit is invalid",
    )
    return {
        "schemaVersion": SCHEMA_REPORT,
        "contractSHA256": contract_sha256,
        "qualityReportSHA256": quality_report_sha256,
        "captureBindingSHA256": capture_binding_sha256,
        "canonicalQualityContractSHA256": canonical_quality_contract_sha256,
        "p05DiscoverySHA256": p05_discovery_sha256,
        "p05BindingSHA256": p05_binding_sha256,
        "sourceCommit": source_commit,
        "corpus": {
            "corpusID": corpus.get("corpusID"),
            "corpusKind": corpus.get("corpusKind"),
            "caseCount": corpus.get("caseCount"),
            "clipCount": corpus.get("clipCount"),
        },
        "thresholds": {
            "minimumQualityIndex": minimum_quality,
            "minimumQualityLowerConfidenceBound": minimum_lower,
            "maximumMedianProcessingTimeRatio": maximum_median,
            "maximumP95ProcessingTimeRatio": maximum_p95,
            "maximumTotalProcessingTimeRatio": maximum_total,
        },
        "selectionOrder": contract["selectionOrder"],
        "candidates": ranked,
        "selectedCandidateID": selected["candidateID"] if selected is not None else None,
        "m7Satisfied": selected is not None,
        "qualificationFailureReason": (
            None
            if selected is not None
            else "no simulator candidate satisfies every quality and processing-time target"
        ),
    }


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SelectionError(f"cannot read {label}: {error}") from error
    require(isinstance(value, dict), f"{label} is not an object")
    return value


def validate_capture_binding(path: Path, report: Mapping[str, Any]) -> str:
    path = path.resolve(strict=True)
    binding = load_json(path, "capture binding")
    expected_fields = {
        "schemaVersion",
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "canonicalCaptureSourceSHA256",
        "injectedCaptureSourceSHA256",
        "injections",
        "timedVariantBaseOrder",
        "timedVariantOrder",
        "warmupCountPerVariant",
    }
    require(set(binding) == expected_fields, "capture binding field set differs")
    require(
        binding.get("schemaVersion") == "mirmir-ash-v4-m7-capture-binding-v1",
        "capture binding schema differs",
    )
    identities = report.get("identities")
    require(isinstance(identities, dict), "quality report identities are absent")
    require(binding.get("sourceCommit") == identities.get("sourceCommit"), "capture source commit differs")
    require(
        binding.get("sourceTreeIdentitySHA256") == identities.get("sourceTreeIdentitySHA256"),
        "capture source-tree identity differs",
    )
    require(tuple(binding.get("timedVariantBaseOrder", ())) == LOCKED_CANDIDATES, "timed variant order differs")
    require(
        binding.get("timedVariantOrder")
        == "left rotation by sorted-case ordinal modulo five",
        "timed ordering rule differs",
    )
    require(binding.get("warmupCountPerVariant") == 5, "candidate warmup count differs")

    bindings_directory = path.parent / "bindings"
    canonical_path = bindings_directory / "QualityGateCaptureTests.swift"
    injected_path = bindings_directory / "QualityGateCaptureTests.injected.swift"
    repository_source = Path(__file__).with_name("QualityGateCaptureTests.swift")
    for source in (canonical_path, injected_path, repository_source):
        require(source.is_file() and not source.is_symlink(), f"capture source is absent or unsafe: {source}")
    canonical = canonical_path.read_text(encoding="utf-8")
    require(canonical_path.read_bytes() == repository_source.read_bytes(), "canonical capture source differs")
    require(
        hashlib.sha256(canonical.encode()).hexdigest()
        == binding.get("canonicalCaptureSourceSHA256"),
        "canonical capture-source identity differs",
    )
    injections = binding.get("injections")
    expected_sentinels = {
        "__MIRMIR_V4_QUALITY_CAPTURE_DIR__",
        "__MIRMIR_V4_QUALITY_CORPUS_MANIFEST__",
        "__MIRMIR_V4_QUALITY_CONTRACT_SHA256__",
        "__MIRMIR_V4_QUALITY_SOURCE_COMMIT__",
        "__MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256__",
    }
    require(
        isinstance(injections, dict)
        and set(injections) == expected_sentinels
        and all(isinstance(value, str) and value for value in injections.values()),
        "capture injection set differs",
    )
    require(
        injections["__MIRMIR_V4_QUALITY_SOURCE_COMMIT__"] == identities.get("sourceCommit"),
        "injected source commit differs",
    )
    require(
        injections["__MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256__"]
        == identities.get("sourceTreeIdentitySHA256"),
        "injected source-tree identity differs",
    )
    require(
        injections["__MIRMIR_V4_QUALITY_CONTRACT_SHA256__"]
        == identities.get("contractSHA256"),
        "injected quality contract identity differs",
    )
    reproduced = canonical
    for sentinel, value in injections.items():
        quoted = json.dumps(sentinel)
        require(reproduced.count(quoted) == 1, f"capture sentinel is not unique: {sentinel}")
        reproduced = reproduced.replace(quoted, json.dumps(value))
    require(reproduced.encode() == injected_path.read_bytes(), "injected capture source does not reproduce")
    require(
        hashlib.sha256(reproduced.encode()).hexdigest()
        == binding.get("injectedCaptureSourceSHA256"),
        "injected capture-source identity differs",
    )
    return sha256(path)


def validate_p05_derivation(
    canonical_path: Path,
    discovery_path: Path,
    quality_contract_path: Path,
    binding_path: Path,
) -> tuple[str, str, str]:
    for path in (canonical_path, discovery_path, quality_contract_path, binding_path):
        require(path.exists() and not path.is_symlink(), f"P05 derivation input is absent or unsafe: {path}")
    canonical_path = canonical_path.resolve(strict=True)
    discovery_path = discovery_path.resolve(strict=True)
    quality_contract_path = quality_contract_path.resolve(strict=True)
    binding_path = binding_path.resolve(strict=True)
    repository_contract_path = Path(__file__).with_name("quality-gate-contract-v1.json")
    require(
        repository_contract_path.is_file() and not repository_contract_path.is_symlink(),
        "repository quality contract is absent or unsafe",
    )
    require(
        canonical_path.read_bytes() == repository_contract_path.read_bytes(),
        "canonical quality contract differs from the repository contract",
    )
    derivation = load_derivation_module()
    canonical_bytes = canonical_path.read_bytes()
    expected_contract, expected_binding = derivation.derive(
        load_json(canonical_path, "canonical quality contract"),
        load_json(discovery_path, "P05 discovery"),
        canonical_sha256=hashlib.sha256(canonical_bytes).hexdigest(),
    )
    require(
        quality_contract_path.read_bytes() == derivation.encoded(expected_contract),
        "run-specific quality contract does not reproduce",
    )
    require(
        binding_path.read_bytes() == derivation.encoded(expected_binding),
        "P05 toolchain binding does not reproduce",
    )
    return sha256(canonical_path), sha256(discovery_path), sha256(binding_path)


def validate_replayed_timings(
    quality: Any,
    quality_report_path: Path,
    report: Mapping[str, Any],
) -> None:
    capture_path = quality_report_path.parent / "capture-manifest.json"
    capture = load_json(capture_path, "capture manifest")
    cases = capture.get("cases")
    require(isinstance(cases, list) and cases, "capture manifest has no cases")
    variants = ("baseline_p05", *LOCKED_CANDIDATES)
    samples: dict[str, list[float]] = {variant: [] for variant in variants}
    for index, case in enumerate(cases):
        require(isinstance(case, dict), f"capture case is not an object: {index}")
        timings = case.get("milliseconds")
        require(
            isinstance(timings, dict) and set(timings) == set(variants),
            f"capture timing variant set differs: {index}",
        )
        for variant in variants:
            samples[variant].append(
                require_number(timings[variant], f"capture[{index}].{variant}", positive=True)
            )
    reported = report.get("timingDiagnostic", {}).get("variants")
    require(isinstance(reported, dict) and set(reported) == set(variants), "reported timing set differs")
    for variant in variants:
        expected = {
            "sampleCount": len(samples[variant]),
            "medianMilliseconds": float(statistics.median(samples[variant])),
            "p95Milliseconds": quality.percentile(samples[variant], 95),
            "totalMilliseconds": float(sum(samples[variant])),
        }
        observed = reported[variant]
        require(isinstance(observed, dict), f"reported timing is not an object: {variant}")
        for field, value in expected.items():
            require(observed.get(field) == value, f"reported timing does not replay: {variant}.{field}")


def expected_selection(
    contract_path: Path,
    quality_report_path: Path,
    quality_contract_path: Path,
    capture_binding_path: Path,
    canonical_quality_contract_path: Path,
    p05_discovery_path: Path,
    p05_binding_path: Path,
) -> dict[str, Any]:
    contract_path = contract_path.resolve(strict=True)
    quality_report_path = quality_report_path.resolve(strict=True)
    quality_contract_path = quality_contract_path.resolve(strict=True)
    quality = load_quality_module()
    quality.verify_report(quality_report_path, quality_contract_path)
    report = load_json(quality_report_path, "quality report")
    validate_replayed_timings(quality, quality_report_path, report)
    canonical_sha, discovery_sha, binding_sha = validate_p05_derivation(
        canonical_quality_contract_path,
        p05_discovery_path,
        quality_contract_path,
        p05_binding_path,
    )
    return build_selection(
        load_json(contract_path, "selection contract"),
        report,
        contract_sha256=sha256(contract_path),
        quality_report_sha256=sha256(quality_report_path),
        capture_binding_sha256=validate_capture_binding(capture_binding_path, report),
        canonical_quality_contract_sha256=canonical_sha,
        p05_discovery_sha256=discovery_sha,
        p05_binding_sha256=binding_sha,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("select", "verify"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--contract", required=True, type=Path)
        subparser.add_argument("--quality-report", required=True, type=Path)
        subparser.add_argument("--quality-contract", required=True, type=Path)
        subparser.add_argument("--capture-binding", required=True, type=Path)
        subparser.add_argument("--canonical-quality-contract", required=True, type=Path)
        subparser.add_argument("--p05-discovery", required=True, type=Path)
        subparser.add_argument("--p05-binding", required=True, type=Path)
        subparser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args(argv)
    expected = expected_selection(
        arguments.contract,
        arguments.quality_report,
        arguments.quality_contract,
        arguments.capture_binding,
        arguments.canonical_quality_contract,
        arguments.p05_discovery,
        arguments.p05_binding,
    )
    output = arguments.output.resolve()
    if arguments.command == "select":
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(output)
        return 0
    observed = load_json(output.resolve(strict=True), "selection report")
    require(observed == expected, "selection report does not reproduce")
    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, SelectionError) as error:
        print(f"simulator candidate selection failed: {error}", file=sys.stderr)
        raise SystemExit(2)
