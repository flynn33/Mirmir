#!/usr/bin/env python3
"""Replay and verify sealed ASH P06 clean-build reproduction evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
from typing import Any, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-ash-v4-p06-reproduction-contract-v2"
REPORT_SCHEMA = "mirmir-ash-v4-p06-reproduction-report-v2"
SEALED_SCHEMA = "mirmir-ash-v4-p06-reproduction-evidence-v2"
VERIFICATION_SCHEMA = "mirmir-ash-v4-p06-reproduction-verification-v2"
ARTIFACT_MANIFEST_SCHEMA = "mirmir-p06-artifact-manifest-v1"
BUILD_EXECUTION_SCHEMA = "mirmir-ash-v4-p06-build-execution-v2"
BUILD_TRANSCRIPT_SCHEMA = "mirmir-ash-v4-p06-build-transcript-v2"
SOURCE_MANIFEST_SCHEMA = "mirmir-ash-v4-p06-production-source-manifest-v1"
SOURCE_CONTRACT_SCHEMA = "mirmir-ash-v4-p06-source-provenance-contract-v1"
MANIFEST_SCHEMA = "ash.p06.runtime-manifest.v1"
MANIFEST_DOMAIN = b"ash-p06-runtime-manifest-v4\0"
SOURCE_TREE_DOMAIN = b"mirmir-source-tree-v1\0"
SOURCE_IDENTITY_DOMAIN = b"ash-p06-production-source-v1"
BUILD_CAUSAL_DOMAIN = b"mirmir-p06-build-causal-binding-v1\0"
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
BUILD_CAUSAL_FIELDS = (
    "buildID",
    "invocationNonce",
    "captureProcessID",
    "processID",
    "startedAtUnixNanoseconds",
    "finishedAtUnixNanoseconds",
    "durationNanoseconds",
    "workingDirectory",
    "buildOutputRoot",
    "buildChallenge",
    "buildCommand",
    "buildEnvironment",
    "sourceCommit",
    "sourceCommitObjectSHA256",
    "checkoutTreeObject",
    "sourceTreeIdentitySHA256",
    "sourceTreeListingSHA256",
    "sourceArchiveSHA256",
    "buildRunnerSHA256",
    "buildTranscriptSHA256",
    "runtimeArtifactSetSHA256",
    "runtimeManifestFileSHA256",
    "productionSourceManifestSHA256",
    "predecessorExecutionSHA256",
)


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


def build_causal_binding(execution: Mapping[str, Any]) -> str:
    return sha256_bytes(
        BUILD_CAUSAL_DOMAIN
        + canonical_bytes({key: execution[key] for key in BUILD_CAUSAL_FIELDS})
    )


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
    require_exact_keys(
        contract,
        (
            "schemaVersion",
            "suiteID",
            "buildConfiguration",
            "builderID",
            "canonicalManifestIdentityDomain",
            "candidateSourceArchiveFormat",
            "sourceTreeIdentityDomain",
            "capture",
            "cleanBuildCount",
            "cleanBuildIDs",
            "developmentArtifactDependencyCount",
            "p05ProductionDependencyCount",
            "productionSourceCount",
            "requiredRuntimeArtifactRoles",
            "runtimeID",
            "runtimeReleaseStatus",
            "sourceCheckoutState",
            "verification",
        ),
        "P06 reproduction contract",
    )
    require(contract.get("schemaVersion") == CONTRACT_SCHEMA, "unsupported P06 reproduction contract")
    require(contract.get("suiteID") == "mirmir-ash-v4-p06-reproduction-v2", "P06 suite identity mismatch")
    require(contract.get("buildConfiguration") == "Release", "P06 contract must require Release")
    require(
        contract.get("builderID") == "ash-p06-release-builder-v4-1",
        "P06 builder identity mismatch",
    )
    require(contract.get("sourceCheckoutState") == "clean", "P06 contract must require clean checkouts")
    require(
        contract.get("candidateSourceArchiveFormat") == "git-archive-tar-v1",
        "P06 source archive format mismatch",
    )
    require(
        contract.get("sourceTreeIdentityDomain") == "mirmir-source-tree-v1",
        "P06 source-tree identity domain mismatch",
    )
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
            "buildRunnerSHA256",
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
    required_verification = (
        "buildExecutionReceiptRequired",
        "buildOutputCausalBindingRequired",
        "buildTranscriptRequired",
        "byteIdenticalToShippingBundle",
        "independentBuildExecutionRequired",
        "productionLoaderAcceptanceRequired",
        "sameLengthArtifactTamperRejectionRequired",
        "sealedCandidateSourceArchiveRequired",
        "sealedCandidateSourceCommitObjectRequired",
        "sealedClosureRequired",
        "sourceManifestRecomputedFromSealedBytes",
        "toolchainProvenanceEqualityRequired",
    )
    require_exact_keys(verification, required_verification, "contract.verification")
    for key in required_verification:
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
    require(
        provenance.get("builderID") == "ash-p06-release-builder-v4-1",
        "runtime builder identity mismatch",
    )
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


def validate_build_qualification_markers(
    stdout: str,
    *,
    challenge: str,
    artifact_set_identity: str,
    runtime_manifest_file_identity: str,
    source_manifest_identity: str,
    identifier: str,
) -> None:
    markers: dict[str, str] = {}
    for line in stdout.splitlines():
        if not line.startswith("qualification_"):
            continue
        require("=" in line, f"{identifier} builder qualification marker is malformed")
        key, value = line.split("=", 1)
        require(
            key not in markers and value != "",
            f"{identifier} builder qualification marker is repeated or empty: {key}",
        )
        markers[key] = value
    expected = {
        "qualification_challenge": challenge,
        "qualification_runtime_artifact_set_sha256": artifact_set_identity,
        "qualification_runtime_manifest_file_sha256": runtime_manifest_file_identity,
        "qualification_production_source_manifest_sha256": source_manifest_identity,
    }
    require(
        markers == expected,
        f"{identifier} builder qualification challenge/output transcript differs",
    )


def git_blob_sha1(data: bytes) -> str:
    return hashlib.sha1(
        b"blob " + str(len(data)).encode("ascii") + b"\0" + data
    ).hexdigest()


def validate_source_commit_object(
    path: Path,
    candidate: Mapping[str, Any],
    checkout_tree_object: str,
) -> str:
    data = path.read_bytes()
    require(data, "sealed source commit object is empty")
    identity = hashlib.sha1(
        b"commit " + str(len(data)).encode("ascii") + b"\0" + data
    ).hexdigest()
    require(identity == candidate["sourceCommit"], "sealed source commit object identity differs from candidate")
    first_line = data.split(b"\n", 1)[0]
    require(
        first_line == f"tree {checkout_tree_object}".encode("ascii"),
        "sealed source commit does not name the reconstructed candidate tree",
    )
    return sha256_file(path)


def git_tree_sha1(listing: Mapping[str, tuple[str, str]]) -> str:
    root: dict[str, Any] = {}
    for relative, leaf in listing.items():
        components = PurePosixPath(relative).parts
        node = root
        for component in components[:-1]:
            existing = node.setdefault(component, {})
            require(isinstance(existing, dict), f"source tree path conflicts at {relative}")
            node = existing
        require(components[-1] not in node, f"source tree repeats {relative}")
        node[components[-1]] = leaf

    def tree_identity(node: Mapping[str, Any]) -> str:
        serialized = bytearray()
        ordered = sorted(
            node.items(),
            key=lambda item: item[0].encode("utf-8")
            + (b"/" if isinstance(item[1], dict) else b"\0"),
        )
        for name, value in ordered:
            encoded_name = name.encode("utf-8")
            if isinstance(value, dict):
                mode = b"40000"
                object_id = tree_identity(value)
            else:
                mode_text, object_id = value
                mode = mode_text.encode("ascii")
            serialized.extend(mode)
            serialized.extend(b" ")
            serialized.extend(encoded_name)
            serialized.extend(b"\0")
            serialized.extend(bytes.fromhex(object_id))
        payload = bytes(serialized)
        return hashlib.sha1(
            b"tree " + str(len(payload)).encode("ascii") + b"\0" + payload
        ).hexdigest()

    return tree_identity(root)


def parse_source_tree_listing(
    path: Path,
    candidate: Mapping[str, Any],
) -> tuple[dict[str, tuple[str, str]], str, str]:
    raw = path.read_bytes()
    require(raw and raw.endswith(b"\0"), "source tree listing is empty or unterminated")
    require(
        sha256_bytes(SOURCE_TREE_DOMAIN + raw)
        == candidate["sourceTreeIdentitySHA256"],
        "sealed source tree listing differs from the candidate tree identity",
    )
    entries: dict[str, tuple[str, str]] = {}
    for index, record in enumerate(raw[:-1].split(b"\0")):
        require(b"\t" in record, f"source tree listing[{index}] is malformed")
        header, encoded_path = record.split(b"\t", 1)
        components = header.split(b" ")
        require(len(components) == 3, f"source tree listing[{index}] header is malformed")
        mode_bytes, kind, object_id_bytes = components
        try:
            relative = encoded_path.decode("utf-8")
            mode = mode_bytes.decode("ascii")
            object_id = object_id_bytes.decode("ascii")
        except UnicodeDecodeError as error:
            raise EvidenceError(
                f"source tree listing[{index}] is not canonical UTF-8/ASCII"
            ) from error
        require_safe_relative(relative, f"source tree listing[{index}].path")
        require(relative not in entries, f"source tree listing repeats {relative}")
        require(kind == b"blob", f"source tree listing contains unsupported object {relative}")
        require(mode in ("100644", "100755"), f"source tree listing has unsupported mode for {relative}")
        require_hex(object_id, (40,), f"source tree listing[{index}].objectID")
        entries[relative] = (mode, object_id)
    require(entries, "source tree listing contains no source files")
    return entries, sha256_file(path), git_tree_sha1(entries)


def validate_source_archive(
    path: Path,
    listing: Mapping[str, tuple[str, str]],
    candidate: Mapping[str, Any],
) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    directories: set[str] = set()
    try:
        with tarfile.open(path, mode="r:") as archive:
            for index, member in enumerate(archive.getmembers()):
                relative = require_safe_relative(
                    member.name.rstrip("/"), f"source archive member[{index}].path"
                )
                require(
                    member.pax_headers == {"comment": candidate["sourceCommit"]},
                    f"source archive member is not bound to candidate commit: {relative}",
                )
                if member.isdir():
                    require(relative not in directories, f"source archive repeats directory {relative}")
                    directories.add(relative)
                    continue
                require(member.isfile(), f"source archive contains a non-file member: {relative}")
                require(relative not in files, f"source archive repeats file {relative}")
                stream = archive.extractfile(member)
                require(stream is not None, f"source archive cannot read {relative}")
                data = stream.read()
                expected = listing.get(relative)
                require(expected is not None, f"source archive adds a file outside the candidate tree: {relative}")
                expected_mode, expected_object = expected
                observed_mode = "100755" if member.mode & 0o111 else "100644"
                require(observed_mode == expected_mode, f"source archive mode differs for {relative}")
                require(git_blob_sha1(data) == expected_object, f"source archive bytes differ for {relative}")
                files[relative] = data
    except (tarfile.TarError, OSError) as error:
        raise EvidenceError(f"cannot validate sealed candidate source archive: {error}") from error
    require(set(files) == set(listing), "source archive file closure differs from candidate tree")
    expected_directories = {
        PurePosixPath(relative).parents[index].as_posix()
        for relative in files
        for index in range(len(PurePosixPath(relative).parents) - 1)
        if PurePosixPath(relative).parents[index].as_posix() != "."
    }
    require(directories == expected_directories, "source archive directory closure differs from candidate tree")
    return files


def validate_source_contract(
    source_contract: Mapping[str, Any],
    archive_files: Mapping[str, bytes],
) -> tuple[list[str], str, str]:
    require_exact_keys(
        source_contract,
        (
            "schemaVersion",
            "identityDomain",
            "coverage",
            "requiredAdditionalSources",
            "normalizedDeploymentTrustRoot",
            "sources",
        ),
        "source provenance contract",
    )
    require(
        source_contract.get("schemaVersion") == SOURCE_CONTRACT_SCHEMA,
        "source provenance contract schema mismatch",
    )
    require(
        source_contract.get("identityDomain") == SOURCE_IDENTITY_DOMAIN.decode("ascii"),
        "source provenance identity domain mismatch",
    )
    coverage = require_mapping(source_contract["coverage"], "source provenance coverage")
    require_exact_keys(coverage, ("roots", "fileExtensions"), "source provenance coverage")
    roots = require_list(coverage["roots"], "source provenance coverage roots")
    extensions = require_list(
        coverage["fileExtensions"], "source provenance coverage extensions"
    )
    require(roots == sorted(set(roots)) and roots, "source provenance roots are not closed and sorted")
    require(
        extensions == sorted(set(extensions)) and extensions,
        "source provenance extensions are not closed and sorted",
    )
    for index, root in enumerate(roots):
        require_safe_relative(root, f"source provenance root[{index}]")
    for index, extension in enumerate(extensions):
        require(
            isinstance(extension, str)
            and extension.startswith(".")
            and "/" not in extension,
            f"source provenance extension[{index}] is invalid",
        )
    additional = require_list(
        source_contract["requiredAdditionalSources"],
        "source provenance required additional sources",
    )
    sources = require_list(source_contract["sources"], "source provenance sources")
    for label, values in (("additional", additional), ("sources", sources)):
        for index, value in enumerate(values):
            require_safe_relative(value, f"source provenance {label}[{index}]")
        require(values == sorted(set(values)), f"source provenance {label} is not unique and sorted")
    discovered = set(additional)
    for relative in archive_files:
        if any(relative == root or relative.startswith(root + "/") for root in roots):
            if PurePosixPath(relative).suffix in extensions:
                discovered.add(relative)
    require(sources == sorted(discovered), "sealed source archive does not reproduce the P06 source closure")
    require(all(relative in archive_files for relative in sources), "sealed source archive omits a declared P06 source")
    normalized = require_mapping(
        source_contract["normalizedDeploymentTrustRoot"],
        "source provenance normalized trust root",
    )
    require_exact_keys(normalized, ("path", "assignments"), "source provenance normalized trust root")
    normalized_path = require_safe_relative(normalized["path"], "normalized trust-root path")
    require(normalized_path in sources, "normalized trust-root source is outside the P06 closure")
    require(
        normalized["assignments"]
        == ["builderSourceSHA256", "manifestSHA256", "sourceRevision"],
        "normalized deployment assignments differ",
    )
    return sources, normalized_path, sha256_bytes(canonical_bytes(source_contract))


def normalize_trust_roots(data: bytes) -> tuple[bytes, list[str]]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError("deployment trust-root source is not UTF-8") from error
    patterns = {
        "manifestSHA256": re.compile(
            r"static let manifestSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"
            r"(?:\"[0-9a-f]{64}\"|String\(repeating:\s*\"0\",\s*count:\s*64\))\s*\)",
            re.MULTILINE,
        ),
        "sourceRevision": re.compile(
            r"static let sourceRevision\s*=\s*"
            r"(?:\"[0-9a-f]{40,64}\"|String\(repeating:\s*\"0\",\s*count:\s*(?:40|64)\))",
            re.MULTILINE,
        ),
        "builderSourceSHA256": re.compile(
            r"static let builderSourceSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"
            r"(?:\"[0-9a-f]{64}\"|String\(repeating:\s*\"0\",\s*count:\s*64\))\s*\)",
            re.MULTILINE,
        ),
    }
    replacements = {
        "manifestSHA256": 'static let manifestSHA256 = try! ASHSHA256V4("__P06_MANIFEST_SHA256__")',
        "sourceRevision": 'static let sourceRevision = "__P06_SOURCE_REVISION__"',
        "builderSourceSHA256": 'static let builderSourceSHA256 = try! ASHSHA256V4("__P06_BUILDER_SHA256__")',
    }
    for assignment in ("builderSourceSHA256", "manifestSHA256", "sourceRevision"):
        text, count = patterns[assignment].subn(replacements[assignment], text)
        require(count == 1, f"deployment trust-root assignment is absent or repeated: {assignment}")
    return text.encode("utf-8"), ["builderSourceSHA256", "manifestSHA256", "sourceRevision"]


def recompute_production_source_manifest(
    source_contract: Mapping[str, Any],
    archive_files: Mapping[str, bytes],
) -> dict[str, Any]:
    sources, normalized_path, contract_identity = validate_source_contract(
        source_contract, archive_files
    )
    digest = hashlib.sha256()
    digest.update(SOURCE_IDENTITY_DOMAIN)
    digest.update(b"\0")
    digest.update(bytes.fromhex(contract_identity))
    entries: list[dict[str, Any]] = []
    for relative in sources:
        raw = archive_files[relative]
        normalized = raw
        normalizations: list[str] = []
        if relative == normalized_path:
            normalized, normalizations = normalize_trust_roots(raw)
        encoded_path = relative.encode("utf-8")
        digest.update(len(encoded_path).to_bytes(4, "big"))
        digest.update(encoded_path)
        digest.update(len(normalized).to_bytes(8, "big"))
        digest.update(normalized)
        entries.append(
            {
                "path": relative,
                "byteCount": len(raw),
                "sha256": sha256_bytes(raw),
                "normalizedByteCount": len(normalized),
                "normalizedSHA256": sha256_bytes(normalized),
                "normalizations": normalizations,
            }
        )
    return {
        "schemaVersion": SOURCE_MANIFEST_SCHEMA,
        "contractSemanticSHA256": contract_identity,
        "identityDomain": SOURCE_IDENTITY_DOMAIN.decode("ascii"),
        "sourceCount": len(entries),
        "sourceRevision": digest.hexdigest(),
        "sources": entries,
    }


def validate_production_source_manifest(
    path: Path,
    source_contract: Mapping[str, Any],
    candidate: Mapping[str, Any],
    required_count: int,
    archive_files: Mapping[str, bytes],
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
        == SOURCE_MANIFEST_SCHEMA,
        "production source manifest schema mismatch",
    )
    require(path.read_bytes() == canonical_bytes(document), "production source manifest is not canonical JSON")
    expected = recompute_production_source_manifest(source_contract, archive_files)
    require(document == expected, "production source manifest does not reproduce sealed source bytes")
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


def validate_build_execution(
    path: Path,
    *,
    identifier: str,
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    source_commit_object_identity: str,
    source_listing_identity: str,
    source_archive_identity: str,
    checkout_tree_object: str,
    transcript_path: Path,
    transcript_identity: str,
    artifact_set_identity: str,
    runtime_manifest_file_identity: str,
    source_manifest_identity: str,
) -> dict[str, Any]:
    execution = require_mapping(load_json(path), f"{identifier} build execution")
    require(
        path.read_bytes() == canonical_bytes(execution),
        f"{identifier} build execution is not canonical JSON",
    )
    require_exact_keys(
        execution,
        (
            "schemaVersion",
            "buildID",
            "invocationNonce",
            "captureProcessID",
            "processID",
            "startedAtUnixNanoseconds",
            "finishedAtUnixNanoseconds",
            "durationNanoseconds",
            "exitStatus",
            "workingDirectory",
            "buildOutputRoot",
            "buildChallenge",
            "archiveCommand",
            "buildCommand",
            "buildEnvironment",
            "sourceCommit",
            "sourceCommitObjectSHA256",
            "checkoutTreeObject",
            "sourceTreeIdentitySHA256",
            "sourceTreeListingSHA256",
            "sourceArchiveSHA256",
            "preBuildCheckoutStatusSHA256",
            "postBuildCheckoutStatusSHA256",
            "buildRunnerSHA256",
            "buildTranscriptSHA256",
            "runtimeArtifactSetSHA256",
            "runtimeManifestFileSHA256",
            "productionSourceManifestSHA256",
            "predecessorExecutionSHA256",
            "causalBindingSHA256",
        ),
        f"{identifier} build execution",
    )
    require(execution["schemaVersion"] == BUILD_EXECUTION_SCHEMA, f"{identifier} build execution schema mismatch")
    require(execution["buildID"] == identifier, f"{identifier} build execution identity mismatch")
    invocation_nonce = require_hex(
        execution["invocationNonce"], (64,), f"{identifier} invocation nonce"
    )
    capture_process = require_integer(
        execution["captureProcessID"], f"{identifier} capture process", 1
    )
    process_id = require_integer(execution["processID"], f"{identifier} process", 1)
    require(process_id != capture_process, f"{identifier} builder did not execute in a child process")
    started = require_integer(
        execution["startedAtUnixNanoseconds"], f"{identifier} start time", 1
    )
    finished = require_integer(
        execution["finishedAtUnixNanoseconds"], f"{identifier} finish time", 1
    )
    duration = require_integer(
        execution["durationNanoseconds"], f"{identifier} duration", 1
    )
    require(finished > started, f"{identifier} build interval is empty")
    require(
        duration <= finished - started,
        f"{identifier} monotonic duration exceeds its wall-clock interval",
    )
    require_integer(execution["exitStatus"], f"{identifier} exit status")
    require(execution["exitStatus"] == 0, f"{identifier} build command failed")

    working_text = require_string(execution["workingDirectory"], f"{identifier} working directory")
    output_text = require_string(execution["buildOutputRoot"], f"{identifier} output root")
    working = PurePosixPath(working_text)
    output = PurePosixPath(output_text)
    for value, label in ((working, "working directory"), (output, "output root")):
        require(value.is_absolute() and ".." not in value.parts, f"{identifier} {label} is not canonical absolute")
    require(working.name == f"{identifier}-worktree", f"{identifier} working directory token differs")
    require(output.name == f"{identifier}-outputs", f"{identifier} output directory token differs")
    require(working.parent == output.parent, f"{identifier} worktree/output roots are not isolated siblings")

    build_challenge = require_hex(
        execution["buildChallenge"], (64,), f"{identifier} build challenge"
    )
    build_environment = require_mapping(
        execution["buildEnvironment"], f"{identifier} build environment"
    )
    require_exact_keys(
        build_environment,
        ("MIRMIR_P06_BUILD_CHALLENGE",),
        f"{identifier} build environment",
    )
    require(
        build_environment["MIRMIR_P06_BUILD_CHALLENGE"] == build_challenge,
        f"{identifier} build challenge argv/environment binding differs",
    )

    archive_command = require_list(execution["archiveCommand"], f"{identifier} archive command")
    require(
        len(archive_command) == 6
        and archive_command[:4] == ["git", "archive", "--format=tar", "--output"]
        and archive_command[5] == "HEAD",
        f"{identifier} source archive command differs",
    )
    archive_output = PurePosixPath(
        require_string(archive_command[4], f"{identifier} archive output")
    )
    require(
        archive_output.is_absolute()
        and archive_output.name == "candidate-source.tar"
        and archive_output.parent.name == "source"
        and archive_output.parent.parent.name == identifier,
        f"{identifier} source archive output is not build-scoped",
    )
    build_command = require_list(execution["buildCommand"], f"{identifier} build command")
    expected_command = [
        str(working / "script/v4/build_p06_release_runtime.sh"),
        "--artifacts",
        str(output / "runtime-inputs"),
        "--output",
        str(output / "ASH-P06.bundle"),
        "--provenance",
        str(output / "provenance"),
        "--qualification-challenge",
        build_challenge,
    ]
    require(build_command == expected_command, f"{identifier} build argv differs")

    transcript = require_mapping(
        load_json(transcript_path), f"{identifier} build transcript"
    )
    require(
        transcript_path.read_bytes() == canonical_bytes(transcript),
        f"{identifier} build transcript is not canonical JSON",
    )
    require_exact_keys(
        transcript,
        (
            "schemaVersion",
            "command",
            "environment",
            "workingDirectory",
            "processID",
            "exitStatus",
            "stdoutByteCount",
            "stdoutSHA256",
            "stdout",
        ),
        f"{identifier} build transcript",
    )
    require(
        transcript["schemaVersion"] == BUILD_TRANSCRIPT_SCHEMA,
        f"{identifier} build transcript schema mismatch",
    )
    require(
        transcript["command"] == build_command
        and transcript["environment"] == build_environment
        and transcript["workingDirectory"] == working_text
        and transcript["processID"] == process_id
        and transcript["exitStatus"] == 0,
        f"{identifier} build transcript differs from its execution receipt",
    )
    stdout = require_string(transcript["stdout"], f"{identifier} build stdout") if transcript["stdout"] else ""
    stdout_bytes = stdout.encode("utf-8")
    require(
        require_integer(
            transcript["stdoutByteCount"], f"{identifier} build stdout byte count"
        )
        == len(stdout_bytes)
        and require_hex(
            transcript["stdoutSHA256"], (64,), f"{identifier} build stdout SHA-256"
        )
        == sha256_bytes(stdout_bytes),
        f"{identifier} build transcript stdout binding differs",
    )
    validate_build_qualification_markers(
        stdout,
        challenge=build_challenge,
        artifact_set_identity=artifact_set_identity,
        runtime_manifest_file_identity=runtime_manifest_file_identity,
        source_manifest_identity=source_manifest_identity,
        identifier=identifier,
    )

    require(execution["sourceCommit"] == candidate["sourceCommit"], f"{identifier} source commit differs")
    require(
        require_hex(
            execution["checkoutTreeObject"],
            (40,),
            f"{identifier} checkout tree object",
        )
        == checkout_tree_object,
        f"{identifier} checkout tree object does not reproduce the sealed candidate tree",
    )
    require(
        execution["sourceTreeIdentitySHA256"] == candidate["sourceTreeIdentitySHA256"],
        f"{identifier} source tree differs",
    )
    expected_empty_status = sha256_bytes(b"")
    for key in ("preBuildCheckoutStatusSHA256", "postBuildCheckoutStatusSHA256"):
        require(
            execution[key] == expected_empty_status,
            f"{identifier} checkout was not clean according to {key}",
        )
    bindings = {
        "sourceCommitObjectSHA256": source_commit_object_identity,
        "sourceTreeListingSHA256": source_listing_identity,
        "sourceArchiveSHA256": source_archive_identity,
        "buildRunnerSHA256": contract["capture"]["buildRunnerSHA256"],
        "buildTranscriptSHA256": transcript_identity,
        "runtimeArtifactSetSHA256": artifact_set_identity,
        "runtimeManifestFileSHA256": runtime_manifest_file_identity,
        "productionSourceManifestSHA256": source_manifest_identity,
    }
    for key, expected in bindings.items():
        require(execution[key] == expected, f"{identifier} execution binding differs for {key}")
    predecessor = require_hex(
        execution["predecessorExecutionSHA256"],
        (64,),
        f"{identifier} predecessor execution",
    )
    causal_binding = require_hex(
        execution["causalBindingSHA256"],
        (64,),
        f"{identifier} causal binding",
    )
    require(
        causal_binding == build_causal_binding(execution),
        f"{identifier} build causal binding differs",
    )
    return {
        "invocationNonce": invocation_nonce,
        "buildChallenge": build_challenge,
        "captureProcessID": capture_process,
        "processID": process_id,
        "startedAtUnixNanoseconds": started,
        "finishedAtUnixNanoseconds": finished,
        "workingDirectory": working_text,
        "buildOutputRoot": output_text,
        "executionSHA256": sha256_file(path),
        "checkoutTreeObject": checkout_tree_object,
        "predecessorExecutionSHA256": predecessor,
        "causalBindingSHA256": causal_binding,
    }


def validate_build(
    root: Path,
    sealed: set[Path],
    raw: Any,
    index: int,
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    source_contract: Mapping[str, Any],
) -> dict[str, Any]:
    label = f"build[{index}]"
    build = require_mapping(raw, label)
    require_exact_keys(
        build,
        (
            "id",
            "sourceCommit",
            "sourceCommitObjectSHA256",
            "sourceTreeIdentitySHA256",
            "sourceTreeListingSHA256",
            "sourceArchiveSHA256",
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
            "sourceCommitObjectArtifact",
            "sourceTreeListingArtifact",
            "sourceArchiveArtifact",
            "buildTranscriptArtifact",
            "buildExecutionArtifact",
            "releaseQualifiedStatus",
            "developmentArtifactDependencyCount",
            "p05ProductionDependencyCount",
        ),
        label,
    )
    identifier = require_string(build["id"], f"{label}.id")
    require(identifier == contract["cleanBuildIDs"][index], f"{label} identity/order mismatch")
    build_artifact_keys = (
        "artifactManifest",
        "runtimeManifestArtifact",
        "builderArtifact",
        "productionSourceArtifact",
        "toolchainImageArtifact",
        "loaderEvidenceArtifact",
        "sourceCommitObjectArtifact",
        "sourceTreeListingArtifact",
        "sourceArchiveArtifact",
        "buildTranscriptArtifact",
        "buildExecutionArtifact",
    )
    for artifact_key in build_artifact_keys:
        artifact_descriptor = require_mapping(
            build[artifact_key], f"{label}.{artifact_key}"
        )
        relative_artifact = require_safe_relative(
            artifact_descriptor.get("path"), f"{label}.{artifact_key}.path"
        )
        require(
            relative_artifact.startswith(identifier + "/"),
            f"{label}.{artifact_key} is not scoped to its build",
        )
    require(build["sourceCommit"] == candidate["sourceCommit"], f"{label} source commit differs")
    require(
        build["sourceTreeIdentitySHA256"] == candidate["sourceTreeIdentitySHA256"],
        f"{label} source tree differs",
    )
    source_listing_claim = require_hex(
        build["sourceTreeListingSHA256"], (64,), f"{label}.sourceTreeListingSHA256"
    )
    source_archive_claim = require_hex(
        build["sourceArchiveSHA256"], (64,), f"{label}.sourceArchiveSHA256"
    )
    source_commit_object_claim = require_hex(
        build["sourceCommitObjectSHA256"],
        (64,),
        f"{label}.sourceCommitObjectSHA256",
    )
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

    source_listing_path, source_listing_identity = require_sealed_descriptor(
        root,
        sealed,
        build["sourceTreeListingArtifact"],
        f"{label}.sourceTreeListingArtifact",
    )
    require(
        source_listing_identity == source_listing_claim,
        f"{label} source tree listing claim mismatch",
    )
    source_listing, recomputed_listing_identity, checkout_tree_object = parse_source_tree_listing(
        source_listing_path, candidate
    )
    require(
        recomputed_listing_identity == source_listing_identity,
        f"{label} source tree listing identity mismatch",
    )
    source_commit_object_path, source_commit_object_identity = require_sealed_descriptor(
        root,
        sealed,
        build["sourceCommitObjectArtifact"],
        f"{label}.sourceCommitObjectArtifact",
    )
    require(
        source_commit_object_identity == source_commit_object_claim,
        f"{label} source commit object claim mismatch",
    )
    require(
        validate_source_commit_object(
            source_commit_object_path, candidate, checkout_tree_object
        )
        == source_commit_object_identity,
        f"{label} source commit object identity mismatch",
    )
    source_archive_path, source_archive_identity = require_sealed_descriptor(
        root,
        sealed,
        build["sourceArchiveArtifact"],
        f"{label}.sourceArchiveArtifact",
    )
    require(
        source_archive_identity == source_archive_claim,
        f"{label} source archive claim mismatch",
    )
    archive_files = validate_source_archive(
        source_archive_path, source_listing, candidate
    )

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
        archive_files,
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
    build_transcript_path, build_transcript_identity = require_sealed_descriptor(
        root,
        sealed,
        build["buildTranscriptArtifact"],
        f"{label}.buildTranscriptArtifact",
    )
    try:
        build_transcript_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise EvidenceError(f"{label} build transcript is not readable UTF-8: {error}") from error
    build_execution_path, _ = require_sealed_descriptor(
        root,
        sealed,
        build["buildExecutionArtifact"],
        f"{label}.buildExecutionArtifact",
    )
    execution = validate_build_execution(
        build_execution_path,
        identifier=identifier,
        candidate=candidate,
        contract=contract,
        source_commit_object_identity=source_commit_object_identity,
        source_listing_identity=source_listing_identity,
        source_archive_identity=source_archive_identity,
        checkout_tree_object=checkout_tree_object,
        transcript_path=build_transcript_path,
        transcript_identity=build_transcript_identity,
        artifact_set_identity=artifact_set_claim,
        runtime_manifest_file_identity=runtime_file_identity,
        source_manifest_identity=source_manifest_identity,
    )
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
        "sourceTree": candidate["sourceTreeIdentitySHA256"],
        "sourceCommitObject": source_commit_object_identity,
        "sourceTreeListing": source_listing_identity,
        "sourceArchive": source_archive_identity,
        "checkoutTreeObject": checkout_tree_object,
        "toolchain": toolchain_identity,
        **execution,
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
            "sourceEvidence",
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
        "buildRunnerSHA256": "build-runner.sh",
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

    source_evidence = require_mapping(report.get("sourceEvidence"), "report.sourceEvidence")
    require_exact_keys(
        source_evidence,
        (
            "sourceCommit",
            "sourceTreeIdentitySHA256",
            "sourceCommitObjectSHA256",
            "sourceTreeListingSHA256",
            "sourceArchiveSHA256",
            "sourceArchiveFormat",
        ),
        "report.sourceEvidence",
    )
    require(
        source_evidence["sourceCommit"] == candidate["sourceCommit"],
        "P06 source evidence commit differs from candidate",
    )
    require(
        source_evidence["sourceTreeIdentitySHA256"]
        == candidate["sourceTreeIdentitySHA256"],
        "P06 source evidence tree differs from candidate",
    )
    require_hex(
        source_evidence["sourceCommitObjectSHA256"],
        (64,),
        "report.sourceEvidence.sourceCommitObjectSHA256",
    )
    require_hex(
        source_evidence["sourceTreeListingSHA256"],
        (64,),
        "report.sourceEvidence.sourceTreeListingSHA256",
    )
    require_hex(
        source_evidence["sourceArchiveSHA256"],
        (64,),
        "report.sourceEvidence.sourceArchiveSHA256",
    )
    require(
        source_evidence["sourceArchiveFormat"]
        == contract["candidateSourceArchiveFormat"],
        "P06 source archive format differs from contract",
    )

    builds = require_list(report.get("builds"), "report.builds")
    require(len(builds) == contract["cleanBuildCount"], "P06 clean-build count mismatch")
    summaries = [
        validate_build(root, sealed, raw, index, candidate, contract, source_contract)
        for index, raw in enumerate(builds)
    ]
    for key in (
        "artifactSet",
        "manifest",
        "builder",
        "sourceManifest",
        "sourceTree",
        "sourceCommitObject",
        "sourceTreeListing",
        "sourceArchive",
        "checkoutTreeObject",
        "toolchain",
    ):
        require(len({summary[key] for summary in summaries}) == 1, f"clean builds differ in {key}")
    require(
        summaries[0]["sourceCommitObject"]
        == source_evidence["sourceCommitObjectSHA256"]
        and summaries[0]["sourceTreeListing"]
        == source_evidence["sourceTreeListingSHA256"]
        and summaries[0]["sourceArchive"] == source_evidence["sourceArchiveSHA256"],
        "P06 source evidence summary differs from clean builds",
    )
    for key in (
        "invocationNonce",
        "buildChallenge",
        "processID",
        "executionSHA256",
        "causalBindingSHA256",
        "workingDirectory",
        "buildOutputRoot",
    ):
        require(
            len({summary[key] for summary in summaries}) == len(summaries),
            f"clean builds reused {key}",
        )
    require(
        len({summary["captureProcessID"] for summary in summaries}) == 1,
        "clean builds do not belong to one capture process",
    )
    predecessor = "0" * 64
    for summary in summaries:
        require(
            summary["predecessorExecutionSHA256"] == predecessor,
            "clean build causal execution chain differs",
        )
        predecessor = summary["executionSHA256"]
    for first, second in zip(summaries, summaries[1:]):
        require(
            first["finishedAtUnixNanoseconds"]
            <= second["startedAtUnixNanoseconds"],
            "clean build execution intervals overlap or are reordered",
        )
    require_bool(report.get("productionLoaderAcceptancePass"), "report.productionLoaderAcceptancePass", True)
    require_bool(report.get("tamperRejectionPass"), "report.tamperRejectionPass", True)
    require_bool(report.get("p06ReproductionGatePass"), "report.p06ReproductionGatePass", True)
    return {
        "schemaVersion": VERIFICATION_SCHEMA,
        "candidateSourceCommit": candidate["sourceCommit"],
        "candidateSourceCommitObjectSHA256": summaries[0]["sourceCommitObject"],
        "candidateSourceTreeIdentitySHA256": summaries[0]["sourceTree"],
        "candidateSourceTreeListingSHA256": summaries[0]["sourceTreeListing"],
        "candidateSourceArchiveSHA256": summaries[0]["sourceArchive"],
        "cleanBuildCount": len(summaries),
        "independentBuildExecutionCount": len(
            {summary["executionSHA256"] for summary in summaries}
        ),
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
