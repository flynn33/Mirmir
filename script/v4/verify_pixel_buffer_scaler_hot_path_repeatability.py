#!/usr/bin/env python3
"""Recompute and verify every scaler hot-path repeatability pair."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys


SCHEMA = "mirmir-v4-pixel-buffer-hot-path-repeatability-v4"
SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIRECTORY.parent.parent
EVALUATOR = SCRIPT_DIRECTORY / "evaluate_pixel_buffer_scaler_hot_path.py"
EVIDENCE_DIRECTORY = pathlib.Path(
    "docs/v4/evidence/m2-pixel-buffer-hot-path-2026-10-02"
)
REPEATABILITY_REPORT = EVIDENCE_DIRECTORY / "repeatability.json"
PAIR_PATHS = (
    (
        "baseline-54d97e3.json",
        "prepared-direct-after.json",
        "evaluation.json",
    ),
    (
        "baseline-54d97e3-pair-02.json",
        "prepared-direct-after-pair-02.json",
        "evaluation-pair-02.json",
    ),
    (
        "baseline-54d97e3-pair-03.json",
        "prepared-direct-after-pair-03.json",
        "evaluation-pair-03.json",
    ),
    (
        "baseline-54d97e3-pair-04.json",
        "prepared-direct-after-pair-04.json",
        "evaluation-pair-04.json",
    ),
)
METRICS = (
    "cpuMedianMilliseconds",
    "cpuP95Milliseconds",
    "metalMedianMilliseconds",
    "metalP95Milliseconds",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256_file(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_json(value: object) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def relative_artifact(name: str) -> pathlib.Path:
    return EVIDENCE_DIRECTORY / name


def read_json(path: pathlib.Path) -> dict:
    absolute = REPOSITORY_ROOT / path
    try:
        value = json.loads(absolute.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"unable to read repeatability artifact {path}: {error}")
    if not isinstance(value, dict):
        fail(f"repeatability artifact is not an object: {path}")
    return value


def evaluate_pair(
    pair_number: int,
    baseline_path: pathlib.Path,
    candidate_path: pathlib.Path,
    evaluation_path: pathlib.Path,
) -> tuple[dict, dict, dict, dict]:
    result = subprocess.run(
        [
            sys.executable,
            str(EVALUATOR.relative_to(REPOSITORY_ROOT)),
            str(baseline_path),
            str(candidate_path),
        ],
        cwd=REPOSITORY_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        fail(
            f"repeatability pair {pair_number} failed evaluation: "
            f"{result.stderr.strip()}"
        )
    try:
        recomputed_evaluation = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"pair {pair_number} evaluator output is invalid: {error}")
    stored_evaluation = read_json(evaluation_path)
    stored_evaluation_text = (REPOSITORY_ROOT / evaluation_path).read_text()
    if stored_evaluation_text != canonical_json(stored_evaluation):
        fail(f"stored evaluation is not canonical for pair {pair_number}")
    if result.stdout != stored_evaluation_text:
        fail(f"stored evaluation differs from replay for pair {pair_number}")
    if stored_evaluation.get("passed") is not True:
        fail(f"stored evaluation did not pass for pair {pair_number}")

    baseline = read_json(baseline_path)
    candidate = read_json(candidate_path)
    baseline_absolute = REPOSITORY_ROOT / baseline_path
    candidate_absolute = REPOSITORY_ROOT / candidate_path
    evaluation_absolute = REPOSITORY_ROOT / evaluation_path
    hashes = {
        "baselineCaptureSHA256": sha256_file(baseline_absolute),
        "candidateCaptureSHA256": sha256_file(candidate_absolute),
        "evaluationSHA256": sha256_file(evaluation_absolute),
    }
    if stored_evaluation.get("baselineCaptureSHA256") != hashes[
        "baselineCaptureSHA256"
    ]:
        fail(f"baseline hash mismatch for pair {pair_number}")
    if stored_evaluation.get("candidateCaptureSHA256") != hashes[
        "candidateCaptureSHA256"
    ]:
        fail(f"candidate hash mismatch for pair {pair_number}")

    summary = {
        "pair": pair_number,
        "baseline": str(baseline_path),
        "candidate": str(candidate_path),
        "evaluation": str(evaluation_path),
        **hashes,
        "aggregateRatios": stored_evaluation["aggregateRatios"],
        "caseRatios": stored_evaluation["caseRatios"],
        "passed": True,
    }
    return summary, baseline, candidate, stored_evaluation


def cross_pair_identity(capture: dict) -> dict:
    identities = capture["identities"]
    return {
        "scope": capture["scope"],
        "configuration": capture["configuration"],
        "environment": capture["environment"],
        "compiler": capture["compiler"],
        "benchmarkSourceSHA256": identities["benchmarkSourceSHA256"],
        "runnerSourceSHA256": identities["runnerSourceSHA256"],
        "engineSourceSHA256": identities["engineSourceSHA256"],
        "engineSourceManifest": identities["engineSourceManifest"],
        "metalLibrarySHA256": identities["metalLibrarySHA256"],
        "cases": [
            {
                key: value
                for key, value in case.items()
                if key
                not in {
                    "cpuMilliseconds",
                    "cpuMedianMilliseconds",
                    "cpuP95Milliseconds",
                    "metalMilliseconds",
                    "metalMedianMilliseconds",
                    "metalP95Milliseconds",
                }
            }
            for case in capture["cases"]
        ],
    }


def build_report() -> dict:
    pairs: list[dict] = []
    baseline_identity: dict | None = None
    candidate_identity: dict | None = None
    evaluator_identity = sha256_file(EVALUATOR)
    threshold: dict | None = None

    for pair_number, names in enumerate(PAIR_PATHS, start=1):
        baseline_path, candidate_path, evaluation_path = map(
            relative_artifact,
            names,
        )
        summary, baseline, candidate, evaluation = evaluate_pair(
            pair_number,
            baseline_path,
            candidate_path,
            evaluation_path,
        )
        current_baseline_identity = cross_pair_identity(baseline)
        current_candidate_identity = cross_pair_identity(candidate)
        if baseline_identity is None:
            baseline_identity = current_baseline_identity
            candidate_identity = current_candidate_identity
            threshold = evaluation["threshold"]
        elif (
            current_baseline_identity != baseline_identity
            or current_candidate_identity != candidate_identity
        ):
            fail(f"machine, workload, or source identity changed in pair {pair_number}")
        if evaluation.get("threshold") != threshold:
            fail(f"threshold changed in pair {pair_number}")
        if evaluation.get("evaluatorSourceSHA256") != evaluator_identity:
            fail(f"evaluator source identity changed in pair {pair_number}")
        pairs.append(summary)

    worst_aggregate = {
        metric: max(pair["aggregateRatios"][metric] for pair in pairs)
        for metric in METRICS
    }
    worst_case = {
        metric: max(
            ratios[metric]
            for pair in pairs
            for ratios in pair["caseRatios"].values()
        )
        for metric in METRICS
    }
    return {
        "schemaVersion": SCHEMA,
        "threshold": threshold,
        "pairCount": len(pairs),
        "allPairsPassed": all(pair["passed"] for pair in pairs),
        "evaluatorSourceSHA256": evaluator_identity,
        "verifierSourceSHA256": sha256_file(pathlib.Path(__file__).resolve()),
        "baselineEngineSourceSHA256": baseline_identity["engineSourceSHA256"],
        "candidateEngineSourceSHA256": candidate_identity["engineSourceSHA256"],
        "pairs": pairs,
        "worstAggregateRatios": worst_aggregate,
        "worstCaseRatios": worst_case,
    }


def main() -> None:
    emit = sys.argv[1:] == ["--emit"]
    if sys.argv[1:] not in ([], ["--emit"]):
        fail(
            "usage: verify_pixel_buffer_scaler_hot_path_repeatability.py "
            "[--emit]"
        )
    report = build_report()
    encoded = canonical_json(report)
    if emit:
        sys.stdout.write(encoded)
        return
    stored = read_json(REPEATABILITY_REPORT)
    stored_text = (REPOSITORY_ROOT / REPEATABILITY_REPORT).read_text()
    if stored_text != canonical_json(stored):
        fail("stored repeatability report is not canonical")
    if stored_text != encoded:
        fail("stored repeatability report differs from replay")
    sys.stdout.write(encoded)


if __name__ == "__main__":
    main()
