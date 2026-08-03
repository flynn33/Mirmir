#!/usr/bin/env python3
"""Fail-closed identity and reproducibility tests for quality_gate_v4.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "quality_gate_v4", SCRIPT_DIRECTORY / "quality_gate_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
quality_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality_gate)


class QualityGateV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = SCRIPT_DIRECTORY / "quality-gate-contract-v1.json"

    def testSyntheticCorpusReproducesByteForByte(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            first = root / "first"
            second = root / "second"
            with contextlib.redirect_stdout(io.StringIO()):
                quality_gate.generate_corpus(self.contract, first)
                quality_gate.generate_corpus(self.contract, second)
            first_manifest = (first / "corpus-manifest.json").read_bytes()
            second_manifest = (second / "corpus-manifest.json").read_bytes()
            self.assertEqual(first_manifest, second_manifest)
            manifest = json.loads(first_manifest)
            self.assertEqual(manifest["caseCount"], 168)
            self.assertEqual(manifest["clipCount"], 28)
            self.assertFalse(manifest["releaseEligible"])
            self.assertEqual(
                manifest["artifactSetSHA256"],
                quality_gate.artifact_set_sha(
                    (entry["path"], entry["sha256"])
                    for entry in manifest["artifacts"]
                ),
            )

    def testArtifactTamperAndPathEscapeFailClosed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            corpus = root / "corpus"
            with contextlib.redirect_stdout(io.StringIO()):
                quality_gate.generate_corpus(self.contract, corpus)
            manifest = json.loads((corpus / "corpus-manifest.json").read_text())
            first = manifest["artifacts"][0]
            path = corpus / first["path"]
            path.write_bytes(path.read_bytes() + b"tamper")
            with self.assertRaisesRegex(ValueError, "size mismatch"):
                quality_gate.validate_artifacts(corpus, manifest["artifacts"])
            with self.assertRaisesRegex(ValueError, "escapes root"):
                quality_gate.checked_relative(corpus, "../outside")

    def testReportCannotPromoteSyntheticOrUnlockedRuntime(self) -> None:
        digest = "0" * 64
        identities = {
            "contractSHA256": digest,
            "metricToolSHA256": digest,
            "captureTestSourceSHA256": digest,
            "corpusManifestSHA256": digest,
            "corpusArtifactSetSHA256": digest,
            "runtimeManifestSHA256": digest,
            "runtimeSourceRevision": "a" * 40,
            "sourceCommit": "b" * 40,
            "sourceTreeIdentitySHA256": digest,
            "cropRuleSHA256": digest,
            "metricModelSHA256": digest,
            "outputSetSHA256": {
                variant: digest for variant in quality_gate.VARIANTS
            },
        }
        report = {
            "schemaVersion": quality_gate.SCHEMA_REPORT,
            "identities": identities,
            "corpus": {"releaseEligible": False},
            "runtime": {"productionRuntimeLocked": False},
            "quality": {
                "summaries": {"candidate_v4": {}},
                "gates": {"releaseQualityGatePass": True},
            },
        }
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            path = Path(temporary) / "report.json"
            path.write_text(json.dumps(report))
            with self.assertRaisesRegex(SystemExit, "ineligible evidence"):
                quality_gate.verify_report(path)
            del report["identities"]["cropRuleSHA256"]
            path.write_text(json.dumps(report))
            with self.assertRaisesRegex(SystemExit, "identity set"):
                quality_gate.verify_report(path)

    def testSplitMixSequenceAndRejectionIndexAreLocked(self) -> None:
        generator = quality_gate.SplitMix64(1095977012)
        self.assertEqual(
            [generator.next() for _ in range(4)],
            [
                16184690339002422794,
                7296582889478452222,
                11025824772574243359,
                11370822711440041114,
            ],
        )
        generator = quality_gate.SplitMix64(1095977012)
        self.assertEqual([generator.index(7) for _ in range(8)], [4, 2, 0, 6, 2, 5, 5, 5])

    def testVerifierRecomputesSummariesAndRejectsSemanticTamper(self) -> None:
        contract = json.loads(self.contract.read_text())
        cohorts = contract["cohortConstraints"]["contentCohorts"]
        weights = {item["id"]: float(item["weight"]) for item in contract["components"]}
        per_clip = []
        metrics = {}
        clips_by_cohort = {cohort: [] for cohort in cohorts}
        for cohort in cohorts:
            for index in range(4):
                clip_id = f"{cohort}-fixture-{index}"
                clips_by_cohort[cohort].append(clip_id)
                components = {
                    variant: {
                        component: 1.0 if variant == "baseline_p05" else 0.9
                        for component in weights
                    }
                    for variant in quality_gate.VARIANTS
                }
                metrics[clip_id] = components
                per_clip.append(
                    {
                        "clipID": clip_id,
                        "cohort": cohort,
                        "pixelFormat": "420v" if index % 2 == 0 else "420f",
                        "frameCount": 6,
                        "components": components,
                    }
                )
        summaries = {}
        for variant in quality_gate.VARIANTS:
            aggregate, by_cohort, error, quality = quality_gate.aggregate_ratios(
                metrics, clips_by_cohort, variant, weights
            )
            summaries[variant] = {
                "normalizedComponents": aggregate,
                "normalizedComponentsByCohort": by_cohort,
                "weightedError": error,
                "qualityIndex": quality,
            }
        candidate = summaries["candidate_v4"]
        candidate["pairedBootstrap95PercentCI"] = {
            "lower": candidate["qualityIndex"],
            "upper": candidate["qualityIndex"],
            "replicateCount": 10000,
            "lowerOrderStatisticIndex": 250,
        }
        luma_id = "luma_multiscale_structural_error"
        temporal_id = "motion_compensated_temporal_flicker_error"
        luma = {
            cohort: candidate["normalizedComponentsByCohort"][cohort][luma_id]
            for cohort in cohorts
        }
        temporal = {
            cohort: candidate["normalizedComponentsByCohort"][cohort][temporal_id]
            for cohort in contract["cohortConstraints"]["temporalNonRegressionCohorts"]
        }
        gates = {
            "identityPass": True,
            "naturalCorpusEligibilityPass": False,
            "productionRuntimeLockPass": False,
            "requiredAblationsPresentPass": True,
            "qualityPointEstimatePass": True,
            "qualityLowerConfidenceBoundPass": True,
            "allCohortLumaNonRegressionPass": True,
            "temporalCohortNonRegressionPass": True,
            "candidateBackendIdentityPass": True,
            "fullMirrorIdentityPass": True,
            "releaseQualityGatePass": False,
        }
        tool = SCRIPT_DIRECTORY / "quality_gate_v4.py"
        capture_source = SCRIPT_DIRECTORY / "QualityGateCaptureTests.swift"
        tool_identity = quality_gate.sha256(tool)
        crop_identity = quality_gate.sha256_bytes(
            quality_gate.canonical_bytes(
                [{item["id"]: item["crop"]} for item in contract["components"]]
            )
        )
        model_identity = quality_gate.sha256_bytes(
            b"mirmir-analytic-quality-model-v1\0"
            + quality_gate.canonical_bytes(contract["components"])
            + bytes.fromhex(tool_identity)
        )
        digest = "0" * 64
        report = {
            "schemaVersion": quality_gate.SCHEMA_REPORT,
            "contract": contract,
            "identities": {
                "contractSHA256": quality_gate.sha256(self.contract),
                "metricToolSHA256": tool_identity,
                "captureTestSourceSHA256": quality_gate.sha256(capture_source),
                "corpusManifestSHA256": digest,
                "corpusArtifactSetSHA256": digest,
                "runtimeManifestSHA256": digest,
                "runtimeSourceRevision": "a" * 40,
                "sourceCommit": "b" * 40,
                "sourceTreeIdentitySHA256": digest,
                "cropRuleSHA256": crop_identity,
                "metricModelSHA256": model_identity,
                "outputSetSHA256": {
                    variant: digest for variant in quality_gate.VARIANTS
                },
            },
            "corpus": {
                "corpusID": "semantic-verifier-fixture",
                "corpusKind": "synthetic_diagnostic",
                "releaseEligible": False,
                "limitations": ["test fixture"],
                "clipCount": 28,
                "caseCount": 168,
                "cohorts": cohorts,
            },
            "runtime": {
                "candidateBackendID": "mirmir_deterministic_cpu",
                "candidateImplementationVersion": "test",
                "baselineImplementationVersion": "test",
                "productionRuntimeLocked": False,
                "fullMirrorIdentityPass": True,
            },
            "quality": {
                "summaries": summaries,
                "perCohortLumaCandidateToBaselineRatio": luma,
                "temporalCandidateToBaselineRatio": temporal,
                "gates": gates,
            },
            "timingDiagnostic": {"releasePerformanceGateEligible": False},
            "perClip": per_clip,
        }
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            path = Path(temporary) / "report.json"
            quality_gate.write_json(path, report)
            with contextlib.redirect_stdout(io.StringIO()):
                quality_gate.verify_report(path)
            report["quality"]["summaries"]["candidate_v4"]["qualityIndex"] += 1.0
            quality_gate.write_json(path, report)
            with self.assertRaisesRegex(SystemExit, "report value mismatch"):
                quality_gate.verify_report(path)


if __name__ == "__main__":
    unittest.main()
