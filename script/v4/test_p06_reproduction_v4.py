#!/usr/bin/env python3
"""Tamper-oriented tests for the P06 reproduction replay verifier."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "p06_reproduction_v4", SCRIPT_DIRECTORY / "p06_reproduction_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
p06 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p06)


ROLES = [
    "benchmark_corpus_identity",
    "branch_aggregation",
    "codeword_tables",
    "core_certificate",
    "measurement_contract",
    "metal_compiler_contract",
    "metal_library",
    "metric_contract",
    "operator_bank",
    "phase_coefficient_procedure",
    "quality_corpus_identity",
    "verification_contract",
]


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_canonical(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(p06.canonical_bytes(value))


def descriptor(path: Path, root: Path) -> dict[str, object]:
    return {
        "path": path.relative_to(root).as_posix(),
        "byteCount": path.stat().st_size,
        "sha256": p06.sha256_file(path),
    }


class EvidenceFixture:
    def __init__(self, parent: Path) -> None:
        self.root = parent / "evidence"
        self.root.mkdir()
        self.candidate_path = parent / "candidate.json"
        self.contract_path = parent / "contract.json"
        self.toolchain = {"sdk": "macosx99A1", "swift": "Swift 99.0"}
        self.builder_bytes = b"builder manifest\n"
        self.source_contract = {
            "schemaVersion": "mirmir-ash-v4-p06-source-provenance-contract-v1",
            "identityDomain": "ash-p06-production-source-v1",
            "normalizedDeploymentTrustRoot": {
                "path": "Sources/TrustV4.swift",
                "assignments": [
                    "builderSourceSHA256",
                    "manifestSHA256",
                    "sourceRevision",
                ],
            },
            "sources": ["Sources/TrustV4.swift"],
        }

        tool_files = {
            "captureSourceSHA256": ("capture-tool.py", b"capture\n"),
            "evaluatorSHA256": ("evaluator.py", b"evaluator\n"),
            "runnerSHA256": ("runner.sh", b"runner\n"),
            "runtimeLoadCheckRunnerSHA256": ("runtime-load-check-runner.sh", b"load runner\n"),
            "runtimeLoadCheckSourceSHA256": ("runtime-load-check.swift", b"load source\n"),
            "sourceIdentityToolSHA256": ("source-identity-tool.py", b"source identity\n"),
            "sourceProvenanceContractSHA256": (
                "source-provenance-contract.json",
                p06.canonical_bytes(self.source_contract),
            ),
        }
        capture_identities: dict[str, str] = {}
        for key, (relative, contents) in tool_files.items():
            path = self.root / relative
            path.write_bytes(contents)
            capture_identities[key] = p06.sha256_file(path)

        self.contract = {
            "schemaVersion": p06.CONTRACT_SCHEMA,
            "suiteID": "mirmir-ash-v4-p06-reproduction-v1",
            "buildConfiguration": "Release",
            "builderID": "ash-p06-release-builder-v4-1",
            "canonicalManifestIdentityDomain": "ash-p06-runtime-manifest-v4",
            "capture": capture_identities,
            "cleanBuildCount": 2,
            "cleanBuildIDs": ["clean-build-a", "clean-build-b"],
            "developmentArtifactDependencyCount": 0,
            "p05ProductionDependencyCount": 0,
            "productionSourceCount": 1,
            "requiredRuntimeArtifactRoles": ROLES,
            "runtimeID": p06.RUNTIME_ID,
            "runtimeReleaseStatus": "release_qualified",
            "sourceCheckoutState": "clean",
            "verification": {
                "byteIdenticalToShippingBundle": True,
                "productionLoaderAcceptanceRequired": True,
                "sameLengthArtifactTamperRejectionRequired": True,
                "sealedClosureRequired": True,
                "toolchainProvenanceEqualityRequired": True,
            },
        }
        write_json(self.contract_path, self.contract)
        (self.root / "suite-contract.json").write_bytes(self.contract_path.read_bytes())
        release_configuration = self.root / "Release.xcconfig"
        release_configuration.write_text("SWIFT_OPTIMIZATION_LEVEL = -O\n", encoding="utf-8")

        artifact_contents: dict[str, bytes] = {}
        for role in ROLES:
            relative = "artifacts/ash-p06.metallib" if role == "metal_library" else f"artifacts/{role}.json"
            artifact_contents[relative] = (
                b"MTLB-test" if role == "metal_library" else p06.canonical_bytes({"role": role})
            )
        artifact_declarations = []
        for role in ROLES:
            relative = "artifacts/ash-p06.metallib" if role == "metal_library" else f"artifacts/{role}.json"
            data = artifact_contents[relative]
            artifact_declarations.append(
                {
                    "role": role,
                    "relativePath": relative,
                    "schemaID": f"ash.p06.{role}.v1",
                    "contentSHA256": p06.sha256_bytes(data),
                    "byteCount": len(data),
                }
            )
        source_revision = "2" * 64
        builder_identity = p06.sha256_bytes(self.builder_bytes)
        manifest = {
            "schemaID": p06.MANIFEST_SCHEMA,
            "runtimeID": p06.RUNTIME_ID,
            "releaseStatus": "release_qualified",
            "artifacts": artifact_declarations,
            "provenance": {
                "sourceRevision": source_revision,
                "builderSourceSHA256": builder_identity,
                "metalLibrarySHA256": next(
                    item["contentSHA256"] for item in artifact_declarations if item["role"] == "metal_library"
                ),
                "toolchain": self.toolchain,
            },
        }
        manifest_bytes = p06.canonical_bytes(manifest)
        semantic_identity = p06.sha256_bytes(p06.MANIFEST_DOMAIN + manifest_bytes)
        entries = [("runtime-manifest.json", p06.sha256_bytes(manifest_bytes))]
        entries.extend((relative, p06.sha256_bytes(data)) for relative, data in artifact_contents.items())
        artifact_set = p06.artifact_set_sha(entries)
        self.candidate = {
            "sourceCommit": "1" * 40,
            "sourceTreeIdentitySHA256": "3" * 64,
            "runtimeManifestSHA256": semantic_identity,
            "runtimeManifestFileSHA256": p06.sha256_bytes(manifest_bytes),
            "runtimeArtifactSetSHA256": artifact_set,
            "runtimeSourceRevision": source_revision,
            "releaseConfigurationSHA256": p06.sha256_file(release_configuration),
            "appBundleSHA256": "4" * 64,
            "bundleIdentifier": "com.example.Mirmir",
            "productVersion": "4.0",
            "productBuild": "400",
        }
        write_json(self.candidate_path, {"candidate": self.candidate})

        write_canonical(self.root / "runtime-manifest.json", manifest)
        for relative, data in artifact_contents.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

        builds = []
        for identifier in self.contract["cleanBuildIDs"]:
            build_root = self.root / identifier
            for relative, data in artifact_contents.items():
                path = build_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            write_canonical(build_root / "runtime-manifest.json", manifest)
            provenance = build_root / "provenance"
            provenance.mkdir()
            builder = provenance / "builder-source-manifest.txt"
            builder.write_bytes(self.builder_bytes)
            toolchain = provenance / "toolchain-image.json"
            write_canonical(toolchain, self.toolchain)
            production_source = provenance / "production-source-manifest.json"
            source_bytes = b"normalized trust source\n"
            write_canonical(
                production_source,
                {
                    "schemaVersion": "mirmir-ash-v4-p06-production-source-manifest-v1",
                    "contractSemanticSHA256": p06.sha256_bytes(
                        p06.canonical_bytes(self.source_contract)
                    ),
                    "identityDomain": "ash-p06-production-source-v1",
                    "sourceCount": 1,
                    "sourceRevision": source_revision,
                    "sources": [
                        {
                            "path": "Sources/TrustV4.swift",
                            "byteCount": len(source_bytes),
                            "sha256": p06.sha256_bytes(source_bytes),
                            "normalizedByteCount": len(source_bytes),
                            "normalizedSHA256": p06.sha256_bytes(source_bytes),
                            "normalizations": [
                                "builderSourceSHA256",
                                "manifestSHA256",
                                "sourceRevision",
                            ],
                        }
                    ],
                },
            )
            loader = build_root / "runtime-load-and-tamper-check.log"
            loader.write_text(
                "\n".join(
                    (
                        f"runtime_id={p06.RUNTIME_ID}",
                        f"manifest_sha256={semantic_identity}",
                        f"source_revision={source_revision}",
                        f"builder_source_sha256={builder_identity}",
                        f"artifact_count={len(ROLES)}",
                        "production_loader_acceptance=pass",
                        "same_length_artifact_tamper_rejection=pass",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            runtime_paths = [build_root / relative for relative, _ in entries]
            artifact_manifest = build_root / "artifact-manifest.json"
            write_json(
                artifact_manifest,
                {
                    "schemaVersion": p06.ARTIFACT_MANIFEST_SCHEMA,
                    "artifacts": [descriptor(path, build_root) for path in sorted(runtime_paths)],
                },
            )
            builds.append(
                {
                    "id": identifier,
                    "runtimeArtifactSetSHA256": artifact_set,
                    "runtimeManifestSHA256": semantic_identity,
                    "builderSHA256": builder_identity,
                    "productionSourceRevision": source_revision,
                    "productionSourceManifestSHA256": p06.sha256_file(production_source),
                    "toolchainImageSHA256": p06.sha256_file(toolchain),
                    "artifactManifest": descriptor(artifact_manifest, self.root),
                    "runtimeManifestArtifact": descriptor(build_root / "runtime-manifest.json", self.root),
                    "builderArtifact": descriptor(builder, self.root),
                    "productionSourceArtifact": descriptor(production_source, self.root),
                    "toolchainImageArtifact": descriptor(toolchain, self.root),
                    "loaderEvidenceArtifact": descriptor(loader, self.root),
                    "releaseQualifiedStatus": True,
                    "developmentArtifactDependencyCount": 0,
                    "p05ProductionDependencyCount": 0,
                }
            )
        self.report = {
            "schemaVersion": p06.REPORT_SCHEMA,
            "contractSHA256": p06.sha256_file(self.contract_path),
            "candidate": self.candidate,
            "releaseEligible": True,
            "identities": capture_identities,
            "buildConfiguration": "Release",
            "sourceCheckoutState": "clean",
            "builds": builds,
            "productionLoaderAcceptancePass": True,
            "tamperRejectionPass": True,
            "p06ReproductionGatePass": True,
        }
        self.publish()

    def publish(self) -> None:
        write_json(self.root / "report.json", self.report)
        manifest = self.root / "sealed-manifest.json"
        if manifest.exists():
            manifest.unlink()
        files = [path for path in self.root.rglob("*") if path.is_file() and not path.is_symlink()]
        write_json(
            manifest,
            {
                "schemaVersion": p06.SEALED_SCHEMA,
                "artifacts": [descriptor(path, self.root) for path in sorted(files)],
            },
        )

    def refresh_descriptor(self, build_index: int, key: str) -> None:
        descriptor_value = self.report["builds"][build_index][key]
        path = self.root / descriptor_value["path"]
        self.report["builds"][build_index][key] = descriptor(path, self.root)


class P06ReproductionVerifierTests(unittest.TestCase):
    def fixture(self, temporary: str) -> EvidenceFixture:
        return EvidenceFixture(Path(temporary))

    def test_valid_evidence_recomputes_every_clean_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            result = p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)
            self.assertTrue(result["p06ReproductionGatePass"])
            self.assertEqual(result["cleanBuildCount"], 2)

    def test_claimed_loader_pass_cannot_hide_failed_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            loader = fixture.root / fixture.report["builds"][0]["loaderEvidenceArtifact"]["path"]
            loader.write_text(loader.read_text().replace("tamper_rejection=pass", "tamper_rejection=fail"))
            fixture.refresh_descriptor(0, "loaderEvidenceArtifact")
            fixture.publish()
            with self.assertRaisesRegex(p06.EvidenceError, "did not reject same-length tamper"):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_resealed_toolchain_claim_must_equal_runtime_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            toolchain = fixture.root / fixture.report["builds"][0]["toolchainImageArtifact"]["path"]
            write_canonical(toolchain, {"sdk": "different", "swift": "Swift 99.0"})
            fixture.refresh_descriptor(0, "toolchainImageArtifact")
            fixture.report["builds"][0]["toolchainImageSHA256"] = p06.sha256_file(toolchain)
            fixture.publish()
            with self.assertRaisesRegex(p06.EvidenceError, "differs from runtime provenance"):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_unsealed_extra_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            (fixture.root / "unowned.txt").write_text("unowned\n", encoding="utf-8")
            with self.assertRaisesRegex(p06.EvidenceError, "sealed evidence closure mismatch"):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_report_for_another_candidate_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            fixture.report["candidate"] = copy.deepcopy(fixture.candidate)
            fixture.report["candidate"]["appBundleSHA256"] = "f" * 64
            fixture.publish()
            with self.assertRaisesRegex(p06.EvidenceError, "another candidate"):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)


if __name__ == "__main__":
    unittest.main()
