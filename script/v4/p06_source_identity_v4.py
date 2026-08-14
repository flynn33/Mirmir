#!/usr/bin/env python3
"""Compute the closed, deployment-root-normalized P06 production source identity."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-ash-v4-p06-source-provenance-contract-v1"
MANIFEST_SCHEMA = "mirmir-ash-v4-p06-production-source-manifest-v1"
HEX = frozenset("0123456789abcdef")


class SourceIdentityError(ValueError):
    """The declared P06 source set or its provenance is not closed."""


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SourceIdentityError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value: str) -> None:
    raise SourceIdentityError(f"non-finite JSON value is forbidden: {value}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SourceIdentityError(f"cannot read JSON {path}: {error}") from error


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


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SourceIdentityError(message)


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


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, "
        f"unexpected={sorted(actual-expected_set)}",
    )


def require_sha256(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(len(text) == 64 and set(text) <= HEX, f"{label} must be lowercase SHA-256")
    return text


def require_safe_relative(value: Any, label: str) -> str:
    text = require_string(value, label)
    path = PurePosixPath(text)
    require(
        not path.is_absolute() and ".." not in path.parts and path.as_posix() == text,
        f"{label} must be a safe canonical relative path",
    )
    return text


def checked_source(repository: Path, relative: str) -> Path:
    candidate = repository / relative
    require(candidate.exists(), f"declared P06 source does not exist: {relative}")
    require(not candidate.is_symlink(), f"P06 sources may not be symbolic links: {relative}")
    root = repository.resolve(strict=True)
    path = candidate.resolve(strict=True)
    require(path.is_file() and root in path.parents, f"P06 source escapes repository: {relative}")
    return path


def load_contract(path: Path, repository: Path) -> tuple[dict[str, Any], str]:
    contract = require_mapping(load_json(path), "source provenance contract")
    require_exact_keys(
        contract,
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
    require(contract.get("schemaVersion") == CONTRACT_SCHEMA, "source provenance contract schema mismatch")
    require(contract.get("identityDomain") == "ash-p06-production-source-v1", "source identity domain mismatch")
    coverage = require_mapping(contract["coverage"], "contract.coverage")
    require_exact_keys(coverage, ("roots", "fileExtensions"), "contract.coverage")
    roots = require_list(coverage["roots"], "contract.coverage.roots")
    extensions = require_list(coverage["fileExtensions"], "contract.coverage.fileExtensions")
    require(roots == sorted(set(roots)) and roots, "coverage roots must be nonempty, unique, and sorted")
    require(extensions == sorted(set(extensions)) and extensions, "coverage extensions must be nonempty, unique, and sorted")
    for index, root in enumerate(roots):
        require_safe_relative(root, f"contract.coverage.roots[{index}]")
        root_path = repository / root
        require(root_path.is_dir() and not root_path.is_symlink(), f"coverage root is absent or unsafe: {root}")
    for index, extension in enumerate(extensions):
        require(extension.startswith(".") and "/" not in extension, f"invalid coverage extension[{index}]")

    additional = require_list(contract["requiredAdditionalSources"], "contract.requiredAdditionalSources")
    sources = require_list(contract["sources"], "contract.sources")
    for label, values in (("requiredAdditionalSources", additional), ("sources", sources)):
        for index, value in enumerate(values):
            require_safe_relative(value, f"contract.{label}[{index}]")
        require(values == sorted(set(values)), f"contract.{label} must be unique and sorted")
    require(sources, "contract.sources must be nonempty")
    discovered: set[str] = set(additional)
    for root in roots:
        for candidate in (repository / root).rglob("*"):
            if candidate.suffix in extensions and candidate.is_symlink():
                raise SourceIdentityError(
                    "shipping source closure contains a symbolic link: "
                    + candidate.relative_to(repository).as_posix()
                )
            if candidate.is_file() and candidate.suffix in extensions:
                discovered.add(candidate.relative_to(repository).as_posix())
    require(
        sources == sorted(discovered),
        f"P06 source closure mismatch; missing={sorted(discovered-set(sources))}, "
        f"unexpected={sorted(set(sources)-discovered)}",
    )
    for relative in sources:
        checked_source(repository, relative)

    normalized = require_mapping(
        contract["normalizedDeploymentTrustRoot"],
        "contract.normalizedDeploymentTrustRoot",
    )
    require_exact_keys(normalized, ("path", "assignments"), "contract.normalizedDeploymentTrustRoot")
    normalized_path = require_safe_relative(normalized["path"], "normalized trust-root path")
    require(normalized_path in sources, "normalized trust-root source is outside P06 source closure")
    assignments = require_list(normalized["assignments"], "normalized trust-root assignments")
    require(
        assignments == ["builderSourceSHA256", "manifestSHA256", "sourceRevision"],
        "normalized deployment assignments differ from the three circular trust roots",
    )
    semantic_contract_identity = sha256_bytes(canonical_bytes(contract))
    return contract, semantic_contract_identity


def normalize_trust_roots(data: bytes) -> tuple[bytes, list[str]]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SourceIdentityError("deployment trust-root source is not UTF-8") from error
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


def build_manifest(repository: Path, contract_path: Path) -> dict[str, Any]:
    root = repository.expanduser().resolve(strict=True)
    contract, contract_identity = load_contract(contract_path.expanduser().resolve(strict=True), root)
    normalized_path = contract["normalizedDeploymentTrustRoot"]["path"]
    entries: list[dict[str, Any]] = []
    digest = hashlib.sha256()
    digest.update(contract["identityDomain"].encode("utf-8"))
    digest.update(b"\0")
    digest.update(bytes.fromhex(contract_identity))
    for relative in contract["sources"]:
        raw = checked_source(root, relative).read_bytes()
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
        "schemaVersion": MANIFEST_SCHEMA,
        "contractSemanticSHA256": contract_identity,
        "identityDomain": contract["identityDomain"],
        "sourceCount": len(entries),
        "sourceRevision": digest.hexdigest(),
        "sources": entries,
    }


def validate_manifest(path: Path, repository: Path, contract_path: Path) -> dict[str, Any]:
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
    require(document.get("schemaVersion") == MANIFEST_SCHEMA, "production source manifest schema mismatch")
    require_sha256(document.get("contractSemanticSHA256"), "manifest.contractSemanticSHA256")
    require_sha256(document.get("sourceRevision"), "manifest.sourceRevision")
    require_integer(document.get("sourceCount"), "manifest.sourceCount", 1)
    require_list(document.get("sources"), "manifest.sources")
    regenerated = build_manifest(repository, contract_path)
    require(document == regenerated, "production source manifest does not reproduce repository bytes")
    require(path.read_bytes() == canonical_bytes(document), "production source manifest is not canonical JSON")
    return document


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("identity", "manifest"):
        command = subparsers.add_parser(name)
        command.add_argument("--repository", type=Path, required=True)
        command.add_argument("--contract", type=Path, required=True)
    verify = subparsers.add_parser("verify-manifest")
    verify.add_argument("--repository", type=Path, required=True)
    verify.add_argument("--contract", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "identity":
        print(build_manifest(arguments.repository, arguments.contract)["sourceRevision"])
        return 0
    if arguments.command == "manifest":
        sys.stdout.buffer.write(canonical_bytes(build_manifest(arguments.repository, arguments.contract)))
        return 0
    if arguments.command == "verify-manifest":
        document = validate_manifest(
            arguments.manifest.expanduser().resolve(strict=True),
            arguments.repository,
            arguments.contract,
        )
        print(document["sourceRevision"])
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SourceIdentityError, OSError) as error:
        print(f"P06 source provenance failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
