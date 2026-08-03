#!/usr/bin/env python3
"""Fail-closed tests for the M7 release-qualification evidence aggregator."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "release_qualification_v4", SCRIPT_DIRECTORY / "release_qualification_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
qualification = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qualification)

PERFORMANCE_SPEC = importlib.util.spec_from_file_location(
    "performance_gate_v4_for_release_tests",
    SCRIPT_DIRECTORY / "performance_gate_v4.py",
)
assert PERFORMANCE_SPEC is not None and PERFORMANCE_SPEC.loader is not None
performance_gate = importlib.util.module_from_spec(PERFORMANCE_SPEC)
PERFORMANCE_SPEC.loader.exec_module(performance_gate)


def identity(label: str) -> str:
    return qualification.sha256_bytes(label.encode("utf-8"))


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def descriptor(path: Path, root: Path) -> dict[str, object]:
    return {
        "path": path.relative_to(root).as_posix(),
        "byteCount": path.stat().st_size,
        "sha256": qualification.sha256(path),
    }


class EvidenceFixture:
    def __init__(self, root: Path):
        self.root = root
        self.contract_path = SCRIPT_DIRECTORY / "release-qualification-contract-v1.json"
        self.contract = json.loads(self.contract_path.read_text())
        runtime_revision = "b" * 40
        self.builder_bytes = b"#!/bin/sh\n# locked production P06 builder\n"
        self.toolchain_bytes = qualification.canonical_bytes(
            {"xcode": "locked-release", "metal": "locked-release"}
        )
        self.runtime_artifacts: dict[str, bytes] = {}
        runtime_declarations = []
        for role in self.contract["p06RuntimeArtifactRoles"]:
            relative = (
                "artifacts/ash-p06.metallib"
                if role == "metal_library"
                else f"artifacts/{role}.json"
            )
            content = f"locked-production-p06-{role}".encode("utf-8")
            self.runtime_artifacts[relative] = content
            runtime_declarations.append(
                {
                    "role": role,
                    "relativePath": relative,
                    "schemaID": f"ash.p06.{role.replace('_', '-')}.v1",
                    "contentSHA256": qualification.sha256_bytes(content),
                    "byteCount": len(content),
                }
            )
        runtime_manifest = {
            "schemaID": "ash.p06.runtime-manifest.v1",
            "runtimeID": "ash-p06-deterministic-v4",
            "releaseStatus": "release_qualified",
            "provenance": {
                "sourceRevision": runtime_revision,
                "builderID": "mirmir-p06-release-builder-v1",
                "builderSourceSHA256": qualification.sha256_bytes(self.builder_bytes),
                "buildParametersSHA256": identity("p06-build-parameters"),
                "inputSetSHA256": identity("p06-input-set"),
                "metalLibrarySHA256": qualification.sha256_bytes(
                    self.runtime_artifacts["artifacts/ash-p06.metallib"]
                ),
                "toolchain": {
                    "swiftCompilerIdentity": "Apple Swift release toolchain",
                    "metalCompilerIdentity": "Apple Metal release toolchain",
                    "metalLanguageVersion": "4.0",
                    "sdkBuildIdentity": "macOS release SDK",
                    "deploymentTarget": "15.0",
                    "targetTriple": "arm64-apple-macos15.0",
                },
            },
            "artifacts": runtime_declarations,
        }
        runtime_bytes = qualification.canonical_bytes(runtime_manifest)
        release_bytes = b'CONFIGURATION=Release\nSWIFT_OPTIMIZATION_LEVEL=-O\n'
        app_bytes = b"notarized-and-stapled-mirmir-app-archive"
        runtime_set_entries = [
            (relative, qualification.sha256_bytes(content))
            for relative, content in self.runtime_artifacts.items()
        ] + [("runtime-manifest.json", qualification.sha256_bytes(runtime_bytes))]
        self.candidate = {
            "sourceCommit": "a" * 40,
            "sourceTreeIdentitySHA256": identity("source-tree"),
            "runtimeManifestSHA256": qualification.sha256_bytes(runtime_bytes),
            "runtimeManifestFileSHA256": qualification.sha256_bytes(runtime_bytes),
            "runtimeArtifactSetSHA256": qualification.artifact_set_sha(
                runtime_set_entries
            ),
            "runtimeSourceRevision": runtime_revision,
            "releaseConfigurationSHA256": qualification.sha256_bytes(release_bytes),
            "appBundleSHA256": qualification.sha256_bytes(app_bytes),
            "bundleIdentifier": "com.example.Mirmir",
            "productVersion": "4.0",
            "productBuild": "400",
        }
        self.runtime_bytes = runtime_bytes
        self.candidate["runtimeManifestSHA256"] = qualification.ash_canonical_identity(
            "ash-p06-runtime-manifest-v4", runtime_manifest
        )
        self.release_bytes = release_bytes
        self.app_bytes = app_bytes
        self.entries: list[dict[str, object]] = []
        self._build_quality()
        self._build_common_reports()
        self.index = {
            "schemaVersion": qualification.SCHEMA_CANDIDATE,
            "candidate": self.candidate,
            "waivers": [],
            "evidence": self.entries,
        }
        self.index_path = root / "release-candidate-evidence.json"
        self.save_index()

    def save_index(self) -> None:
        write_json(self.index_path, self.index)

    def _write_bound_files(self, role_dir: Path, role: str, contract_value: object) -> tuple[Path, Path, Path]:
        contract_path = role_dir / "suite-contract.json"
        runtime_path = role_dir / "runtime-manifest.json"
        release_path = role_dir / "Release.xcconfig"
        write_json(contract_path, contract_value)
        runtime_path.write_bytes(self.runtime_bytes)
        release_path.write_bytes(self.release_bytes)
        return contract_path, runtime_path, release_path

    def _seal_and_add(
        self,
        role: str,
        report: dict[str, object],
        contract_path: Path,
        runtime_path: Path,
        release_path: Path | None,
        extra_bindings: list[tuple[str, Path]],
    ) -> None:
        role_dir = report_path = self.root / role
        role_dir.mkdir(parents=True, exist_ok=True)
        report_path = role_dir / "report.json"
        write_json(report_path, report)
        bindings = [
            {
                "jsonPointer": pointer,
                **descriptor(path, self.root),
            }
            for pointer, path in extra_bindings
        ]
        if release_path is not None:
            bindings = [
                {"jsonPointer": "/contractSHA256", **descriptor(contract_path, self.root)},
                {
                    "jsonPointer": "/candidate/runtimeManifestFileSHA256",
                    **descriptor(runtime_path, self.root),
                },
                {"jsonPointer": "/candidate/releaseConfigurationSHA256", **descriptor(release_path, self.root)},
            ] + bindings
        sealed_paths = sorted(
            path
            for path in role_dir.rglob("*")
            if path.is_file() and path.name != "sealed-manifest.json"
        )
        sealed = {
            "schemaVersion": "mirmir-test-sealed-evidence-v1",
            "artifacts": [descriptor(path, role_dir) for path in sealed_paths],
        }
        sealed_path = role_dir / "sealed-manifest.json"
        write_json(sealed_path, sealed)
        self.entries.append(
            {
                "role": role,
                **descriptor(report_path, self.root),
                "contractSHA256": qualification.sha256(contract_path),
                "sealedManifest": descriptor(sealed_path, self.root),
                "identityBindings": bindings,
            }
        )

    def _build_quality(self) -> None:
        role = "quality"
        role_dir = self.root / role
        components = [
            ("luma_multiscale_structural_error", 0.35),
            ("chroma_multiscale_structural_error", 0.15),
            ("perceptual_feature_distance", 0.20),
            ("motion_compensated_temporal_flicker_error", 0.20),
            ("edge_displacement_ringing_overshoot_error", 0.10),
        ]
        cohorts = [
            "natural_detail",
            "text_graphics",
            "animation",
            "faces",
            "low_light_noise",
            "high_motion",
            "scene_cuts",
        ]
        quality_contract = {
            "schemaVersion": "mirmir-ash-v4-quality-gate-contract-v1",
            "components": [
                {"id": component, "weight": weight, "crop": "locked"}
                for component, weight in components
            ],
            "cohortConstraints": {
                "contentCohorts": cohorts,
                "minimumFramesPerClip": 6,
                "minimumClipsPerCohort": 4,
                "lumaStructuralMaximumCandidateToBaselineRatio": 1.01,
                "temporalStructuralMaximumCandidateToBaselineRatio": 1.0,
                "temporalNonRegressionCohorts": ["high_motion", "scene_cuts"],
            },
            "bootstrap": {
                "replicateCount": 10000,
                "seedUnsignedDecimal": 1095977012,
            },
        }
        contract_path, runtime_path, _ = self._write_bound_files(role_dir, role, quality_contract)
        metric_path = role_dir / "quality_gate_v4.py"
        capture_source_path = role_dir / "QualityGateCaptureTests.swift"
        metric_path.write_text("# locked metric tool\n", encoding="utf-8")
        capture_source_path.write_text("// locked capture source\n", encoding="utf-8")
        corpus_artifact = role_dir / "natural-source-frame.bin"
        corpus_artifact.write_bytes(b"natural-source-frame")
        corpus_entries = [(corpus_artifact.name, qualification.sha256(corpus_artifact))]
        corpus_set = qualification.artifact_set_sha(corpus_entries)
        corpus_manifest = {
            "schemaVersion": "mirmir-ash-v4-quality-corpus-v1",
            "corpusKind": "locked_natural",
            "releaseEligible": True,
            "artifactSetSHA256": corpus_set,
            "artifacts": [descriptor(corpus_artifact, role_dir)],
        }
        corpus_path = role_dir / "corpus-manifest.json"
        write_json(corpus_path, corpus_manifest)
        output_paths: dict[str, Path] = {}
        for variant in qualification.QUALITY_VARIANTS:
            path = role_dir / "artifacts" / f"{variant}.nv12"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(variant.encode("utf-8"))
            output_paths[variant] = path
        per_clip = []
        capture_cases = []
        clips_by_cohort: dict[str, list[str]] = {cohort: [] for cohort in cohorts}
        metrics: dict[str, dict[str, dict[str, float]]] = {}
        component_ids = [component for component, _ in components]
        for cohort in cohorts:
            for clip_index in range(4):
                clip_id = f"{cohort}-c{clip_index:02d}"
                clips_by_cohort[cohort].append(clip_id)
                values = {}
                for variant in qualification.QUALITY_VARIANTS:
                    ratio = 1.0 if variant == "baseline_p05" else (0.8 if variant == "candidate_v4" else 0.85)
                    values[variant] = {component: ratio for component in component_ids}
                metrics[clip_id] = values
                per_clip.append(
                    {
                        "clipID": clip_id,
                        "cohort": cohort,
                        "pixelFormat": "420v" if clip_index % 2 == 0 else "420f",
                        "frameCount": 6,
                        "components": values,
                    }
                )
                for frame in range(6):
                    capture_cases.append(
                        {
                            "id": f"{clip_id}-f{frame:02d}",
                            "outputs": {
                                variant: path.relative_to(role_dir).as_posix()
                                for variant, path in output_paths.items()
                            },
                        }
                    )
        weights = dict(components)
        summaries: dict[str, object] = {}
        for variant in qualification.QUALITY_VARIANTS:
            aggregate, by_cohort, error, quality_index = qualification.quality_aggregate(
                metrics, clips_by_cohort, variant, weights
            )
            summaries[variant] = {
                "normalizedComponents": aggregate,
                "normalizedComponentsByCohort": by_cohort,
                "weightedError": error,
                "qualityIndex": quality_index,
            }
        candidate_summary = summaries["candidate_v4"]
        assert isinstance(candidate_summary, dict)
        candidate_summary["pairedBootstrap95PercentCI"] = {
            "lower": candidate_summary["qualityIndex"],
            "upper": candidate_summary["qualityIndex"],
            "replicateCount": 10000,
            "lowerOrderStatisticIndex": 250,
        }
        contract_sha = qualification.sha256(contract_path)
        corpus_sha = qualification.sha256(corpus_path)
        output_sets = {
            variant: qualification.artifact_set_sha(
                [
                    (path.relative_to(role_dir).as_posix(), qualification.sha256(path))
                    for _ in capture_cases
                ]
            )
            for variant, path in output_paths.items()
        }
        report = {
            "schemaVersion": self.contract["evidenceSchemas"][role],
            "contract": quality_contract,
            "identities": {
                "contractSHA256": contract_sha,
                "metricToolSHA256": qualification.sha256(metric_path),
                "captureTestSourceSHA256": qualification.sha256(capture_source_path),
                "corpusManifestSHA256": corpus_sha,
                "corpusArtifactSetSHA256": corpus_set,
                "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
                "sourceCommit": self.candidate["sourceCommit"],
                "sourceTreeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
                "cropRuleSHA256": qualification.sha256_bytes(
                    qualification.canonical_bytes(
                        [{item["id"]: item["crop"]} for item in quality_contract["components"]]
                    )
                ),
                "metricModelSHA256": qualification.sha256_bytes(
                    b"mirmir-analytic-quality-model-v1\0"
                    + qualification.canonical_bytes(quality_contract["components"])
                    + bytes.fromhex(qualification.sha256(metric_path))
                ),
                "outputSetSHA256": output_sets,
            },
            "runtime": {
                "candidateBackendID": self.contract["quality"]["requiredBackendID"],
                "candidateImplementationVersion": self.contract["quality"]["requiredCandidateImplementationVersion"],
                "productionRuntimeLocked": True,
                "fullMirrorIdentityPass": True,
            },
            "corpus": {
                "corpusID": "locked-natural-test-v1",
                "corpusKind": "locked_natural",
                "releaseEligible": True,
                "clipCount": len(per_clip),
                "caseCount": len(capture_cases),
                "cohorts": cohorts,
            },
            "quality": {
                "summaries": summaries,
                "gates": {
                    "identityPass": True,
                    "naturalCorpusEligibilityPass": True,
                    "productionRuntimeLockPass": True,
                    "requiredAblationsPresentPass": True,
                    "qualityPointEstimatePass": True,
                    "qualityLowerConfidenceBoundPass": True,
                    "allCohortLumaNonRegressionPass": True,
                    "temporalCohortNonRegressionPass": True,
                    "candidateBackendIdentityPass": True,
                    "fullMirrorIdentityPass": True,
                    "releaseQualityGatePass": True,
                },
            },
            "perClip": per_clip,
            "timingDiagnostic": {"releasePerformanceGateEligible": False},
        }
        report_path = role_dir / "report.json"
        capture_manifest = {
            "schemaVersion": "mirmir-ash-v4-quality-capture-v1",
            "contractSHA256": contract_sha,
            "corpusManifestSHA256": corpus_sha,
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
            "cases": capture_cases,
        }
        write_json(role_dir / "capture-manifest.json", capture_manifest)
        bindings = [
            ("/identities/contractSHA256", contract_path),
            ("/identities/metricToolSHA256", metric_path),
            ("/identities/captureTestSourceSHA256", capture_source_path),
            ("/identities/corpusManifestSHA256", corpus_path),
        ]
        self._seal_and_add(role, report, contract_path, runtime_path, None, bindings)

    def _base(self, role: str, contract_sha: str) -> dict[str, object]:
        return {
            "schemaVersion": self.contract["evidenceSchemas"][role],
            "contractSHA256": contract_sha,
            "candidate": self.candidate,
            "releaseEligible": True,
        }

    def _build_performance_actual(self) -> None:
        role = "same_scope_performance"
        role_dir = self.root / role
        role_dir.mkdir(parents=True, exist_ok=True)
        suite_contract = json.loads(
            (SCRIPT_DIRECTORY / "performance-gate-contract-v1.json").read_text()
        )
        suite_contract["capture"]["captureSourceSHA256"] = identity("performance capture source")
        suite_contract["capture"]["evaluatorSourceSHA256"] = identity("performance evaluator")
        suite_contract["capture"]["runnerSourceSHA256"] = identity("performance runner")
        contract_path = role_dir / "performance-gate-contract-v1.json"
        write_json(contract_path, suite_contract)
        contract_sha = qualification.sha256(contract_path)

        def environment() -> dict[str, object]:
            return {
                "schemaVersion": "mirmir-v4-performance-environment-v1",
                "stableIdentity": {
                    "hardwareModel": "Mac-Qualification",
                    "memoryBytes": 48 * 1024**3,
                    "processor": "Apple Qualification",
                    "gpuIdentity": ["Apple Qualification"],
                    "macOSBuild": "locked",
                    "xcodeBuild": "locked",
                    "swiftCompiler": "locked",
                },
                "power": {"identity": "locked-ac-power", "source": "AC Power"},
                "thermal": {"accepted": True, "observationSHA256": identity("thermal")},
            }

        def make_capture(variant: str, wall: float, engine: float) -> Path:
            directory = role_dir / ("baseline" if variant == "baseline_p05" else "candidate")
            directory.mkdir(parents=True)
            if variant == "baseline_p05":
                revision = suite_contract["baseline"]["sourceRevision"]
                source_tree = identity("baseline tree")
                runtime = {
                    "status": suite_contract["baseline"]["runtimeStatus"],
                    "runtimeID": None,
                    "implementationVersions": suite_contract["baseline"]["implementationVersions"],
                    "manifestSHA256": None,
                    "releaseQualified": False,
                    "trustRootConfigured": False,
                    "artifactsVerified": True,
                }
            else:
                revision = self.candidate["sourceCommit"]
                source_tree = self.candidate["sourceTreeIdentitySHA256"]
                runtime = {
                    "status": "release_qualified",
                    "runtimeID": "ash-p06-deterministic-v4",
                    "implementationVersions": ["ash-p06-deterministic-v4"],
                    "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                    "manifestSourceRevision": self.candidate["runtimeSourceRevision"],
                    "builderSourceSHA256": qualification.sha256_bytes(self.builder_bytes),
                    "releaseQualified": True,
                    "trustRootConfigured": True,
                    "artifactsVerified": True,
                }
            source = {
                "schemaVersion": "mirmir-v4-performance-source-identity-v1",
                "variant": variant,
                "sourceRevision": revision,
                "sourceTreeSHA256": source_tree,
                "runtime": runtime,
            }
            source_path = directory / "source-identity.json"
            write_json(source_path, source)
            write_json(directory / "environment-before.json", environment())
            write_json(directory / "environment-after.json", environment())
            (directory / "xcodebuild.log").write_text(
                "Release qualification test process completed successfully\n",
                encoding="utf-8",
            )
            cases = []
            for case_index, case_contract in enumerate(suite_contract["workload"]["cases"]):
                verification = {
                    "requestedBackendExecutedWithoutFallback": True,
                    "allInputTracksAccounted": True,
                    "exactEnabledVideoTrackCount": True,
                    "exactEncodedDimensions": True,
                    "exactCodec": True,
                    "exactFrameCount": True,
                    "exactPresentationTimestamps": True,
                    "exactDuration": True,
                    "bt709ColorContract": True,
                    "decodedVisiblePixelSHA256": format(case_index + 8, "064x"),
                    "semanticTrackManifestSHA256": format(case_index + 16, "064x"),
                    "allRequiredChecksPassed": True,
                }
                engine_runs = []
                wall_runs = []
                for sample_index in range(10):
                    jitter = sample_index * 0.001
                    engine_runs.append(
                        {
                            "sampleIndex": sample_index,
                            "frameMilliseconds": [
                                engine + jitter,
                                engine + 0.01 + jitter,
                                engine + 0.02 + jitter,
                            ],
                            "processedFrameCount": 3,
                        }
                    )
                    wall_runs.append(
                        {
                            "sampleIndex": sample_index,
                            "wallMilliseconds": wall + case_index * 0.1 + jitter,
                            "peakResidentBytes": (
                                100 * 1024**2
                                if variant == "baseline_p05"
                                else 110 * 1024**2
                            ),
                            "processedFrameCount": 3,
                            "verification": verification,
                        }
                    )
                cases.append(
                    {
                        **case_contract,
                        "request": copy.deepcopy(suite_contract["workload"]["output"]),
                        "engineRuns": engine_runs,
                        "endToEndRuns": wall_runs,
                    }
                )
            capture = {
                "schemaVersion": "mirmir-v4-performance-capture-v1",
                "variant": variant,
                "contractSHA256": contract_sha,
                "captureSourceSHA256": suite_contract["capture"]["captureSourceSHA256"],
                "sourceIdentitySHA256": qualification.sha256(source_path),
                "sourceRevision": revision,
                "sourceTreeSHA256": source_tree,
                "buildConfiguration": "Release",
                "warmupCount": 5,
                "sampleCount": 10,
                "input": {
                    key: value
                    for key, value in suite_contract["workload"]["input"].items()
                    if key != "repositoryPath"
                }
                | {"allRequiredChecksPassed": True},
                "cases": cases,
            }
            write_json(directory / "capture.json", capture)
            nested = performance_gate.make_evidence_manifest(directory)
            nested["schemaVersion"] = "mirmir-v4-performance-capture-artifacts-v1"
            write_json(directory / "artifact-manifest.json", nested)
            return directory

        baseline = make_capture("baseline_p05", wall=100.0, engine=10.0)
        observed = make_capture("candidate_p06", wall=50.0, engine=5.0)
        report = performance_gate.evaluate(contract_path, baseline, observed)
        report_path = role_dir / "performance-gate-report.json"
        write_json(report_path, report)
        root_manifest_path = role_dir / "artifact-manifest.json"
        root_artifacts = [
            descriptor(path, role_dir)
            for path in sorted(role_dir.rglob("*"))
            if path.is_file() and path != root_manifest_path
        ]
        write_json(
            root_manifest_path,
            {
                "schemaVersion": "mirmir-v4-performance-evidence-manifest-v1",
                "artifacts": root_artifacts,
            },
        )
        binding_sources = [
            ("/contractSHA256", contract_path),
            ("/baseline/sourceIdentitySHA256", baseline / "source-identity.json"),
            ("/baseline/artifactManifestSHA256", baseline / "artifact-manifest.json"),
            ("/candidate/sourceIdentitySHA256", observed / "source-identity.json"),
            ("/candidate/artifactManifestSHA256", observed / "artifact-manifest.json"),
        ]
        self.entries.append(
            {
                "role": role,
                **descriptor(report_path, self.root),
                "contractSHA256": contract_sha,
                "sealedManifest": descriptor(root_manifest_path, self.root),
                "identityBindings": [
                    {"jsonPointer": pointer, **descriptor(path, self.root)}
                    for pointer, path in binding_sources
                ],
            }
        )

    def _build_common_reports(self) -> None:
        for role in self.contract["requiredEvidenceRoles"]:
            if role == "quality":
                continue
            if role == "same_scope_performance":
                self._build_performance_actual()
                continue
            role_dir = self.root / role
            suite_contract = {"schemaVersion": f"mirmir-{role}-contract-v1", "coverageLocked": True}
            contract_path, runtime_path, release_path = self._write_bound_files(role_dir, role, suite_contract)
            contract_sha = qualification.sha256(contract_path)
            report = self._base(role, contract_sha)
            extra_bindings: list[tuple[str, Path]] = []
            if role == "same_scope_performance":
                environment_path = role_dir / "environment.json"
                scope_path = role_dir / "scope.json"
                write_json(environment_path, {"machine": "locked", "software": "locked"})
                write_json(scope_path, {"inputs": "locked", "work": "same"})
                environment_sha = qualification.sha256(environment_path)
                scope_sha = qualification.sha256(scope_path)
                extra_bindings.extend(
                    [
                        ("/measurement/baselineEnvironmentSHA256", environment_path),
                        ("/measurement/candidateEnvironmentSHA256", environment_path),
                        ("/measurement/baselineScopeSHA256", scope_path),
                        ("/measurement/candidateScopeSHA256", scope_path),
                    ]
                )
                baseline = [100.0] * 10
                observed = [70.0] * 10
                intervals = {}
                for offset, metric in enumerate(self.contract["performance"]["requiredMetrics"]):
                    statistic = qualification.percentile95 if metric == "engineP95" else __import__("statistics").median
                    point, lower, upper = qualification.paired_ratio_interval(
                        baseline, observed, statistic, 7 + offset, 10000
                    )
                    intervals[metric] = {
                        "pointRatio": point,
                        "lower": lower,
                        "upper": upper,
                        "replicateCount": 10000,
                    }
                report.update(
                    {
                        "measurement": {
                            "buildConfiguration": "Release",
                            "warmupCount": 5,
                            "measuredRunCount": 10,
                            "bootstrapReplicateCount": 10000,
                            "bootstrapSeed": 7,
                            "thermalEnvelopeAccepted": True,
                            "loggingExcludedFromTimedLoops": True,
                            "diagnosticSerializationExcludedFromTimedLoops": True,
                            "baselineEnvironmentSHA256": environment_sha,
                            "candidateEnvironmentSHA256": environment_sha,
                            "baselineScopeSHA256": scope_sha,
                            "candidateScopeSHA256": scope_sha,
                            "sameHardware": True,
                            "sameSoftwareImage": True,
                            "identicalInputs": True,
                            "identicalTargets": True,
                            "identicalCodecSettings": True,
                            "identicalTrackSet": True,
                            "identicalPrecision": True,
                            "identicalTemporalWork": True,
                            "identicalVerification": True,
                            "identicalOutputQuality": True,
                        },
                        "mandatoryClassIDs": ["locked-common-sdr"],
                        "mandatoryClasses": [
                            {
                                "id": "locked-common-sdr",
                                "scopeSHA256": scope_sha,
                                "baseline": {metric: 100.0 for metric in self.contract["performance"]["requiredMetrics"]},
                                "candidate": {metric: 70.0 for metric in self.contract["performance"]["requiredMetrics"]},
                                "ratios": {metric: 0.7 for metric in self.contract["performance"]["requiredMetrics"]},
                            }
                        ],
                        "rawPairedSamplesMilliseconds": {
                            metric: {"baseline": baseline, "candidate": observed}
                            for metric in self.contract["performance"]["requiredMetrics"]
                        },
                        "aggregateRatio95PercentCI": intervals,
                        "memory": {
                            "baselinePeakBytes": 1000,
                            "candidatePeakBytes": 1100,
                            "approvedTemporalHistoryBudgetBytes": 100,
                        },
                        "releasePerformanceGatePass": True,
                    }
                )
            elif role == "cpu_metal_parity":
                capture_source = role_dir / "parity-capture.swift"
                evaluator_source = role_dir / "parity-evaluator.py"
                runner_source = role_dir / "parity-runner.sh"
                capture_source.write_bytes(b"// locked CPU/Metal parity capture\n")
                evaluator_source.write_bytes(b"# locked byte-exact parity evaluator\n")
                runner_source.write_bytes(b"#!/bin/sh\n# locked parity runner\n")
                extra_bindings.extend(
                    [
                        ("/identities/captureSourceSHA256", capture_source),
                        ("/identities/evaluatorSHA256", evaluator_source),
                        ("/identities/runnerSHA256", runner_source),
                    ]
                )
                visible = role_dir / "visible.bin"
                visible_metal = role_dir / "visible-metal.bin"
                attachments = role_dir / "attachments.json"
                attachments_metal = role_dir / "attachments-metal.json"
                visible.write_bytes(b"exact-visible-planes")
                visible_metal.write_bytes(visible.read_bytes())
                write_json(attachments, {"range": "video", "siting": "left"})
                attachments_metal.write_bytes(attachments.read_bytes())
                report.update(
                    {
                        "identities": {
                            "captureSourceSHA256": qualification.sha256(capture_source),
                            "evaluatorSHA256": qualification.sha256(evaluator_source),
                            "runnerSHA256": qualification.sha256(runner_source),
                        },
                        "comparison": "exact_visible_plane_and_attachment_bytes",
                        "cases": [
                            {
                                "id": "all-required-parity-coverage",
                                "coverage": self.contract["parityCoverage"],
                                "cpuVisibleArtifact": descriptor(visible, self.root),
                                "metalVisibleArtifact": descriptor(visible_metal, self.root),
                                "cpuAttachmentsArtifact": descriptor(attachments, self.root),
                                "metalAttachmentsArtifact": descriptor(attachments_metal, self.root),
                                "repeatRunIdentityPass": True,
                                "crossProcessIdentityPass": True,
                                "tileScheduleIdentityPass": True,
                            }
                        ],
                        "byteParityGatePass": True,
                    }
                )
            elif role == "media_preservation":
                input_manifest = role_dir / "input-media-manifest.json"
                output_manifest = role_dir / "output-media-manifest.json"
                verifier = role_dir / "semantic-verifier.json"
                write_json(input_manifest, {"tracks": 17, "coverage": self.contract["mediaPreservationCoverage"]})
                write_json(output_manifest, {"tracks": 17, "coverage": self.contract["mediaPreservationCoverage"]})
                write_json(verifier, {"pass": True, "mismatchCount": 0})
                report.update(
                    {
                        "fixtures": [
                            {
                                "id": "mandatory-delivery-matrix",
                                "coverage": self.contract["mediaPreservationCoverage"],
                                "enabledInputTrackCount": 17,
                                "accountedOutputTrackCount": 17,
                                "unconsentedDropCount": 0,
                                "silentToneMapCount": 0,
                                "precisionReductionCount": 0,
                                "alphaLossCount": 0,
                                "geometryMismatchCount": 0,
                                "metadataMismatchCount": 0,
                                "exactSemanticVerifierPass": True,
                                "inputManifestArtifact": descriptor(input_manifest, self.root),
                                "outputManifestArtifact": descriptor(output_manifest, self.root),
                                "semanticVerifierArtifact": descriptor(verifier, self.root),
                            }
                        ],
                        "mediaPreservationGatePass": True,
                    }
                )
            elif role == "recovery":
                corrupt = {"corrupt_journal", "corrupt_checkpoint", "unowned_artifact_rejection"}
                normal = [item for item in self.contract["recoveryCoverage"] if item not in corrupt]
                reference_output = role_dir / "reference-output.mov"
                resumed_output = role_dir / "resumed-output.mov"
                reference_output.write_bytes(b"identical-resumed-output")
                resumed_output.write_bytes(reference_output.read_bytes())
                resume_evidence = role_dir / "resume-fault-injection.json"
                corrupt_evidence = role_dir / "corruption-containment.json"
                write_json(resume_evidence, {"injectedBoundaries": normal, "pass": True})
                write_json(corrupt_evidence, {"injectedBoundaries": sorted(corrupt), "pass": True})
                output_sha = qualification.sha256(reference_output)
                report.update(
                    {
                        "scenarios": [
                            {
                                "id": "resume-identically",
                                "coverage": normal,
                                "outcome": "identical_resumed_output",
                                "referenceOutputSHA256": output_sha,
                                "resumedOutputSHA256": output_sha,
                                "containedFailureCode": None,
                                "unownedArtifactCount": 0,
                                "ownedArtifactReconciled": True,
                                "referenceOutputArtifact": descriptor(reference_output, self.root),
                                "resumedOutputArtifact": descriptor(resumed_output, self.root),
                                "externalEvidenceArtifact": descriptor(resume_evidence, self.root),
                            },
                            {
                                "id": "contain-corruption",
                                "coverage": sorted(corrupt),
                                "outcome": "explicit_contained_failure",
                                "referenceOutputSHA256": None,
                                "resumedOutputSHA256": None,
                                "containedFailureCode": "qualification_fixture_corrupt",
                                "unownedArtifactCount": 0,
                                "ownedArtifactReconciled": True,
                                "referenceOutputArtifact": None,
                                "resumedOutputArtifact": None,
                                "externalEvidenceArtifact": descriptor(corrupt_evidence, self.root),
                            },
                        ],
                        "recoveryGatePass": True,
                    }
                )
            elif role == "p06_reproduction":
                builds = []
                for build_id in ("clean-build-a", "clean-build-b"):
                    build_dir = role_dir / build_id
                    build_dir.mkdir(parents=True, exist_ok=True)
                    build_runtime = build_dir / "runtime-manifest.json"
                    builder = build_dir / "builder.sh"
                    toolchain = build_dir / "toolchain-image.json"
                    build_runtime.write_bytes(self.runtime_bytes)
                    runtime_artifact_paths = []
                    for relative, content in self.runtime_artifacts.items():
                        artifact_path = build_dir / relative
                        artifact_path.parent.mkdir(parents=True, exist_ok=True)
                        artifact_path.write_bytes(content)
                        runtime_artifact_paths.append(artifact_path)
                    builder.write_bytes(self.builder_bytes)
                    toolchain.write_bytes(self.toolchain_bytes)
                    artifact_manifest = build_dir / "artifact-manifest.json"
                    write_json(
                        artifact_manifest,
                        {
                            "schemaVersion": "mirmir-p06-artifact-manifest-v1",
                            "artifacts": [
                                *[
                                    descriptor(path, build_dir)
                                    for path in sorted(runtime_artifact_paths)
                                ],
                                descriptor(build_runtime, build_dir),
                            ],
                        },
                    )
                    builds.append(
                        {
                            "id": build_id,
                            "runtimeArtifactSetSHA256": self.candidate["runtimeArtifactSetSHA256"],
                            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                            "builderSHA256": qualification.sha256(builder),
                            "toolchainImageSHA256": qualification.sha256(toolchain),
                            "artifactManifest": descriptor(artifact_manifest, self.root),
                            "runtimeManifestArtifact": descriptor(build_runtime, self.root),
                            "builderArtifact": descriptor(builder, self.root),
                            "toolchainImageArtifact": descriptor(toolchain, self.root),
                            "releaseQualifiedStatus": True,
                            "developmentArtifactDependencyCount": 0,
                            "p05ProductionDependencyCount": 0,
                        }
                    )
                report.update(
                    {
                        "buildConfiguration": "Release",
                        "sourceCheckoutState": "clean",
                        "builds": builds,
                        "productionLoaderAcceptancePass": True,
                        "tamperRejectionPass": True,
                        "p06ReproductionGatePass": True,
                    }
                )
            elif role == "support_matrix":
                app_archive = role_dir / "Mirmir-notarized.zip"
                app_archive.write_bytes(self.app_bytes)
                extra_bindings.append(("/candidate/appBundleSHA256", app_archive))
                support_evidence = {}
                for machine_class in ("reference", "supported"):
                    path = role_dir / f"{machine_class}-matrix.json"
                    write_json(path, {"machineClass": machine_class, "fullMatrixPass": True})
                    support_evidence[machine_class] = path
                report.update(
                    {
                        "declaredSupportedMachineClassIDs": ["reference", "supported"],
                        "rows": [
                            {
                                "id": f"{machine_class}-row",
                                "machineClass": machine_class,
                                "hardwareIdentitySHA256": identity(f"hardware-{machine_class}"),
                                "softwareImageSHA256": identity("supported-software"),
                                "appBundleSHA256": self.candidate["appBundleSHA256"],
                                "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                                "fullQualificationMatrixPass": True,
                                "unexpectedSkipCount": 0,
                                "externalEvidenceArtifact": descriptor(
                                    support_evidence[machine_class], self.root
                                ),
                            }
                            for machine_class in ("reference", "supported")
                        ],
                        "supportMatrixGatePass": True,
                    }
                )
            elif role == "notarized_smoke":
                app_archive = role_dir / "Mirmir-notarized.zip"
                app_archive.write_bytes(self.app_bytes)
                extra_bindings.append(("/candidate/appBundleSHA256", app_archive))
                smoke_evidence = {}
                for action in self.contract["notarizedSmokeActions"]:
                    transcript = role_dir / "external-evidence" / f"{action}.log"
                    path = role_dir / "external-evidence" / f"{action}.json"
                    transcript.parent.mkdir(parents=True, exist_ok=True)
                    transcript.write_text(
                        f"external observer completed {action} for the notarized candidate\n",
                        encoding="utf-8",
                    )
                    command = ["mirmir-v4-external-observer", "--action", action]
                    write_json(
                        path,
                        {
                            "schemaVersion": "mirmir-ash-v4-external-execution-evidence-v1",
                            "actionID": action,
                            "evidenceKind": self.contract["notarizedSmokeEvidenceKinds"][action],
                            "command": command,
                            "invocationSHA256": qualification.sha256_bytes(
                                qualification.canonical_bytes(command)
                            ),
                            "exitStatus": 0,
                            "startedAtUTC": "2026-08-02T12:00:00Z",
                            "finishedAtUTC": "2026-08-02T12:00:01Z",
                            "observedAppBundleSHA256": self.candidate["appBundleSHA256"],
                            "observedRuntimeManifestSHA256": self.candidate[
                                "runtimeManifestSHA256"
                            ],
                            "transcriptArtifact": descriptor(transcript, self.root),
                        },
                    )
                    smoke_evidence[action] = path
                report.update(
                    {
                        "appBundleSHA256": self.candidate["appBundleSHA256"],
                        "bundleIdentifier": self.candidate["bundleIdentifier"],
                        "productVersion": self.candidate["productVersion"],
                        "productBuild": self.candidate["productBuild"],
                        "notarizationAccepted": True,
                        "ticketStapled": True,
                        "gatekeeperAccepted": True,
                        "codeSignatureValid": True,
                        "hardenedRuntimeEnabled": True,
                        "productionP06Loaded": True,
                        "actions": [
                            {
                                "id": action,
                                "pass": True,
                                "externalEvidenceArtifact": descriptor(
                                    smoke_evidence[action], self.root
                                ),
                            }
                            for action in self.contract["notarizedSmokeActions"]
                        ],
                        "notarizedSmokeGatePass": True,
                    }
                )
            else:
                raise AssertionError(role)
            self._seal_and_add(
                role,
                report,
                contract_path,
                runtime_path,
                release_path,
                extra_bindings,
            )

    def entry(self, role: str) -> dict[str, object]:
        return next(entry for entry in self.index["evidence"] if entry["role"] == role)

    def mutate_report(self, role: str, mutation) -> None:
        entry = self.entry(role)
        report_path = self.root / entry["path"]
        report = json.loads(report_path.read_text())
        mutation(report)
        if role == "same_scope_performance" and "reportSHA256" in report:
            unsigned = dict(report)
            del unsigned["reportSHA256"]
            report["reportSHA256"] = qualification.sha256_bytes(
                qualification.canonical_bytes(unsigned) + b"\n"
            )
        write_json(report_path, report)
        entry["byteCount"] = report_path.stat().st_size
        entry["sha256"] = qualification.sha256(report_path)
        sealed_descriptor = entry["sealedManifest"]
        sealed_path = self.root / sealed_descriptor["path"]
        sealed = json.loads(sealed_path.read_text())
        report_relative = report_path.relative_to(sealed_path.parent).as_posix()
        artifact = next(item for item in sealed["artifacts"] if item["path"] == report_relative)
        artifact.update(descriptor(report_path, sealed_path.parent))
        write_json(sealed_path, sealed)
        sealed_descriptor.update(descriptor(sealed_path, self.root))
        self.save_index()


class ReleaseQualificationV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="mirmir-release-qualification-")
        self.root = Path(self.temporary.name)
        self.fixture = EvidenceFixture(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def evaluate(self) -> dict[str, object]:
        return qualification.evaluate_candidate(
            self.fixture.index_path, self.root, self.fixture.contract_path
        )

    def testCompleteCandidateEvaluatesAndVerifiesDeterministically(self) -> None:
        first = self.evaluate()
        second = self.evaluate()
        self.assertEqual(first, second)
        self.assertTrue(first["releaseQualified"])
        self.assertTrue(all(first["gates"].values()))
        report_path = self.root / "qualification-report.json"
        write_json(report_path, first)
        self.assertEqual(
            first,
            qualification.verify_report(
                report_path, self.fixture.index_path, self.root, self.fixture.contract_path
            ),
        )

    def testPublishedJSONSchemaAcceptsBindingAndRejectsExtraProperty(self) -> None:
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is not installed")
        schema = json.loads(
            (SCRIPT_DIRECTORY / "release-qualification-evidence-schema-v1.json").read_text()
        )
        jsonschema.Draft202012Validator.check_schema(schema)
        jsonschema.validate(self.fixture.index, schema)
        binding = self.fixture.index["evidence"][0]["identityBindings"][0]
        binding["unexpected"] = True
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(self.fixture.index, schema)

    def testMissingRoleAndWaiverFailClosed(self) -> None:
        self.fixture.index["evidence"].pop()
        self.fixture.save_index()
        with self.assertRaisesRegex(qualification.QualificationError, "role mismatch"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "second")
        self.root = self.root / "second"
        self.fixture.index["waivers"] = [{"role": "quality"}]
        self.fixture.save_index()
        with self.assertRaisesRegex(qualification.QualificationError, "does not admit waivers"):
            self.evaluate()

    def testArtifactTamperAndStaleCandidateFailClosed(self) -> None:
        entry = self.fixture.entry("cpu_metal_parity")
        path = self.root / entry["path"]
        path.write_bytes(path.read_bytes() + b"tamper")
        with self.assertRaisesRegex(qualification.QualificationError, "byte count mismatch"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "stale")
        self.root = self.root / "stale"
        self.fixture.mutate_report(
            "same_scope_performance",
            lambda report: report["candidate"].update({"sourceRevision": "c" * 40}),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "source revision mismatch"):
            self.evaluate()

    def testQualityIneligibilityAndSemanticTamperFailClosed(self) -> None:
        self.fixture.mutate_report(
            "quality", lambda report: report["corpus"].update({"releaseEligible": False})
        )
        with self.assertRaisesRegex(qualification.QualificationError, "releaseEligible"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "semantic")
        self.root = self.root / "semantic"
        self.fixture.mutate_report(
            "quality",
            lambda report: report["perClip"][0]["components"]["candidate_v4"].update(
                {"luma_multiscale_structural_error": 1.7}
            ),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "does not match recomputed"):
            self.evaluate()

    def testPerformanceScopeAndConfidenceGateFailClosed(self) -> None:
        self.fixture.mutate_report(
            "same_scope_performance",
            lambda report: report["environmentGate"].update(
                {"stableHardwareAndSoftwareImageMatch": False, "pass": False}
            ),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "environment gate"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "slow")
        self.root = self.root / "slow"
        def slow(report):
            report["metricGates"]["aggregateCorpusWall"]["ratio"] = 0.9
        self.fixture.mutate_report("same_scope_performance", slow)
        with self.assertRaisesRegex(qualification.QualificationError, "does not match recomputed"):
            self.evaluate()

    def testParityAndPreservationFailuresCannotBeClaimedAway(self) -> None:
        self.fixture.mutate_report(
            "cpu_metal_parity",
            lambda report: report["cases"][0]["metalVisibleArtifact"].update(
                {"sha256": identity("different-visible")}
            ),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "SHA-256 mismatch"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "identity")
        self.root = self.root / "identity"
        self.fixture.mutate_report(
            "cpu_metal_parity",
            lambda report: report["identities"].update(
                {"captureSourceSHA256": identity("different-capture-source")}
            ),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "binding does not match report"):
            self.evaluate()
        loss_root = self.root.parent / "loss"
        self.fixture = EvidenceFixture(loss_root)
        self.root = loss_root
        self.fixture.mutate_report(
            "media_preservation",
            lambda report: report["fixtures"][0].update({"unconsentedDropCount": 1}),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "unconsentedDropCount"):
            self.evaluate()

    def testRecoveryAndP06FailuresCannotBeWaived(self) -> None:
        self.fixture.mutate_report(
            "recovery",
            lambda report: report["scenarios"][0].update({"unownedArtifactCount": 1}),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "unowned artifacts"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "p05")
        self.root = self.root / "p05"
        self.fixture.mutate_report(
            "p06_reproduction",
            lambda report: report["builds"][1].update({"p05ProductionDependencyCount": 1}),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "P05 production dependency"):
            self.evaluate()

    def testSupportMatrixAndNotarizedSmokeMustCoverExactCandidate(self) -> None:
        self.fixture.mutate_report(
            "support_matrix", lambda report: report["rows"].pop()
        )
        with self.assertRaisesRegex(qualification.QualificationError, "does not cover"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "smoke")
        self.root = self.root / "smoke"
        self.fixture.mutate_report(
            "notarized_smoke", lambda report: report.update({"ticketStapled": False})
        )
        with self.assertRaisesRegex(qualification.QualificationError, "ticketStapled"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "placeholder")
        self.root = self.root / "placeholder"
        contract_artifact = descriptor(
            self.root / "notarized_smoke" / "suite-contract.json", self.root
        )
        self.fixture.mutate_report(
            "notarized_smoke",
            lambda report: report["actions"][0].update(
                {"externalEvidenceArtifact": contract_artifact}
            ),
        )
        with self.assertRaisesRegex(
            qualification.QualificationError, "attestation.*key set mismatch"
        ):
            self.evaluate()

    def testQualificationReportTamperIsRejectedOnVerify(self) -> None:
        report = self.evaluate()
        report["releaseQualified"] = False
        path = self.root / "tampered-qualification-report.json"
        write_json(path, report)
        with self.assertRaisesRegex(qualification.QualificationError, "differs from recomputed"):
            qualification.verify_report(
                path, self.fixture.index_path, self.root, self.fixture.contract_path
            )


if __name__ == "__main__":
    unittest.main()
