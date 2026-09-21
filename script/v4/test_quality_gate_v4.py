#!/usr/bin/env python3
"""Fail-closed identity and reproducibility tests for quality_gate_v4.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock


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

    def testOrderedFloatSumUsesStableManifestOrder(self) -> None:
        self.assertEqual(
            quality_gate.ordered_float_sum([1.0e16, 1.0, 1.0]),
            1.0e16,
        )

    def sealEvidence(self, root: Path) -> None:
        seal_path = root / "artifact-manifest.json"
        if seal_path.exists():
            seal_path.unlink()
        sealed = []
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.name != "artifact-manifest.json":
                sealed.append(
                    {
                        "path": path.relative_to(root).as_posix(),
                        "byteCount": path.stat().st_size,
                        "sha256": quality_gate.sha256(path),
                    }
                )
        quality_gate.write_json(
            seal_path,
            {
                "schemaVersion": "mirmir-ash-v4-quality-evidence-manifest-v1",
                "artifacts": sealed,
            },
        )

    def materializeValidEvidence(self, root: Path) -> tuple[Path, Path]:
        contract = json.loads(self.contract.read_text())
        contract["bootstrap"]["replicateCount"] = 32
        contract["cohortConstraints"]["minimumClipsPerCohort"] = 1
        contract["cohortConstraints"]["minimumFramesPerClip"] = 2
        contract["corpusConstruction"]["syntheticDiagnosticClipCountPerCohort"] = 1
        contract["corpusConstruction"]["syntheticDiagnosticFramesPerClip"] = 2
        contract_path = root / "quality-gate-contract-v1.json"
        quality_gate.write_json(contract_path, contract)

        corpus_stage = root / "corpus-stage"
        with contextlib.redirect_stdout(io.StringIO()):
            quality_gate.generate_corpus(contract_path, corpus_stage)
        shutil.move(str(corpus_stage / "artifacts"), str(root / "artifacts"))
        shutil.move(
            str(corpus_stage / "corpus-manifest.json"),
            str(root / "corpus-manifest.json"),
        )
        corpus_stage.rmdir()
        corpus_path = root / "corpus-manifest.json"
        corpus = json.loads(corpus_path.read_text())

        capture_cases = []
        for case_index, case in enumerate(corpus["cases"]):
            reference = root / case["referenceFile"]
            reference_bytes = reference.read_bytes()
            shift = 1 + case_index % 3
            transformed = reference_bytes[-shift:] + reference_bytes[:-shift]
            outputs = {}
            milliseconds = {}
            for variant_index, variant in enumerate(quality_gate.VARIANTS):
                relative = f"artifacts/{case['id']}-{variant}.nv12"
                (root / relative).write_bytes(transformed)
                outputs[variant] = relative
                milliseconds[variant] = float(variant_index + 1)
            capture_cases.append(
                {"id": case["id"], "outputs": outputs, "milliseconds": milliseconds}
            )

        identity = quality_gate.p05.frozen_identity(contract)
        capture = {
            "schemaVersion": quality_gate.SCHEMA_CAPTURE,
            "contractSHA256": quality_gate.sha256(contract_path),
            "corpusManifestSHA256": quality_gate.sha256(corpus_path),
            "sourceCommit": "b" * 40,
            "sourceTreeIdentitySHA256": "c" * 64,
            "candidateBackendID": "mirmir_deterministic_cpu",
            "candidateImplementationVersion": "ash-p06-test",
            "runtimeManifestSHA256": "d" * 64,
            "runtimeSourceRevision": "a" * 64,
            "productionRuntimeLocked": False,
            "fullMirrorIdentityPass": True,
            "warmupCount": 1,
            "baselineIdentity": identity,
            "baselineImplementationVersion": identity["implementationVersion"],
            "baselineWarmupCount": 1,
            "cases": capture_cases,
        }
        capture_path = root / "capture-manifest.json"
        quality_gate.write_json(capture_path, capture)
        report_path = root / "quality-gate-report.json"
        with contextlib.redirect_stdout(io.StringIO()):
            quality_gate.evaluate(
                contract_path, corpus_path, capture_path, report_path
            )
        self.sealEvidence(root)
        return report_path, contract_path

    def testPackagedObserverIncludesCanonicalMotionAndSpatialPaths(self) -> None:
        source = (
            SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("motionCompensatedTemporalEvidenceQ16:", source)
        self.assertIn("ASHSpatialReconstructorV4.reconstruct(", source)
        self.assertIn("uniformSpatialReconstruction(", source)
        self.assertIn("fullMirrorIdentityPass", source)
        self.assertNotIn("ASHDeterministicUpscaleBackend", source)
        self.assertNotIn("developmentP05", source)
        self.assertIn("mirmir-ash-v4-quality-candidate-capture-v1", source)

    def testPackagedArchiveVerificationFailureIsNormative(self) -> None:
        verifier = mock.Mock()
        verifier.validate_capture_binding.side_effect = ValueError(
            "candidate record differs from the verified application archive"
        )
        with mock.patch.object(
            quality_gate, "packaged_evidence_module", return_value=verifier
        ), self.assertRaisesRegex(SystemExit, "verified application archive"):
            quality_gate.validate_packaged_quality_capture(
                Path("packaged-quality"),
                Path("repository"),
                Path("runtime"),
                {},
                Path("capture"),
            )

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

    def testMutatedP05IdentityFailsBeforeScoring(self) -> None:
        contract = json.loads(self.contract.read_text())
        identity = quality_gate.p05.frozen_identity(contract)
        identity["executableSHA256"] = "f" * 64
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            contract_path = root / "contract.json"
            corpus_path = root / "corpus.json"
            capture_path = root / "capture.json"
            quality_gate.write_json(contract_path, contract)
            quality_gate.write_json(
                corpus_path, {"schemaVersion": quality_gate.SCHEMA_CORPUS}
            )
            quality_gate.write_json(
                capture_path,
                {
                    "schemaVersion": quality_gate.SCHEMA_CAPTURE,
                    "baselineIdentity": identity,
                },
            )
            with mock.patch.object(
                quality_gate,
                "component_errors",
                side_effect=AssertionError("scoring must not execute"),
            ) as scoring:
                with self.assertRaisesRegex(SystemExit, "frozen P05 identity"):
                    quality_gate.evaluate(
                        contract_path,
                        corpus_path,
                        capture_path,
                        root / "report.json",
                    )
                scoring.assert_not_called()

    def testReportCannotPromoteSyntheticOrUnlockedRuntime(self) -> None:
        digest = "0" * 64
        identities = {
            "contractSHA256": digest,
            "metricToolSHA256": digest,
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
            "evidenceRequestSHA256": None,
            "observerSourceSHA256": None,
            "packagedCaptureTreeSHA256": None,
            "packagedCandidateIdentity": None,
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

    def testVerifierReplaysSealedPlanesAndRejectsMissingEvidence(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            report_path, contract_path = self.materializeValidEvidence(root)
            with contextlib.redirect_stdout(io.StringIO()):
                quality_gate.verify_report(report_path, contract_path)
            with self.assertRaisesRegex(
                SystemExit,
                "final quality verification requires a release-quality pass",
            ):
                quality_gate.verify_report(
                    report_path,
                    contract_path,
                    require_release=True,
                )

            capture = json.loads((root / "capture-manifest.json").read_text())
            capture_artifact = root / capture["cases"][0]["outputs"]["candidate_v4"]
            capture_bytes = capture_artifact.read_bytes()
            capture_artifact.unlink()
            with self.assertRaisesRegex(ValueError, "missing artifact"):
                quality_gate.verify_report(report_path, contract_path)
            capture_artifact.write_bytes(capture_bytes)

            seal_path = root / "artifact-manifest.json"
            seal_bytes = seal_path.read_bytes()
            seal_path.unlink()
            with self.assertRaisesRegex(SystemExit, "evidence seal is absent"):
                quality_gate.verify_report(report_path, contract_path)
            seal_path.write_bytes(seal_bytes)

    def testFullyResealedForgedPerClipMetricFailsRawReplay(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            report_path, contract_path = self.materializeValidEvidence(root)
            report = json.loads(report_path.read_text())
            report["perClip"][0]["components"]["candidate_v4"][
                "luma_multiscale_structural_error"
            ] += 0.125
            quality_gate.write_json(report_path, report)
            self.sealEvidence(root)
            with self.assertRaisesRegex(
                SystemExit, "perClip metrics differ from sealed raw-plane replay"
            ):
                quality_gate.verify_report(report_path, contract_path)

    def testRawReplayAllowsBoundedCrossRuntimeRoundoff(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            report_path, contract_path = self.materializeValidEvidence(root)
            report = json.loads(report_path.read_text())
            original_value = report["perClip"][0]["components"]["candidate_v4"][
                "luma_multiscale_structural_error"
            ]
            clip_id = report["perClip"][0]["clipID"]
            report["perClip"][0]["components"]["candidate_v4"][
                "luma_multiscale_structural_error"
            ] += 5e-15
            quality_gate.write_json(report_path, report)
            self.sealEvidence(root)
            with mock.patch.object(
                quality_gate,
                "aggregate_ratios",
                wraps=quality_gate.aggregate_ratios,
            ) as aggregate, contextlib.redirect_stdout(io.StringIO()):
                quality_gate.verify_report(report_path, contract_path)
            replayed_metrics = aggregate.call_args_list[0].args[0]
            self.assertEqual(
                replayed_metrics[clip_id]["candidate_v4"][
                    "luma_multiscale_structural_error"
                ],
                original_value,
            )

    def testRawReplayRejectsDriftOutsideNumericTolerance(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            report_path, contract_path = self.materializeValidEvidence(root)
            report = json.loads(report_path.read_text())
            report["perClip"][0]["components"]["candidate_v4"][
                "luma_multiscale_structural_error"
            ] += 2 * quality_gate.REPLAY_NUMERIC_TOLERANCE
            quality_gate.write_json(report_path, report)
            self.sealEvidence(root)
            with self.assertRaisesRegex(
                SystemExit, "perClip metrics differ from sealed raw-plane replay"
            ):
                quality_gate.verify_report(report_path, contract_path)

    def testVerifierEvolutionUsesExactSealedEvaluatorIdentity(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            report_path, contract_path = self.materializeValidEvidence(root)
            bindings = root / "bindings"
            bindings.mkdir()
            evaluator = bindings / "quality_gate_v4.py"
            evaluator.write_bytes(
                (SCRIPT_DIRECTORY / "quality_gate_v4.py").read_bytes()
                + b"\n# frozen evaluator fixture\n"
            )
            for name in (
                "P05QualityBaselineCaptureTests.swift",
                "p05-baseline-source-manifest-v1.json",
                "p05_baseline_v4.py",
            ):
                shutil.copy2(SCRIPT_DIRECTORY / name, bindings / name)

            report = json.loads(report_path.read_text())
            evaluator_identity = quality_gate.sha256(evaluator)
            report["identities"]["metricToolSHA256"] = evaluator_identity
            report["identities"]["metricModelSHA256"] = quality_gate.sha256_bytes(
                b"mirmir-analytic-quality-model-v1\0"
                + quality_gate.canonical_bytes(report["contract"]["components"])
                + bytes.fromhex(evaluator_identity)
            )
            quality_gate.write_json(report_path, report)
            self.sealEvidence(root)

            with contextlib.redirect_stdout(io.StringIO()):
                quality_gate.verify_report(report_path, contract_path)

            evaluator.write_bytes(evaluator.read_bytes() + b"tamper")
            self.sealEvidence(root)
            with self.assertRaisesRegex(SystemExit, "metric tool identity mismatch"):
                quality_gate.verify_report(report_path, contract_path)

    def testOuterReleaseEnvelopeDoesNotWeakenRecursiveSeal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ash-quality-test-") as temporary:
            root = Path(temporary)
            report_path, contract_path = self.materializeValidEvidence(root)
            quality_gate.write_json(
                root / "sealed-manifest.json",
                {
                    "schemaVersion": "mirmir-test-sealed-evidence-v1",
                    "artifacts": [],
                },
            )
            with contextlib.redirect_stdout(io.StringIO()):
                quality_gate.verify_report(report_path, contract_path)

            (root / "unrelated-unsealed.bin").write_bytes(b"unsealed")
            with self.assertRaisesRegex(SystemExit, "sealed file set mismatch"):
                quality_gate.verify_report(report_path, contract_path)


if __name__ == "__main__":
    unittest.main()
