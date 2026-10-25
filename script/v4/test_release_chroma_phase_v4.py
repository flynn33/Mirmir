"""Synthetic fresh quality2/parity3 release-consumer fixtures; not product evidence.

Unrelated lane builders are reused without changing their source or globals.
The versioned builders below generate fresh envelopes and physical declarations
before any report is evaluated or sealed. Archived fixture compatibility is
covered separately, against authentic old helper bytes.
"""
from __future__ import annotations
from fractions import Fraction
import copy
import contextlib
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock
import test_release_qualification_v4 as legacy_fixture
from test_release_qualification_v4 import identity,write_json,descriptor
import chroma_geometry_v4 as chroma

SCRIPT_DIRECTORY=Path(__file__).resolve().parent
qualification=legacy_fixture.qualification
quality_replay=legacy_fixture.quality_replay
parity_fixture_module=legacy_fixture.parity_fixture_module
parity=parity_fixture_module.parity
trust_builder=legacy_fixture.trust_builder

def geometry(definition, source, target, *, quality=False):
    dims=tuple(definition[k]for k in ["sourceWidth","sourceHeight","targetWidth","targetHeight"])
    plan,kernel=chroma.expected_hashes(*dims,source,target)
    return dict(schemaVersion="mirmir-ash-v4-quality-chroma-geometry-v1" if quality else "mirmir-ash-v4-parity-chroma-plan-v1",
        recipePolicyID="quality-box-source-reference-center-v1" if quality else "parity-declared-raw-uv-field-siting-v1",
        coordinateProcedureID=chroma.COORDINATE_ID,kernelContractID=chroma.KERNEL_ID,
        sourceSiting=source,outputSiting=target,planSchemaVersion=2,
        sourceLumaWidth=dims[0],sourceLumaHeight=dims[1],targetLumaWidth=dims[2],targetLumaHeight=dims[3],
        scalePlanSHA256=plan,kernelIRSHA256=kernel)

class FreshParityFixture(parity_fixture_module.ParityEvidenceFixture):
    TOOL_NAMES=("cpu-metal-parity-contract-v3.json","MirmirApp.swift","cpu_metal_parity_v4.py","run_cpu_metal_parity_v4.sh","chroma_geometry_v4.py")
    def __init__(
        self,
        root: Path,
        *,
        candidate: dict[str, object] | None = None,
        production_runtime: bool = False,
    ):
        self.root = root
        self.tools = root / "sealed-tools"
        self.tools.mkdir(parents=True)
        for name in self.TOOL_NAMES:
            source = (
                SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift"
                if name == "MirmirApp.swift"
                else SCRIPT_DIRECTORY / name
            )
            shutil.copy2(source, self.tools / name)
        self.contract_path = self.tools / self.TOOL_NAMES[0]
        self.capture_source = self.tools / self.TOOL_NAMES[1]
        self.evaluator = self.tools / self.TOOL_NAMES[2]
        self.runner = self.tools / self.TOOL_NAMES[3]
        self.contract = parity.load_json(self.contract_path)
        observed_tools = {
            "captureSourceSHA256": parity.sha256_file(self.capture_source),
            "evaluatorSHA256": parity.sha256_file(self.evaluator),
            "runnerSHA256": parity.sha256_file(self.runner),
            "chromaGeometryValidatorSHA256": parity.sha256_file(self.tools / "chroma_geometry_v4.py"),
        }
        if self.contract["tools"] != observed_tools:
            raise AssertionError("checked-in parity tool identities are stale")
        self.contract_sha = parity.sha256_file(self.contract_path)
        if candidate is None:
            self.source_revision = "1" * 40
            self.runtime = {
                "mode": "fixture",
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": identity("fixture-runtime-manifest-canonical"),
                "manifestFileSHA256": identity("fixture-runtime-manifest-file"),
                "sourceRevision": "2" * 40,
                "builderSourceSHA256": identity("fixture-runtime-builder"),
                "trustRootConfigured": False,
                "bindingVerified": True,
            }
            self.candidate = {
                "sourceCommit": self.source_revision,
                "sourceTreeIdentitySHA256": identity("fixture-source-tree"),
                "runtimeManifestSHA256": self.runtime["manifestSHA256"],
                "runtimeManifestFileSHA256": self.runtime["manifestFileSHA256"],
                "runtimeArtifactSetSHA256": identity("fixture-runtime-artifacts"),
                "runtimeSourceRevision": self.runtime["sourceRevision"],
                "releaseConfigurationSHA256": identity("fixture-release-config"),
                "appBundleSHA256": identity("fixture-app-bundle"),
                "bundleIdentifier": "com.mirmir.parity-tests",
                "productVersion": "4.0-test",
                "productBuild": "test",
            }
        else:
            if not production_runtime:
                raise AssertionError(
                    "an externally supplied candidate requires production runtime evidence"
                )
            self.candidate = copy.deepcopy(candidate)
            self.source_revision = str(candidate["sourceCommit"])
            self.runtime = {
                "mode": "production",
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": candidate["runtimeManifestSHA256"],
                "manifestFileSHA256": candidate["runtimeManifestFileSHA256"],
                "sourceRevision": candidate["runtimeSourceRevision"],
                "builderSourceSHA256": identity("release-fixture-runtime-builder"),
                "trustRootConfigured": True,
                "bindingVerified": True,
            }
        self.capture_a = root / "capture-a"
        self.capture_b = root / "capture-b"
        self._build_capture(self.capture_a, "process-a")
        self._build_capture(self.capture_b, "process-b")
        self.candidate_path = root / "candidate-identity.json"
        parity.write_json(self.candidate_path, self.candidate)

    def _format_identity(self,definition):
        sw,sh,tw,th=(definition[k]for k in ["sourceWidth","sourceHeight","targetWidth","targetHeight"])
        x,y=Fraction(tw,sw),Fraction(th,sh)
        field=(parity.FIELD_CHROMA_POLICY+":top=left;bottom=center;output=left") if definition["scanMode"]!="progressive" else "no-authenticated-field-geometry"
        return parity.sha256_bytes("|".join(["ash-p06-deterministic-v4",self.runtime["manifestSHA256"],
            self.STORAGE_RAW[definition["storage"]],str(sw),str(sh),str(tw),str(th),f"x={x.numerator}/{x.denominator};y={y.numerator}/{y.denominator}",
            chroma.COORDINATE_ID,chroma.COORDINATE_ID+":left->left",field]).encode())

    def _replace_format(self,value,definition):
        if isinstance(value,dict):return {k:self._format_identity(definition) if k=="formatIdentity" else self._replace_format(v,definition)for k,v in value.items()}
        if isinstance(value,list):return [self._replace_format(v,definition)for v in value]
        return value

    def _checkpoint(self,definition,ordinal):
        raw=super()._checkpoint(definition,ordinal)
        return parity.compact_canonical_json(self._replace_format(parity.parse_json_bytes(raw,"fixture checkpoint"),definition))

    def _tiled_checkpoint(self,definition,ordinal):
        raw=super()._tiled_checkpoint(definition,ordinal)
        return parity.compact_canonical_json(self._replace_format(parity.parse_json_bytes(raw,"fixture tiled checkpoint"),definition))

    def _execution(self,definition,backend,spatial_schedule,temporal_schedule):
        value=parity.parse_json_bytes(super()._execution(definition,backend,spatial_schedule,temporal_schedule),"unsealed shared execution blueprint")
        value["schemaVersion"]=parity.EXECUTION_SCHEMA_PHASE2
        alpha=definition["kind"]=="alpha_spatial"
        interlaced=definition["scanMode"]!="progressive"
        value.update(fixedPointKernelID="not_applicable_packed_alpha" if alpha else chroma.KERNEL_ID,
            chromaApplicability="not_applicable_packed_alpha" if alpha else "subsampled_420",
            chromaGeometry=None if alpha else dict(schemaVersion="mirmir-ash-v4-parity-chroma-geometry-v1",
                normalizationPolicyID=parity.FIELD_CHROMA_POLICY if interlaced else "progressive-declared-uv-left-v1",
                top=geometry(definition,"left","left"),bottom=geometry(definition,"center","left") if interlaced else None))
        return parity.canonical_json(value)

    def _semantics(self,definition):
        self._semantic_kind=definition["kind"]
        return super()._semantics(definition)

    def _source_attachments(self,frame):
        values=[x for x in super()._source_attachments(frame)if x["key"]!=parity.BOTTOM_FIELD_CHROMA_ATTACHMENT]
        if self._semantic_kind!="alpha_spatial":
            values.append(self._attachment(parity.TOP_FIELD_CHROMA_ATTACHMENT,{"kind":"string","value":"Left"}))
            if frame["fieldDetail"]!="none":values.append(self._attachment(parity.BOTTOM_FIELD_CHROMA_ATTACHMENT,{"kind":"string","value":"Center"}))
        return sorted(values,key=lambda x:x["key"])

    def _output_attachments(self,frame):
        values=super()._output_attachments(frame)
        if self._semantic_kind!="alpha_spatial":values.append(self._attachment(parity.BOTTOM_FIELD_CHROMA_ATTACHMENT,{"kind":"string","value":"Left"}))
        return sorted(values,key=lambda x:x["key"])

    def reseal(self,directory):
        path=directory/"artifact-manifest.json"
        parity.write_json(path,{"schemaVersion":parity.CAPTURE_MANIFEST_SCHEMA_PHASE2,
            "artifacts":[parity.descriptor(p,directory)for p in sorted(directory.rglob("*"))if p.is_file()and p!=path]})

class FreshReleaseFixture(legacy_fixture.EvidenceFixture):
    quality_contract_name = "quality-gate-contract-v2.json"

    def _write_bound_files(self,role_dir,role,contract_value):
        contract_path,runtime_path,release_path=super()._write_bound_files(role_dir,role,contract_value)
        if role=="quality":
            named=role_dir/self.quality_contract_name
            contract_path.rename(named)
            contract_path=named
        return contract_path,runtime_path,release_path
    def _build_common_reports(self):
        # This fixture exercises only the two changed central lane consumers.
        # Its contract still requires all8roles, so its2lane index cannot qualify
        # an aggregate candidate or bypass pending unrelated source locks.
        self._build_parity_actual(self.root / "cpu_metal_parity")

    def _build_quality(self) -> None:
        role = "quality"
        role_dir = self.root / role
        quality_gate = quality_replay
        quality_contract = copy.deepcopy(
            json.loads(
                (SCRIPT_DIRECTORY / self.quality_contract_name).read_text()
            )
        )
        # Keep the release contract's 10,000 bootstrap replicates while making
        # the unit-test corpus small enough for repeated fail-closed cases.
        quality_contract["cohortConstraints"]["minimumClipsPerCohort"] = 1
        quality_contract["cohortConstraints"]["minimumFramesPerClip"] = 2
        quality_contract["corpusConstruction"][
            "syntheticDiagnosticClipCountPerCohort"
        ] = 1
        quality_contract["corpusConstruction"][
            "syntheticDiagnosticFramesPerClip"
        ] = 2
        contract_path, runtime_path, _ = self._write_bound_files(role_dir, role, quality_contract)

        copied_sources = (
            "quality_gate_v4.py",
            "chroma_geometry_v4.py",
            "p05_baseline_v4.py",
            "P05QualityBaselineCaptureTests.swift",
            "p05-baseline-source-manifest-v1.json",
            "natural-quality-corpus-lock-v2.json",
        )
        for filename in copied_sources:
            shutil.copy2(SCRIPT_DIRECTORY / filename, role_dir / filename)
        metric_path = role_dir / "quality_gate_v4.py"
        observer_source_path = role_dir / "MirmirApp.swift"
        observer_source_path.write_bytes(
            (SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift")
            .read_bytes()
        )

        corpus_stage = role_dir / "corpus-stage"
        with contextlib.redirect_stdout(io.StringIO()):
            quality_gate.generate_corpus(contract_path, corpus_stage)
        shutil.move(str(corpus_stage / "artifacts"), str(role_dir / "artifacts"))
        shutil.move(
            str(corpus_stage / "corpus-manifest.json"),
            str(role_dir / "corpus-manifest.json"),
        )
        corpus_stage.rmdir()
        corpus_path = role_dir / "corpus-manifest.json"
        corpus_manifest = json.loads(corpus_path.read_text())
        # This is a release-eligible fixture for verifier tests, not claimed
        # project evidence.  Its raw planes still pass the production replay.
        corpus_manifest["corpusKind"] = "locked_natural"
        corpus_manifest["releaseEligible"] = True
        corpus_manifest.setdefault(
            "sourceAssetSetSHA256", identity("fixture-quality-source-assets")
        )
        corpus_manifest.setdefault(
            "sourceLicenseSetSHA256",
            identity("fixture-quality-source-licenses"),
        )
        write_json(corpus_path, corpus_manifest)
        corpus_release_lock_path = (
            role_dir / "natural-quality-corpus-lock-v2.json"
        )
        corpus_release_lock = json.loads(corpus_release_lock_path.read_text())
        corpus_release_lock.update(
            {
                "artifactSetSHA256": corpus_manifest["artifactSetSHA256"],
                "caseCount": corpus_manifest["caseCount"],
                "clipCount": corpus_manifest["clipCount"],
                "manifestSHA256": quality_gate.sha256(corpus_path),
                "qualityContractSHA256": quality_gate.sha256(contract_path),
                "sourceAssetSetSHA256": corpus_manifest[
                    "sourceAssetSetSHA256"
                ],
                "sourceLicenseSetSHA256": corpus_manifest[
                    "sourceLicenseSetSHA256"
                ],
            }
        )
        write_json(corpus_release_lock_path, corpus_release_lock)

        capture_cases = []
        for case_index, case in enumerate(corpus_manifest["cases"]):
            reference_path = role_dir / case["referenceFile"]
            reference_bytes = reference_path.read_bytes()
            shift = 1 + case_index % 3
            baseline_bytes = reference_bytes[-shift:] + reference_bytes[:-shift]
            outputs: dict[str, str] = {}
            milliseconds: dict[str, float] = {}
            for variant_index, variant in enumerate(quality_gate.VARIANTS):
                relative = f"artifacts/{case['id']}-{variant}.nv12"
                output_path = role_dir / relative
                output_path.write_bytes(
                    reference_bytes if variant == "candidate_v4" else baseline_bytes
                )
                outputs[variant] = relative
                milliseconds[variant] = float(variant_index + 1)
            capture_cases.append(
                {
                    "id": case["id"],
                    "chromaGeometry": geometry(case,"center","center",quality=True),
                    "outputs": outputs,
                    "milliseconds": milliseconds,
                }
            )

        contract_sha = quality_gate.sha256(contract_path)
        corpus_sha = quality_gate.sha256(corpus_path)
        baseline_identity = quality_gate.p05.frozen_identity(quality_contract)
        package_fixture = self._build_packaged_quality_fixture(
            role_dir,
            contract_path,
            corpus_path,
            capture_cases,
            observer_source_path,
        )
        capture_manifest = {
            "schemaVersion": quality_gate.SCHEMA_CAPTURE_PHASE2,
            "fixedPointKernelID": chroma.KERNEL_ID,
            "contractSHA256": contract_sha,
            "corpusManifestSHA256": corpus_sha,
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
            "candidateBackendID": self.contract["quality"]["requiredBackendID"],
            "candidateImplementationVersion": self.contract["quality"][
                "requiredCandidateImplementationVersion"
            ],
            "productionRuntimeLocked": True,
            "fullMirrorIdentityPass": True,
            "warmupCount": 1,
            "baselineIdentity": baseline_identity,
            "baselineImplementationVersion": baseline_identity[
                "implementationVersion"
            ],
            "baselineWarmupCount": 1,
            "evidenceRequestSHA256": package_fixture["requestSHA256"],
            "observerSourceSHA256": package_fixture["observerSourceSHA256"],
            "packagedCandidateIdentity": package_fixture["packageIdentity"],
            "cases": capture_cases,
        }
        capture_path = role_dir / "capture-manifest.json"
        write_json(capture_path, capture_manifest)
        write_json(
            role_dir / "p05-capture-manifest.json",
            {
                "schemaVersion": "mirmir-ash-v4-quality-p05-capture-v1",
                "contractSHA256": contract_sha,
                "corpusManifestSHA256": corpus_sha,
                "baselineIdentity": baseline_identity,
                "warmupCount": 1,
                "cases": [
                    {
                        "id": case["id"],
                        "output": case["outputs"]["baseline_p05"],
                        "milliseconds": case["milliseconds"]["baseline_p05"],
                    }
                    for case in capture_cases
                ],
            },
        )
        (role_dir / "p05-xcodebuild.log").write_text(
            "fixture frozen P05 Release capture completed\n",
            encoding="utf-8",
        )
        report_path = role_dir / "report.json"
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(
            quality_gate,
            "validate_packaged_quality_capture",
            return_value={
                "packageIdentity": package_fixture["packageIdentity"],
                "requestSHA256": package_fixture["requestSHA256"],
                "observerSourceSHA256": package_fixture["observerSourceSHA256"],
                "captureTree": package_fixture["captureTree"],
            },
        ):
            quality_gate.evaluate(
                contract_path,
                corpus_path,
                capture_path,
                report_path,
                package_fixture["root"],
                self.root,
                runtime_path,
            )
        report = json.loads(report_path.read_text())
        self.contract["qualityLaneContractSHA256"] = contract_sha
        self.contract["qualityLockedSources"] = {
            "chromaGeometryValidatorSHA256": qualification.sha256(role_dir/"chroma_geometry_v4.py"),
            "baselineRunnerSHA256": qualification.sha256(
                SCRIPT_DIRECTORY / "run_p05_quality_baseline_v4.sh"
            ),
            "metricToolSHA256": report["identities"]["metricToolSHA256"],
            "observerSourceSHA256": report["identities"][
                "observerSourceSHA256"
            ],
        }
        self.contract["qualityCorpusLock"] = {
            "artifactSetSHA256": report["identities"][
                "corpusArtifactSetSHA256"
            ],
            "caseCount": corpus_manifest["caseCount"],
            "clipCount": corpus_manifest["clipCount"],
            "contractSHA256": contract_sha,
            "manifestSHA256": corpus_sha,
            "releaseLockSHA256": qualification.sha256(
                corpus_release_lock_path
            ),
            "sourceAssetSetSHA256": corpus_manifest[
                "sourceAssetSetSHA256"
            ],
            "sourceLicenseSetSHA256": corpus_manifest[
                "sourceLicenseSetSHA256"
            ],
        }
        self.contract["qualityFrozenP05Baseline"] = baseline_identity
        self.contract["qualityFrozenP05OutputSetSHA256"] = report[
            "identities"
        ]["outputSetSHA256"]["baseline_p05"]
        self._write_quality_evidence_manifest()
        bindings = [
            ("/identities/chromaGeometryValidatorSHA256", role_dir/"chroma_geometry_v4.py"),
            ("/identities/contractSHA256", contract_path),
            ("/identities/metricToolSHA256", metric_path),
            ("/identities/corpusManifestSHA256", corpus_path),
            ("/identities/evidenceRequestSHA256", package_fixture["request"]),
            ("/identities/observerSourceSHA256", package_fixture["observerSource"]),
            (
                "/identities/packagedCandidateIdentity/applicationArchiveSHA256",
                package_fixture["applicationArchive"],
            ),
            (
                "/identities/packagedCandidateIdentity/attestationSHA256",
                package_fixture["attestation"],
            ),
            (
                "/identities/packagedCandidateIdentity/releaseConfigurationSHA256",
                package_fixture["releaseConfiguration"],
            ),
        ]
        self._seal_and_add(
            role,
            report,
            contract_path,
            runtime_path,
            None,
            bindings,
            existing_report_path=report_path,
        )

    def _build_packaged_quality_fixture(
        self,
        role_dir: Path,
        contract_path: Path,
        corpus_path: Path,
        capture_cases: list[dict[str, object]],
        observer_source_path: Path,
    ) -> dict[str, object]:
        """Build a package-shaped unit fixture; production CLI has no such adapter."""

        package_root = role_dir / "packaged-candidate"
        observer_root = package_root / "observer"
        capture_root = package_root / "capture"
        bindings_root = package_root / "bindings"
        for directory in (observer_root, capture_root / "artifacts", bindings_root):
            directory.mkdir(parents=True, exist_ok=True)

        def write_canonical(path: Path, value: object) -> None:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(qualification.canonical_bytes(value))

        candidate_path = bindings_root / "candidate.json"
        write_canonical(candidate_path, self.candidate)
        observer_path = bindings_root / "observer-source.swift"
        observer_path.write_bytes(observer_source_path.read_bytes())
        lane_contract_path = bindings_root / "lane-contract.json"
        lane_contract_path.write_bytes(contract_path.read_bytes())
        release_configuration = bindings_root / "release-candidate-v4.xcconfig"
        release_configuration.write_bytes(self.release_bytes)
        application_archive = bindings_root / "application-archive.zip"
        application_archive.write_bytes(self.app_bytes)
        attestation = bindings_root / "application-archive-attestation-v1.json"
        write_canonical(
            attestation,
            {
                "schemaVersion": "mirmir-v4-release-archive-attestation-v1",
                "fixtureOnly": True,
            },
        )
        package = {
            "schemaVersion": "mirmir-v4-packaged-candidate-identity-v1",
            "buildConfiguration": "Release",
            "applicationArchiveSHA256": qualification.sha256(application_archive),
            "applicationPayloadIdentitySHA256": identity("quality-package-payload"),
            "applicationInfoPlistSHA256": identity("quality-package-info"),
            "applicationExecutableSHA256": qualification.sha256_bytes(
                b"shipping-app-executable"
            ),
            "codeDirectories": [
                {"architecture": "arm64", "sha256": identity("quality-cd-arm64")},
                {"architecture": "x86_64", "sha256": identity("quality-cd-x86_64")},
            ],
            "codeDirectorySetSHA256": identity("quality-cd-set"),
            "designatedRequirementSHA256": identity("quality-requirement"),
            "releaseConfigurationSHA256": qualification.sha256(
                release_configuration
            ),
            "attestationSHA256": qualification.sha256(attestation),
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate[
                "sourceTreeIdentitySHA256"
            ],
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeManifestFileSHA256": self.candidate[
                "runtimeManifestFileSHA256"
            ],
            "runtimeArtifactSetSHA256": self.candidate[
                "runtimeArtifactSetSHA256"
            ],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "bundleIdentifier": self.candidate["bundleIdentifier"],
            "productVersion": self.candidate["productVersion"],
            "productBuild": self.candidate["productBuild"],
        }
        package_path = bindings_root / "package-identity.json"
        write_canonical(package_path, package)
        exact_cases = []
        for case in capture_cases:
            outputs = {
                variant: case["outputs"][variant]
                for variant in quality_replay.CANDIDATE_VARIANTS
            }
            milliseconds = {
                variant: case["milliseconds"][variant]
                for variant in quality_replay.CANDIDATE_VARIANTS
            }
            for relative in outputs.values():
                destination = capture_root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(role_dir / relative, destination)
            exact_cases.append(
                {"id": case["id"], "outputs": outputs, "milliseconds": milliseconds, "chromaGeometry":copy.deepcopy(case["chromaGeometry"])}
            )
        observer_sha = qualification.sha256(observer_path)
        request = {
            "schemaVersion": "mirmir-v4-packaged-evidence-request-v1",
            "lane": "quality",
            "requestID": "11111111-1111-4111-8111-111111111111",
            "nonce": identity("quality-request-nonce"),
            "generatedAtUTC": "2026-08-02T12:00:00Z",
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "captureEnvironment": {
                "MIRMIR_V4_QUALITY_CAPTURE_DIR": "/fixture/capture",
                "MIRMIR_V4_QUALITY_CORPUS_MANIFEST": "/fixture/inputs/corpus-manifest.json",
                "MIRMIR_V4_QUALITY_CONTRACT_SHA256": qualification.sha256(
                    contract_path
                ),
                "MIRMIR_V4_QUALITY_SOURCE_COMMIT": self.candidate[
                    "sourceCommit"
                ],
                "MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256": self.candidate[
                    "sourceTreeIdentitySHA256"
                ],
            },
        }
        request_path = observer_root / "request.json"
        write_canonical(request_path, request)
        request_sha = qualification.sha256(request_path)
        exact_manifest = {
            "schemaVersion": quality_replay.SCHEMA_CANDIDATE_PHASE2,
            "fixedPointKernelID":chroma.KERNEL_ID,
            "contractSHA256": qualification.sha256(contract_path),
            "corpusManifestSHA256": qualification.sha256(corpus_path),
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate[
                "sourceTreeIdentitySHA256"
            ],
            "candidateBackendID": self.contract["quality"]["requiredBackendID"],
            "candidateImplementationVersion": self.contract["quality"][
                "requiredCandidateImplementationVersion"
            ],
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "productionRuntimeLocked": True,
            "fullMirrorIdentityPass": True,
            "warmupCount": 1,
            "evidenceRequestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "packagedCandidateIdentity": package,
            "cases": exact_cases,
        }
        exact_manifest_path = capture_root / "candidate-capture-manifest.json"
        write_json(exact_manifest_path, exact_manifest)
        capture_tree = qualification.packaged_capture_tree(capture_root)
        result = {
            "schemaVersion": "mirmir-v4-packaged-evidence-result-v1",
            "lane": "quality",
            "requestID": request["requestID"],
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "process": {
                "bundlePath": "/fixture/Mirmir.app",
                "executablePath": "/fixture/Mirmir.app/Contents/MacOS/Mirmir",
                "executableSHA256": package["applicationExecutableSHA256"],
                "processID": 101,
                "parentProcessID": 100,
            },
            "runtime": {
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                "sourceRevision": self.candidate["runtimeSourceRevision"],
                "trustRootConfigured": True,
            },
            "captureManifest": {
                "fileName": exact_manifest_path.name,
                "byteCount": exact_manifest_path.stat().st_size,
                "sha256": qualification.sha256(exact_manifest_path),
            },
            "captureTree": capture_tree,
            "checks": {
                "exactExecutableIdentity": True,
                "signedBuildClaims": True,
                "productionP06Load": True,
                "normativePixelCapture": True,
            },
        }
        result_path = observer_root / "result.json"
        write_canonical(result_path, result)
        stdout_path = observer_root / "stdout.bin"
        stderr_path = observer_root / "stderr.bin"
        stdout_path.write_bytes(b"fixture packaged observer result\n")
        stderr_path.write_bytes(b"")
        record = {
            "schemaVersion": "mirmir-v4-packaged-evidence-capture-record-v1",
            "lane": "quality",
            "startedAtUTC": "2026-08-02T12:00:00Z",
            "finishedAtUTC": "2026-08-02T12:00:01Z",
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "captureTree": capture_tree,
            "process": {
                "executableSHA256": package["applicationExecutableSHA256"],
                "exitStatus": 0,
            },
            "artifacts": {
                "request": descriptor(request_path, package_root),
                "result": descriptor(result_path, package_root),
                "stdout": descriptor(stdout_path, package_root),
                "stderr": descriptor(stderr_path, package_root),
                "candidate": descriptor(candidate_path, package_root),
                "packageIdentity": descriptor(package_path, package_root),
                "attestation": descriptor(attestation, package_root),
                "observerSource": descriptor(observer_path, package_root),
                "contract": descriptor(lane_contract_path, package_root),
                "releaseConfiguration": descriptor(
                    release_configuration, package_root
                ),
                "applicationArchive": descriptor(application_archive, package_root),
            },
        }
        write_canonical(package_root / "capture-record.json", record)
        self.packaged_candidate_identity = copy.deepcopy(package)
        return {
            "root": package_root,
            "packageIdentity": package,
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "captureTree": capture_tree,
            "request": request_path,
            "observerSource": observer_path,
            "applicationArchive": application_archive,
            "attestation": attestation,
            "releaseConfiguration": release_configuration,
        }

    def _build_parity_actual(self, role_dir: Path) -> None:
        parity_root = role_dir / "parity-evidence"
        fixture = FreshParityFixture(
            parity_root,
            candidate=self.candidate,
            production_runtime=True,
        )
        packaged = [
            self._build_parity_package_fixture(
                fixture,
                fixture.capture_a,
                parity_root / "packaged-process-a",
                "process-a",
                1,
            ),
            self._build_parity_package_fixture(
                fixture,
                fixture.capture_b,
                parity_root / "packaged-process-b",
                "process-b",
                2,
            ),
        ]
        fixture.capture_a = packaged[0]["root"] / "capture"
        fixture.capture_b = packaged[1]["root"] / "capture"
        report = fixture.evaluate(allow_fixture_runtime=True)
        report["releaseEligible"] = True
        report["identities"]["packagedCandidateIdentity"] = copy.deepcopy(
            self.packaged_candidate_identity
        )
        report["identities"]["evidenceRequestSHA256"] = [
            item["requestSHA256"] for item in packaged
        ]
        report["identities"]["packagedCaptureTreeSHA256"] = [
            item["captureTree"]["sha256"] for item in packaged
        ]
        report["exactPackagedCandidatePass"] = True
        report["byteParityGatePass"] = True
        self.contract["parityLaneContractSHA256"] = qualification.sha256(
            fixture.contract_path
        )
        self.contract["parityLockedSources"] = {
            key: report["identities"][key]
            for key in (
                "captureSourceSHA256",
                "evaluatorSHA256",
                "runnerSHA256",
                "chromaGeometryValidatorSHA256",
            )
        }
        report_path = parity_root / "cpu-metal-parity-report.json"
        parity_fixture_module.parity.write_json(report_path, report)
        manifest_path = parity_root / "artifact-manifest.json"
        parity_fixture_module.parity.write_json(
            manifest_path,
            parity_fixture_module.parity.make_root_manifest(
                parity_root, manifest_path, phase2=True
            ),
        )
        runtime_path = role_dir / "runtime-manifest.json"
        release_path = role_dir / "Release.xcconfig"
        runtime_path.write_bytes(self.runtime_bytes)
        release_path.write_bytes(self.release_bytes)
        self.parity_fixture = fixture
        self._seal_and_add(
            "cpu_metal_parity",
            report,
            fixture.contract_path,
            runtime_path,
            release_path,
            [
                (
                    "/identities/captureSourceSHA256",
                    fixture.capture_source,
                ),
                ("/identities/evaluatorSHA256", fixture.evaluator),
                ("/identities/chromaGeometryValidatorSHA256", fixture.tools/"chroma_geometry_v4.py"),
                ("/identities/runnerSHA256", fixture.runner),
                (
                    "/identities/evidenceRequestSHA256/0",
                    packaged[0]["request"],
                ),
                (
                    "/identities/evidenceRequestSHA256/1",
                    packaged[1]["request"],
                ),
                (
                    "/identities/packagedCandidateIdentity/applicationArchiveSHA256",
                    packaged[0]["applicationArchive"],
                ),
                (
                    "/identities/packagedCandidateIdentity/attestationSHA256",
                    packaged[0]["attestation"],
                ),
            ],
            existing_report_path=report_path,
        )

class FreshEightRoleFixture(FreshReleaseFixture):
    """Fresh changed lanes plus the existing hermetic eight-role blueprints."""

    def _build_common_reports(self):
        legacy_fixture.EvidenceFixture._build_common_reports(self)


class FreshPhaseReleaseConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix="mirmir-fresh-release-unit-")
        self.root=Path(self.temporary.name).resolve()
        self.fixture=FreshReleaseFixture(self.root)
        self.operator_trust=self.root.parent/(self.root.name+"-operator-trust2.json")
        trust_builder.write_json(self.operator_trust,trust_builder.build_trust_root(SCRIPT_DIRECTORY,self.fixture.contract_path))
        self.trust_sha=trust_builder.sha256(self.operator_trust)
        qualification.establish_external_trust(self.operator_trust,self.trust_sha,self.fixture.contract_path)

    def tearDown(self):
        self.operator_trust.unlink(missing_ok=True)
        self.temporary.cleanup()

    def evaluate_role(self,role):
        if role != "quality":
            return legacy_fixture.ReleaseQualificationV4Tests.evaluate_role(self,role)
        entry=self.fixture.entry(role)
        report_path,_=qualification.validate_artifact(self.root,entry,role,
            allowed_extra_keys={"role","contractSHA256","sealedManifest","identityBindings"})
        report=qualification.load_json(report_path)
        _,sealed=qualification.validate_sealed_manifest(self.root,entry["sealedManifest"],report_path,"fresh quality seal")
        qualification.validate_bindings(self.root,report,entry,set(self.fixture.contract["identityBindings"][role]),role)
        return qualification.validate_quality(report,self.fixture.candidate,self.fixture.contract,entry,self.root,sealed)

    def testFreshQualityAndParityActuallyReplayWithBoundSharedHelper(self):
        self.assertTrue(qualification.phase2_release_profile(self.fixture.contract))
        quality=self.evaluate_role("quality")
        parity_result=self.evaluate_role("cpu_metal_parity")
        self.assertIsInstance(quality,dict)
        self.assertIsInstance(parity_result,dict)
        for role,schema in [("quality","mirmir-ash-v4-quality-report-v2"),("cpu_metal_parity","mirmir-ash-v4-cpu-metal-parity-report-v3")]:
            entry=self.fixture.entry(role);report=qualification.load_json(self.root/entry["path"])
            self.assertEqual(report["schemaVersion"],schema)
            self.assertEqual(report["identities"]["chromaGeometryValidatorSHA256"],qualification.sha256(SCRIPT_DIRECTORY/"chroma_geometry_v4.py"))

    def testMissingSharedHelperBindingRejectsBothFreshLanes(self):
        for role in ["quality", "cpu_metal_parity"]:
            with self.subTest(role=role):
                entry=self.fixture.entry(role)
                original=copy.deepcopy(entry["identityBindings"])
                entry["identityBindings"]=[x for x in original if x["jsonPointer"]!="/identities/chromaGeometryValidatorSHA256"]
                self.fixture.save_index()
                try:
                    with self.assertRaises(qualification.QualificationError):self.evaluate_role(role)
                finally:
                    entry["identityBindings"]=original
                    self.fixture.save_index()

    def testRehashedAndResealedHelperSubstitutionCannotChangeReleaseLock(self):
        for role in ["quality", "cpu_metal_parity"]:
            with self.subTest(role=role):
                entry=self.fixture.entry(role)
                binding=next(x for x in entry["identityBindings"]if x["jsonPointer"]=="/identities/chromaGeometryValidatorSHA256")
                helper=self.root/binding["path"]
                original=helper.read_bytes()
                report_path=self.root/entry["path"]
                report_original=qualification.load_json(report_path)
                binding_original=copy.deepcopy(binding)
                try:
                    helper.write_bytes(original+b"\n# deliberately substituted fixture helper\n")
                    report=copy.deepcopy(report_original)
                    report["identities"]["chromaGeometryValidatorSHA256"]=qualification.sha256(helper)
                    write_json(report_path,report)
                    binding.update(descriptor(helper,self.root))
                    self.fixture.reseal_role(role)
                    with self.assertRaises(qualification.QualificationError):self.evaluate_role(role)
                finally:
                    helper.write_bytes(original)
                    write_json(report_path,report_original)
                    binding.clear();binding.update(binding_original)
                    self.fixture.reseal_role(role)

class FreshReleaseContradictionTests(unittest.TestCase):
    def testFreshCenterCaptureRejectsHistoricalLeftConstructionContract(self):
        class ContradictoryFixture(FreshReleaseFixture):
            quality_contract_name = "quality-gate-contract-v1.json"
        with tempfile.TemporaryDirectory(prefix="mirmir-fresh-wrong-phase-unit-") as temporary:
            with self.assertRaises((SystemExit, ValueError)):
                ContradictoryFixture(Path(temporary).resolve())


class FreshEightRoleConsumerTests(unittest.TestCase):
    def testFreshEightRoleCandidateReplaysAndVerifies(self):
        # These are generated unit-test records, not an actual signed candidate.
        # Keep the legacy fixture's performance-summary and media replay mocks;
        # the changed quality/parity/trust/central consumers execute unmocked.
        with tempfile.TemporaryDirectory(prefix="mirmir-fresh-eight-role-unit-") as temporary:
            root = Path(temporary).resolve()
            fixture = FreshEightRoleFixture(root)
            trust_path = root / "operator-trust2.json"
            trust_builder.write_json(trust_path, trust_builder.build_trust_root(SCRIPT_DIRECTORY, fixture.contract_path))
            trust_sha = trust_builder.sha256(trust_path)
            self.assertEqual({entry["role"] for entry in fixture.entries}, {
                "quality", "same_scope_performance", "cpu_metal_parity", "media_preservation",
                "recovery", "p06_reproduction", "support_matrix", "notarized_smoke",
            })
            self.assertEqual(len(fixture.entries), 8)
            media_replay = mock.Mock()
            media_replay.EvidenceError = ValueError
            media_replay.verify_evidence.side_effect = lambda path: qualification.load_json(path / "report.json")
            with mock.patch.object(qualification, "load_locked_performance_evaluator", return_value=legacy_fixture.performance_gate), mock.patch.object(
                legacy_fixture.performance_gate, "normalized_test_summary", return_value={
                    "schemaVersion": legacy_fixture.performance_gate.TEST_SUMMARY_SCHEMA,
                    "testIdentifier": legacy_fixture.performance_gate.BASELINE_TEST_IDENTIFIER,
                    "result": "Passed", "passedTests": 1, "failedTests": 0, "skippedTests": 0,
                }
            ), mock.patch.object(qualification, "load_locked_media_evaluator", return_value=media_replay):
                def evaluate():
                    return qualification.evaluate_candidate(fixture.index_path, root, fixture.contract_path,
                        trust_root_path=trust_path, expected_trust_root_sha256=trust_sha)
                report = evaluate()
                self.assertTrue(report["releaseQualified"])
                self.assertTrue(all(report["gates"].values()))
                self.assertEqual(report, evaluate())
                report_path = root / "qualification-report.json"
                write_json(report_path, report)
                self.assertEqual(report, qualification.verify_report(report_path, fixture.index_path,
                    root, fixture.contract_path, trust_root_path=trust_path,
                    expected_trust_root_sha256=trust_sha))
                fixture.index["evidence"] = [entry for entry in fixture.entries if entry["role"] != "cpu_metal_parity"]
                fixture.save_index()
                with self.assertRaises(qualification.QualificationError):
                    evaluate()

if __name__=="__main__":unittest.main()
