#!/usr/bin/env python3
"""Tests for deterministic M7 simulator candidate selection."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("select_simulated_candidate_v4.py")
SPEC = importlib.util.spec_from_file_location("select_simulated_candidate_v4", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
selector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = selector
SPEC.loader.exec_module(selector)


def contract() -> dict:
    return {
        "schemaVersion": selector.SCHEMA_CONTRACT,
        "baselineVariant": "baseline_p05",
        "candidateVariants": list(selector.LOCKED_CANDIDATES),
        "eligibleCorpusKinds": ["synthetic_diagnostic"],
        "quality": {
            "minimumIndex": 105.0,
            "minimumPairedBootstrap95PercentLowerBound": 105.0,
        },
        "timing": {
            "maximumMedianRatio": 0.8,
            "maximumP95Ratio": 0.8,
            "maximumTotalRatio": 0.8,
        },
        "selectionOrder": [
            "qualityLowerConfidenceBoundDescending",
            "qualityIndexDescending",
            "totalProcessingTimeRatioAscending",
            "p95ProcessingTimeRatioAscending",
            "medianProcessingTimeRatioAscending",
            "candidateIDAscending",
        ],
    }


def report() -> dict:
    clips = []
    for cohort in ("detail", "motion"):
        for index in range(2):
            clips.append(
                {
                    "clipID": f"{cohort}-{index}",
                    "cohort": cohort,
                    "components": {
                        "baseline_p05": {"error": 1.0},
                        "candidate_v4": {"error": 0.70 + index * 0.01},
                        "uniform_priors": {"error": 0.75 + index * 0.01},
                        "randomized_state_message": {"error": 0.76 + index * 0.01},
                        "temporal_hysteresis_off": {"error": 0.77 + index * 0.01},
                        "motion_history_off": {"error": 0.78 + index * 0.01},
                    },
                }
            )
    return {
        "schemaVersion": "mirmir-ash-v4-quality-report-v1",
        "contract": {
            "bootstrap": {"replicateCount": 1000, "seedUnsignedDecimal": 7},
            "components": [{"id": "error", "weight": 1.0}],
        },
        "corpus": {
            "corpusID": "fixture",
            "corpusKind": "synthetic_diagnostic",
            "caseCount": 24,
            "clipCount": 4,
        },
        "identities": {"sourceCommit": "a" * 40},
        "quality": {
            "summaries": {
                "baseline_p05": {"qualityIndex": 100.0},
                "candidate_v4": {"qualityIndex": 129.5},
                "uniform_priors": {"qualityIndex": 124.5},
                "randomized_state_message": {"qualityIndex": 123.5},
                "temporal_hysteresis_off": {"qualityIndex": 122.5},
                "motion_history_off": {"qualityIndex": 121.5},
            }
        },
        "timingDiagnostic": {
            "variants": {
                variant: {
                    "medianMilliseconds": value,
                    "p95Milliseconds": value,
                    "totalMilliseconds": value * 10,
                }
                for variant, value in {
                    "baseline_p05": 10.0,
                    "candidate_v4": 7.0,
                    "uniform_priors": 5.0,
                    "randomized_state_message": 5.5,
                    "temporal_hysteresis_off": 6.0,
                    "motion_history_off": 6.5,
                }.items()
            }
        },
        "perClip": clips,
    }


def identity_arguments() -> dict[str, str]:
    return {
        "contract_sha256": "1" * 64,
        "quality_report_sha256": "2" * 64,
        "capture_binding_sha256": "3" * 64,
        "canonical_quality_contract_sha256": "4" * 64,
        "p05_discovery_sha256": "5" * 64,
        "p05_binding_sha256": "6" * 64,
    }


class SimulatedCandidateSelectionTests(unittest.TestCase):
    def test_selects_highest_confidence_quality_after_thresholds(self) -> None:
        result = selector.build_selection(
            contract(),
            report(),
            **identity_arguments(),
        )

        self.assertTrue(result["m7Satisfied"])
        self.assertEqual(result["selectedCandidateID"], "candidate_v4")
        self.assertEqual(len(result["candidates"]), 5)
        self.assertTrue(all(item["eligible"] for item in result["candidates"]))

    def test_records_when_no_candidate_meets_time_target(self) -> None:
        value = report()
        for candidate in selector.LOCKED_CANDIDATES:
            value["timingDiagnostic"]["variants"][candidate] = {
                "medianMilliseconds": 9.0,
                "p95Milliseconds": 9.0,
                "totalMilliseconds": 90.0,
            }

        result = selector.build_selection(
            contract(),
            value,
            **identity_arguments(),
        )

        self.assertFalse(result["m7Satisfied"])
        self.assertIsNone(result["selectedCandidateID"])
        self.assertEqual(len(result["candidates"]), 5)
        self.assertTrue(result["qualificationFailureReason"])

    def test_selects_the_only_eligible_candidate(self) -> None:
        value = report()
        for candidate in selector.LOCKED_CANDIDATES:
            value["timingDiagnostic"]["variants"][candidate] = {
                "medianMilliseconds": 9.0,
                "p95Milliseconds": 9.0,
                "totalMilliseconds": 90.0,
            }
        value["timingDiagnostic"]["variants"]["uniform_priors"] = {
            "medianMilliseconds": 5.0,
            "p95Milliseconds": 5.0,
            "totalMilliseconds": 50.0,
        }

        result = selector.build_selection(
            contract(),
            value,
            **identity_arguments(),
        )

        self.assertTrue(result["m7Satisfied"])
        self.assertEqual(result["selectedCandidateID"], "uniform_priors")
        self.assertIsNone(result["qualificationFailureReason"])

    def test_rejects_unlisted_corpus_kind(self) -> None:
        value = report()
        value["corpus"]["corpusKind"] = "locked_natural"

        with self.assertRaisesRegex(selector.SelectionError, "not eligible"):
            selector.build_selection(
                contract(),
                value,
                **identity_arguments(),
            )

    def test_rejects_weakened_threshold(self) -> None:
        value = contract()
        value["timing"]["maximumTotalRatio"] = 0.9

        with self.assertRaisesRegex(selector.SelectionError, "differs from the M7 target"):
            selector.build_selection(
                value,
                report(),
                **identity_arguments(),
            )

    def test_capture_binding_reproduces_injected_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindings = root / "bindings"
            bindings.mkdir()
            canonical = MODULE_PATH.with_name("QualityGateCaptureTests.swift").read_text(
                encoding="utf-8"
            )
            injections = {
                "__MIRMIR_V4_QUALITY_CAPTURE_DIR__": "/tmp/capture",
                "__MIRMIR_V4_QUALITY_CORPUS_MANIFEST__": "/tmp/corpus.json",
                "__MIRMIR_V4_QUALITY_CONTRACT_SHA256__": "c" * 64,
                "__MIRMIR_V4_QUALITY_SOURCE_COMMIT__": "a" * 40,
                "__MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256__": "b" * 64,
            }
            injected = canonical
            for sentinel, value in injections.items():
                injected = injected.replace(json.dumps(sentinel), json.dumps(value))
            (bindings / "QualityGateCaptureTests.swift").write_text(
                canonical,
                encoding="utf-8",
            )
            (bindings / "QualityGateCaptureTests.injected.swift").write_text(
                injected,
                encoding="utf-8",
            )
            binding = {
                "schemaVersion": "mirmir-ash-v4-m7-capture-binding-v1",
                "sourceCommit": "a" * 40,
                "sourceTreeIdentitySHA256": "b" * 64,
                "canonicalCaptureSourceSHA256": hashlib.sha256(canonical.encode()).hexdigest(),
                "injectedCaptureSourceSHA256": hashlib.sha256(injected.encode()).hexdigest(),
                "injections": injections,
                "timedVariantBaseOrder": list(selector.LOCKED_CANDIDATES),
                "timedVariantOrder": "left rotation by sorted-case ordinal modulo five",
                "warmupCountPerVariant": 5,
            }
            binding_path = root / "m7-capture-binding.json"
            binding_path.write_text(
                json.dumps(binding, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            identity = selector.validate_capture_binding(
                binding_path,
                {
                    "identities": {
                        "sourceCommit": "a" * 40,
                        "sourceTreeIdentitySHA256": "b" * 64,
                        "contractSHA256": "c" * 64,
                    }
                },
            )

            self.assertEqual(identity, hashlib.sha256(binding_path.read_bytes()).hexdigest())

    def test_rejects_canonical_quality_contract_not_checked_into_repository(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository_contract_path = MODULE_PATH.with_name("quality-gate-contract-v1.json")
            canonical_value = json.loads(repository_contract_path.read_text(encoding="utf-8"))
            canonical_value["fixtureTamper"] = True
            canonical_path = root / "canonical.json"
            canonical_path.write_text(
                json.dumps(canonical_value, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            frozen = canonical_value["frozenP05Baseline"]
            discovery = {
                "sourceTreeIdentitySHA256": frozen["sourceTreeIdentitySHA256"],
                "sourceManifestSHA256": frozen["sourceManifestSHA256"],
                "captureSourceSHA256": frozen["captureSourceSHA256"],
                "executableSHA256": "1" * 64,
                "captureExecutableSHA256": "2" * 64,
            }
            discovery_path = root / "discovery.json"
            discovery_path.write_text(
                json.dumps(discovery, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            derivation = selector.load_derivation_module()
            derived, binding = derivation.derive(
                canonical_value,
                discovery,
                canonical_sha256=hashlib.sha256(canonical_path.read_bytes()).hexdigest(),
            )
            derived_path = root / "derived.json"
            binding_path = root / "binding.json"
            derived_path.write_bytes(derivation.encoded(derived))
            binding_path.write_bytes(derivation.encoded(binding))

            with self.assertRaisesRegex(
                selector.SelectionError,
                "canonical quality contract differs from the repository contract",
            ):
                selector.validate_p05_derivation(
                    canonical_path,
                    discovery_path,
                    derived_path,
                    binding_path,
                )

    def test_rejects_reported_timing_that_does_not_replay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            quality_report_path = root / "quality-report.json"
            quality_report_path.write_text("{}\n", encoding="utf-8")
            value = report()
            variants = ("baseline_p05", *selector.LOCKED_CANDIDATES)
            case_timings = {
                variant: float(index + 1)
                for index, variant in enumerate(variants)
            }
            (root / "capture-manifest.json").write_text(
                json.dumps({"cases": [{"milliseconds": case_timings}]}) + "\n",
                encoding="utf-8",
            )
            value["timingDiagnostic"]["variants"] = {
                variant: {
                    "sampleCount": 1,
                    "medianMilliseconds": milliseconds,
                    "p95Milliseconds": milliseconds,
                    "totalMilliseconds": milliseconds,
                }
                for variant, milliseconds in case_timings.items()
            }
            value["timingDiagnostic"]["variants"]["candidate_v4"][
                "totalMilliseconds"
            ] += 0.5

            with self.assertRaisesRegex(
                selector.SelectionError,
                "reported timing does not replay: candidate_v4.totalMilliseconds",
            ):
                selector.validate_replayed_timings(
                    selector.load_quality_module(),
                    quality_report_path,
                    value,
                )


if __name__ == "__main__":
    unittest.main()
