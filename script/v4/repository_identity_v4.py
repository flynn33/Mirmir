#!/usr/bin/env python3
"""Fail-closed repository identity checks for the deterministic v4 release."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any, Iterable, Mapping


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
RUNTIME_MANIFEST_DOMAIN = "ash-p06-runtime-manifest-v4"
RUNTIME_SCHEMA = "ash.p06.runtime-manifest.v1"
RUNTIME_ID = "ash-p06-deterministic-v4"
EVIDENCE_SCHEMA = "mirmir-v4-evidence-manifest-v1"
P05_EVIDENCE_SCHEMA = "mirmir-v4-p05-evidence-manifest-v3"
CORPUS_LOCK_SCHEMA = "mirmir-ash-v4-natural-quality-corpus-lock-v1"
HEX = frozenset("0123456789abcdef")


class RepositoryIdentityError(ValueError):
    """A checked-in identity is missing, stale, unsafe, or internally invalid."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RepositoryIdentityError(message)


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value: str) -> None:
    raise RepositoryIdentityError(f"non-finite JSON value is forbidden: {value}")


def load_json(path: Path, *, canonical: bool = False) -> Any:
    try:
        raw = path.read_bytes()
        value = json.loads(
            raw,
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RepositoryIdentityError(f"cannot read JSON {path}: {error}") from error
    if canonical:
        require(raw == canonical_bytes(value), f"JSON is not canonical: {path}")
    return value


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
        raise RepositoryIdentityError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def artifact_set_identity(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for relative, identity in sorted(entries):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(identity.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


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


def require_sha256(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(len(text) == 64 and set(text) <= HEX, f"{label} must be lowercase SHA-256")
    return text


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, "
        f"unexpected={sorted(actual-expected_set)}",
    )


def safe_relative(value: Any, label: str) -> str:
    text = require_string(value, label)
    path = PurePosixPath(text)
    require(
        not path.is_absolute()
        and ".." not in path.parts
        and "." not in path.parts
        and path.as_posix() == text,
        f"{label} must be a canonical safe relative path",
    )
    return text


def checked_file(root: Path, relative: str, label: str) -> Path:
    root = root.resolve(strict=True)
    candidate = root / relative
    require(candidate.exists(), f"missing {label}: {relative}")
    require(not candidate.is_symlink(), f"{label} may not be a symlink: {relative}")
    resolved = candidate.resolve(strict=True)
    require(resolved.is_file() and root in resolved.parents, f"{label} escapes root: {relative}")
    return resolved


def source_identity_module() -> Any:
    path = SCRIPT_DIRECTORY / "p06_source_identity_v4.py"
    spec = importlib.util.spec_from_file_location("p06_source_identity_v4", path)
    require(spec is not None and spec.loader is not None, "cannot load P06 source identity tool")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def manifest_identity(document: Mapping[str, Any]) -> str:
    return sha256_bytes(
        RUNTIME_MANIFEST_DOMAIN.encode("utf-8")
        + b"\0"
        + canonical_bytes(document)
    )


def parse_deployment_trust_roots(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise RepositoryIdentityError(f"cannot read deployment trust roots: {error}") from error
    patterns = {
        "manifestSHA256": re.compile(
            r"static let manifestSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*\"([0-9a-f]{64})\"\s*\)",
            re.MULTILINE,
        ),
        "sourceRevision": re.compile(
            r"static let sourceRevision\s*=\s*\"([0-9a-f]{40,64})\"",
            re.MULTILINE,
        ),
        "builderSourceSHA256": re.compile(
            r"static let builderSourceSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*\"([0-9a-f]{64})\"\s*\)",
            re.MULTILINE,
        ),
    }
    result: dict[str, str] = {}
    for name, pattern in patterns.items():
        matches = pattern.findall(text)
        require(len(matches) == 1, f"deployment trust root is absent or repeated: {name}")
        result[name] = matches[0]
    return result


def verify_runtime_bundle(repository: Path) -> dict[str, str]:
    bundle = repository / "Mirmir/Resources/ASH-P06.bundle"
    require(bundle.is_dir() and not bundle.is_symlink(), "checked-in ASH-P06 bundle is missing or unsafe")
    manifest_path = bundle / "runtime-manifest.json"
    manifest = require_mapping(load_json(manifest_path, canonical=True), "runtime manifest")
    require_exact_keys(
        manifest,
        ("schemaID", "runtimeID", "releaseStatus", "provenance", "artifacts"),
        "runtime manifest",
    )
    require(manifest["schemaID"] == RUNTIME_SCHEMA, "runtime manifest schema mismatch")
    require(manifest["runtimeID"] == RUNTIME_ID, "runtime identity mismatch")
    require(manifest["releaseStatus"] == "release_qualified", "runtime is not release-qualified")

    artifacts = require_list(manifest["artifacts"], "runtime.artifacts")
    require(artifacts, "runtime artifact set is empty")
    seen_roles: set[str] = set()
    seen_paths: set[str] = set()
    for index, raw in enumerate(artifacts):
        artifact = require_mapping(raw, f"runtime.artifacts[{index}]")
        require_exact_keys(
            artifact,
            ("role", "relativePath", "schemaID", "contentSHA256", "byteCount"),
            f"runtime.artifacts[{index}]",
        )
        role = require_string(artifact["role"], f"runtime.artifacts[{index}].role")
        relative = safe_relative(artifact["relativePath"], f"runtime.artifacts[{index}].relativePath")
        require(role not in seen_roles, f"duplicate runtime artifact role: {role}")
        require(relative not in seen_paths, f"duplicate runtime artifact path: {relative}")
        seen_roles.add(role)
        seen_paths.add(relative)
        expected_hash = require_sha256(
            artifact["contentSHA256"],
            f"runtime.artifacts[{index}].contentSHA256",
        )
        expected_count = require_integer(
            artifact["byteCount"],
            f"runtime.artifacts[{index}].byteCount",
            1,
        )
        path = checked_file(bundle, relative, "runtime artifact")
        require(path.stat().st_size == expected_count, f"runtime artifact byte count mismatch: {relative}")
        require(sha256_file(path) == expected_hash, f"runtime artifact SHA-256 mismatch: {relative}")

    actual_bundle_files = {
        path.relative_to(bundle).as_posix()
        for path in bundle.rglob("*")
        if path.is_file()
    }
    expected_bundle_files = seen_paths | {"runtime-manifest.json"}
    require(
        actual_bundle_files == expected_bundle_files,
        f"runtime bundle file set differs; missing={sorted(expected_bundle_files-actual_bundle_files)}, "
        f"unexpected={sorted(actual_bundle_files-expected_bundle_files)}",
    )

    provenance = require_mapping(manifest["provenance"], "runtime.provenance")
    source_revision = require_sha256(provenance.get("sourceRevision"), "runtime.provenance.sourceRevision")
    builder_hash = require_sha256(
        provenance.get("builderSourceSHA256"),
        "runtime.provenance.builderSourceSHA256",
    )
    source_tool = source_identity_module()
    regenerated = source_tool.build_manifest(
        repository,
        repository / "script/v4/p06-source-provenance-v1.json",
    )["sourceRevision"]
    require(source_revision == regenerated, "runtime source revision does not match production source closure")

    trust_roots = parse_deployment_trust_roots(
        repository / "Mirmir/Upscaling/Deterministic/DeterministicEngineV4Support.swift"
    )
    computed_manifest_identity = manifest_identity(manifest)
    require(
        trust_roots["manifestSHA256"] == computed_manifest_identity,
        "deployment manifest trust root does not match checked-in runtime",
    )
    require(
        trust_roots["sourceRevision"] == source_revision,
        "deployment source trust root does not match checked-in runtime",
    )
    require(
        trust_roots["builderSourceSHA256"] == builder_hash,
        "deployment builder trust root does not match checked-in runtime",
    )
    return {
        "manifestSHA256": computed_manifest_identity,
        "sourceRevision": source_revision,
        "builderSourceSHA256": builder_hash,
    }


def verify_corpus_lock(repository: Path) -> dict[str, str]:
    lock_path = repository / "script/v4/natural-quality-corpus-lock-v1.json"
    lock = require_mapping(load_json(lock_path), "natural quality corpus lock")
    require(lock.get("schemaVersion") == CORPUS_LOCK_SCHEMA, "natural corpus lock schema mismatch")
    require(lock.get("releaseEligible") is True, "natural corpus lock is not release-eligible")
    bindings = {
        "sourceSelectionSHA256": repository / "script/v4/natural-quality-sources-v1.json",
        "qualityContractSHA256": repository / "script/v4/quality-gate-release-contract-v1.json",
        "builderSourceSHA256": repository / "script/v4/build_natural_quality_corpus.py",
    }
    for field, path in bindings.items():
        expected = require_sha256(lock.get(field), f"natural corpus lock {field}")
        require(path.is_file() and not path.is_symlink(), f"natural corpus binding is missing or unsafe: {path.name}")
        require(sha256_file(path) == expected, f"natural corpus binding is stale: {field}")
    for field in (
        "manifestSHA256",
        "artifactSetSHA256",
        "sourceAssetSetSHA256",
        "sourceLicenseSetSHA256",
    ):
        require_sha256(lock.get(field), f"natural corpus lock {field}")
    require(require_integer(lock.get("clipCount"), "natural corpus clipCount", 1) > 0, "natural corpus is empty")
    require(require_integer(lock.get("caseCount"), "natural corpus caseCount", 1) > 0, "natural corpus is empty")
    return {
        "corpusID": require_string(lock.get("corpusID"), "natural corpus ID"),
        "manifestSHA256": lock["manifestSHA256"],
        "artifactSetSHA256": lock["artifactSetSHA256"],
    }


def verify_evidence_manifest(path: Path) -> int:
    document = require_mapping(load_json(path), f"evidence manifest {path}")
    schema = document.get("schemaVersion")
    require(
        schema in {EVIDENCE_SCHEMA, P05_EVIDENCE_SCHEMA},
        f"evidence manifest schema mismatch: {path}",
    )
    if schema == EVIDENCE_SCHEMA:
        require_exact_keys(
            document,
            (
                "schemaVersion",
                "sourceCommit",
                "sourceDescribe",
                "artifactCount",
                "artifacts",
                "tools",
            ),
            f"evidence manifest {path}",
        )
    else:
        require_exact_keys(
            document,
            (
                "schemaVersion",
                "artifactCount",
                "artifactSetSHA256",
                "artifacts",
            ),
            f"P05 evidence manifest {path}",
        )
    artifacts = require_list(document.get("artifacts"), f"evidence artifacts {path}")
    expected_count = require_integer(document.get("artifactCount"), f"evidence artifactCount {path}")
    require(expected_count == len(artifacts), f"evidence artifact count mismatch: {path}")
    root = path.parent
    seen: set[str] = set()
    artifact_identities: list[tuple[str, str]] = []
    for index, raw in enumerate(artifacts):
        artifact = require_mapping(raw, f"evidence artifact {index}")
        require_exact_keys(artifact, ("path", "byteCount", "sha256"), f"evidence artifact {index}")
        relative = safe_relative(artifact["path"], f"evidence artifact {index}.path")
        require(relative != path.name, f"evidence manifest may not hash itself: {path}")
        require(relative not in seen, f"duplicate evidence artifact path: {relative}")
        seen.add(relative)
        target = checked_file(root, relative, "evidence artifact")
        count = require_integer(artifact["byteCount"], f"evidence artifact {relative}.byteCount")
        digest = require_sha256(artifact["sha256"], f"evidence artifact {relative}.sha256")
        require(target.stat().st_size == count, f"evidence byte count mismatch: {target}")
        require(sha256_file(target) == digest, f"evidence SHA-256 mismatch: {target}")
        artifact_identities.append((relative, digest))
    if schema == P05_EVIDENCE_SCHEMA:
        expected_set = require_sha256(
            document.get("artifactSetSHA256"),
            f"P05 evidence artifact set {path}",
        )
        require(
            artifact_set_identity(artifact_identities) == expected_set,
            f"evidence artifact-set mismatch: {path}",
        )
    return len(artifacts)


def verify_evidence(repository: Path) -> dict[str, int]:
    root = repository / "docs/v4/evidence"
    require(root.is_dir() and not root.is_symlink(), "v4 evidence directory is missing or unsafe")
    manifests = sorted(root.rglob("evidence-manifest.json"))
    require(manifests, "no sealed v4 evidence manifest is checked in")
    artifact_count = sum(verify_evidence_manifest(path) for path in manifests)
    return {"manifestCount": len(manifests), "verifiedArtifactReferences": artifact_count}


def verify_repository(repository: Path, *, include_evidence: bool = True) -> dict[str, Any]:
    root = repository.expanduser().resolve(strict=True)
    result: dict[str, Any] = {
        "schemaVersion": "mirmir-v4-repository-identity-report-v1",
        "runtime": verify_runtime_bundle(root),
        "corpus": verify_corpus_lock(root),
    }
    if include_evidence:
        result["evidence"] = verify_evidence(root)
    return result


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--skip-evidence", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    report = verify_repository(
        arguments.repository,
        include_evidence=not arguments.skip_evidence,
    )
    print(json.dumps(report, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RepositoryIdentityError, OSError, ValueError) as error:
        print(f"v4 repository identity failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
