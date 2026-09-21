#!/usr/bin/env python3
"""Bind frozen P05 source to the executable identities of one M7 toolchain."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


BINDING_SCHEMA = "mirmir-ash-v4-m7-p05-toolchain-binding-v1"
DISCOVERY_FIELDS = {
    "executableSHA256",
    "captureExecutableSHA256",
    "sourceTreeIdentitySHA256",
    "sourceManifestSHA256",
    "captureSourceSHA256",
}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class DerivationError(ValueError):
    """Raised when a run-specific P05 executable binding is not trustworthy."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DerivationError(message)


def read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DerivationError(f"cannot read {label}: {error}") from error
    require(isinstance(value, dict), f"{label} is not an object")
    return value


def encoded(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def derive(
    canonical: dict[str, Any],
    discovery: dict[str, Any],
    *,
    canonical_sha256: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    require(set(discovery) == DISCOVERY_FIELDS, "P05 discovery field set differs")
    for field, value in discovery.items():
        require(
            isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None,
            f"P05 discovery identity is invalid: {field}",
        )
    frozen = canonical.get("frozenP05Baseline")
    require(isinstance(frozen, dict), "canonical quality contract has no frozen P05 baseline")
    required_frozen = {
        "schemaVersion",
        "implementationVersion",
        "sourceRevision",
        "sourceTreeIdentitySHA256",
        "sourceManifestPath",
        "sourceManifestSHA256",
        "captureSourceSHA256",
        "executableSHA256",
        "captureExecutableSHA256",
    }
    require(set(frozen) == required_frozen, "canonical frozen P05 field set differs")
    for field in (
        "sourceTreeIdentitySHA256",
        "sourceManifestSHA256",
        "captureSourceSHA256",
    ):
        require(discovery[field] == frozen[field], f"frozen P05 source identity differs: {field}")

    derived = copy.deepcopy(canonical)
    derived_frozen = derived["frozenP05Baseline"]
    derived_frozen["executableSHA256"] = discovery["executableSHA256"]
    derived_frozen["captureExecutableSHA256"] = discovery["captureExecutableSHA256"]
    derived_bytes = encoded(derived)
    binding = {
        "schemaVersion": BINDING_SCHEMA,
        "canonicalContractSHA256": canonical_sha256,
        "derivedContractSHA256": sha256_bytes(derived_bytes),
        "sourceRevision": frozen["sourceRevision"],
        "sourceTreeIdentitySHA256": frozen["sourceTreeIdentitySHA256"],
        "sourceManifestSHA256": frozen["sourceManifestSHA256"],
        "captureSourceSHA256": frozen["captureSourceSHA256"],
        "executableSHA256": discovery["executableSHA256"],
        "captureExecutableSHA256": discovery["captureExecutableSHA256"],
        "derivation": "only P05 application and capture executable identities are rebound",
    }
    return derived, binding


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canonical", type=Path, required=True)
    parser.add_argument("--discovery", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binding", type=Path, required=True)
    parser.add_argument("--verify", action="store_true")
    arguments = parser.parse_args(argv)
    canonical_path = arguments.canonical.resolve(strict=True)
    discovery_path = arguments.discovery.resolve(strict=True)
    output_path = arguments.output.resolve()
    binding_path = arguments.binding.resolve()
    require(output_path != binding_path, "derived contract and binding paths collide")
    canonical_bytes = canonical_path.read_bytes()
    derived, binding = derive(
        read_object(canonical_path, "canonical quality contract"),
        read_object(discovery_path, "P05 discovery"),
        canonical_sha256=sha256_bytes(canonical_bytes),
    )
    expected_contract = encoded(derived)
    expected_binding = encoded(binding)
    if arguments.verify:
        require(output_path.is_file() and not output_path.is_symlink(), "derived contract is absent or unsafe")
        require(binding_path.is_file() and not binding_path.is_symlink(), "P05 binding is absent or unsafe")
        require(output_path.read_bytes() == expected_contract, "derived quality contract does not reproduce")
        require(binding_path.read_bytes() == expected_binding, "P05 toolchain binding does not reproduce")
    else:
        require(not output_path.exists(), f"refusing to overwrite derived contract: {output_path}")
        require(not binding_path.exists(), f"refusing to overwrite P05 binding: {binding_path}")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        binding_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(expected_contract)
        require(
            sha256_bytes(output_path.read_bytes()) == binding["derivedContractSHA256"],
            "derived quality contract changed while writing",
        )
        binding_path.write_bytes(expected_binding)
    print(output_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DerivationError, KeyError, TypeError) as error:
        print(f"M7 quality-contract derivation failed: {error}", file=sys.stderr)
        raise SystemExit(2)
