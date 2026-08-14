#!/usr/bin/env python3
"""Replay and verify sealed ASH P06 clean-build reproduction evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
from typing import Any, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-ash-v4-p06-reproduction-contract-v1"
REPORT_SCHEMA = "mirmir-ash-v4-p06-reproduction-report-v1"
SEALED_SCHEMA = "mirmir-ash-v4-p06-reproduction-evidence-v1"
ARTIFACT_MANIFEST_SCHEMA = "mirmir-p06-artifact-manifest-v1"
MANIFEST_SCHEMA = "ash.p06.runtime-manifest.v1"
MANIFEST_DOMAIN = b"ash-p06-runtime-manifest-v4\0"
RUNTIME_ID = "ash-p06-deterministic-v4"
HEX = frozenset("0123456789abcdef")
CANDIDATE_FIELDS = {
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


class EvidenceError(ValueError):
    """P06 evidence is stale, incomplete, malformed, or semantically false."""


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value: str) -> None:
    raise EvidenceError(f"non-finite JSON number is forbidden: {value}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot read JSON {path}: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise EvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be nonempty text")
    return value


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    require(type(value) is int and value >= minimum, f"{label} must be an integer >= {minimum}")
    return value


def require_bool(value: Any, label: str, expected: bool | None = None) -> bool:
    require(type(value) is bool, f"{label} must be Boolean")
    if expected is not None:
        require(value is expected, f"{label} must be {str(expected).lower()}")
    return value


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, "
        f"unexpected={sorted(actual-expected_set)}",
    )


def require_hex(value: Any, lengths: tuple[int, ...], label: str) -> str:
    text = require_string(value, label)
    require(len(text) in lengths and set(text) <= HEX, f"{label} is not lowercase hexadecimal")
    return text


def require_safe_relative(value: Any, label: str) -> str:
    text = require_string(value, label)
    relative = PurePosixPath(text)
    require(
        not relative.is_absolute() and ".." not in relative.parts and text == relative.as_posix(),
        f"{label} is not a safe canonical relative path",
    )
    return text


def checked_file(root: Path, value: Any, label: str) -> Path:
    relative = require_safe_relative(value, label)
    candidate = root / relative
    require(candidate.exists(), f"{label} does not exist: {relative}")
    require(not candidate.is_symlink(), f"{label} may not be a symbolic link")
    resolved_root = root.resolve(strict=True)
    resolved = candidate.resolve(strict=True)
    require(resolved.is_file() and resolved_root in resolved.parents, f"{label} is not a regular file")
    return resolved


def regular_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"symbolic links are forbidden in evidence: {path}")
        if path.is_file():
            files.append(path.resolve(strict=True))
    return sorted(files, key=lambda item: item.relative_to(root.resolve()).as_posix())


def validate_descriptor(root: Path, value: Any, label: str) -> tuple[Path, str]:
    descriptor = require_mapping(value, label)
    require_exact_keys(descriptor, ("path", "byteCount", "sha256"), label)
    path = checked_file(root, descriptor["path"], f"{label}.path")
    byte_count = require_integer(descriptor["byteCount"], f"{label}.byteCount")
    identity = require_hex(descriptor["sha256"], (64,), f"{label}.sha256")
    require(path.stat().st_size == byte_count, f"{label} byte count mismatch")
    require(sha256_file(path) == identity, f"{label} SHA-256 mismatch")
    return path, identity


def artifact_set_sha(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for relative, identity in sorted(entries):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(identity.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def candidate_identity(value: Any, label: str = "candidate") -> dict[str, Any]:
    candidate = require_mapping(value, label)
    require_exact_keys(candidate, CANDIDATE_FIELDS, label)
    require_hex(candidate["sourceCommit"], (40,), f"{label}.sourceCommit")
    for key in (
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
    ):
        require_hex(candidate[key], (64,), f"{label}.{key}")
    require_hex(candidate["runtimeSourceRevision"], (40, 64), f"{label}.runtimeSourceRevision")
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"{label}.{key}")
    return dict(candidate)


def load_candidate(path: Path) -> dict[str, Any]:
    document = require_mapping(load_json(path), "candidate document")
    value = document.get("candidate", document)
    return candidate_identity(value)


def validate_contract(path: Path) -> tuple[dict[str, Any], str]:
    contract = require_mapping(load_json(path), "P06 reproduction contract")
    require(contract.get("schemaVersion") == CONTRACT_SCHEMA, "unsupported P06 reproduction contract")
    require(contract.get("suiteID") == "mirmir-ash-v4-p06-reproduction-v1", "P06 suite identity mismatch")
    require(contract.get("buildConfiguration") == "Release", "P06 contract must require Release")
    require(contract.get("sourceCheckoutState") == "clean", "P06 contract must require clean checkouts")
    require_integer(contract.get("cleanBuildCount"), "contract.cleanBuildCount", 2)
    require_integer(
        contract.get("productionSourceCount"),
        "contract.productionSourceCount",
        1,
    )
    build_ids = require_list(contract.get("cleanBuildIDs"), "contract.cleanBuildIDs")
    require(len(build_ids) == contract["cleanBuildCount"] and len(set(build_ids)) == len(build_ids), "P06 build IDs are incomplete or repeated")
    for index, value in enumerate(build_ids):
        require_string(value, f"contract.cleanBuildIDs[{index}]")
    roles = require_list(contract.get("requiredRuntimeArtifactRoles"), "contract.requiredRuntimeArtifactRoles")
    require(roles == sorted(set(roles)) and roles, "P06 artifact roles must be nonempty, unique, and sorted")
    require(contract.get("runtimeID") == RUNTIME_ID, "P06 runtime ID mismatch")
    require(contract.get("runtimeReleaseStatus") == "release_qualified", "P06 status mismatch")
    require(contract.get("canonicalManifestIdentityDomain") == "ash-p06-runtime-manifest-v4", "P06 manifest domain mismatch")
    require(contract.get("developmentArtifactDependencyCount") == 0, "development dependencies are forbidden")
    require(contract.get("p05ProductionDependencyCount") == 0, "P05 dependencies are forbidden")
    capture = require_mapping(contract.get("capture"), "contract.capture")
    require_exact_keys(
        capture,
        (
            "captureSourceSHA256",
            "evaluatorSHA256",
            "runnerSHA256",
            "runtimeLoadCheckRunnerSHA256",
            "runtimeLoadCheckSourceSHA256",
            "sourceIdentityToolSHA256",
            "sourceProvenanceContractSHA256",
        ),
        "contract.capture",
    )
    for key, value in capture.items():
        require_hex(value, (64,), f"contract.capture.{key}")
    verification = require_mapping(contract.get("verification"), "contract.verification")
    for key in (
        "byteIdenticalToShippingBundle",
        "productionLoaderAcceptanceRequired",
        "sameLengthArtifactTamperRejectionRequired",
        "toolchainProvenanceEqualityRequired",
        "sealedClosureRequired",
    ):
        require_bool(verification.get(key), f"contract.verification.{key}", True)
    return contract, sha256_file(path)


def validate_sealed_manifest(root: Path) -> set[Path]:
    manifest_path = root / "sealed-manifest.json"
    manifest = require_mapping(load_json(manifest_path), "sealed manifest")
    require_exact_keys(manifest, ("schemaVersion", "artifacts"), "sealed manifest")
    require(manifest.get("schemaVersion") == SEALED_SCHEMA, "sealed manifest schema mismatch")
    descriptors = require_list(manifest["artifacts"], "sealed manifest artifacts")
    sealed: set[Path] = set()
    ordered_paths: list[str] = []
    for index, descriptor in enumerate(descriptors):
        path, _ = validate_descriptor(root, descriptor, f"sealed artifact[{index}]")
        require(path != manifest_path.resolve(), "sealed manifest may not recursively list itself")
        require(path not in sealed, f"sealed manifest repeats {path}")
        sealed.add(path)
        ordered_paths.append(path.relative_to(root.resolve()).as_posix())
    require(ordered_paths == sorted(ordered_paths), "sealed artifacts are not canonically ordered")
    actual = set(regular_files(root)) - {manifest_path.resolve(strict=True)}
    require(sealed == actual, f"sealed evidence closure mismatch; missing={sorted(str(path) for path in actual-sealed)}, unexpected={sorted(str(path) for path in sealed-actual)}")
    return sealed


def require_sealed_descriptor(root: Path, sealed: set[Path], value: Any, label: str) -> tuple[Path, str]:
    path, identity = validate_descriptor(root, value, label)
    require(path in sealed, f"{label} is outside sealed evidence")
    return path, identity


def validate_runtime_manifest(
    path: Path,
    candidate: Mapping[str, Any],
    required_roles: list[str],
    sealed: set[Path],
) -> tuple[dict[str, Any], str, list[tuple[str, str]]]:
    manifest = require_mapping(load_json(path), "runtime manifest")
    require(path.read_bytes() == canonical_bytes(manifest), "runtime manifest is not canonical JSON")
    file_identity = sha256_file(path)
    require(file_identity == candidate["runtimeManifestFileSHA256"], "runtime manifest file identity differs from candidate")
    semantic_identity = sha256_bytes(MANIFEST_DOMAIN + canonical_bytes(manifest))
    require(semantic_identity == candidate["runtimeManifestSHA256"], "runtime semantic identity differs from candidate")
    require(manifest.get("schemaID") == MANIFEST_SCHEMA, "runtime manifest schema mismatch")
    require(manifest.get("runtimeID") == RUNTIME_ID, "runtime ID mismatch")
    require(manifest.get("releaseStatus") == "release_qualified", "runtime is not release-qualified")
    provenance = require_mapping(manifest.get("provenance"), "runtime provenance")
    require(provenance.get("sourceRevision") == candidate["runtimeSourceRevision"], "runtime source revision mismatch")
    require_hex(provenance.get("builderSourceSHA256"), (64,), "runtime provenance builder identity")
    require_mapping(provenance.get("toolchain"), "runtime provenance toolchain")
    declarations = require_list(manifest.get("artifacts"), "runtime artifacts")
    observed: list[str] = []
    entries: list[tuple[str, str]] = [("runtime-manifest.json", file_identity)]
    for index, raw in enumerate(declarations):
        declaration = require_mapping(raw, f"runtime artifact[{index}]")
        require_exact_keys(declaration, ("role", "relativePath", "schemaID", "contentSHA256", "byteCount"), f"runtime artifact[{index}]")
        role = require_string(declaration["role"], f"runtime artifact[{index}].role")
        require(role not in observed, f"runtime repeats artifact role {role}")
        observed.append(role)
        relative = require_safe_relative(declaration["relativePath"], f"runtime artifact {role}.relativePath")
        expected = "artifacts/ash-p06.metallib" if role == "metal_library" else f"artifacts/{role}.json"
        require(relative == expected, f"runtime artifact path mismatch for {role}")
        require_string(declaration["schemaID"], f"runtime artifact {role}.schemaID")
        content_identity = require_hex(declaration["contentSHA256"], (64,), f"runtime artifact {role}.contentSHA256")
        byte_count = require_integer(declaration["byteCount"], f"runtime artifact {role}.byteCount")
        content = checked_file(path.parent, relative, f"runtime artifact {role}")
        require(content in sealed, f"runtime artifact {role} is outside sealed evidence")
        require(sha256_file(content) == content_identity, f"runtime artifact hash mismatch for {role}")
        require(content.stat().st_size == byte_count, f"runtime artifact byte count mismatch for {role}")
        entries.append((relative, content_identity))
    require(observed == required_roles, f"runtime artifact role/order mismatch: {observed}")
    metal = next(raw for raw in declarations if raw["role"] == "metal_library")
    require(provenance.get("metalLibrarySHA256") == metal["contentSHA256"], "Metal provenance identity mismatch")
    forbidden = json.dumps(manifest, sort_keys=True).lower()
    require(not any(token in forbidden for token in ("p05", "preview", "development", "dev-runtime")), "runtime retains a forbidden preview identity")
    return manifest, semantic_identity, entries


def parse_loader_transcript(path: Path, candidate: Mapping[str, Any], builder_identity: str, artifact_count: int) -> None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise EvidenceError(f"cannot read loader transcript: {error}") from error
    values: dict[str, str] = {}
    for line in lines:
        require("=" in line, f"loader transcript contains an unstructured line: {line!r}")
        key, value = line.split("=", 1)
        require(key not in values and key != "" and value != "", f"loader transcript repeats or empties {key!r}")
        values[key] = value
    require_exact_keys(
        values,
        (
            "runtime_id",
            "manifest_sha256",
            "source_revision",
            "builder_source_sha256",
            "artifact_count",
            "production_loader_acceptance",
            "same_length_artifact_tamper_rejection",
        ),
        "loader transcript",
    )
    require(values["runtime_id"] == RUNTIME_ID, "loader accepted another runtime")
    require(values["manifest_sha256"] == candidate["runtimeManifestSHA256"], "loader manifest identity mismatch")
    require(values["source_revision"] == candidate["runtimeSourceRevision"], "loader source identity mismatch")
    require(values["builder_source_sha256"] == builder_identity, "loader builder identity mismatch")
    require(values["artifact_count"] == str(artifact_count), "loader artifact count mismatch")
    require(values["production_loader_acceptance"] == "pass", "production loader did not accept P06")
    require(values["same_length_artifact_tamper_rejection"] == "pass", "production loader did not reject same-length tamper")


def validate_production_source_manifest(
    path: Path,
    source_contract: Mapping[str, Any],
    candidate: Mapping[str, Any],
    required_count: int,
) -> tuple[str, str]:
    document = require_mapping(load_json(path), "production source manifest")
    require_exact_keys(
        document,
        (
            "schemaVersion",
            "contractSemanticSHA256",
            "identityDomain",
            "sourceCount",
            "sourceRevision",
            "sources",
        ),
        "production source manifest",
    )
    require(
        document.get("schemaVersion")
        == "mirmir-ash-v4-p06-production-source-manifest-v1",
        "production source manifest schema mismatch",
    )
    require(path.read_bytes() == canonical_bytes(document), "production source manifest is not canonical JSON")
    require(
        document.get("contractSemanticSHA256")
        == sha256_bytes(canonical_bytes(source_contract)),
        "production source manifest contract identity mismatch",
    )
    require(document.get("identityDomain") == "ash-p06-production-source-v1", "production source domain mismatch")
    require_integer(document.get("sourceCount"), "production source count", 1)
    require(document["sourceCount"] == required_count, "production source count differs from P06 contract")
    revision = require_hex(document.get("sourceRevision"), (64,), "production source revision")
    require(revision == candidate["runtimeSourceRevision"], "production source revision differs from candidate")
    sources = require_list(document.get("sources"), "production sources")
    require(len(sources) == required_count, "production source manifest entry count mismatch")
    declared_paths = require_list(source_contract.get("sources"), "source provenance contract sources")
    require(len(declared_paths) == required_count, "source provenance contract count mismatch")
    observed_paths: list[str] = []
    normalized_path = require_mapping(
        source_contract.get("normalizedDeploymentTrustRoot"),
        "source provenance normalized trust root",
    ).get("path")
    for index, raw in enumerate(sources):
        entry = require_mapping(raw, f"production source[{index}]")
        require_exact_keys(
            entry,
            (
                "path",
                "byteCount",
                "sha256",
                "normalizedByteCount",
                "normalizedSHA256",
                "normalizations",
            ),
            f"production source[{index}]",
        )
        relative = require_safe_relative(entry["path"], f"production source[{index}].path")
        observed_paths.append(relative)
        require_integer(entry["byteCount"], f"production source[{index}].byteCount", 1)
        require_hex(entry["sha256"], (64,), f"production source[{index}].sha256")
        require_integer(entry["normalizedByteCount"], f"production source[{index}].normalizedByteCount", 1)
        require_hex(entry["normalizedSHA256"], (64,), f"production source[{index}].normalizedSHA256")
        normalizations = require_list(entry["normalizations"], f"production source[{index}].normalizations")
        if relative == normalized_path:
            require(
                normalizations
                == ["builderSourceSHA256", "manifestSHA256", "sourceRevision"],
                "deployment trust-root normalization is incomplete",
            )
        else:
            require(not normalizations, f"unexpected source normalization: {relative}")
            require(entry["byteCount"] == entry["normalizedByteCount"], f"unmodified source byte count changed: {relative}")
            require(entry["sha256"] == entry["normalizedSHA256"], f"unmodified source identity changed: {relative}")
    require(observed_paths == declared_paths, "production source paths/order differ from locked provenance contract")
    return revision, sha256_file(path)


def validate_build(
    root: Path,
    sealed: set[Path],
    raw: Any,
    index: int,
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    source_contract: Mapping[str, Any],
) -> dict[str, str]:
    label = f"build[{index}]"
    build = require_mapping(raw, label)
    require_exact_keys(
        build,
        (
            "id",
            "runtimeArtifactSetSHA256",
            "runtimeManifestSHA256",
            "builderSHA256",
            "productionSourceRevision",
            "productionSourceManifestSHA256",
            "toolchainImageSHA256",
            "artifactManifest",
            "runtimeManifestArtifact",
            "builderArtifact",
            "productionSourceArtifact",
            "toolchainImageArtifact",
            "loaderEvidenceArtifact",
            "releaseQualifiedStatus",
            "developmentArtifactDependencyCount",
            "p05ProductionDependencyCount",
        ),
        label,
    )
    identifier = require_string(build["id"], f"{label}.id")
    require(identifier == contract["cleanBuildIDs"][index], f"{label} identity/order mismatch")
    artifact_set_claim = require_hex(build["runtimeArtifactSetSHA256"], (64,), f"{label}.runtimeArtifactSetSHA256")
    manifest_claim = require_hex(build["runtimeManifestSHA256"], (64,), f"{label}.runtimeManifestSHA256")
    builder_claim = require_hex(build["builderSHA256"], (64,), f"{label}.builderSHA256")
    source_revision_claim = require_hex(
        build["productionSourceRevision"], (64,), f"{label}.productionSourceRevision"
    )
    source_manifest_claim = require_hex(
        build["productionSourceManifestSHA256"],
        (64,),
        f"{label}.productionSourceManifestSHA256",
    )
    toolchain_claim = require_hex(build["toolchainImageSHA256"], (64,), f"{label}.toolchainImageSHA256")

    artifact_manifest_path, _ = require_sealed_descriptor(root, sealed, build["artifactManifest"], f"{label}.artifactManifest")
    artifact_manifest = require_mapping(load_json(artifact_manifest_path), f"{label} artifact manifest")
    require_exact_keys(artifact_manifest, ("schemaVersion", "artifacts"), f"{label} artifact manifest")
    require(artifact_manifest.get("schemaVersion") == ARTIFACT_MANIFEST_SCHEMA, f"{label} artifact manifest schema mismatch")
    descriptors = require_list(artifact_manifest["artifacts"], f"{label} artifact manifest artifacts")
    entries: list[tuple[str, str]] = []
    observed_paths: list[str] = []
    for artifact_index, descriptor in enumerate(descriptors):
        path, identity = validate_descriptor(artifact_manifest_path.parent, descriptor, f"{label} artifact[{artifact_index}]")
        require(path in sealed, f"{label} runtime artifact is outside sealed evidence")
        relative = path.relative_to(artifact_manifest_path.parent).as_posix()
        require(relative not in observed_paths, f"{label} repeats artifact {relative}")
        observed_paths.append(relative)
        entries.append((relative, identity))
    require(observed_paths == sorted(observed_paths), f"{label} runtime artifacts are not sorted")
    require(artifact_set_sha(entries) == artifact_set_claim, f"{label} artifact-set identity mismatch")
    require(artifact_set_claim == candidate["runtimeArtifactSetSHA256"], f"{label} differs from candidate artifact set")

    runtime_path, runtime_file_identity = require_sealed_descriptor(root, sealed, build["runtimeManifestArtifact"], f"{label}.runtimeManifestArtifact")
    require(runtime_file_identity == candidate["runtimeManifestFileSHA256"], f"{label} runtime file identity mismatch")
    manifest, semantic_identity, runtime_entries = validate_runtime_manifest(
        runtime_path, candidate, contract["requiredRuntimeArtifactRoles"], sealed
    )
    require(semantic_identity == manifest_claim, f"{label} semantic manifest claim mismatch")
    require(sorted(runtime_entries) == sorted(entries), f"{label} artifact manifest does not exactly describe the runtime bundle")

    builder_path, builder_identity = require_sealed_descriptor(root, sealed, build["builderArtifact"], f"{label}.builderArtifact")
    require(builder_identity == builder_claim, f"{label} builder claim mismatch")
    provenance = require_mapping(manifest["provenance"], f"{label} runtime provenance")
    require(provenance.get("builderSourceSHA256") == builder_identity, f"{label} builder provenance mismatch")
    require(builder_path.stat().st_size > 0, f"{label} builder source manifest is empty")

    production_source_path, production_source_identity = require_sealed_descriptor(
        root,
        sealed,
        build["productionSourceArtifact"],
        f"{label}.productionSourceArtifact",
    )
    source_revision, source_manifest_identity = validate_production_source_manifest(
        production_source_path,
        source_contract,
        candidate,
        contract["productionSourceCount"],
    )
    require(source_revision == source_revision_claim, f"{label} production source revision claim mismatch")
    require(production_source_identity == source_manifest_claim == source_manifest_identity, f"{label} production source manifest claim mismatch")

    toolchain_path, toolchain_identity = require_sealed_descriptor(root, sealed, build["toolchainImageArtifact"], f"{label}.toolchainImageArtifact")
    require(toolchain_identity == toolchain_claim, f"{label} toolchain claim mismatch")
    toolchain = require_mapping(load_json(toolchain_path), f"{label} toolchain image")
    require(toolchain_path.read_bytes() == canonical_bytes(toolchain), f"{label} toolchain image is not canonical JSON")
    require(toolchain == provenance.get("toolchain"), f"{label} toolchain artifact differs from runtime provenance")

    loader_path, _ = require_sealed_descriptor(root, sealed, build["loaderEvidenceArtifact"], f"{label}.loaderEvidenceArtifact")
    parse_loader_transcript(loader_path, candidate, builder_identity, len(manifest["artifacts"]))
    require_bool(build["releaseQualifiedStatus"], f"{label}.releaseQualifiedStatus", True)
    require_integer(build["developmentArtifactDependencyCount"], f"{label}.developmentArtifactDependencyCount")
    require(build["developmentArtifactDependencyCount"] == 0, f"{label} depends on a development artifact")
    require_integer(build["p05ProductionDependencyCount"], f"{label}.p05ProductionDependencyCount")
    require(build["p05ProductionDependencyCount"] == 0, f"{label} retains a P05 production dependency")
    return {
        "artifactSet": artifact_set_claim,
        "manifest": semantic_identity,
        "builder": builder_identity,
        "sourceManifest": source_manifest_identity,
        "toolchain": toolchain_identity,
    }


def verify(evidence_root: Path, candidate_path: Path, contract_path: Path) -> dict[str, Any]:
    root = evidence_root.expanduser().resolve(strict=True)
    require(root.is_dir(), "P06 evidence root must be a directory")
    contract, contract_identity = validate_contract(contract_path.expanduser().resolve(strict=True))
    expected_candidate = load_candidate(candidate_path.expanduser().resolve(strict=True))
    sealed = validate_sealed_manifest(root)

    report_path = root / "report.json"
    require(report_path.resolve(strict=True) in sealed, "report is not sealed")
    report = require_mapping(load_json(report_path), "P06 report")
    require_exact_keys(
        report,
        (
            "schemaVersion",
            "contractSHA256",
            "candidate",
            "releaseEligible",
            "identities",
            "buildConfiguration",
            "sourceCheckoutState",
            "builds",
            "productionLoaderAcceptancePass",
            "tamperRejectionPass",
            "p06ReproductionGatePass",
        ),
        "P06 report",
    )
    require(report.get("schemaVersion") == REPORT_SCHEMA, "P06 report schema mismatch")
    require(report.get("contractSHA256") == contract_identity, "P06 contract identity mismatch")
    candidate = candidate_identity(report.get("candidate"))
    require(candidate == expected_candidate, "P06 report belongs to another candidate")
    require_bool(report.get("releaseEligible"), "report.releaseEligible", True)
    require(report.get("buildConfiguration") == contract["buildConfiguration"], "P06 build configuration mismatch")
    require(report.get("sourceCheckoutState") == contract["sourceCheckoutState"], "P06 checkout state mismatch")

    base_artifacts = {
        "captureSourceSHA256": "capture-tool.py",
        "evaluatorSHA256": "evaluator.py",
        "runnerSHA256": "runner.sh",
        "runtimeLoadCheckRunnerSHA256": "runtime-load-check-runner.sh",
        "runtimeLoadCheckSourceSHA256": "runtime-load-check.swift",
        "sourceIdentityToolSHA256": "source-identity-tool.py",
        "sourceProvenanceContractSHA256": "source-provenance-contract.json",
    }
    identities = require_mapping(report.get("identities"), "report.identities")
    require_exact_keys(identities, base_artifacts, "report.identities")
    for key, relative in base_artifacts.items():
        path = checked_file(root, relative, f"report identity {key}")
        require(path in sealed, f"report identity artifact is unsealed: {relative}")
        identity = require_hex(identities[key], (64,), f"report.identities.{key}")
        require(identity == sha256_file(path), f"report identity differs for {key}")
        require(identity == contract["capture"][key], f"contract identity differs for {key}")
    suite_contract = checked_file(root, "suite-contract.json", "sealed suite contract")
    require(suite_contract in sealed and sha256_file(suite_contract) == contract_identity, "sealed suite contract differs")
    require(suite_contract.read_bytes() == contract_path.resolve(strict=True).read_bytes(), "executing contract differs from sealed contract")
    release_configuration = checked_file(root, "Release.xcconfig", "sealed Release configuration")
    require(release_configuration in sealed and sha256_file(release_configuration) == candidate["releaseConfigurationSHA256"], "sealed Release configuration differs from candidate")
    root_runtime = checked_file(root, "runtime-manifest.json", "sealed shipping runtime manifest")
    require(root_runtime in sealed, "shipping runtime manifest is not sealed")
    validate_runtime_manifest(root_runtime, candidate, contract["requiredRuntimeArtifactRoles"], sealed)
    source_contract_path = checked_file(
        root, "source-provenance-contract.json", "sealed source provenance contract"
    )
    source_contract = require_mapping(
        load_json(source_contract_path), "source provenance contract"
    )
    require(
        source_contract.get("schemaVersion")
        == "mirmir-ash-v4-p06-source-provenance-contract-v1",
        "source provenance contract schema mismatch",
    )

    builds = require_list(report.get("builds"), "report.builds")
    require(len(builds) == contract["cleanBuildCount"], "P06 clean-build count mismatch")
    summaries = [
        validate_build(root, sealed, raw, index, candidate, contract, source_contract)
        for index, raw in enumerate(builds)
    ]
    for key in ("artifactSet", "manifest", "builder", "sourceManifest", "toolchain"):
        require(len({summary[key] for summary in summaries}) == 1, f"clean builds differ in {key}")
    require_bool(report.get("productionLoaderAcceptancePass"), "report.productionLoaderAcceptancePass", True)
    require_bool(report.get("tamperRejectionPass"), "report.tamperRejectionPass", True)
    require_bool(report.get("p06ReproductionGatePass"), "report.p06ReproductionGatePass", True)
    return {
        "schemaVersion": "mirmir-ash-v4-p06-reproduction-verification-v1",
        "candidateSourceCommit": candidate["sourceCommit"],
        "cleanBuildCount": len(summaries),
        "runtimeArtifactSetSHA256": summaries[0]["artifactSet"],
        "runtimeManifestSHA256": summaries[0]["manifest"],
        "builderSHA256": summaries[0]["builder"],
        "productionSourceManifestSHA256": summaries[0]["sourceManifest"],
        "productionSourceCount": contract["productionSourceCount"],
        "toolchainImageSHA256": summaries[0]["toolchain"],
        "productionLoaderAcceptancePass": True,
        "sameLengthArtifactTamperRejectionPass": True,
        "p06ReproductionGatePass": True,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--evidence", type=Path, required=True)
    verify_parser.add_argument("--candidate", type=Path, required=True)
    verify_parser.add_argument("--contract", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "verify":
        print(json.dumps(verify(arguments.evidence, arguments.candidate, arguments.contract), indent=2, sort_keys=True))
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (EvidenceError, OSError) as error:
        print(f"P06 reproduction verification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
