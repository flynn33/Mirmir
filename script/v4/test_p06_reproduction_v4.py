#!/usr/bin/env python3
"""Tamper-oriented tests for the P06 reproduction replay verifier."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "p06_reproduction_v4", SCRIPT_DIRECTORY / "p06_reproduction_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
p06 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p06)
SOURCE_SPEC = importlib.util.spec_from_file_location(
    "p06_source_identity_v4", SCRIPT_DIRECTORY / "p06_source_identity_v4.py"
)
assert SOURCE_SPEC is not None and SOURCE_SPEC.loader is not None
source_identity = importlib.util.module_from_spec(SOURCE_SPEC)
SOURCE_SPEC.loader.exec_module(source_identity)


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


def write_source_archive(
    path: Path,
    files: dict[str, bytes],
    source_commit: str,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    directories = sorted(
        {
            parent.as_posix()
            for relative in files
            for parent in PurePosixPath(relative).parents
            if parent.as_posix() != "."
        }
    )
    with tarfile.open(path, "w", format=tarfile.PAX_FORMAT) as archive:
        for relative in directories:
            info = tarfile.TarInfo(relative)
            info.type = tarfile.DIRTYPE
            info.mode = 0o775
            info.mtime = 0
            info.pax_headers = {"comment": source_commit}
            archive.addfile(info)
        for relative in sorted(files):
            data = files[relative]
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mode = 0o664
            info.mtime = 0
            info.pax_headers = {"comment": source_commit}
            archive.addfile(info, io.BytesIO(data))


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
            "coverage": {
                "roots": ["Sources"],
                "fileExtensions": [".swift"],
            },
            "requiredAdditionalSources": [],
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
            "buildRunnerSHA256": ("build-runner.sh", b"build runner\n"),
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
            "suiteID": "mirmir-ash-v4-p06-reproduction-v2",
            "buildConfiguration": "Release",
            "builderID": "ash-p06-release-builder-v4-1",
            "candidateSourceArchiveFormat": "git-archive-tar-v1",
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
            "sourceTreeIdentityDomain": "mirmir-source-tree-v1",
            "verification": {
                "buildExecutionReceiptRequired": True,
                "buildOutputCausalBindingRequired": True,
                "buildTranscriptRequired": True,
                "byteIdenticalToShippingBundle": True,
                "independentBuildExecutionRequired": True,
                "productionLoaderAcceptanceRequired": True,
                "sameLengthArtifactTamperRejectionRequired": True,
                "sealedCandidateSourceArchiveRequired": True,
                "sealedCandidateSourceCommitObjectRequired": True,
                "sealedClosureRequired": True,
                "sourceManifestRecomputedFromSealedBytes": True,
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
        source_bytes = (
            "enum TrustV4 {\n"
            f"    static let manifestSHA256 = try! ASHSHA256V4(\"{'a' * 64}\")\n"
            f"    static let sourceRevision = \"{'b' * 64}\"\n"
            f"    static let builderSourceSHA256 = try! ASHSHA256V4(\"{'c' * 64}\")\n"
            "}\n"
        ).encode("utf-8")
        source_files = {"Sources/TrustV4.swift": source_bytes}
        source_listing = (
            f"100644 blob {p06.git_blob_sha1(source_bytes)}\tSources/TrustV4.swift\0"
        ).encode("utf-8")
        checkout_tree_object = p06.git_tree_sha1(
            {"Sources/TrustV4.swift": ("100644", p06.git_blob_sha1(source_bytes))}
        )
        source_commit_object = (
            f"tree {checkout_tree_object}\n"
            "author P06 Test <p06-test@example.invalid> 0 +0000\n"
            "committer P06 Test <p06-test@example.invalid> 0 +0000\n"
            "\nfixture\n"
        ).encode("utf-8")
        source_commit = hashlib.sha1(
            b"commit "
            + str(len(source_commit_object)).encode("ascii")
            + b"\0"
            + source_commit_object
        ).hexdigest()
        source_tree_identity = p06.sha256_bytes(p06.SOURCE_TREE_DOMAIN + source_listing)
        expected_source_manifest = p06.recompute_production_source_manifest(
            self.source_contract, source_files
        )
        source_revision = expected_source_manifest["sourceRevision"]
        builder_identity = p06.sha256_bytes(self.builder_bytes)
        manifest = {
            "schemaID": p06.MANIFEST_SCHEMA,
            "runtimeID": p06.RUNTIME_ID,
            "releaseStatus": "release_qualified",
            "artifacts": artifact_declarations,
            "provenance": {
                "sourceRevision": source_revision,
                "builderID": "ash-p06-release-builder-v4-1",
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
            "sourceCommit": source_commit,
            "sourceTreeIdentitySHA256": source_tree_identity,
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
        predecessor_execution_sha256 = "0" * 64
        for build_index, identifier in enumerate(self.contract["cleanBuildIDs"]):
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
            write_canonical(production_source, expected_source_manifest)
            source_root = build_root / "source"
            source_root.mkdir()
            source_listing_path = source_root / "source-tree-listing.bin"
            source_listing_path.write_bytes(source_listing)
            source_commit_path = source_root / "source-commit-object.bin"
            source_commit_path.write_bytes(source_commit_object)
            source_archive_path = source_root / "candidate-source.tar"
            write_source_archive(source_archive_path, source_files, source_commit)
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
            working_directory = PurePosixPath(
                f"/private/tmp/p06-v2-fixture/{identifier}-worktree"
            )
            output_root = PurePosixPath(
                f"/private/tmp/p06-v2-fixture/{identifier}-outputs"
            )
            build_challenge = f"{build_index + 101:064x}"
            build_environment = {
                "MIRMIR_P06_BUILD_CHALLENGE": build_challenge,
            }
            build_command = [
                str(working_directory / "script/v4/build_p06_release_runtime.sh"),
                "--artifacts",
                str(output_root / "runtime-inputs"),
                "--output",
                str(output_root / "ASH-P06.bundle"),
                "--provenance",
                str(output_root / "provenance"),
                "--qualification-challenge",
                build_challenge,
            ]
            build_stdout = "\n".join(
                (
                    f"fixture build transcript for {identifier}",
                    f"qualification_challenge={build_challenge}",
                    f"qualification_runtime_artifact_set_sha256={artifact_set}",
                    "qualification_runtime_manifest_file_sha256="
                    + p06.sha256_bytes(manifest_bytes),
                    "qualification_production_source_manifest_sha256="
                    + p06.sha256_file(production_source),
                    "",
                )
            )
            build_transcript = build_root / "build-transcript.json"
            write_canonical(
                build_transcript,
                {
                    "schemaVersion": p06.BUILD_TRANSCRIPT_SCHEMA,
                    "command": build_command,
                    "environment": build_environment,
                    "workingDirectory": str(working_directory),
                    "processID": 901 + build_index,
                    "exitStatus": 0,
                    "stdoutByteCount": len(build_stdout.encode("utf-8")),
                    "stdoutSHA256": p06.sha256_bytes(build_stdout.encode("utf-8")),
                    "stdout": build_stdout,
                },
            )
            started = 1_000_000_000 + build_index * 1_000_000
            execution = {
                "schemaVersion": p06.BUILD_EXECUTION_SCHEMA,
                "buildID": identifier,
                "invocationNonce": f"{build_index + 1:064x}",
                "captureProcessID": 900,
                "processID": 901 + build_index,
                "startedAtUnixNanoseconds": started,
                "finishedAtUnixNanoseconds": started + 500_000,
                "durationNanoseconds": 400_000,
                "exitStatus": 0,
                "workingDirectory": str(working_directory),
                "buildOutputRoot": str(output_root),
                "buildChallenge": build_challenge,
                "archiveCommand": [
                    "git",
                    "archive",
                    "--format=tar",
                    "--output",
                    f"/private/tmp/p06-v2-capture/{identifier}/source/candidate-source.tar",
                    "HEAD",
                ],
                "buildCommand": build_command,
                "buildEnvironment": build_environment,
                "sourceCommit": source_commit,
                "sourceCommitObjectSHA256": p06.sha256_file(source_commit_path),
                "checkoutTreeObject": checkout_tree_object,
                "sourceTreeIdentitySHA256": source_tree_identity,
                "sourceTreeListingSHA256": p06.sha256_file(source_listing_path),
                "sourceArchiveSHA256": p06.sha256_file(source_archive_path),
                "preBuildCheckoutStatusSHA256": p06.sha256_bytes(b""),
                "postBuildCheckoutStatusSHA256": p06.sha256_bytes(b""),
                "buildRunnerSHA256": capture_identities["buildRunnerSHA256"],
                "buildTranscriptSHA256": p06.sha256_file(build_transcript),
                "runtimeArtifactSetSHA256": artifact_set,
                "runtimeManifestFileSHA256": p06.sha256_bytes(manifest_bytes),
                "productionSourceManifestSHA256": p06.sha256_file(production_source),
                "predecessorExecutionSHA256": predecessor_execution_sha256,
            }
            execution["causalBindingSHA256"] = p06.build_causal_binding(execution)
            build_execution = build_root / "build-execution.json"
            write_canonical(build_execution, execution)
            predecessor_execution_sha256 = p06.sha256_file(build_execution)
            builds.append(
                {
                    "id": identifier,
                    "sourceCommit": source_commit,
                    "sourceCommitObjectSHA256": p06.sha256_file(source_commit_path),
                    "sourceTreeIdentitySHA256": source_tree_identity,
                    "sourceTreeListingSHA256": p06.sha256_file(source_listing_path),
                    "sourceArchiveSHA256": p06.sha256_file(source_archive_path),
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
                    "sourceCommitObjectArtifact": descriptor(source_commit_path, self.root),
                    "sourceTreeListingArtifact": descriptor(source_listing_path, self.root),
                    "sourceArchiveArtifact": descriptor(source_archive_path, self.root),
                    "buildTranscriptArtifact": descriptor(build_transcript, self.root),
                    "buildExecutionArtifact": descriptor(build_execution, self.root),
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
            "sourceEvidence": {
                "sourceCommit": source_commit,
                "sourceTreeIdentitySHA256": source_tree_identity,
                "sourceCommitObjectSHA256": builds[0]["sourceCommitObjectSHA256"],
                "sourceTreeListingSHA256": builds[0]["sourceTreeListingSHA256"],
                "sourceArchiveSHA256": builds[0]["sourceArchiveSHA256"],
                "sourceArchiveFormat": "git-archive-tar-v1",
            },
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

    def update_execution(self, build_index: int, values: dict[str, object]) -> None:
        execution_descriptor = self.report["builds"][build_index][
            "buildExecutionArtifact"
        ]
        execution_path = self.root / execution_descriptor["path"]
        execution = json.loads(execution_path.read_text(encoding="utf-8"))
        execution.update(values)
        execution["causalBindingSHA256"] = p06.build_causal_binding(execution)
        write_canonical(execution_path, execution)
        self.refresh_descriptor(build_index, "buildExecutionArtifact")


class P06ReproductionVerifierTests(unittest.TestCase):
    def fixture(self, temporary: str) -> EvidenceFixture:
        return EvidenceFixture(Path(temporary))

    def test_valid_evidence_recomputes_every_clean_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            result = p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)
            self.assertTrue(result["p06ReproductionGatePass"])
            self.assertEqual(result["cleanBuildCount"], 2)

    def test_real_git_archive_reproduces_candidate_tree_listing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repository"
            repository.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.name", "P06 Test"],
                cwd=repository,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "p06-test@example.invalid"],
                cwd=repository,
                check=True,
            )
            source = repository / "Sources" / "Value.swift"
            source.parent.mkdir()
            source.write_text("let value = 4\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=repository, check=True)
            commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()
            listing_bytes = subprocess.check_output(
                ["git", "ls-tree", "-r", "-z", "--full-tree", commit],
                cwd=repository,
            )
            listing_path = Path(temporary) / "listing.bin"
            listing_path.write_bytes(listing_bytes)
            archive_path = Path(temporary) / "source.tar"
            subprocess.run(
                [
                    "git",
                    "archive",
                    "--format=tar",
                    "--output",
                    str(archive_path),
                    commit,
                ],
                cwd=repository,
                check=True,
            )
            candidate = {
                "sourceCommit": commit,
                "sourceTreeIdentitySHA256": p06.sha256_bytes(
                    p06.SOURCE_TREE_DOMAIN + listing_bytes
                ),
            }
            listing, _, tree_object = p06.parse_source_tree_listing(listing_path, candidate)
            archived = p06.validate_source_archive(archive_path, listing, candidate)
            self.assertEqual(archived, {"Sources/Value.swift": b"let value = 4\n"})
            self.assertEqual(
                tree_object,
                subprocess.check_output(
                    ["git", "rev-parse", "HEAD^{tree}"], cwd=repository, text=True
                ).strip(),
            )
            commit_object_path = Path(temporary) / "commit-object.bin"
            commit_object_path.write_bytes(
                subprocess.check_output(
                    ["git", "cat-file", "commit", commit], cwd=repository
                )
            )
            self.assertEqual(
                p06.validate_source_commit_object(
                    commit_object_path, candidate, tree_object
                ),
                p06.sha256_file(commit_object_path),
            )

    def test_archived_source_recomputation_matches_normative_identity_tool(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repository"
            source_path = repository / "Sources" / "TrustV4.swift"
            source_path.parent.mkdir(parents=True)
            source_bytes = (
                "enum TrustV4 {\n"
                f"    static let manifestSHA256 = try! ASHSHA256V4(\"{'a' * 64}\")\n"
                f"    static let sourceRevision = \"{'b' * 64}\"\n"
                f"    static let builderSourceSHA256 = try! ASHSHA256V4(\"{'c' * 64}\")\n"
                "}\n"
            ).encode("utf-8")
            source_path.write_bytes(source_bytes)
            contract = {
                "schemaVersion": source_identity.CONTRACT_SCHEMA,
                "identityDomain": "ash-p06-production-source-v1",
                "coverage": {"roots": ["Sources"], "fileExtensions": [".swift"]},
                "requiredAdditionalSources": [],
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
            contract_path = repository / "source-contract.json"
            write_canonical(contract_path, contract)
            expected = source_identity.build_manifest(repository, contract_path)
            observed = p06.recompute_production_source_manifest(
                contract, {"Sources/TrustV4.swift": source_bytes}
            )
            self.assertEqual(observed, expected)

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

    def test_resealed_source_entry_cannot_differ_from_sealed_source_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            predecessor_execution_sha256 = "0" * 64
            for build_index in range(2):
                build = fixture.report["builds"][build_index]
                source_path = fixture.root / build["productionSourceArtifact"]["path"]
                source = json.loads(source_path.read_text(encoding="utf-8"))
                source["sources"][0]["sha256"] = "f" * 64
                source["sources"][0]["normalizedSHA256"] = "f" * 64
                write_canonical(source_path, source)
                fixture.refresh_descriptor(build_index, "productionSourceArtifact")
                source_identity = p06.sha256_file(source_path)
                build["productionSourceManifestSHA256"] = source_identity
                fixture.update_execution(
                    build_index,
                    {
                        "productionSourceManifestSHA256": source_identity,
                        "predecessorExecutionSHA256": predecessor_execution_sha256,
                    },
                )
                predecessor_execution_sha256 = fixture.report["builds"][build_index][
                    "buildExecutionArtifact"
                ]["sha256"]
            fixture.publish()
            with self.assertRaisesRegex(
                p06.EvidenceError,
                "does not reproduce sealed source bytes",
            ):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_resealed_copied_receipt_without_builder_rerun_is_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            first_build = fixture.report["builds"][0]
            second_build = fixture.report["builds"][1]
            first = fixture.root / first_build["buildExecutionArtifact"]["path"]
            second = fixture.root / second_build["buildExecutionArtifact"]["path"]
            copied = json.loads(first.read_text(encoding="utf-8"))
            original_second = json.loads(second.read_text(encoding="utf-8"))
            for key in (
                "buildID",
                "invocationNonce",
                "processID",
                "startedAtUnixNanoseconds",
                "finishedAtUnixNanoseconds",
                "durationNanoseconds",
                "workingDirectory",
                "buildOutputRoot",
                "buildChallenge",
                "archiveCommand",
                "buildCommand",
                "buildEnvironment",
            ):
                copied[key] = original_second[key]

            first_transcript_path = fixture.root / first_build[
                "buildTranscriptArtifact"
            ]["path"]
            second_transcript_path = fixture.root / second_build[
                "buildTranscriptArtifact"
            ]["path"]
            copied_transcript = json.loads(
                first_transcript_path.read_text(encoding="utf-8")
            )
            for key in (
                "command",
                "environment",
                "workingDirectory",
                "processID",
            ):
                copied_transcript[key] = json.loads(
                    second_transcript_path.read_text(encoding="utf-8")
                )[key]
            write_canonical(second_transcript_path, copied_transcript)
            fixture.refresh_descriptor(1, "buildTranscriptArtifact")
            copied["buildTranscriptSHA256"] = p06.sha256_file(
                second_transcript_path
            )
            copied["predecessorExecutionSHA256"] = p06.sha256_file(first)
            copied["causalBindingSHA256"] = p06.build_causal_binding(copied)
            write_canonical(second, copied)
            fixture.refresh_descriptor(1, "buildExecutionArtifact")
            fixture.publish()
            with self.assertRaisesRegex(
                p06.EvidenceError,
                "builder qualification challenge/output transcript differs",
            ):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_resealed_checkout_tree_object_must_reproduce_archive_listing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            fixture.update_execution(0, {"checkoutTreeObject": "f" * 40})
            fixture.publish()
            with self.assertRaisesRegex(
                p06.EvidenceError,
                "does not reproduce the sealed candidate tree",
            ):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_resealed_commit_object_must_reproduce_candidate_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            build = fixture.report["builds"][0]
            commit_path = fixture.root / build["sourceCommitObjectArtifact"]["path"]
            commit_path.write_bytes(commit_path.read_bytes() + b"forged\n")
            fixture.refresh_descriptor(0, "sourceCommitObjectArtifact")
            commit_identity = p06.sha256_file(commit_path)
            build["sourceCommitObjectSHA256"] = commit_identity
            fixture.update_execution(
                0, {"sourceCommitObjectSHA256": commit_identity}
            )
            fixture.report["sourceEvidence"]["sourceCommitObjectSHA256"] = commit_identity
            fixture.publish()
            with self.assertRaisesRegex(
                p06.EvidenceError,
                "commit object identity differs from candidate",
            ):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_resealed_build_argv_substitution_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            execution_path = fixture.root / fixture.report["builds"][1][
                "buildExecutionArtifact"
            ]["path"]
            execution = json.loads(execution_path.read_text(encoding="utf-8"))
            command = list(execution["buildCommand"])
            command[0] = "/private/tmp/substituted-builder.sh"
            fixture.update_execution(1, {"buildCommand": command})
            fixture.publish()
            with self.assertRaisesRegex(p06.EvidenceError, "build argv differs"):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)

    def test_resealed_build_transcript_substitution_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(temporary)
            build = fixture.report["builds"][1]
            transcript_path = fixture.root / build["buildTranscriptArtifact"]["path"]
            transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
            transcript["command"] = list(transcript["command"])
            transcript["command"][0] = "/private/tmp/substituted-builder.sh"
            write_canonical(transcript_path, transcript)
            fixture.refresh_descriptor(1, "buildTranscriptArtifact")
            transcript_identity = p06.sha256_file(transcript_path)
            fixture.update_execution(
                1, {"buildTranscriptSHA256": transcript_identity}
            )
            fixture.publish()
            with self.assertRaisesRegex(
                p06.EvidenceError,
                "build transcript differs from its execution receipt",
            ):
                p06.verify(fixture.root, fixture.candidate_path, fixture.contract_path)


if __name__ == "__main__":
    unittest.main()
