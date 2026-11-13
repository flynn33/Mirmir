#!/usr/bin/env python3
"""Capture quality, parity, performance, or media evidence from the exact app.

The observer is compiled into the shipping target.  This harness verifies and
extracts the sealed application archive, stages immutable inputs inside the
application sandbox, invokes that exact executable, and seals both the request
and the resulting pixel tree.  A testability-enabled rebuild is never an
admissible producer for this evidence.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping, Sequence
import uuid


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
PROVENANCE_SPEC = importlib.util.spec_from_file_location(
    "release_candidate_archive_v4",
    SCRIPT_DIRECTORY / "release_candidate_archive_v4.py",
)
if PROVENANCE_SPEC is None or PROVENANCE_SPEC.loader is None:
    raise RuntimeError("cannot load release archive provenance implementation")
archive_provenance = importlib.util.module_from_spec(PROVENANCE_SPEC)
sys.modules[PROVENANCE_SPEC.name] = archive_provenance
PROVENANCE_SPEC.loader.exec_module(archive_provenance)


REQUEST_SCHEMA = "mirmir-v4-packaged-evidence-request-v1"
RESULT_SCHEMA = "mirmir-v4-packaged-evidence-result-v1"
PACKAGE_SCHEMA = "mirmir-v4-packaged-candidate-identity-v1"
CAPTURE_RECORD_SCHEMA = "mirmir-v4-packaged-evidence-capture-record-v1"
RESULT_PREFIX = b"MIRMIR_V4_PACKAGED_EVIDENCE_RESULT "
ERROR_PREFIX = b"MIRMIR_V4_PACKAGED_EVIDENCE_ERROR "
CAPTURE_TREE_DOMAIN = b"mirmir-packaged-capture-tree-v1\0"
OBSERVER_SOURCE_PATH = "Mirmir/App/MirmirApp.swift"
RECOVERY_PRODUCER_SOURCE_PATH = (
    "Mirmir/App/WorkflowApplicationCoordinatorV4.swift"
)
MAX_CAPTURE_BYTES = 8 * 1024 * 1024 * 1024
MAX_INPUT_BYTES = 8 * 1024 * 1024 * 1024
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
PACKAGE_FIELDS = {
    "schemaVersion",
    "buildConfiguration",
    "applicationArchiveSHA256",
    "applicationPayloadIdentitySHA256",
    "applicationInfoPlistSHA256",
    "applicationExecutableSHA256",
    "codeDirectories",
    "codeDirectorySetSHA256",
    "designatedRequirementSHA256",
    "releaseConfigurationSHA256",
    "attestationSHA256",
    "sourceCommit",
    "sourceTreeIdentitySHA256",
    "runtimeManifestSHA256",
    "runtimeManifestFileSHA256",
    "runtimeArtifactSetSHA256",
    "runtimeSourceRevision",
    "bundleIdentifier",
    "productVersion",
    "productBuild",
}


class PackagedEvidenceError(ValueError):
    """The exact packaged candidate did not produce admissible evidence."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PackagedEvidenceError(message)


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value: str) -> None:
    raise PackagedEvidenceError(f"non-finite JSON value is forbidden: {value}")


def load_json_bytes(raw: bytes, label: str) -> Any:
    try:
        return json.loads(
            raw,
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PackagedEvidenceError(f"cannot decode {label}: {error}") from error


def load_json(path: Path, label: str) -> Any:
    try:
        return load_json_bytes(path.read_bytes(), label)
    except OSError as error:
        raise PackagedEvidenceError(f"cannot read {label}: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def write_canonical(path: Path, value: Any) -> None:
    require(not path.exists(), f"refusing to overwrite evidence: {path}")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(canonical_bytes(value))
    path.chmod(0o600)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_hex(value: Any, lengths: Sequence[int], label: str) -> str:
    require(
        isinstance(value, str)
        and len(value) in lengths
        and set(value) <= HEX,
        f"{label} is not lowercase hexadecimal",
    )
    return value


def require_exact_keys(value: Mapping[str, Any], keys: set[str], label: str) -> None:
    observed = set(value)
    require(
        observed == keys,
        f"{label} field set differs; missing={sorted(keys - observed)}, "
        f"unexpected={sorted(observed - keys)}",
    )


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} is not an object")
    return value


def safe_regular(path: Path, label: str, *, executable: bool = False) -> Path:
    expanded = path.expanduser()
    try:
        lexical_metadata = expanded.lstat()
    except OSError as error:
        raise PackagedEvidenceError(f"cannot inspect {label}: {error}") from error
    require(
        stat.S_ISREG(lexical_metadata.st_mode)
        and not stat.S_ISLNK(lexical_metadata.st_mode),
        f"{label} is a symbolic link or non-regular file",
    )
    resolved = expanded.resolve(strict=True)
    metadata = resolved.stat()
    require(
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_nlink == 1
        and not resolved.is_symlink(),
        f"{label} is not a single-link regular file",
    )
    if executable:
        require(os.access(resolved, os.X_OK), f"{label} is not executable")
    return resolved


def safe_directory(path: Path, label: str) -> Path:
    expanded = path.expanduser()
    try:
        lexical_metadata = expanded.lstat()
    except OSError as error:
        raise PackagedEvidenceError(f"cannot inspect {label}: {error}") from error
    require(
        stat.S_ISDIR(lexical_metadata.st_mode)
        and not stat.S_ISLNK(lexical_metadata.st_mode),
        f"{label} is a symbolic link or non-directory",
    )
    resolved = expanded.resolve(strict=True)
    require(resolved.is_dir(), f"{label} is not a directory")
    return resolved


def copy_regular(source: Path, destination: Path, label: str) -> None:
    source = safe_regular(source, label)
    require(not destination.exists(), f"refusing to overwrite {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copyfile(source, destination)
    destination.chmod(0o600)
    require(
        sha256_file(source) == sha256_file(destination),
        f"{label} identity changed while copying",
    )


def committed_bytes(repository: Path, commit: str, relative: str) -> bytes:
    process = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    require(
        process.returncode == 0,
        f"candidate commit omits {relative}: "
        + process.stderr.decode("utf-8", errors="replace").strip(),
    )
    return process.stdout


def parse_candidate(path: Path) -> dict[str, Any]:
    document = require_mapping(load_json(path, "candidate identity"), "candidate identity")
    value = document.get("candidate", document)
    candidate = require_mapping(value, "candidate")
    require_exact_keys(candidate, CANDIDATE_FIELDS, "candidate")
    require_hex(candidate["sourceCommit"], (40,), "candidate.sourceCommit")
    for key in (
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
    ):
        require_hex(candidate[key], (64,), f"candidate.{key}")
    require_hex(
        candidate["runtimeSourceRevision"],
        (40, 64),
        "candidate.runtimeSourceRevision",
    )
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require(
            isinstance(candidate[key], str) and candidate[key],
            f"candidate.{key} is empty",
        )
    return dict(candidate)


def package_identity(
    candidate: Mapping[str, Any], inspection: Mapping[str, Any]
) -> dict[str, Any]:
    attestation = require_mapping(inspection.get("attestation"), "archive attestation")
    application = require_mapping(attestation.get("application"), "attested application")
    payload = require_mapping(attestation.get("archivePayload"), "attested archive payload")
    source = require_mapping(attestation.get("source"), "attested source")
    runtime = require_mapping(attestation.get("runtime"), "attested runtime")
    release = require_mapping(
        attestation.get("releaseConfiguration"), "attested release configuration"
    )
    code_directories = application.get("codeDirectories")
    require(isinstance(code_directories, list) and code_directories, "CodeDirectories are absent")
    package = {
        "schemaVersion": PACKAGE_SCHEMA,
        "buildConfiguration": attestation.get("buildConfiguration"),
        "applicationArchiveSHA256": inspection.get("appBundleSHA256"),
        "applicationPayloadIdentitySHA256": payload.get("identitySHA256"),
        "applicationInfoPlistSHA256": application.get("infoPlistSHA256"),
        "applicationExecutableSHA256": application.get("executableSHA256"),
        "codeDirectories": code_directories,
        "codeDirectorySetSHA256": application.get("codeDirectorySetSHA256"),
        "designatedRequirementSHA256": application.get(
            "designatedRequirementSHA256"
        ),
        "releaseConfigurationSHA256": release.get("sha256"),
        "attestationSHA256": inspection.get("attestationSHA256"),
        "sourceCommit": source.get("commit"),
        "sourceTreeIdentitySHA256": source.get("treeIdentitySHA256"),
        "runtimeManifestSHA256": runtime.get("manifestSHA256"),
        "runtimeManifestFileSHA256": runtime.get("manifestFileSHA256"),
        "runtimeArtifactSetSHA256": runtime.get("artifactSetSHA256"),
        "runtimeSourceRevision": runtime.get("sourceRevision"),
        "bundleIdentifier": application.get("bundleIdentifier"),
        "productVersion": application.get("productVersion"),
        "productBuild": application.get("productBuild"),
    }
    validate_package_identity(package)
    candidate_projection = {
        "sourceCommit": package["sourceCommit"],
        "sourceTreeIdentitySHA256": package["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": package["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": package["runtimeManifestFileSHA256"],
        "runtimeArtifactSetSHA256": package["runtimeArtifactSetSHA256"],
        "runtimeSourceRevision": package["runtimeSourceRevision"],
        "releaseConfigurationSHA256": package["releaseConfigurationSHA256"],
        "appBundleSHA256": package["applicationArchiveSHA256"],
        "bundleIdentifier": package["bundleIdentifier"],
        "productVersion": package["productVersion"],
        "productBuild": package["productBuild"],
    }
    require(
        dict(candidate) == candidate_projection,
        "candidate record differs from the verified application archive",
    )
    return package


def validate_package_identity(value: Any) -> dict[str, Any]:
    package = require_mapping(value, "packaged candidate identity")
    require_exact_keys(package, PACKAGE_FIELDS, "packaged candidate identity")
    require(package["schemaVersion"] == PACKAGE_SCHEMA, "package schema differs")
    require(package["buildConfiguration"] == "Release", "package is not Release")
    require_hex(package["sourceCommit"], (40,), "package.sourceCommit")
    require_hex(package["runtimeSourceRevision"], (40, 64), "package runtime source")
    for key in PACKAGE_FIELDS - {
        "schemaVersion",
        "buildConfiguration",
        "sourceCommit",
        "runtimeSourceRevision",
        "bundleIdentifier",
        "productVersion",
        "productBuild",
        "codeDirectories",
    }:
        require_hex(package[key], (64,), f"package.{key}")
    rows = package["codeDirectories"]
    require(isinstance(rows, list) and rows, "package CodeDirectories are absent")
    expected_architectures: list[str] = []
    for index, item in enumerate(rows):
        row = require_mapping(item, f"package CodeDirectory {index}")
        require_exact_keys(row, {"architecture", "sha256"}, "package CodeDirectory")
        architecture = row["architecture"]
        require(
            isinstance(architecture, str)
            and architecture
            and all(character.isalnum() or character == "_" for character in architecture),
            "package CodeDirectory architecture is invalid",
        )
        require_hex(row["sha256"], (64,), "package CodeDirectory")
        expected_architectures.append(architecture)
    require(
        expected_architectures == sorted(set(expected_architectures)),
        "package CodeDirectories are not uniquely sorted",
    )
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require(isinstance(package[key], str) and package[key], f"package.{key} is empty")
    return dict(package)


def inspected_package(
    repository: Path,
    candidate_path: Path,
    archive: Path,
    runtime: Path,
    release_configuration: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, str], list[dict[str, Any]]]:
    repository = repository.expanduser().resolve(strict=True)
    candidate = parse_candidate(safe_regular(candidate_path, "candidate record"))
    archive = safe_regular(archive, "application archive")
    runtime = runtime.expanduser().resolve(strict=True)
    release_configuration = safe_regular(
        release_configuration, "release configuration"
    )
    context = archive_provenance.release_context(
        repository,
        candidate["sourceCommit"],
        runtime,
        release_configuration,
    )
    tools = archive_provenance.tool_descriptors(repository, context["sourceCommit"])
    inspection = archive_provenance.inspect_archive(
        archive,
        context,
        tools,
        require_attestation=True,
    )
    return candidate, package_identity(candidate, inspection), context, tools


def safe_relative(value: Any, label: str) -> PurePosixPath:
    require(isinstance(value, str) and value, f"{label} is empty")
    path = PurePosixPath(value)
    require(
        not path.is_absolute()
        and ".." not in path.parts
        and "." not in path.parts
        and all(part not in ("", ".", "..") for part in path.parts),
        f"{label} is unsafe",
    )
    return path


def stage_quality_corpus(manifest: Path, destination: Path) -> Path:
    manifest = safe_regular(manifest, "quality corpus manifest")
    value = require_mapping(load_json(manifest, "quality corpus manifest"), "quality corpus manifest")
    require(
        value.get("schemaVersion") == "mirmir-ash-v4-quality-corpus-v1",
        "quality corpus schema differs",
    )
    cases = value.get("cases")
    require(isinstance(cases, list) and cases, "quality corpus cases are absent")
    relatives: set[PurePosixPath] = set()
    for index, item in enumerate(cases):
        case = require_mapping(item, f"quality corpus case {index}")
        relatives.add(safe_relative(case.get("sourceFile"), "quality source file"))
        relatives.add(safe_relative(case.get("referenceFile"), "quality reference file"))
    staged_manifest = destination / "corpus-manifest.json"
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    copy_regular(manifest, staged_manifest, "quality corpus manifest")
    total = staged_manifest.stat().st_size
    root = manifest.parent.resolve(strict=True)
    for relative in sorted(relatives, key=str):
        source = root.joinpath(*relative.parts)
        resolved = safe_regular(source, f"quality corpus artifact {relative}")
        require(root in resolved.parents, f"quality corpus artifact escapes root: {relative}")
        total += resolved.stat().st_size
        require(total <= MAX_INPUT_BYTES, "quality corpus exceeds 8 GiB")
        copy_regular(
            resolved,
            destination.joinpath(*relative.parts),
            f"quality corpus artifact {relative}",
        )
    return staged_manifest


def stage_parity_contract(contract: Path, destination: Path) -> Path:
    contract = safe_regular(contract, "parity contract")
    value = require_mapping(load_json(contract, "parity contract"), "parity contract")
    schema = value.get("schemaVersion")
    require(schema in {"mirmir-ash-v4-cpu-metal-parity-contract-v2", "mirmir-ash-v4-cpu-metal-parity-contract-v3"},
            "parity contract schema differs")
    phase2 = schema == "mirmir-ash-v4-cpu-metal-parity-contract-v3"
    if phase2:
        tools = require_mapping(value.get("tools"), "parity contract tools")
        require_exact_keys(tools, {"captureSourceSHA256", "evaluatorSHA256", "runnerSHA256", "chromaGeometryValidatorSHA256"}, "parity contract tools")
        for key, value in tools.items(): require_hex(value, (64,), f"parity contract {key}")
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    staged = destination / ("cpu-metal-parity-contract-v3.json" if phase2 else "cpu-metal-parity-contract-v2.json")
    copy_regular(contract, staged, "parity contract")
    return staged


def stage_recovery_contract(contract: Path, destination: Path) -> Path:
    contract = safe_regular(contract, "recovery contract")
    value = require_mapping(
        load_json(contract, "recovery contract"), "recovery contract"
    )
    require(
        value.get("schemaVersion")
        == "mirmir-v4-recovery-qualification-contract-v2",
        "recovery contract schema differs",
    )
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    staged = destination / "recovery-qualification-contract-v1.json"
    copy_regular(contract, staged, "recovery contract")
    return staged


def stage_performance_input(
    contract: Path, input_path: Path, destination: Path
) -> Path:
    contract_value = require_mapping(
        load_json(contract, "performance contract"), "performance contract"
    )
    require(
        contract_value.get("schemaVersion")
        == "mirmir-v4-performance-gate-contract-v1",
        "performance contract schema differs",
    )
    workload = require_mapping(
        contract_value.get("workload"), "performance workload"
    )
    expected = require_mapping(
        workload.get("input"), "performance input contract"
    )
    input_path = safe_regular(input_path, "performance input")
    require(
        input_path.stat().st_size == expected.get("byteCount")
        and sha256_file(input_path) == expected.get("sha256"),
        "performance input identity differs from the contract",
    )
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    staged = destination / "end-to-end-input.mov"
    copy_regular(input_path, staged, "performance input")
    return staged


def stage_media_fixture_package(
    contract: Path, manifest: Path, destination: Path
) -> Path:
    contract = safe_regular(contract, "media contract")
    contract_value = require_mapping(
        load_json(contract, "media contract"), "media contract"
    )
    require(
        contract_value.get("schemaVersion")
        == "mirmir-ash-v4-media-preservation-contract-v1",
        "media contract schema differs",
    )
    manifest = safe_regular(manifest, "media fixture manifest")
    value = require_mapping(
        load_json(manifest, "media fixture manifest"),
        "media fixture manifest",
    )
    require(
        value.get("schemaVersion")
        == "mirmir-ash-v4-media-fixture-package-v2"
        and value.get("suiteID") == contract_value.get("suiteID"),
        "media fixture package header differs",
    )
    fixtures = value.get("fixtures")
    require(
        isinstance(fixtures, list) and len(fixtures) == 6,
        "media fixture package must contain six fixtures",
    )
    relatives: set[PurePosixPath] = set()
    identities: dict[PurePosixPath, tuple[int, str]] = {}
    for index, raw in enumerate(fixtures):
        fixture = require_mapping(raw, f"media fixture {index}")
        relative = safe_relative(
            fixture.get("sourceFile"), f"media fixture {index} source"
        )
        byte_count = fixture.get("sourceByteCount")
        identity = fixture.get("sourceSHA256")
        require(
            isinstance(byte_count, int) and byte_count > 0,
            f"media fixture {index} byte count is invalid",
        )
        require_hex(identity, (64,), f"media fixture {index} identity")
        relatives.add(relative)
        identities[relative] = (byte_count, identity)
        alpha = fixture.get("alphaOracleInput")
        if alpha is not None:
            alpha = require_mapping(alpha, f"media fixture {index} alpha")
            alpha_relative = safe_relative(
                alpha.get("path"), f"media fixture {index} alpha path"
            )
            alpha_count = alpha.get("byteCount")
            alpha_identity = alpha.get("sha256")
            require(
                isinstance(alpha_count, int) and alpha_count > 0,
                f"media fixture {index} alpha byte count is invalid",
            )
            require_hex(
                alpha_identity, (64,), f"media fixture {index} alpha identity"
            )
            relatives.add(alpha_relative)
            identities[alpha_relative] = (alpha_count, alpha_identity)
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    staged_manifest = destination / "fixture-manifest.json"
    copy_regular(manifest, staged_manifest, "media fixture manifest")
    copy_regular(
        contract,
        destination / "media-preservation-contract-v1.json",
        "media contract",
    )
    total = staged_manifest.stat().st_size + contract.stat().st_size
    root = manifest.parent.resolve(strict=True)
    for relative in sorted(relatives, key=str):
        source = safe_regular(
            root.joinpath(*relative.parts), f"media fixture artifact {relative}"
        )
        require(
            root in source.parents,
            f"media fixture artifact escapes package: {relative}",
        )
        expected_count, expected_sha = identities[relative]
        require(
            source.stat().st_size == expected_count
            and sha256_file(source) == expected_sha,
            f"media fixture artifact identity differs: {relative}",
        )
        total += source.stat().st_size
        require(total <= MAX_INPUT_BYTES, "media fixture package exceeds 8 GiB")
        copy_regular(
            source,
            destination.joinpath(*relative.parts),
            f"media fixture artifact {relative}",
        )
    return staged_manifest


def input_tree_sha256(root: Path) -> str:
    root = safe_directory(root, "packaged input root")
    rows: list[tuple[str, str, Path | None]] = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = Path(directory)
        names.sort()
        files.sort()
        for name in names:
            path = directory_path / name
            metadata = path.lstat()
            require(stat.S_ISDIR(metadata.st_mode), f"input entry is unsafe: {path}")
            rows.append((path.relative_to(root).as_posix(), "directory", None))
        for name in files:
            path = directory_path / name
            metadata = path.lstat()
            require(
                stat.S_ISREG(metadata.st_mode)
                and metadata.st_nlink == 1
                and not path.is_symlink(),
                f"input file is unsafe: {path}",
            )
            rows.append((path.relative_to(root).as_posix(), "file", path))
    digest = hashlib.sha256()
    digest.update(b"mirmir-packaged-input-tree-v1\0")
    for relative, kind, path in sorted(rows):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if kind == "directory":
            digest.update(b"directory\n")
        else:
            assert path is not None
            digest.update(b"file\0")
            digest.update(sha256_file(path).encode("ascii"))
            digest.update(b"\n")
    return digest.hexdigest()


def application_support_root(bundle_identifier: str) -> Path:
    require(
        all(character.isalnum() or character in ".-" for character in bundle_identifier),
        "bundle identifier is unsafe",
    )
    return (
        Path.home()
        / "Library"
        / "Containers"
        / bundle_identifier
        / "Data"
        / "Library"
        / "Application Support"
    )


def capture_tree(root: Path) -> dict[str, Any]:
    root = safe_directory(root, "capture root")
    rows: list[tuple[str, str, Path | None]] = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = Path(directory)
        names.sort()
        files.sort()
        for name in names:
            path = directory_path / name
            metadata = path.lstat()
            require(stat.S_ISDIR(metadata.st_mode), f"capture entry is unsafe: {path}")
            relative = path.relative_to(root).as_posix()
            rows.append((relative, "directory", None))
        for name in files:
            path = directory_path / name
            metadata = path.lstat()
            require(
                stat.S_ISREG(metadata.st_mode)
                and metadata.st_nlink == 1
                and not path.is_symlink(),
                f"capture file is unsafe: {path}",
            )
            rows.append((path.relative_to(root).as_posix(), "file", path))
    digest = hashlib.sha256()
    digest.update(CAPTURE_TREE_DOMAIN)
    byte_count = 0
    file_count = 0
    for relative, kind, path in sorted(rows):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if kind == "directory":
            digest.update(b"directory\n")
        else:
            assert path is not None
            size = path.stat().st_size
            byte_count += size
            file_count += 1
            require(byte_count <= MAX_CAPTURE_BYTES, "capture tree exceeds 8 GiB")
            digest.update(b"file\0")
            digest.update(sha256_file(path).encode("ascii"))
            digest.update(b"\n")
    return {
        "byteCount": byte_count,
        "fileCount": file_count,
        "sha256": digest.hexdigest(),
    }


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    path = safe_regular(path, "evidence artifact")
    relative = path.relative_to(root.resolve()).as_posix()
    return {
        "path": relative,
        "byteCount": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def copy_capture_tree(source: Path, destination: Path) -> None:
    require(not destination.exists(), f"capture destination exists: {destination}")
    destination.mkdir(parents=True, mode=0o700)
    for directory, names, files in os.walk(source, topdown=True, followlinks=False):
        directory_path = Path(directory)
        relative_directory = directory_path.relative_to(source)
        names.sort()
        files.sort()
        for name in names:
            child = directory_path / name
            metadata = child.lstat()
            require(stat.S_ISDIR(metadata.st_mode), f"capture directory is unsafe: {child}")
            destination.joinpath(relative_directory, name).mkdir(mode=0o700)
        for name in files:
            child = directory_path / name
            copy_regular(
                child,
                destination.joinpath(relative_directory, name),
                f"capture artifact {child.relative_to(source)}",
            )


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_request(
    lane: str,
    package: Mapping[str, Any],
    contract_sha: str,
    observer_source_sha: str,
    request_id: str,
    root: Path,
    staged_input: Path,
    *,
    performance_source_identity_sha: str | None = None,
    performance_capture_source_sha: str | None = None,
    warmup_count: int | None = None,
    sample_count: int | None = None,
    media_fixture_source_sha: str | None = None,
    media_generator_source_sha: str | None = None,
    recovery_producer_source_sha: str | None = None,
) -> dict[str, Any]:
    output = root / "capture"
    if lane == "quality":
        environment = {
            "MIRMIR_V4_QUALITY_CAPTURE_DIR": str(output),
            "MIRMIR_V4_QUALITY_CORPUS_MANIFEST": str(staged_input),
            "MIRMIR_V4_QUALITY_CONTRACT_SHA256": contract_sha,
            "MIRMIR_V4_QUALITY_SOURCE_COMMIT": package["sourceCommit"],
            "MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256": package[
                "sourceTreeIdentitySHA256"
            ],
        }
    elif lane == "parity":
        environment = {
            "MIRMIR_PARITY_CAPTURE_DIRECTORY": str(output),
            "MIRMIR_PARITY_CONTRACT_PATH": str(staged_input),
            "MIRMIR_PARITY_CONTRACT_SHA256": contract_sha,
            "MIRMIR_PARITY_CAPTURE_SOURCE_SHA256": observer_source_sha,
            "MIRMIR_PARITY_SOURCE_REVISION": package["sourceCommit"],
            "MIRMIR_PARITY_BUILD_CONFIGURATION": "Release",
            "MIRMIR_PARITY_PROCESS_RUN_ID": str(uuid.uuid4()),
            "MIRMIR_PARITY_RUNTIME_MODE": "production",
        }
    elif lane == "performance":
        require(
            performance_source_identity_sha is not None
            and performance_capture_source_sha is not None
            and warmup_count is not None
            and sample_count is not None,
            "performance request inputs are incomplete",
        )
        environment = {
            "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR": str(output),
            "MIRMIR_V4_PERFORMANCE_INPUT": str(staged_input),
            "MIRMIR_V4_PERFORMANCE_VARIANT": "candidate_p06",
            "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256": contract_sha,
            "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256":
                performance_capture_source_sha,
            "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256":
                performance_source_identity_sha,
            "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION": package["sourceCommit"],
            "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256": package[
                "sourceTreeIdentitySHA256"
            ],
            "MIRMIR_V4_PERFORMANCE_WARMUPS": str(warmup_count),
            "MIRMIR_V4_PERFORMANCE_SAMPLES": str(sample_count),
        }
    elif lane == "media":
        require(
            media_fixture_source_sha is not None
            and media_generator_source_sha is not None,
            "media request inputs are incomplete",
        )
        environment = {
            "MIRMIR_V4_MEDIA_CAPTURE_DIR": str(output),
            "MIRMIR_V4_MEDIA_CONTRACT_PATH": str(
                staged_input.parent / "media-preservation-contract-v1.json"
            ),
            "MIRMIR_V4_MEDIA_CONTRACT_SHA256": contract_sha,
            "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST": str(staged_input),
            "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST_SHA256": sha256_file(
                staged_input
            ),
            "MIRMIR_V4_MEDIA_FIXTURE_TREE_SHA256": input_tree_sha256(
                staged_input.parent
            ),
            "MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256":
                media_fixture_source_sha,
            "MIRMIR_V4_MEDIA_GENERATOR_SOURCE_SHA256":
                media_generator_source_sha,
            "MIRMIR_V4_MEDIA_SOURCE_COMMIT": package["sourceCommit"],
            "MIRMIR_V4_MEDIA_SOURCE_TREE_SHA256": package[
                "sourceTreeIdentitySHA256"
            ],
        }
    else:
        require(
            lane == "recovery" and recovery_producer_source_sha is not None,
            "recovery request inputs are incomplete",
        )
        environment = {
            "MIRMIR_V4_RECOVERY_CAPTURE_DIR": str(output),
            "MIRMIR_V4_RECOVERY_CONTRACT_PATH": str(staged_input),
            "MIRMIR_V4_RECOVERY_CONTRACT_SHA256": contract_sha,
            "MIRMIR_V4_RECOVERY_PRODUCER_SOURCE_SHA256":
                recovery_producer_source_sha,
            "MIRMIR_V4_RECOVERY_SOURCE_COMMIT": package["sourceCommit"],
            "MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256": package[
                "sourceTreeIdentitySHA256"
            ],
        }
    return {
        "schemaVersion": REQUEST_SCHEMA,
        "lane": lane,
        "requestID": request_id,
        "nonce": secrets.token_hex(32),
        "generatedAtUTC": utc_now(),
        "observerSourceSHA256": observer_source_sha,
        "contractSHA256": contract_sha,
        "packageIdentity": dict(package),
        "captureEnvironment": environment,
    }


def parse_observer_stdout(stdout: bytes) -> bytes:
    if stdout.startswith(ERROR_PREFIX):
        encoded = stdout[len(ERROR_PREFIX) :].strip()
        try:
            detail = base64.b64decode(encoded, validate=True).decode(
                "utf-8", errors="replace"
            )
        except (ValueError, UnicodeError):
            detail = stdout.decode("utf-8", errors="replace").strip()
        raise PackagedEvidenceError(f"shipping observer rejected capture: {detail}")
    require(
        stdout.startswith(RESULT_PREFIX) and stdout.endswith(b"\n"),
        "shipping observer stdout marker is absent",
    )
    encoded = stdout[len(RESULT_PREFIX) : -1]
    require(b"\n" not in encoded and b"\r" not in encoded, "observer stdout is not one record")
    try:
        result = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise PackagedEvidenceError("observer result marker contains invalid base64") from error
    return result


def validate_observer_result(
    result_bytes: bytes,
    request: Mapping[str, Any],
    executable: Path,
    capture_root: Path,
    expected_manifest_schema: str | None = None,
) -> dict[str, Any]:
    result = require_mapping(load_json_bytes(result_bytes, "observer result"), "observer result")
    require(result_bytes == canonical_bytes(result), "observer result is not canonical JSON")
    require_exact_keys(
        result,
        {
            "schemaVersion",
            "lane",
            "requestID",
            "requestSHA256",
            "observerSourceSHA256",
            "contractSHA256",
            "packageIdentity",
            "process",
            "runtime",
            "captureManifest",
            "captureTree",
            "checks",
        },
        "observer result",
    )
    request_bytes = canonical_bytes(request)
    require(result["schemaVersion"] == RESULT_SCHEMA, "observer result schema differs")
    for key in ("lane", "requestID", "observerSourceSHA256", "contractSHA256"):
        require(result[key] == request[key], f"observer result differs: {key}")
    require(result["requestSHA256"] == sha256_bytes(request_bytes), "request seal differs")
    require(result["packageIdentity"] == request["packageIdentity"], "result package differs")
    process = require_mapping(result["process"], "observer process")
    require_exact_keys(
        process,
        {
            "bundlePath",
            "executablePath",
            "executableSHA256",
            "processID",
            "parentProcessID",
        },
        "observer process",
    )
    executable = safe_regular(executable, "shipping executable", executable=True)
    require(
        Path(process["executablePath"]).resolve(strict=True) == executable,
        "observer ran another executable path",
    )
    require(
        process["executableSHA256"]
        == request["packageIdentity"]["applicationExecutableSHA256"]
        == sha256_file(executable),
        "observer ran another executable identity",
    )
    require(
        isinstance(process["processID"], int)
        and process["processID"] > 0
        and isinstance(process["parentProcessID"], int)
        and process["parentProcessID"] > 0,
        "observer process identifiers are invalid",
    )
    runtime = require_mapping(result["runtime"], "observer runtime")
    require_exact_keys(
        runtime,
        {
            "runtimeID",
            "releaseStatus",
            "manifestSHA256",
            "sourceRevision",
            "trustRootConfigured",
        },
        "observer runtime",
    )
    require(runtime["runtimeID"] == "ash-p06-deterministic-v4", "observer runtime ID differs")
    require(runtime["releaseStatus"] == "release_qualified", "observer runtime is not released")
    require(
        runtime["manifestSHA256"] == request["packageIdentity"]["runtimeManifestSHA256"]
        and runtime["sourceRevision"] == request["packageIdentity"]["runtimeSourceRevision"]
        and runtime["trustRootConfigured"] is True,
        "observer runtime binding differs",
    )
    checks = require_mapping(result["checks"], "observer checks")
    require_exact_keys(
        checks,
        {
            "exactExecutableIdentity",
            "signedBuildClaims",
            "productionP06Load",
            "normativePixelCapture",
        },
        "observer checks",
    )
    require(all(value is True for value in checks.values()), "observer checks are not all true")
    observed_tree = capture_tree(capture_root)
    require(result["captureTree"] == observed_tree, "observer capture tree seal differs")
    manifest = require_mapping(result["captureManifest"], "capture manifest descriptor")
    require_exact_keys(manifest, {"fileName", "byteCount", "sha256"}, "capture manifest descriptor")
    name = manifest["fileName"]
    require(
        isinstance(name, str)
        and name in (
            {"candidate-capture-manifest.json"}
            if request["lane"] == "quality"
            else {"capture.json"}
        ),
        "capture manifest name differs",
    )
    manifest_path = safe_regular(capture_root / name, "capture manifest")
    require(
        manifest_path.stat().st_size == manifest["byteCount"]
        and sha256_file(manifest_path) == manifest["sha256"],
        "capture manifest descriptor differs",
    )
    captured = require_mapping(load_json(manifest_path, "capture manifest"), "capture manifest")
    if expected_manifest_schema is not None:
        require(
            captured.get("schemaVersion") == expected_manifest_schema,
            "capture manifest and contract schema profiles differ",
        )
    require(
        captured.get("evidenceRequestSHA256") == result["requestSHA256"],
        "capture manifest request identity differs",
    )
    require(
        captured.get("packagedCandidateIdentity") == request["packageIdentity"],
        "capture manifest package identity differs",
    )
    if request["lane"] == "quality":
        require(
            captured.get("observerSourceSHA256") == request["observerSourceSHA256"],
            "quality manifest observer source differs",
        )
    elif request["lane"] == "parity":
        require(
            captured.get("captureSourceSHA256") == request["observerSourceSHA256"],
            "parity manifest observer source differs",
        )
    else:
        require(
            captured.get("observerSourceSHA256")
            == request["observerSourceSHA256"],
            "packaged manifest observer source differs",
        )
    return result


def capture_exact_candidate(
    *,
    repository: Path,
    candidate_path: Path,
    archive: Path,
    runtime: Path,
    release_configuration: Path,
    lane: str,
    contract: Path,
    output: Path,
    corpus_manifest: Path | None,
    timeout_seconds: int,
    performance_input: Path | None = None,
    performance_source_identity: Path | None = None,
    media_fixture_manifest: Path | None = None,
    warmup_count: int = 5,
    sample_count: int = 10,
) -> Path:
    require(
        lane in {"quality", "parity", "performance", "media", "recovery"},
        "lane must be quality, parity, performance, media, or recovery",
    )
    repository = repository.expanduser().resolve(strict=True)
    archive = safe_regular(archive, "application archive")
    contract = safe_regular(contract, f"{lane} contract")
    output = output.expanduser().resolve()
    require(not output.exists(), f"refusing to overwrite output: {output}")
    require(output.parent.is_dir(), f"output parent does not exist: {output.parent}")
    candidate, package, context, tools = inspected_package(
        repository,
        candidate_path,
        archive,
        runtime,
        release_configuration,
    )
    observer_source = committed_bytes(
        repository, candidate["sourceCommit"], OBSERVER_SOURCE_PATH
    )
    observer_source_sha = sha256_bytes(observer_source)
    contract_sha = sha256_file(contract)
    recovery_producer_source: bytes | None = None
    recovery_producer_source_sha: str | None = None
    expected_manifest_schema: str | None = None
    if lane == "quality":
        contract_value = require_mapping(load_json(contract, "quality contract"), "quality contract")
        schema = contract_value.get("schemaVersion")
        require(schema in {"mirmir-ash-v4-quality-gate-contract-v1", "mirmir-ash-v4-quality-gate-contract-v2"},
                "quality contract schema differs")
        expected_manifest_schema = (
            "mirmir-ash-v4-quality-candidate-capture-v2"
            if schema == "mirmir-ash-v4-quality-gate-contract-v2"
            else "mirmir-ash-v4-quality-candidate-capture-v1"
        )
    if lane == "parity":
        contract_value = require_mapping(load_json(contract, "parity contract"), "parity contract")
        contract_tools = require_mapping(contract_value.get("tools"), "parity contract tools")
        require(
            contract_tools.get("captureSourceSHA256") == observer_source_sha,
            "parity contract is not bound to the packaged observer source",
        )
        if contract_value.get("schemaVersion") == "mirmir-ash-v4-cpu-metal-parity-contract-v3":
            require_exact_keys(contract_tools, {"captureSourceSHA256", "evaluatorSHA256", "runnerSHA256", "chromaGeometryValidatorSHA256"}, "parity contract tools")
            for key, relative in {
                "evaluatorSHA256": "script/v4/cpu_metal_parity_v4.py",
                "runnerSHA256": "script/v4/run_cpu_metal_parity_v4.sh",
                "chromaGeometryValidatorSHA256": "script/v4/chroma_geometry_v4.py",
            }.items():
                require(contract_tools[key] == sha256_bytes(committed_bytes(repository, candidate["sourceCommit"], relative)),
                    f"parity contract candidate source differs: {key}")
    elif lane == "recovery":
        contract_value = require_mapping(
            load_json(contract, "recovery contract"), "recovery contract"
        )
        capture_contract = require_mapping(
            contract_value.get("capture"), "recovery capture contract"
        )
        recovery_producer_source = committed_bytes(
            repository,
            package["sourceCommit"],
            Path(RECOVERY_PRODUCER_SOURCE_PATH),
        )
        recovery_producer_source_sha = sha256_bytes(
            recovery_producer_source
        )
        require(
            contract_value.get("schemaVersion")
            == "mirmir-v4-recovery-qualification-contract-v2"
            and capture_contract.get("producerSourceSHA256")
            == recovery_producer_source_sha
            and capture_contract.get("observerSourceSHA256")
            == observer_source_sha,
            "recovery contract is not bound to packaged producer/observer source",
        )

    request_id = str(uuid.uuid4())
    support = application_support_root(package["bundleIdentifier"])
    namespace = support / "MirmirQualificationV4" / "packaged-evidence"
    qualification_root = namespace / request_id
    require(not qualification_root.exists(), "qualification UUID root already exists")
    extraction_directory: Path | None = None
    evidence_temporary: Path | None = None
    try:
        qualification_root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        qualification_root.mkdir(mode=0o700)
        inputs = qualification_root / "inputs"
        if lane == "quality":
            require(corpus_manifest is not None, "quality capture requires a corpus manifest")
            staged_input = stage_quality_corpus(corpus_manifest, inputs)
        elif lane == "parity":
            require(corpus_manifest is None, "parity capture does not accept a corpus manifest")
            staged_input = stage_parity_contract(contract, inputs)
        elif lane == "performance":
            require(
                corpus_manifest is None
                and performance_input is not None
                and performance_source_identity is not None,
                "performance capture inputs are incomplete",
            )
            require(
                warmup_count >= 5 and sample_count >= 10,
                "performance capture has too few warmups or samples",
            )
            staged_input = stage_performance_input(
                contract, performance_input, inputs
            )
            performance_source_identity = safe_regular(
                performance_source_identity, "performance source identity"
            )
            source_identity = require_mapping(
                load_json(
                    performance_source_identity, "performance source identity"
                ),
                "performance source identity",
            )
            require(
                source_identity.get("schemaVersion")
                    == "mirmir-v4-performance-source-identity-v1"
                and source_identity.get("variant") == "candidate_p06"
                and source_identity.get("sourceRevision")
                    == package["sourceCommit"]
                and source_identity.get("sourceTreeSHA256")
                    == package["sourceTreeIdentitySHA256"],
                "performance source identity differs from the package",
            )
            contract_value = require_mapping(
                load_json(contract, "performance contract"),
                "performance contract",
            )
            performance_capture_source_sha = require_mapping(
                contract_value.get("capture"), "performance capture contract"
            ).get("captureSourceSHA256")
            require_hex(
                performance_capture_source_sha,
                (64,),
                "performance capture source",
            )
        elif lane == "media":
            require(
                corpus_manifest is None
                and performance_input is None
                and performance_source_identity is None
                and media_fixture_manifest is not None,
                "media capture inputs are incomplete",
            )
            staged_input = stage_media_fixture_package(
                contract, media_fixture_manifest, inputs
            )
            media_fixture_source_sha = sha256_bytes(
                committed_bytes(
                    repository,
                    package["sourceCommit"],
                    Path("MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift"),
                )
            )
            media_generator_source_sha = sha256_bytes(
                committed_bytes(
                    repository,
                    package["sourceCommit"],
                    Path("script/v4/MediaPreservationCaptureTests.swift"),
                )
            )
        else:
            require(
                lane == "recovery"
                and corpus_manifest is None
                and performance_input is None
                and performance_source_identity is None
                and media_fixture_manifest is None,
                "recovery capture does not accept unrelated lane inputs",
            )
            staged_input = stage_recovery_contract(contract, inputs)
        request = make_request(
            lane,
            package,
            contract_sha,
            observer_source_sha,
            request_id,
            qualification_root,
            staged_input,
            performance_source_identity_sha=(
                sha256_file(performance_source_identity)
                if lane == "performance"
                else None
            ),
            performance_capture_source_sha=(
                performance_capture_source_sha
                if lane == "performance"
                else None
            ),
            warmup_count=warmup_count if lane == "performance" else None,
            sample_count=sample_count if lane == "performance" else None,
            media_fixture_source_sha=(
                media_fixture_source_sha if lane == "media" else None
            ),
            media_generator_source_sha=(
                media_generator_source_sha if lane == "media" else None
            ),
            recovery_producer_source_sha=(
                recovery_producer_source_sha
                if lane == "recovery" else None
            ),
        )
        request_bytes = canonical_bytes(request)

        extraction_directory = Path(
            tempfile.mkdtemp(prefix=".mirmir-v4-packaged-app-", dir=output.parent)
        )
        application, executable, extraction_inspection = (
            archive_provenance.extract_verified_application(
                archive,
                extraction_directory,
                context,
                tools,
            )
        )
        require(
            package_identity(candidate, extraction_inspection) == package,
            "archive identity changed before packaged capture",
        )
        executable = safe_regular(executable, "shipping executable", executable=True)
        environment = dict(os.environ)
        environment["NSUnbufferedIO"] = "YES"
        started = utc_now()
        try:
            process = subprocess.run(
                [
                    str(executable),
                    "--mirmir-v4-packaged-evidence",
                    base64.b64encode(request_bytes).decode("ascii"),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=timeout_seconds,
                env=environment,
            )
        except subprocess.TimeoutExpired as error:
            raise PackagedEvidenceError(
                f"exact packaged {lane} capture exceeded {timeout_seconds} seconds"
            ) from error
        finished = utc_now()
        require(
            process.returncode == 0,
            f"exact packaged {lane} capture exited {process.returncode}: "
            + process.stderr.decode("utf-8", errors="replace").strip(),
        )
        result_bytes = parse_observer_stdout(process.stdout)
        live_capture = qualification_root / "capture"
        result = validate_observer_result(
            result_bytes, request, executable, live_capture, expected_manifest_schema
        )
        tree = capture_tree(live_capture)

        evidence_temporary = Path(
            tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent)
        )
        evidence_temporary.chmod(0o700)
        observer_directory = evidence_temporary / "observer"
        write_canonical(observer_directory / "request.json", request)
        write_canonical(observer_directory / "result.json", result)
        (observer_directory / "stdout.bin").write_bytes(process.stdout)
        (observer_directory / "stderr.bin").write_bytes(process.stderr)
        (observer_directory / "stdout.bin").chmod(0o600)
        (observer_directory / "stderr.bin").chmod(0o600)
        copy_capture_tree(live_capture, evidence_temporary / "capture")
        bindings = evidence_temporary / "bindings"
        write_canonical(bindings / "candidate.json", candidate)
        write_canonical(bindings / "package-identity.json", package)
        write_canonical(
            bindings / archive_provenance.ATTESTATION_PATH,
            extraction_inspection["attestation"],
        )
        (bindings / "observer-source.swift").write_bytes(observer_source)
        (bindings / "observer-source.swift").chmod(0o600)
        if lane == "recovery":
            require(
                recovery_producer_source is not None,
                "recovery producer source is absent",
            )
            (bindings / "producer-source.swift").write_bytes(
                recovery_producer_source
            )
            (bindings / "producer-source.swift").chmod(0o600)
        copy_regular(contract, bindings / "lane-contract.json", f"{lane} contract")
        copy_regular(
            release_configuration,
            bindings / "release-candidate-v4.xcconfig",
            "release configuration",
        )
        copy_regular(archive, bindings / "application-archive.zip", "application archive")
        record_artifacts = {
            "request": descriptor(observer_directory / "request.json", evidence_temporary),
            "result": descriptor(observer_directory / "result.json", evidence_temporary),
            "stdout": descriptor(observer_directory / "stdout.bin", evidence_temporary),
            "stderr": descriptor(observer_directory / "stderr.bin", evidence_temporary),
            "candidate": descriptor(bindings / "candidate.json", evidence_temporary),
            "packageIdentity": descriptor(
                bindings / "package-identity.json", evidence_temporary
            ),
            "attestation": descriptor(
                bindings / archive_provenance.ATTESTATION_PATH,
                evidence_temporary,
            ),
            "observerSource": descriptor(
                bindings / "observer-source.swift", evidence_temporary
            ),
            "contract": descriptor(bindings / "lane-contract.json", evidence_temporary),
            "releaseConfiguration": descriptor(
                bindings / "release-candidate-v4.xcconfig", evidence_temporary
            ),
            "applicationArchive": descriptor(
                bindings / "application-archive.zip", evidence_temporary
            ),
        }
        if lane == "recovery":
            record_artifacts["producerSource"] = descriptor(
                bindings / "producer-source.swift", evidence_temporary
            )
        record = {
            "schemaVersion": CAPTURE_RECORD_SCHEMA,
            "lane": lane,
            "startedAtUTC": started,
            "finishedAtUTC": finished,
            "requestSHA256": sha256_bytes(request_bytes),
            "observerSourceSHA256": observer_source_sha,
            "contractSHA256": contract_sha,
            "packageIdentity": package,
            "captureTree": tree,
            "process": {
                "executableSHA256": sha256_file(executable),
                "exitStatus": process.returncode,
            },
            "artifacts": record_artifacts,
        }
        write_canonical(evidence_temporary / "capture-record.json", record)
        os.replace(evidence_temporary, output)
        evidence_temporary = None
        return output / "capture-record.json"
    finally:
        if qualification_root.exists():
            resolved = qualification_root.resolve()
            expected_parent = namespace.resolve()
            require(
                resolved.parent == expected_parent and resolved.name == request_id,
                "refusing to clean an unexpected qualification root",
            )
            shutil.rmtree(resolved)
        if extraction_directory is not None and extraction_directory.exists():
            shutil.rmtree(extraction_directory)
        if evidence_temporary is not None and evidence_temporary.exists():
            shutil.rmtree(evidence_temporary)


def checked_artifact(root: Path, value: Any, label: str) -> Path:
    artifact = require_mapping(value, label)
    require_exact_keys(artifact, {"path", "byteCount", "sha256"}, label)
    relative = safe_relative(artifact["path"], f"{label}.path")
    path = safe_regular(root.joinpath(*relative.parts), label)
    require(root.resolve() in path.parents, f"{label} escapes evidence")
    require(
        path.stat().st_size == artifact["byteCount"]
        and sha256_file(path) == artifact["sha256"],
        f"{label} descriptor differs",
    )
    return path


def validate_capture_binding(
    evidence_root: Path,
    repository: Path,
    runtime: Path,
) -> dict[str, Any]:
    """Re-inspect sealed evidence, including the exact archived application."""

    evidence_root = safe_directory(evidence_root, "evidence root")
    record_path = safe_regular(evidence_root / "capture-record.json", "capture record")
    record_bytes = record_path.read_bytes()
    record = require_mapping(load_json_bytes(record_bytes, "capture record"), "capture record")
    require(record_bytes == canonical_bytes(record), "capture record is not canonical JSON")
    require(record.get("schemaVersion") == CAPTURE_RECORD_SCHEMA, "capture record schema differs")
    require(
        record.get("lane")
        in {"quality", "parity", "performance", "media", "recovery"},
        "capture record lane differs",
    )
    artifacts = require_mapping(record.get("artifacts"), "capture record artifacts")
    required_artifacts = {
        "request",
        "result",
        "stdout",
        "stderr",
        "candidate",
        "packageIdentity",
        "attestation",
        "observerSource",
        "contract",
        "releaseConfiguration",
        "applicationArchive",
    }
    if record.get("lane") == "recovery":
        required_artifacts.add("producerSource")
    require_exact_keys(artifacts, required_artifacts, "capture record artifacts")
    paths = {
        key: checked_artifact(evidence_root, value, f"capture artifact {key}")
        for key, value in artifacts.items()
    }
    candidate, observed_package, _, _ = inspected_package(
        repository,
        paths["candidate"],
        paths["applicationArchive"],
        runtime,
        paths["releaseConfiguration"],
    )
    recorded_package = validate_package_identity(record.get("packageIdentity"))
    require(
        observed_package == recorded_package,
        "archive/package identity binding differs",
    )
    package_file = validate_package_identity(
        load_json(paths["packageIdentity"], "package identity artifact")
    )
    require(package_file == observed_package, "package identity artifact differs")
    attestation = load_json(paths["attestation"], "attestation artifact")
    require(
        canonical_bytes(attestation) == paths["attestation"].read_bytes()
        and sha256_bytes(paths["attestation"].read_bytes())
        == observed_package["attestationSHA256"],
        "attestation artifact differs",
    )
    observer_source = committed_bytes(
        repository, candidate["sourceCommit"], OBSERVER_SOURCE_PATH
    )
    require(
        paths["observerSource"].read_bytes() == observer_source
        and sha256_bytes(observer_source) == record["observerSourceSHA256"],
        "observer source binding differs",
    )
    if record["lane"] == "recovery":
        producer_source = committed_bytes(
            repository,
            candidate["sourceCommit"],
            Path(RECOVERY_PRODUCER_SOURCE_PATH),
        )
        require(
            paths["producerSource"].read_bytes() == producer_source,
            "recovery producer source binding differs",
        )
    request_bytes = paths["request"].read_bytes()
    request = require_mapping(load_json_bytes(request_bytes, "observer request"), "observer request")
    require(request_bytes == canonical_bytes(request), "observer request is not canonical")
    require(
        request.get("packageIdentity") == observed_package
        and request.get("lane") == record["lane"]
        and sha256_bytes(request_bytes) == record["requestSHA256"],
        "observer request binding differs",
    )
    result_bytes = paths["result"].read_bytes()
    result = require_mapping(load_json_bytes(result_bytes, "observer result"), "observer result")
    require(result_bytes == canonical_bytes(result), "observer result is not canonical")
    require(
        result.get("packageIdentity") == observed_package
        and result.get("lane") == record["lane"]
        and result.get("requestSHA256") == record["requestSHA256"],
        "observer result binding differs",
    )
    expected_stdout = RESULT_PREFIX + base64.b64encode(result_bytes) + b"\n"
    require(paths["stdout"].read_bytes() == expected_stdout, "observer stdout/result differs")
    capture = evidence_root / "capture"
    observed_tree = capture_tree(capture)
    require(
        observed_tree == record["captureTree"] == result.get("captureTree"),
        "sealed capture tree differs",
    )
    manifest_name = require_mapping(
        result.get("captureManifest"), "result capture manifest"
    ).get("fileName")
    require(
        isinstance(manifest_name, str)
        and manifest_name
        in ({"candidate-capture-manifest.json"} if record["lane"] == "quality" else {"capture.json"}),
        "result capture manifest name differs",
    )
    manifest = require_mapping(
        load_json(capture / manifest_name, "capture manifest"), "capture manifest"
    )
    if record["lane"] == "quality":
        contract_value = require_mapping(load_json(paths["contract"], "quality contract"), "quality contract")
        schema = contract_value.get("schemaVersion")
        require(schema in {"mirmir-ash-v4-quality-gate-contract-v1", "mirmir-ash-v4-quality-gate-contract-v2"},
                "quality contract schema differs")
        expected_manifest_schema = (
            "mirmir-ash-v4-quality-candidate-capture-v2"
            if schema == "mirmir-ash-v4-quality-gate-contract-v2"
            else "mirmir-ash-v4-quality-candidate-capture-v1"
        )
        require(manifest.get("schemaVersion") == expected_manifest_schema,
                "capture manifest and contract schema profiles differ")
    require(
        manifest.get("packagedCandidateIdentity") == observed_package
        and manifest.get("evidenceRequestSHA256") == record["requestSHA256"],
        "capture manifest package/request binding differs",
    )
    return {
        "lane": record["lane"],
        "candidate": candidate,
        "packageIdentity": observed_package,
        "requestSHA256": record["requestSHA256"],
        "observerSourceSHA256": record["observerSourceSHA256"],
        "contractSHA256": record["contractSHA256"],
        "captureTree": observed_tree,
        "captureManifest": manifest,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    capture = subparsers.add_parser("capture")
    capture.add_argument("--repository", type=Path, required=True)
    capture.add_argument("--candidate", type=Path, required=True)
    capture.add_argument("--application-archive", type=Path, required=True)
    capture.add_argument("--runtime", type=Path, required=True)
    capture.add_argument("--release-configuration", type=Path, required=True)
    capture.add_argument(
        "--lane",
        choices=("quality", "parity", "performance", "media", "recovery"),
        required=True,
    )
    capture.add_argument("--contract", type=Path, required=True)
    capture.add_argument("--corpus-manifest", type=Path)
    capture.add_argument("--output", type=Path, required=True)
    capture.add_argument("--timeout-seconds", type=int, default=3600)
    capture.add_argument("--performance-input", type=Path)
    capture.add_argument("--performance-source-identity", type=Path)
    capture.add_argument("--media-fixture-manifest", type=Path)
    capture.add_argument("--warmups", type=int, default=5)
    capture.add_argument("--samples", type=int, default=10)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--repository", type=Path, required=True)
    verify.add_argument("--runtime", type=Path, required=True)
    verify.add_argument("--evidence", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "capture":
        require(arguments.timeout_seconds > 0, "timeout must be positive")
        path = capture_exact_candidate(
            repository=arguments.repository,
            candidate_path=arguments.candidate,
            archive=arguments.application_archive,
            runtime=arguments.runtime,
            release_configuration=arguments.release_configuration,
            lane=arguments.lane,
            contract=arguments.contract,
            output=arguments.output,
            corpus_manifest=arguments.corpus_manifest,
            timeout_seconds=arguments.timeout_seconds,
            performance_input=arguments.performance_input,
            performance_source_identity=arguments.performance_source_identity,
            media_fixture_manifest=arguments.media_fixture_manifest,
            warmup_count=arguments.warmups,
            sample_count=arguments.samples,
        )
        print(path)
    else:
        result = validate_capture_binding(
            arguments.evidence,
            arguments.repository,
            arguments.runtime,
        )
        print(canonical_bytes(result).decode("utf-8"))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        PackagedEvidenceError,
        archive_provenance.ArchiveProvenanceError,
        OSError,
        ValueError,
        subprocess.SubprocessError,
    ) as error:
        print(f"packaged-candidate evidence failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
