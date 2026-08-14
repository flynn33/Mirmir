#!/usr/bin/env python3
"""Fail-closed evidence evaluator for deterministic-engine v4 recovery.

The XCTest capture performs the faults.  This evaluator distrusts its summary:
it reopens every sealed artifact, recomputes byte and semantic identities,
checks the locked scenario matrix, and emits the recovery role consumed by the
final release-qualification aggregator.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any, Callable, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-v4-recovery-qualification-contract-v1"
CAPTURE_SCHEMA = "mirmir-v4-recovery-capture-v1"
CAPTURE_MANIFEST_SCHEMA = "mirmir-v4-recovery-capture-artifacts-v1"
REPORT_SCHEMA = "mirmir-ash-v4-recovery-report-v1"
SCENARIO_SCHEMA = "mirmir-v4-recovery-scenario-evidence-v1"
SEMANTIC_SCHEMA = "mirmir-v4-recovery-semantic-output-v1"
SUITE_MANIFEST_SCHEMA = "mirmir-v4-recovery-evidence-manifest-v1"
TRANSCRIPT_SCHEMA = "mirmir-v4-recovery-fault-transcript-v1"
SOURCE_EXPORT_SCHEMA = "mirmir-v4-recovery-source-export-v1"

REQUIRED_COVERAGE = (
    "append_only_event_boundary",
    "snapshot_publish_boundary",
    "bookmark_resolution_and_toctou",
    "segment_commit_boundary",
    "checkpoint_publish_boundary",
    "prepared_decision_boundary",
    "final_assembly_boundary",
    "atomic_output_publish_boundary",
    "pause_resume",
    "forced_termination_restart",
    "disk_full",
    "corrupt_journal",
    "corrupt_checkpoint",
    "orphan_partial_reconciliation",
    "unowned_artifact_rejection",
)

# Bound release evidence must not acquire path-dependent Python bytecode files.
sys.dont_write_bytecode = True

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
PACKAGED_EVIDENCE_SPEC = importlib.util.spec_from_file_location(
    "recovery_packaged_candidate_evidence_v4",
    SCRIPT_DIRECTORY / "packaged_candidate_evidence_v4.py",
)
if PACKAGED_EVIDENCE_SPEC is None or PACKAGED_EVIDENCE_SPEC.loader is None:
    raise RuntimeError("cannot load packaged-candidate evidence implementation")
packaged_evidence = importlib.util.module_from_spec(PACKAGED_EVIDENCE_SPEC)
sys.modules[PACKAGED_EVIDENCE_SPEC.name] = packaged_evidence
PACKAGED_EVIDENCE_SPEC.loader.exec_module(packaged_evidence)

PACKAGE_SCHEMA = "mirmir-v4-packaged-candidate-identity-v1"
ATTESTATION_SCHEMA = "mirmir-v4-release-build-attestation-v1"


class RecoveryEvidenceError(ValueError):
    """Raised when recovery evidence is incomplete, stale, or contradictory."""


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise RecoveryEvidenceError(f"duplicate JSON key: {key}")
        value[key] = child
    return value


def reject_nonfinite(token: str) -> Any:
    raise RecoveryEvidenceError(f"non-finite JSON number: {token}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RecoveryEvidenceError(f"cannot read JSON {path}: {error}") from error


def pretty_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode()


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode()


def write_exclusive_regular(path: Path, value: bytes, label: str) -> None:
    """Create one artifact through held no-follow file and directory handles."""

    require(path.name not in {"", ".", ".."}, f"invalid {label} path")
    try:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        no_follow = os.O_NOFOLLOW
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | no_follow
        file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | no_follow
        directory_fd = os.open(path.parent, directory_flags)
    except (AttributeError, OSError) as error:
        raise RecoveryEvidenceError(
            f"cannot open {label} parent safely: {error}"
        ) from error

    artifact_fd: int | None = None
    try:
        directory_metadata = os.fstat(directory_fd)
        require(
            stat.S_ISDIR(directory_metadata.st_mode),
            f"{label} parent is not a directory",
        )
        try:
            artifact_fd = os.open(
                path.name,
                file_flags,
                0o600,
                dir_fd=directory_fd,
            )
        except FileExistsError as error:
            raise RecoveryEvidenceError(
                f"refusing to overwrite package artifact: {path}"
            ) from error
        except OSError as error:
            raise RecoveryEvidenceError(
                f"cannot create {label} safely: {error}"
            ) from error

        before = os.fstat(artifact_fd)
        require(
            stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
            f"{label} is not a single-link regular file",
        )
        pending = memoryview(value)
        while pending:
            written = os.write(artifact_fd, pending)
            require(written > 0, f"short write while creating {label}")
            pending = pending[written:]
        os.fchmod(artifact_fd, 0o600)
        os.fsync(artifact_fd)
        after = os.fstat(artifact_fd)
        require(
            stat.S_ISREG(after.st_mode)
            and after.st_nlink == 1
            and after.st_dev == before.st_dev
            and after.st_ino == before.st_ino
            and after.st_size == len(value),
            f"{label} identity changed while writing",
        )
    except OSError as error:
        raise RecoveryEvidenceError(f"cannot write {label}: {error}") from error
    finally:
        if artifact_fd is not None:
            os.close(artifact_fd)
        os.close(directory_fd)


def write_json(path: Path, value: Any) -> None:
    write_exclusive_regular(path, pretty_json(value), "recovery JSON artifact")


def write_canonical_artifact(path: Path, value: Any) -> None:
    write_exclusive_regular(
        path,
        packaged_evidence.canonical_bytes(value),
        "recovery package artifact",
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise RecoveryEvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RecoveryEvidenceError(message)


def role_artifact_path(
    role_root: Path,
    path: Path,
    label: str,
    *,
    must_exist: bool,
) -> Path:
    """Resolve and confine one packaged-candidate artifact to its role root."""

    try:
        root = role_root.expanduser().resolve(strict=True)
        resolved = path.expanduser().resolve(strict=must_exist)
    except OSError as error:
        raise RecoveryEvidenceError(
            f"cannot resolve recovery {label}: {error}"
        ) from error
    require(
        resolved != root and root in resolved.parents,
        f"recovery {label} must remain inside the role root",
    )
    return resolved


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be text")
    return value


def require_bool(value: Any, label: str, expected: bool | None = None) -> bool:
    require(type(value) is bool, f"{label} must be boolean")
    if expected is not None:
        require(value is expected, f"{label} must be {str(expected).lower()}")
    return value


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    require(type(value) is int and value >= minimum, f"{label} must be an integer >= {minimum}")
    return value


def require_sha256(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(
        len(text) == 64
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a lowercase SHA-256",
    )
    return text


def require_revision(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(
        len(text) == 40
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a full lowercase Git revision",
    )
    return text


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, extra={sorted(actual-expected_set)}",
    )


def checked_path(root: Path, relative_value: Any, label: str) -> Path:
    relative = Path(require_string(relative_value, f"{label}.path"))
    require(not relative.is_absolute() and ".." not in relative.parts, f"{label} path escapes evidence root")
    root = root.resolve(strict=True)
    lexical = root
    for component in relative.parts:
        lexical = lexical / component
        require(not lexical.is_symlink(), f"{label} traverses a symbolic link")
    candidate = lexical.resolve(strict=True)
    require(candidate != root and root in candidate.parents, f"{label} path escapes evidence root")
    require(candidate.is_file() and not candidate.is_symlink(), f"{label} is not a regular file")
    return candidate


def descriptor(path: Path, evidence_root: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    root = evidence_root.resolve(strict=True)
    require(root in resolved.parents, f"artifact is outside evidence root: {resolved}")
    return {
        "path": resolved.relative_to(root).as_posix(),
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def validate_artifact(
    evidence_root: Path,
    value: Any,
    label: str,
    allowed_root: Path | None = None,
) -> tuple[Path, str]:
    artifact = require_mapping(value, label)
    require_exact_keys(artifact, {"path", "byteCount", "sha256"}, label)
    path = checked_path(evidence_root, artifact["path"], label)
    if allowed_root is not None:
        allowed = allowed_root.resolve(strict=True)
        require(path == allowed or allowed in path.parents, f"{label} is outside capture root")
    byte_count = require_integer(artifact["byteCount"], f"{label}.byteCount", 1)
    require(path.stat().st_size == byte_count, f"{label} byte count mismatch")
    expected = require_sha256(artifact["sha256"], f"{label}.sha256")
    actual = sha256_file(path)
    require(actual == expected, f"{label} SHA-256 mismatch")
    return path, actual


def validate_candidate(value: Any) -> dict[str, Any]:
    candidate = require_mapping(value, "candidate")
    expected = {
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "runtimeSourceRevision",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
        "bundleIdentifier",
        "productVersion",
        "productBuild",
    }
    require_exact_keys(candidate, expected, "candidate")
    require_revision(candidate["sourceCommit"], "candidate.sourceCommit")
    for key in expected - {
        "sourceCommit",
        "runtimeSourceRevision",
        "bundleIdentifier",
        "productVersion",
        "productBuild",
    }:
        require_sha256(candidate[key], f"candidate.{key}")
    runtime_revision = require_string(candidate["runtimeSourceRevision"], "candidate.runtimeSourceRevision")
    require(
        len(runtime_revision) in (40, 64)
        and all(character in "0123456789abcdef" for character in runtime_revision),
        "candidate.runtimeSourceRevision must be hexadecimal",
    )
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"candidate.{key}")
    return candidate


def load_candidate(path: Path) -> dict[str, Any]:
    value = require_mapping(load_json(path), "candidate input")
    if value.get("schemaVersion") == "mirmir-ash-v4-release-candidate-evidence-v1":
        return validate_candidate(value.get("candidate"))
    return validate_candidate(value)


PackageVerifier = Callable[
    [Path, Path, Path, Path, Path],
    Mapping[str, Any],
]


def export_verified_candidate_source(
    repository: Path,
    revision: str,
    destination: Path,
) -> dict[str, Any]:
    """Export only committed bytes/modes and prove the resulting workspace."""

    provenance = packaged_evidence.archive_provenance
    repository = repository.expanduser()
    require(
        repository.is_dir() and not repository.is_symlink(),
        "recovery source repository must be a non-symlink directory",
    )
    repository = repository.resolve(strict=True)
    require(
        isinstance(revision, str)
        and revision != ""
        and "\x00" not in revision
        and "\n" not in revision
        and "\r" not in revision,
        "recovery source revision is invalid",
    )
    try:
        commit = provenance.git_output(
            repository,
            [
                "rev-parse",
                "--verify",
                "--end-of-options",
                f"{revision}^{{commit}}",
            ],
        )
        provenance.require_hex(commit, (40,), "recovery source commit")
        committed = provenance.source_manifest_summary(
            provenance.committed_source_manifest(repository, commit)
        )
        exported = provenance.verified_git_archive_source(
            {
                "repositoryAbsolutePath": str(repository),
                "sourceCommit": commit,
            },
            destination,
        )
        observed = provenance.directory_source_manifest(destination)
    except (OSError, provenance.ArchiveProvenanceError) as error:
        raise RecoveryEvidenceError(
            f"cannot export verified recovery source: {error}"
        ) from error
    require(
        committed == exported == observed,
        "verified recovery source manifest differs from the candidate commit",
    )
    return {
        "schemaVersion": SOURCE_EXPORT_SCHEMA,
        "sourceCommit": commit,
        "sourceTreeIdentitySHA256": provenance.source_tree_identity(
            repository,
            commit,
        ),
        "sourceManifest": observed,
    }


def export_source_command(arguments: argparse.Namespace) -> None:
    result = export_verified_candidate_source(
        Path(arguments.repository),
        arguments.revision,
        Path(arguments.destination),
    )
    sys.stdout.buffer.write(canonical_json(result))


def inspect_exact_package(
    repository: Path,
    candidate_path: Path,
    application_archive: Path,
    runtime: Path,
    release_configuration: Path,
) -> dict[str, Any]:
    """Verify the sealed Release application against committed provenance."""

    try:
        repository = repository.expanduser().resolve(strict=True)
        candidate_path = packaged_evidence.safe_regular(
            candidate_path,
            "recovery candidate identity",
        )
        application_archive = packaged_evidence.safe_regular(
            application_archive,
            "recovery application archive",
        )
        release_configuration = packaged_evidence.safe_regular(
            release_configuration,
            "recovery Release configuration",
        )
        runtime = runtime.expanduser()
        require(
            runtime.is_dir() and not runtime.is_symlink(),
            "recovery P06 runtime must be a non-symlink directory",
        )
        runtime = runtime.resolve(strict=True)
        candidate = packaged_evidence.parse_candidate(candidate_path)
        provenance = packaged_evidence.archive_provenance
        context = provenance.release_context(
            repository,
            candidate["sourceCommit"],
            runtime,
            release_configuration,
        )
        tools = provenance.tool_descriptors(
            repository,
            context["sourceCommit"],
        )
        inspection = provenance.inspect_archive(
            application_archive,
            context,
            tools,
            require_attestation=True,
        )
        identity = packaged_evidence.package_identity(candidate, inspection)
    except (
        OSError,
        packaged_evidence.PackagedEvidenceError,
        packaged_evidence.archive_provenance.ArchiveProvenanceError,
    ) as error:
        raise RecoveryEvidenceError(
            f"exact packaged candidate verification failed: {error}"
        ) from error
    return {
        "candidate": candidate,
        "identity": identity,
        "attestation": inspection["attestation"],
    }


def validate_inspected_package(
    value: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
) -> dict[str, Any]:
    inspected = require_mapping(value, "inspected packaged candidate")
    require_exact_keys(
        inspected,
        {"attestation", "candidate", "identity"},
        "inspected packaged candidate",
    )
    inspected_candidate = validate_candidate(inspected["candidate"])
    require(
        inspected_candidate == candidate,
        "verified archive candidate differs from recovery candidate",
    )
    try:
        identity = packaged_evidence.validate_package_identity(
            inspected["identity"]
        )
    except packaged_evidence.PackagedEvidenceError as error:
        raise RecoveryEvidenceError(
            f"packaged candidate identity is invalid: {error}"
        ) from error
    candidate_projection = {
        "sourceCommit": identity["sourceCommit"],
        "sourceTreeIdentitySHA256": identity["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": identity["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": identity["runtimeManifestFileSHA256"],
        "runtimeArtifactSetSHA256": identity["runtimeArtifactSetSHA256"],
        "runtimeSourceRevision": identity["runtimeSourceRevision"],
        "releaseConfigurationSHA256": identity["releaseConfigurationSHA256"],
        "appBundleSHA256": identity["applicationArchiveSHA256"],
        "bundleIdentifier": identity["bundleIdentifier"],
        "productVersion": identity["productVersion"],
        "productBuild": identity["productBuild"],
    }
    require(
        candidate_projection == candidate,
        "packaged candidate projection differs from recovery candidate",
    )

    policy = require_mapping(
        contract["packagedCandidate"],
        "contract.packagedCandidate",
    )
    required_architectures = require_list(
        policy["requiredArchitectures"],
        "contract.packagedCandidate.requiredArchitectures",
    )
    observed_architectures = [
        row["architecture"]
        for row in identity["codeDirectories"]
    ]
    require(
        observed_architectures == required_architectures,
        "packaged candidate architecture set differs",
    )

    attestation = require_mapping(
        inspected["attestation"],
        "release build attestation",
    )
    require(
        attestation.get("schemaVersion") == ATTESTATION_SCHEMA
        and attestation.get("buildConfiguration") == "Release",
        "release build attestation header differs",
    )
    source = require_mapping(attestation.get("source"), "attested source")
    require(
        source.get("commit") == candidate["sourceCommit"]
        and source.get("treeIdentitySHA256")
        == candidate["sourceTreeIdentitySHA256"],
        "release build attestation source differs",
    )
    runtime = require_mapping(attestation.get("runtime"), "attested runtime")
    require(
        runtime
        == {
            "artifactSetSHA256": candidate["runtimeArtifactSetSHA256"],
            "bundleRepositoryRelativePath": runtime.get(
                "bundleRepositoryRelativePath"
            ),
            "manifestFileSHA256": candidate["runtimeManifestFileSHA256"],
            "manifestSHA256": candidate["runtimeManifestSHA256"],
            "sourceRevision": candidate["runtimeSourceRevision"],
        }
        and isinstance(runtime["bundleRepositoryRelativePath"], str)
        and runtime["bundleRepositoryRelativePath"],
        "release build attestation runtime differs",
    )
    release = require_mapping(
        attestation.get("releaseConfiguration"),
        "attested Release configuration",
    )
    require(
        release.get("sha256") == candidate["releaseConfigurationSHA256"],
        "release build attestation configuration differs",
    )
    application = require_mapping(
        attestation.get("application"),
        "attested application",
    )
    require(
        application.get("bundleIdentifier") == candidate["bundleIdentifier"]
        and application.get("productVersion") == candidate["productVersion"]
        and application.get("productBuild") == candidate["productBuild"]
        and application.get("codeDirectories") == identity["codeDirectories"],
        "release build attestation application differs",
    )

    source_build = require_mapping(
        attestation.get("sourceBuild"),
        "attested clean-source build",
    )
    build = require_mapping(
        source_build.get("build"),
        "attested clean-source build invocation",
    )
    require(
        build.get("configuration") == "Release"
        and build.get("destination") == "generic/platform=macOS",
        "attested application is not the locked Release build",
    )
    settings = require_mapping(
        build.get("settings"),
        "attested clean-source build settings",
    )
    command = require_list(
        build.get("command"),
        "attested clean-source build command",
    )
    testability_arguments = [
        argument
        for argument in command
        if isinstance(argument, str)
        and argument.startswith("ENABLE_TESTABILITY=")
    ]
    require(
        settings.get("ENABLE_TESTABILITY") == "NO"
        and testability_arguments == ["ENABLE_TESTABILITY=NO"],
        "testability-enabled rebuild cannot satisfy packaged recovery evidence",
    )
    return {
        "candidate": inspected_candidate,
        "identity": identity,
        "attestation": attestation,
    }


def bind_or_verify_package_evidence(
    *,
    repository: Path,
    candidate_path: Path,
    application_archive: Path,
    runtime: Path,
    release_configuration: Path,
    release_configuration_artifact: Path,
    runtime_manifest_artifact: Path,
    package_identity_path: Path,
    attestation_path: Path,
    contract: Mapping[str, Any],
    write_artifacts: bool,
    verifier: PackageVerifier = inspect_exact_package,
) -> dict[str, Any]:
    candidate_path = packaged_evidence.safe_regular(
        candidate_path,
        "recovery candidate identity",
    )
    application_archive = packaged_evidence.safe_regular(
        application_archive,
        "recovery application archive",
    )
    release_configuration = packaged_evidence.safe_regular(
        release_configuration,
        "recovery Release configuration",
    )
    release_configuration_artifact = packaged_evidence.safe_regular(
        release_configuration_artifact,
        "sealed recovery Release configuration",
    )
    runtime_manifest_artifact = packaged_evidence.safe_regular(
        runtime_manifest_artifact,
        "sealed recovery P06 runtime manifest",
    )
    runtime = packaged_evidence.safe_directory(
        runtime,
        "recovery P06 runtime",
    )
    inspected = validate_inspected_package(
        verifier(
            repository,
            candidate_path,
            application_archive,
            runtime,
            release_configuration,
        ),
        load_candidate(candidate_path),
        contract,
    )
    identity = inspected["identity"]
    attestation = inspected["attestation"]
    package_bytes = packaged_evidence.canonical_bytes(identity)
    attestation_bytes = packaged_evidence.canonical_bytes(attestation)
    if write_artifacts:
        write_canonical_artifact(package_identity_path, identity)
        write_canonical_artifact(attestation_path, attestation)
    package_identity_path = packaged_evidence.safe_regular(
        package_identity_path,
        "recovery package identity artifact",
    )
    attestation_path = packaged_evidence.safe_regular(
        attestation_path,
        "recovery attestation artifact",
    )
    require(
        package_identity_path.read_bytes() == package_bytes,
        "recovery package identity artifact differs",
    )
    require(
        attestation_path.read_bytes() == attestation_bytes
        and sha256_bytes(attestation_bytes) == identity["attestationSHA256"],
        "recovery attestation artifact differs",
    )
    require(
        sha256_file(application_archive)
        == identity["applicationArchiveSHA256"],
        "recovery application archive differs after provenance verification",
    )
    runtime_manifest = packaged_evidence.safe_regular(
        runtime / "runtime-manifest.json",
        "recovery P06 runtime manifest",
    )
    require(
        sha256_file(runtime_manifest) == identity["runtimeManifestFileSHA256"]
        and sha256_file(release_configuration)
        == identity["releaseConfigurationSHA256"],
        "recovery runtime or Release configuration differs after verification",
    )
    require(
        runtime_manifest_artifact.read_bytes() == runtime_manifest.read_bytes()
        and release_configuration_artifact.read_bytes()
        == release_configuration.read_bytes(),
        "sealed recovery runtime or Release configuration artifact differs",
    )
    return {
        "identity": identity,
        "applicationArchiveSHA256": identity["applicationArchiveSHA256"],
        "attestationSHA256": identity["attestationSHA256"],
        "candidateIdentitySHA256": sha256_file(candidate_path),
        "packageIdentitySHA256": sha256_file(package_identity_path),
        "requiredArchitectures": list(
            contract["packagedCandidate"]["requiredArchitectures"]
        ),
        "exactApplicationArchivePass": True,
        "releaseAttestationPass": True,
        "packageIdentityTestabilitySubstitutionRejected": True,
    }


def validate_packaged_report(
    value: Any,
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
) -> dict[str, Any]:
    packaged = require_mapping(value, "packaged recovery candidate")
    require_exact_keys(
        packaged,
        {
            "applicationArchiveSHA256",
            "attestationSHA256",
            "candidateIdentitySHA256",
            "exactApplicationArchivePass",
            "identity",
            "packageIdentitySHA256",
            "releaseAttestationPass",
            "requiredArchitectures",
            "packageIdentityTestabilitySubstitutionRejected",
        },
        "packaged recovery candidate",
    )
    try:
        identity = packaged_evidence.validate_package_identity(
            packaged["identity"]
        )
    except packaged_evidence.PackagedEvidenceError as error:
        raise RecoveryEvidenceError(
            f"packaged recovery identity is invalid: {error}"
        ) from error
    require(
        identity["applicationArchiveSHA256"]
        == packaged["applicationArchiveSHA256"]
        == candidate["appBundleSHA256"],
        "packaged recovery archive identity differs",
    )
    require(
        identity["attestationSHA256"] == packaged["attestationSHA256"],
        "packaged recovery attestation identity differs",
    )
    for key in (
        "applicationArchiveSHA256",
        "attestationSHA256",
        "candidateIdentitySHA256",
        "packageIdentitySHA256",
    ):
        require_sha256(packaged[key], f"packaged recovery candidate.{key}")
    for key in (
        "exactApplicationArchivePass",
        "releaseAttestationPass",
        "packageIdentityTestabilitySubstitutionRejected",
    ):
        require_bool(packaged[key], f"packaged recovery candidate.{key}", True)
    require(
        packaged["requiredArchitectures"]
        == contract["packagedCandidate"]["requiredArchitectures"],
        "packaged recovery architecture contract differs",
    )
    return dict(packaged)


def load_contract(path: Path, verify_tools: bool = True) -> tuple[dict[str, Any], str]:
    contract = require_mapping(load_json(path), "contract")
    require_exact_keys(
        contract,
        {
            "artifactSchemas",
            "buildConfiguration",
            "capture",
            "hashAlgorithm",
            "packagedCandidate",
            "scenarios",
            "schemaVersion",
            "semanticVerification",
            "suiteID",
        },
        "contract",
    )
    require(contract["schemaVersion"] == CONTRACT_SCHEMA, "unsupported recovery contract")
    require(contract["hashAlgorithm"] == "sha256", "unsupported recovery hash algorithm")
    require(contract["buildConfiguration"] == "Release", "recovery capture must use Release")
    require_string(contract["suiteID"], "contract.suiteID")
    schemas = require_mapping(contract["artifactSchemas"], "contract.artifactSchemas")
    require_exact_keys(
        schemas,
        {
            "capture",
            "captureManifest",
            "packageIdentity",
            "releaseAttestation",
            "report",
            "scenarioEvidence",
            "semanticManifest",
            "suiteManifest",
            "transcript",
        },
        "contract.artifactSchemas",
    )
    expected_schemas = {
        "capture": CAPTURE_SCHEMA,
        "captureManifest": CAPTURE_MANIFEST_SCHEMA,
        "packageIdentity": PACKAGE_SCHEMA,
        "releaseAttestation": ATTESTATION_SCHEMA,
        "report": REPORT_SCHEMA,
        "scenarioEvidence": SCENARIO_SCHEMA,
        "semanticManifest": SEMANTIC_SCHEMA,
        "suiteManifest": SUITE_MANIFEST_SCHEMA,
        "transcript": TRANSCRIPT_SCHEMA,
    }
    require(schemas == expected_schemas, "contract artifact schemas differ")
    packaged = require_mapping(
        contract["packagedCandidate"],
        "contract.packagedCandidate",
    )
    require_exact_keys(
        packaged,
        {
            "requireExactApplicationArchive",
            "requireReleaseAttestation",
            "requireTestabilityDisabled",
            "requiredArchitectures",
        },
        "contract.packagedCandidate",
    )
    for key in (
        "requireExactApplicationArchive",
        "requireReleaseAttestation",
        "requireTestabilityDisabled",
    ):
        require_bool(
            packaged[key],
            f"contract.packagedCandidate.{key}",
            True,
        )
    architectures = require_list(
        packaged["requiredArchitectures"],
        "contract.packagedCandidate.requiredArchitectures",
    )
    require(
        architectures == ["arm64", "x86_64"],
        "contract packaged-candidate architectures differ",
    )
    semantic = require_mapping(contract["semanticVerification"], "contract.semanticVerification")
    require_exact_keys(
        semantic,
        {"requireByteIdentity", "requireDecodedVisiblePixelIdentity", "requireExactPresentationTimeline", "requireTrackGraphIdentity"},
        "contract.semanticVerification",
    )
    for key in semantic:
        require_bool(semantic[key], f"contract.semanticVerification.{key}", True)
    scenarios = require_list(contract["scenarios"], "contract.scenarios")
    require(len(scenarios) == len(REQUIRED_COVERAGE), "contract recovery scenario count differs")
    seen_ids: set[str] = set()
    seen_coverage: list[str] = []
    for index, value in enumerate(scenarios):
        scenario = require_mapping(value, f"contract.scenarios[{index}]")
        require_exact_keys(
            scenario,
            {"containedFailureCode", "coverageID", "id", "injectionPoint", "outcome"},
            f"contract.scenarios[{index}]",
        )
        identifier = require_string(scenario["id"], f"contract scenario {index}.id")
        require(identifier not in seen_ids, f"contract repeats scenario: {identifier}")
        seen_ids.add(identifier)
        coverage = require_string(scenario["coverageID"], f"contract scenario {index}.coverageID")
        seen_coverage.append(coverage)
        require_string(scenario["injectionPoint"], f"contract scenario {index}.injectionPoint")
        outcome = scenario["outcome"]
        require(outcome in {"identical_resumed_output", "explicit_contained_failure"}, f"unsupported outcome: {identifier}")
        if outcome == "identical_resumed_output":
            require(scenario["containedFailureCode"] is None, f"identical scenario has failure code: {identifier}")
        else:
            require_string(scenario["containedFailureCode"], f"contract scenario {index}.containedFailureCode")
    require(tuple(seen_coverage) == REQUIRED_COVERAGE, "contract recovery coverage/order differs")
    capture = require_mapping(contract["capture"], "contract.capture")
    require_exact_keys(
        capture,
        {
            "archiveProvenanceSourceSHA256",
            "captureSourceSHA256",
            "evaluatorSourceSHA256",
            "packagedEvidenceSourceSHA256",
            "runnerSourceSHA256",
        },
        "contract.capture",
    )
    for key in capture:
        require_sha256(capture[key], f"contract.capture.{key}")
    if verify_tools:
        tool_paths = {
            "archiveProvenanceSourceSHA256": SCRIPT_DIRECTORY
            / "release_candidate_archive_v4.py",
            "captureSourceSHA256": SCRIPT_DIRECTORY / "RecoveryQualificationCaptureTests.swift",
            "evaluatorSourceSHA256": SCRIPT_DIRECTORY / "recovery_qualification_v4.py",
            "packagedEvidenceSourceSHA256": SCRIPT_DIRECTORY
            / "packaged_candidate_evidence_v4.py",
            "runnerSourceSHA256": SCRIPT_DIRECTORY / "run_recovery_qualification_v4.sh",
        }
        for field, tool_path in tool_paths.items():
            require(tool_path.is_file() and not tool_path.is_symlink(), f"recovery tool is missing: {tool_path.name}")
            require(
                sha256_file(tool_path) == capture[field],
                f"recovery tool identity mismatch for {field}",
            )
    return contract, sha256_file(path)


def validate_semantic(path: Path, label: str) -> dict[str, Any]:
    value = require_mapping(load_json(path), label)
    require_exact_keys(
        value,
        {
            "allRequiredChecksPassed",
            "decodedVisiblePixelSHA256",
            "duration",
            "presentationTimelineSHA256",
            "sampleCount",
            "schemaVersion",
            "trackGraphSHA256",
        },
        label,
    )
    require(value["schemaVersion"] == SEMANTIC_SCHEMA, f"{label} schema differs")
    require_bool(value["allRequiredChecksPassed"], f"{label}.allRequiredChecksPassed", True)
    for key in ("decodedVisiblePixelSHA256", "presentationTimelineSHA256", "trackGraphSHA256"):
        require_sha256(value[key], f"{label}.{key}")
    require_integer(value["sampleCount"], f"{label}.sampleCount", 1)
    duration = require_mapping(value["duration"], f"{label}.duration")
    require_exact_keys(duration, {"value", "timescale"}, f"{label}.duration")
    require(type(duration["value"]) is int, f"{label}.duration.value must be an integer")
    require_integer(duration["timescale"], f"{label}.duration.timescale", 1)
    return value


def validate_transcript(path: Path, expected: Mapping[str, Any], label: str) -> dict[str, Any]:
    value = require_mapping(load_json(path), label)
    require_exact_keys(
        value,
        {"coverageID", "events", "faultObserved", "id", "injectionPoint", "reopenedDurableState", "schemaVersion", "terminalDisposition"},
        label,
    )
    require(value["schemaVersion"] == TRANSCRIPT_SCHEMA, f"{label} schema differs")
    for key in ("id", "coverageID", "injectionPoint"):
        require(value[key] == expected[key], f"{label}.{key} differs")
    require_bool(value["faultObserved"], f"{label}.faultObserved", True)
    require_bool(value["reopenedDurableState"], f"{label}.reopenedDurableState", True)
    terminal = "completed" if expected["outcome"] == "identical_resumed_output" else "contained"
    require(value["terminalDisposition"] == terminal, f"{label}.terminalDisposition differs")
    events = require_list(value["events"], f"{label}.events")
    require(len(events) >= 3, f"{label} must record pre-fault, fault, and reopen events")
    operations: list[str] = []
    for index, item in enumerate(events):
        event = require_mapping(item, f"{label}.events[{index}]")
        require_exact_keys(event, {"durableStateSHA256", "operation", "sequence"}, f"{label}.events[{index}]")
        require(event["sequence"] == index, f"{label} event sequence differs")
        operations.append(require_string(event["operation"], f"{label}.events[{index}].operation"))
        require_sha256(event["durableStateSHA256"], f"{label}.events[{index}].durableStateSHA256")
    require("inject_fault" in operations and "reopen_durable_state" in operations, f"{label} omits fault/reopen operations")
    return value


def artifact_set_sha(artifacts: Iterable[Mapping[str, Any]]) -> str:
    normalized = [
        {"path": item["path"], "byteCount": item["byteCount"], "sha256": item["sha256"]}
        for item in artifacts
    ]
    normalized.sort(key=lambda item: item["path"])
    return sha256_bytes(canonical_json(normalized))


def evaluate_capture(
    contract_path: Path,
    capture_path: Path,
    candidate_path: Path,
    evidence_root: Path,
    packaged_candidate: Mapping[str, Any],
    verify_tools: bool = True,
) -> tuple[dict[str, Any], dict[str, Any]]:
    evidence_root = evidence_root.resolve(strict=True)
    capture_path = capture_path.resolve(strict=True)
    capture_root = capture_path.parent
    require(evidence_root == capture_root or evidence_root in capture_root.parents, "capture is outside evidence root")
    contract, contract_sha = load_contract(contract_path, verify_tools=verify_tools)
    candidate = load_candidate(candidate_path)
    packaged_candidate = validate_packaged_report(
        packaged_candidate,
        candidate,
        contract,
    )
    capture = require_mapping(load_json(capture_path), "capture")
    require_exact_keys(
        capture,
        {"buildConfiguration", "captureSourceSHA256", "contractSHA256", "scenarios", "schemaVersion", "sourceCommit", "sourceTreeSHA256"},
        "capture",
    )
    require(capture["schemaVersion"] == CAPTURE_SCHEMA, "unsupported recovery capture schema")
    require(capture["contractSHA256"] == contract_sha, "capture contract identity mismatch")
    require(capture["captureSourceSHA256"] == contract["capture"]["captureSourceSHA256"], "capture source identity mismatch")
    require(capture["buildConfiguration"] == contract["buildConfiguration"], "capture build configuration differs")
    require_revision(capture["sourceCommit"], "capture.sourceCommit")
    require_sha256(capture["sourceTreeSHA256"], "capture.sourceTreeSHA256")
    require(capture["sourceCommit"] == candidate["sourceCommit"], "capture source commit is stale")
    require(capture["sourceTreeSHA256"] == candidate["sourceTreeIdentitySHA256"], "capture source tree is stale")

    expected_scenarios = {item["id"]: item for item in contract["scenarios"]}
    observed = require_list(capture["scenarios"], "capture.scenarios")
    require(len(observed) == len(expected_scenarios), "capture scenario count differs")
    report_scenarios: list[dict[str, Any]] = []
    referenced_paths: set[Path] = {capture_path}
    seen: set[str] = set()
    for index, item in enumerate(observed):
        scenario = require_mapping(item, f"capture.scenarios[{index}]")
        require_exact_keys(scenario, {"externalEvidenceArtifact", "id"}, f"capture.scenarios[{index}]")
        identifier = require_string(scenario["id"], f"capture.scenarios[{index}].id")
        require(identifier in expected_scenarios and identifier not in seen, f"capture has unexpected/duplicate scenario: {identifier}")
        seen.add(identifier)
        expected = expected_scenarios[identifier]
        external_path, _ = validate_artifact(
            evidence_root,
            scenario["externalEvidenceArtifact"],
            f"capture scenario {identifier}.externalEvidenceArtifact",
            capture_root,
        )
        referenced_paths.add(external_path)
        external = require_mapping(load_json(external_path), f"scenario evidence {identifier}")
        require_exact_keys(
            external,
            {
                "containedFailureCode",
                "coverageID",
                "faultInjected",
                "id",
                "injectionPoint",
                "outcome",
                "ownedArtifactReconciled",
                "referenceOutputArtifact",
                "referenceSemanticArtifact",
                "resumedOutputArtifact",
                "resumedSemanticArtifact",
                "schemaVersion",
                "transcriptArtifact",
                "unownedArtifactCount",
            },
            f"scenario evidence {identifier}",
        )
        require(external["schemaVersion"] == SCENARIO_SCHEMA, f"scenario evidence schema differs: {identifier}")
        for key in ("id", "coverageID", "injectionPoint", "outcome", "containedFailureCode"):
            require(external[key] == expected[key], f"scenario {identifier}.{key} differs from contract")
        require_bool(external["faultInjected"], f"scenario {identifier}.faultInjected", True)
        require_bool(external["ownedArtifactReconciled"], f"scenario {identifier}.ownedArtifactReconciled", True)
        require_integer(external["unownedArtifactCount"], f"scenario {identifier}.unownedArtifactCount", 0)
        require(external["unownedArtifactCount"] == 0, f"scenario left an unowned artifact: {identifier}")
        transcript_path, _ = validate_artifact(
            evidence_root,
            external["transcriptArtifact"],
            f"scenario {identifier}.transcriptArtifact",
            capture_root,
        )
        referenced_paths.add(transcript_path)
        validate_transcript(transcript_path, expected, f"scenario transcript {identifier}")

        report_item: dict[str, Any] = {
            "id": identifier,
            "coverage": [expected["coverageID"]],
            "outcome": expected["outcome"],
            "referenceOutputSHA256": None,
            "resumedOutputSHA256": None,
            "referenceSemanticSHA256": None,
            "resumedSemanticSHA256": None,
            "containedFailureCode": expected["containedFailureCode"],
            "unownedArtifactCount": 0,
            "ownedArtifactReconciled": True,
            "referenceOutputArtifact": None,
            "resumedOutputArtifact": None,
            "referenceSemanticArtifact": None,
            "resumedSemanticArtifact": None,
            "externalEvidenceArtifact": scenario["externalEvidenceArtifact"],
        }
        if expected["outcome"] == "identical_resumed_output":
            require(external["containedFailureCode"] is None, f"identical scenario has failure code: {identifier}")
            reference_path, reference_sha = validate_artifact(
                evidence_root,
                external["referenceOutputArtifact"],
                f"scenario {identifier}.referenceOutputArtifact",
                capture_root,
            )
            resumed_path, resumed_sha = validate_artifact(
                evidence_root,
                external["resumedOutputArtifact"],
                f"scenario {identifier}.resumedOutputArtifact",
                capture_root,
            )
            reference_semantic_path, reference_semantic_sha = validate_artifact(
                evidence_root,
                external["referenceSemanticArtifact"],
                f"scenario {identifier}.referenceSemanticArtifact",
                capture_root,
            )
            resumed_semantic_path, resumed_semantic_sha = validate_artifact(
                evidence_root,
                external["resumedSemanticArtifact"],
                f"scenario {identifier}.resumedSemanticArtifact",
                capture_root,
            )
            referenced_paths.update({reference_path, resumed_path, reference_semantic_path, resumed_semantic_path})
            require(reference_sha == resumed_sha, f"resumed output bytes differ: {identifier}")
            reference_semantic = validate_semantic(reference_semantic_path, f"reference semantic {identifier}")
            resumed_semantic = validate_semantic(resumed_semantic_path, f"resumed semantic {identifier}")
            require(reference_semantic == resumed_semantic, f"resumed output semantics differ: {identifier}")
            require(reference_semantic_sha == resumed_semantic_sha, f"semantic manifest bytes differ: {identifier}")
            report_item.update(
                {
                    "referenceOutputSHA256": reference_sha,
                    "resumedOutputSHA256": resumed_sha,
                    "referenceSemanticSHA256": reference_semantic_sha,
                    "resumedSemanticSHA256": resumed_semantic_sha,
                    "referenceOutputArtifact": external["referenceOutputArtifact"],
                    "resumedOutputArtifact": external["resumedOutputArtifact"],
                    "referenceSemanticArtifact": external["referenceSemanticArtifact"],
                    "resumedSemanticArtifact": external["resumedSemanticArtifact"],
                }
            )
        else:
            for key in ("referenceOutputArtifact", "resumedOutputArtifact", "referenceSemanticArtifact", "resumedSemanticArtifact"):
                require(external[key] is None, f"contained scenario supplies {key}: {identifier}")
            require_string(external["containedFailureCode"], f"scenario {identifier}.containedFailureCode")
        report_scenarios.append(report_item)

    require(seen == set(expected_scenarios), "capture recovery coverage differs")
    environment_path = capture_root / "environment.json"
    execution_log_path = capture_root / "xcodebuild.log"
    require(environment_path.is_file() and not environment_path.is_symlink(), "capture environment is missing")
    require(execution_log_path.is_file() and not execution_log_path.is_symlink(), "capture xcodebuild log is missing")
    referenced_paths.update({environment_path.resolve(), execution_log_path.resolve()})
    environment = require_mapping(load_json(environment_path), "capture environment")
    require_exact_keys(environment, {"buildConfiguration", "hardwareModel", "macOSVersion", "schemaVersion", "xcodeVersion"}, "capture environment")
    require(environment["schemaVersion"] == "mirmir-v4-recovery-environment-v1", "capture environment schema differs")
    require(environment["buildConfiguration"] == "Release", "capture environment is not Release")
    for key in ("hardwareModel", "macOSVersion", "xcodeVersion"):
        require_string(environment[key], f"capture environment.{key}")
    try:
        log = execution_log_path.read_text()
    except (OSError, UnicodeError) as error:
        raise RecoveryEvidenceError(f"cannot read capture log: {error}") from error
    require("** TEST SUCCEEDED **" in log, "capture xcodebuild log does not prove success")

    actual_raw_files = {
        path.resolve()
        for path in capture_root.rglob("*")
        if path.is_file() and path.name != "artifact-manifest.json"
    }
    require(
        actual_raw_files == referenced_paths,
        "capture file set differs; "
        f"unreferenced={sorted(path.as_posix() for path in actual_raw_files-referenced_paths)}, "
        f"missing={sorted(path.as_posix() for path in referenced_paths-actual_raw_files)}",
    )
    raw_descriptors = [descriptor(path, evidence_root) for path in sorted(referenced_paths)]
    capture_manifest = {
        "schemaVersion": CAPTURE_MANIFEST_SCHEMA,
        "artifacts": raw_descriptors,
        "artifactSetSHA256": artifact_set_sha(raw_descriptors),
    }
    report = {
        "schemaVersion": REPORT_SCHEMA,
        "contractSHA256": contract_sha,
        "candidate": candidate,
        "releaseEligible": True,
        "identities": {
            "archiveProvenanceSHA256": contract["capture"][
                "archiveProvenanceSourceSHA256"
            ],
            "captureSourceSHA256": contract["capture"]["captureSourceSHA256"],
            "evaluatorSHA256": contract["capture"]["evaluatorSourceSHA256"],
            "packagedEvidenceSHA256": contract["capture"][
                "packagedEvidenceSourceSHA256"
            ],
            "runnerSHA256": contract["capture"]["runnerSourceSHA256"],
        },
        "capture": {
            "artifactManifestSHA256": "__CAPTURE_MANIFEST_SHA256__",
            "artifactSetSHA256": capture_manifest["artifactSetSHA256"],
            "buildConfiguration": capture["buildConfiguration"],
            "execution": {
                "applicationArchiveExecuted": False,
                "kind": "source_bound_xctest_host",
                "sourceBoundToCandidate": True,
            },
            "sourceCommit": capture["sourceCommit"],
            "sourceTreeSHA256": capture["sourceTreeSHA256"],
        },
        "packagedCandidate": packaged_candidate,
        "scenarios": report_scenarios,
        "recoveryGatePass": True,
    }
    return report, capture_manifest


def make_suite_manifest(role_root: Path, manifest_path: Path) -> dict[str, Any]:
    files = sorted(
        path.resolve()
        for path in role_root.rglob("*")
        if path.is_file() and path.resolve() != manifest_path.resolve()
    )
    # The release aggregator resolves a role's sealed-manifest descriptors
    # relative to the directory containing that manifest. Nested capture and
    # scenario descriptors remain relative to the global evidence root.
    artifacts = [descriptor(path, role_root) for path in files]
    return {
        "schemaVersion": SUITE_MANIFEST_SCHEMA,
        "artifacts": artifacts,
        "artifactSetSHA256": artifact_set_sha(artifacts),
    }


def evaluate_command(arguments: argparse.Namespace) -> None:
    evidence_root = Path(arguments.evidence_root).expanduser().resolve(strict=True)
    capture_path = Path(arguments.capture).expanduser().resolve(strict=True)
    contract_path = Path(arguments.contract).expanduser().resolve(strict=True)
    candidate_path = Path(arguments.candidate).expanduser().resolve(strict=True)
    report_path = Path(arguments.output).expanduser().resolve()
    capture_manifest_path = Path(arguments.capture_manifest).expanduser().resolve()
    suite_manifest_path = Path(arguments.sealed_manifest).expanduser().resolve()
    role_root = report_path.parent.resolve(strict=True)
    package_identity_path = role_artifact_path(
        role_root,
        Path(arguments.package_identity),
        "package identity output",
        must_exist=False,
    )
    attestation_path = role_artifact_path(
        role_root,
        Path(arguments.attestation),
        "attestation output",
        must_exist=False,
    )
    application_archive = role_artifact_path(
        role_root,
        Path(arguments.application_archive),
        "application archive",
        must_exist=True,
    )
    candidate_path = role_artifact_path(
        role_root,
        candidate_path,
        "candidate identity",
        must_exist=True,
    )
    release_configuration_artifact = role_artifact_path(
        role_root,
        Path(arguments.release_configuration_artifact),
        "Release configuration artifact",
        must_exist=True,
    )
    runtime_manifest_artifact = role_artifact_path(
        role_root,
        Path(arguments.runtime_manifest_artifact),
        "runtime manifest artifact",
        must_exist=True,
    )
    contract, _ = load_contract(contract_path)
    packaged_candidate = bind_or_verify_package_evidence(
        repository=Path(arguments.repository),
        candidate_path=candidate_path,
        application_archive=application_archive,
        runtime=Path(arguments.runtime),
        release_configuration=Path(arguments.release_configuration),
        release_configuration_artifact=release_configuration_artifact,
        runtime_manifest_artifact=runtime_manifest_artifact,
        package_identity_path=package_identity_path,
        attestation_path=attestation_path,
        contract=contract,
        write_artifacts=True,
    )
    report, capture_manifest = evaluate_capture(
        contract_path,
        capture_path,
        candidate_path,
        evidence_root,
        packaged_candidate,
    )
    write_json(capture_manifest_path, capture_manifest)
    report["capture"]["artifactManifestSHA256"] = sha256_file(capture_manifest_path)
    write_json(report_path, report)
    write_json(
        suite_manifest_path,
        make_suite_manifest(role_root, suite_manifest_path),
    )


def verify_command(arguments: argparse.Namespace) -> None:
    evidence_root = Path(arguments.evidence_root).expanduser().resolve(strict=True)
    contract_path = Path(arguments.contract).expanduser().resolve(strict=True)
    candidate_path = Path(arguments.candidate).expanduser().resolve(strict=True)
    capture_manifest_path = Path(arguments.capture_manifest).expanduser().resolve(strict=True)
    report_path = Path(arguments.report).expanduser().resolve(strict=True)
    suite_manifest_path = Path(arguments.sealed_manifest).expanduser().resolve(strict=True)
    role_root = report_path.parent.resolve(strict=True)
    candidate_path = role_artifact_path(
        role_root,
        candidate_path,
        "candidate identity",
        must_exist=True,
    )
    application_archive = role_artifact_path(
        role_root,
        Path(arguments.application_archive),
        "application archive",
        must_exist=True,
    )
    package_identity_path = role_artifact_path(
        role_root,
        Path(arguments.package_identity),
        "package identity artifact",
        must_exist=True,
    )
    attestation_path = role_artifact_path(
        role_root,
        Path(arguments.attestation),
        "attestation artifact",
        must_exist=True,
    )
    release_configuration_artifact = role_artifact_path(
        role_root,
        Path(arguments.release_configuration_artifact),
        "Release configuration artifact",
        must_exist=True,
    )
    runtime_manifest_artifact = role_artifact_path(
        role_root,
        Path(arguments.runtime_manifest_artifact),
        "runtime manifest artifact",
        must_exist=True,
    )
    contract, _ = load_contract(contract_path)
    packaged_candidate = bind_or_verify_package_evidence(
        repository=Path(arguments.repository),
        candidate_path=candidate_path,
        application_archive=application_archive,
        runtime=Path(arguments.runtime),
        release_configuration=Path(arguments.release_configuration),
        release_configuration_artifact=release_configuration_artifact,
        runtime_manifest_artifact=runtime_manifest_artifact,
        package_identity_path=package_identity_path,
        attestation_path=attestation_path,
        contract=contract,
        write_artifacts=False,
    )
    expected_report, expected_capture_manifest = evaluate_capture(
        contract_path,
        Path(arguments.capture),
        candidate_path,
        evidence_root,
        packaged_candidate,
    )
    require(
        load_json(capture_manifest_path) == expected_capture_manifest
        and capture_manifest_path.read_bytes() == pretty_json(expected_capture_manifest),
        "capture artifact manifest is stale or noncanonical",
    )
    expected_report["capture"]["artifactManifestSHA256"] = sha256_file(capture_manifest_path)
    require(
        load_json(report_path) == expected_report
        and report_path.read_bytes() == pretty_json(expected_report),
        "recovery report is stale or noncanonical",
    )
    expected_suite_manifest = make_suite_manifest(
        report_path.parent.resolve(strict=True),
        suite_manifest_path,
    )
    require(
        load_json(suite_manifest_path) == expected_suite_manifest
        and suite_manifest_path.read_bytes() == pretty_json(expected_suite_manifest),
        "recovery sealed manifest is stale or noncanonical",
    )


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    subparsers = value.add_subparsers(dest="command", required=True)
    export_source = subparsers.add_parser(
        "export-source",
        help="export and verify the exact committed recovery source",
    )
    evaluate = subparsers.add_parser("evaluate", help="validate capture and write sealed recovery evidence")
    verify = subparsers.add_parser("verify", help="recompute and verify existing recovery evidence")
    export_source.add_argument("--destination", required=True)
    export_source.add_argument("--repository", required=True)
    export_source.add_argument("--revision", required=True)
    for command in (evaluate, verify):
        command.add_argument("--application-archive", required=True)
        command.add_argument("--attestation", required=True)
        command.add_argument("--contract", required=True)
        command.add_argument("--capture", required=True)
        command.add_argument("--candidate", required=True)
        command.add_argument("--evidence-root", required=True)
        command.add_argument("--package-identity", required=True)
        command.add_argument("--release-configuration", required=True)
        command.add_argument("--release-configuration-artifact", required=True)
        command.add_argument("--repository", required=True)
        command.add_argument("--runtime", required=True)
        command.add_argument("--runtime-manifest-artifact", required=True)
        command.add_argument("--capture-manifest", required=True)
        command.add_argument("--sealed-manifest", required=True)
    evaluate.add_argument("--output", required=True)
    verify.add_argument("--report", required=True)
    return value


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "export-source":
            export_source_command(arguments)
        elif arguments.command == "evaluate":
            evaluate_command(arguments)
        else:
            verify_command(arguments)
    except (
        RecoveryEvidenceError,
        packaged_evidence.PackagedEvidenceError,
        packaged_evidence.archive_provenance.ArchiveProvenanceError,
    ) as error:
        print(f"recovery qualification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
