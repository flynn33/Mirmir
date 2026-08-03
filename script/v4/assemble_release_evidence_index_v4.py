#!/usr/bin/env python3
"""Assemble the sealed eight-lane deterministic-v4 release evidence index."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
from typing import Any, Iterable, Mapping, Sequence


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIRECTORY / "release-qualification-contract-v1.json"

INDEX_SCHEMA = "mirmir-ash-v4-release-candidate-evidence-v1"
CONTRACT_SCHEMA = "mirmir-ash-v4-release-qualification-contract-v1"
PACKAGED_CANDIDATE_SCHEMA = "mirmir-v4-packaged-candidate-identity-v1"
EXPECTED_ROLES = (
    "quality",
    "same_scope_performance",
    "cpu_metal_parity",
    "media_preservation",
    "recovery",
    "p06_reproduction",
    "support_matrix",
    "notarized_smoke",
)
EXPECTED_CANDIDATE_FIELDS = (
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
)
FULL_CANDIDATE_ROLES = frozenset(EXPECTED_ROLES) - {
    "quality",
    "same_scope_performance",
}
BINDING_BASENAME_REQUIREMENTS = {
    ("cpu_metal_parity", "/contractSHA256"): "cpu-metal-parity-contract-v2.json",
    ("cpu_metal_parity", "/identities/captureSourceSHA256"): "MirmirApp.swift",
    ("cpu_metal_parity", "/identities/evaluatorSHA256"): "cpu_metal_parity_v4.py",
    ("cpu_metal_parity", "/identities/runnerSHA256"): "run_cpu_metal_parity_v4.sh",
}
HEX_PATTERN = re.compile(r"^[0-9a-f]+$")
MAX_JSON_BYTES = 64 * 1024 * 1024
MAX_EVIDENCE_FILES = 200_000
MAX_EVIDENCE_BYTES = 256 * 1024 * 1024 * 1024


class AssemblyError(ValueError):
    """The supplied files cannot form one sealed release evidence index."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssemblyError(message)


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be text")
    return value


def require_integer(value: Any, label: str, *, minimum: int = 0) -> int:
    require(
        isinstance(value, int) and not isinstance(value, bool) and value >= minimum,
        f"{label} must be an integer >= {minimum}",
    )
    return value


def require_hex(value: Any, lengths: int | Sequence[int], label: str) -> str:
    text = require_string(value, label)
    allowed = {lengths} if isinstance(lengths, int) else set(lengths)
    require(len(text) in allowed and HEX_PATTERN.fullmatch(text) is not None, f"{label} is not lowercase hexadecimal")
    return text


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    observed = set(value)
    require(
        observed == expected_set,
        f"{label} field set mismatch; missing={sorted(expected_set-observed)}, "
        f"unexpected={sorted(observed-expected_set)}",
    )


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AssemblyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise AssemblyError(f"non-finite JSON number: {value}")


def load_json(path: Path, label: str) -> Any:
    checked = checked_regular(path, label)
    require(checked.stat().st_size <= MAX_JSON_BYTES, f"{label} exceeds the JSON size limit")
    try:
        value = json.loads(
            checked.read_text(encoding="utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AssemblyError(f"cannot decode {label}: {error}") from error
    reject_nonfinite(value, label)
    return value


def reject_nonfinite(value: Any, label: str) -> None:
    if isinstance(value, float):
        require(math.isfinite(value), f"{label} contains a non-finite number")
    elif isinstance(value, dict):
        for key, nested in value.items():
            reject_nonfinite(nested, f"{label}.{key}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            reject_nonfinite(nested, f"{label}[{index}]")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checked_regular(path: Path, label: str) -> Path:
    raw = path.expanduser()
    require(not raw.is_symlink(), f"{label} cannot be a symbolic link")
    try:
        resolved = raw.resolve(strict=True)
        metadata = resolved.stat()
    except (OSError, ValueError) as error:
        raise AssemblyError(f"{label} is absent or inaccessible: {error}") from error
    require(stat.S_ISREG(metadata.st_mode), f"{label} must be a regular file")
    require(metadata.st_nlink == 1, f"{label} cannot be hard-linked")
    return resolved


def checked_directory(path: Path, label: str) -> Path:
    raw = path.expanduser()
    require(not raw.is_symlink(), f"{label} cannot be a symbolic link")
    try:
        resolved = raw.resolve(strict=True)
        metadata = resolved.stat()
    except (OSError, ValueError) as error:
        raise AssemblyError(f"{label} is absent or inaccessible: {error}") from error
    require(stat.S_ISDIR(metadata.st_mode), f"{label} must be a directory")
    return resolved


def relative_path(root: Path, path: Path, label: str) -> str:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as error:
        raise AssemblyError(f"{label} escapes the evidence root") from error
    require(relative not in {"", "."}, f"{label} cannot be the evidence root")
    return relative


def safe_manifest_relative(value: Any, label: str) -> str:
    text = require_string(value, label)
    pure = PurePosixPath(text)
    require(
        not pure.is_absolute()
        and text == pure.as_posix()
        and "\0" not in text
        and "\\" not in text
        and all(part not in {"", ".", ".."} for part in pure.parts),
        f"{label} is not a safe canonical relative path",
    )
    return text


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    checked = checked_regular(path, f"artifact {path}")
    return {
        "path": relative_path(root, checked, f"artifact {path}"),
        "byteCount": checked.stat().st_size,
        "sha256": sha256(checked),
    }


def descriptor_from_seal(
    path: Path,
    root: Path,
    sealed_facts: Mapping[Path, Mapping[str, Any]],
) -> dict[str, Any]:
    checked = checked_regular(path, f"sealed artifact {path}")
    require(checked in sealed_facts, f"artifact is outside its validated seal: {path}")
    facts = sealed_facts[checked]
    count = require_integer(facts["byteCount"], f"sealed artifact {path}.byteCount")
    identity = require_hex(facts["sha256"], 64, f"sealed artifact {path}.sha256")
    require(checked.stat().st_size == count, f"sealed artifact changed during assembly: {path}")
    return {
        "path": relative_path(root, checked, f"sealed artifact {path}"),
        "byteCount": count,
        "sha256": identity,
    }


def decode_pointer_token(raw: str, label: str) -> str:
    decoded: list[str] = []
    index = 0
    while index < len(raw):
        character = raw[index]
        if character != "~":
            decoded.append(character)
            index += 1
            continue
        require(
            index + 1 < len(raw) and raw[index + 1] in {"0", "1"},
            f"{label} contains an invalid escape",
        )
        decoded.append("~" if raw[index + 1] == "0" else "/")
        index += 2
    return "".join(decoded)


def validate_pointer_syntax(pointer: Any, label: str) -> str:
    value = require_string(pointer, label)
    require(value.startswith("/") and value != "/", f"{label} is not an absolute JSON pointer")
    for raw in value[1:].split("/"):
        decode_pointer_token(raw, label)
    return value


def json_pointer(document: Any, pointer: str, label: str) -> Any:
    pointer = validate_pointer_syntax(pointer, label)
    current = document
    for raw in pointer[1:].split("/"):
        token = decode_pointer_token(raw, label)
        if isinstance(current, dict):
            require(token in current, f"{label} does not resolve: {pointer}")
            current = current[token]
        elif isinstance(current, list):
            require(
                token.isdigit() and (token == "0" or not token.startswith("0")),
                f"{label} has an invalid array index: {pointer}",
            )
            index = int(token)
            require(index < len(current), f"{label} array index is out of range: {pointer}")
            current = current[index]
        else:
            raise AssemblyError(f"{label} traverses a scalar: {pointer}")
    return current


def validate_contract(path: Path) -> tuple[Path, dict[str, Any]]:
    contract_path = checked_regular(path, "release contract")
    contract = require_mapping(load_json(contract_path, "release contract"), "release contract")
    require(contract.get("schemaVersion") == CONTRACT_SCHEMA, "release contract schema is unsupported")
    require(
        contract.get("hashAlgorithm") == "sha256",
        "release contract hash algorithm is unsupported",
    )
    fields = require_list(contract.get("candidateIdentityFields"), "candidateIdentityFields")
    require(tuple(fields) == EXPECTED_CANDIDATE_FIELDS, "release contract candidate identity fields differ from v1")
    roles = require_list(contract.get("requiredEvidenceRoles"), "requiredEvidenceRoles")
    require(
        tuple(roles) == EXPECTED_ROLES and len(roles) == len(set(roles)),
        "release contract role order/set differs from v1",
    )
    schemas = require_mapping(contract.get("evidenceSchemas"), "evidenceSchemas")
    require_exact_keys(schemas, EXPECTED_ROLES, "evidenceSchemas")
    for role in EXPECTED_ROLES:
        require_string(schemas[role], f"evidenceSchemas.{role}")
    binding_contract = require_mapping(contract.get("identityBindings"), "identityBindings")
    require_exact_keys(binding_contract, {"common", *EXPECTED_ROLES}, "identityBindings")
    for name, value in binding_contract.items():
        pointers = require_list(value, f"identityBindings.{name}")
        validated: list[str] = []
        for index, pointer in enumerate(pointers):
            validated.append(
                validate_pointer_syntax(pointer, f"identityBindings.{name}[{index}]")
            )
        require(
            validated and len(validated) == len(set(validated)),
            f"identityBindings.{name} is empty or contains duplicates",
        )
    return contract_path, contract


def validate_candidate(path: Path, contract: Mapping[str, Any]) -> tuple[Path, dict[str, Any]]:
    candidate_path = checked_regular(path, "inner candidate identity")
    candidate = require_mapping(load_json(candidate_path, "inner candidate identity"), "inner candidate identity")
    require_exact_keys(candidate, contract["candidateIdentityFields"], "inner candidate identity")
    require_hex(candidate["sourceCommit"], 40, "candidate.sourceCommit")
    for key in (
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
    ):
        require_hex(candidate[key], 64, f"candidate.{key}")
    require_hex(candidate["runtimeSourceRevision"], (40, 64), "candidate.runtimeSourceRevision")
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"candidate.{key}")
    return candidate_path, candidate


def scan_regular_tree(root: Path, label: str) -> list[Path]:
    files: list[Path] = []
    total = 0
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        require(not path.is_symlink(), f"{label} contains a symbolic link: {path}")
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        require(stat.S_ISREG(metadata.st_mode), f"{label} contains a special file: {path}")
        require(metadata.st_nlink == 1, f"{label} contains a hard-linked file: {path}")
        files.append(path.resolve(strict=True))
        total += metadata.st_size
        require(len(files) <= MAX_EVIDENCE_FILES, f"{label} exceeds the file-count limit")
        require(total <= MAX_EVIDENCE_BYTES, f"{label} exceeds the byte-count limit")
    require(files, f"{label} is empty")
    return files


def validate_manifest_descriptor(base: Path, value: Any, label: str) -> tuple[Path, dict[str, Any]]:
    item = require_mapping(value, label)
    require_exact_keys(item, {"path", "byteCount", "sha256"}, label)
    relative = safe_manifest_relative(item["path"], f"{label}.path")
    target = base.joinpath(*PurePosixPath(relative).parts)
    checked = checked_regular(target, label)
    require(relative_path(base, checked, label) == relative, f"{label} path is not canonical")
    count = require_integer(item["byteCount"], f"{label}.byteCount")
    identity = require_hex(item["sha256"], 64, f"{label}.sha256")
    require(checked.stat().st_size == count, f"{label} byte count differs")
    require(sha256(checked) == identity, f"{label} SHA-256 differs")
    return checked, {"path": relative, "byteCount": count, "sha256": identity}


def recovery_artifact_set_sha(artifacts: Sequence[Mapping[str, Any]]) -> str:
    normalized = [
        {"path": item["path"], "byteCount": item["byteCount"], "sha256": item["sha256"]}
        for item in artifacts
    ]
    normalized.sort(key=lambda item: item["path"])
    return hashlib.sha256(canonical_bytes(normalized) + b"\n").hexdigest()


def media_artifact_set_sha(artifacts: Sequence[Mapping[str, Any]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for item in sorted(artifacts, key=lambda value: value["path"]):
        digest.update(item["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(item["sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def validate_seal(
    root: Path,
    manifest_path: Path,
    files: Sequence[Path],
    role: str,
) -> tuple[list[dict[str, Any]], set[Path], dict[Path, dict[str, Any]]]:
    manifest = require_mapping(
        load_json(manifest_path, f"seal {manifest_path}"),
        f"seal {manifest_path}",
    )
    allowed = {"schemaVersion", "artifacts", "artifactCount", "artifactSetSHA256"}
    require(
        set(manifest).issubset(allowed)
        and {"schemaVersion", "artifacts"}.issubset(manifest),
        f"seal {manifest_path} has an unsupported field set",
    )
    require_string(manifest["schemaVersion"], f"seal {manifest_path}.schemaVersion")
    values = require_list(manifest["artifacts"], f"seal {manifest_path}.artifacts")
    require(values, f"seal {manifest_path} is empty")
    normalized: list[dict[str, Any]] = []
    resolved: set[Path] = set()
    facts: dict[Path, dict[str, Any]] = {}
    seen: set[str] = set()
    for index, value in enumerate(values):
        path, item = validate_manifest_descriptor(
            root,
            value,
            f"seal {manifest_path}.artifacts[{index}]",
        )
        require(
            item["path"] not in seen,
            f"seal {manifest_path} repeats artifact path: {item['path']}",
        )
        require(path != manifest_path, f"seal {manifest_path} cannot seal itself")
        seen.add(item["path"])
        resolved.add(path)
        facts[path] = item
        normalized.append(item)
    actual = set(files) - {manifest_path}
    require(
        resolved == actual,
        f"seal {manifest_path} file set differs; "
        f"missing={sorted(str(path) for path in resolved-actual)}, "
        f"unsealed={sorted(str(path) for path in actual-resolved)}",
    )
    if "artifactCount" in manifest:
        require(
            role == "notarized_smoke",
            f"seal {manifest_path} declares an unsupported artifact count for {role}",
        )
        require(
            require_integer(manifest["artifactCount"], f"seal {manifest_path}.artifactCount", minimum=1)
            == len(normalized),
            f"seal {manifest_path} artifact count differs",
        )
    if "artifactSetSHA256" in manifest:
        expected = require_hex(
            manifest["artifactSetSHA256"],
            64,
            f"seal {manifest_path}.artifactSetSHA256",
        )
        if role == "recovery":
            observed = recovery_artifact_set_sha(normalized)
        elif role == "media_preservation":
            observed = media_artifact_set_sha(normalized)
        elif role == "notarized_smoke":
            observed = hashlib.sha256(canonical_bytes(normalized)).hexdigest()
        else:
            raise AssemblyError(
                f"seal {manifest_path} declares an unsupported artifact-set identity for {role}"
            )
        require(expected == observed, f"seal {manifest_path} artifact-set identity differs")
    return normalized, resolved, facts


def find_report(root: Path, files: Sequence[Path], expected_schema: str, role: str) -> tuple[Path, dict[str, Any]]:
    matches: list[tuple[Path, dict[str, Any]]] = []
    for path in files:
        if path.suffix != ".json" or path.name in {"artifact-manifest.json", "sealed-manifest.json"}:
            continue
        # Some sealed runtime artifacts deliberately use a .json suffix while
        # carrying opaque fixture bytes.  They are not report candidates.  A
        # matching report is still decoded strictly below, including duplicate
        # key and non-finite-number rejection.
        try:
            value = load_json(path, f"{role} JSON artifact {path}")
        except AssemblyError:
            continue
        if isinstance(value, dict) and value.get("schemaVersion") == expected_schema:
            matches.append((path, value))
    require(len(matches) == 1, f"{role} must contain exactly one {expected_schema} report; found {len(matches)}")
    return matches[0]


def validate_suite(
    root: Path,
    role: str,
    expected_schema: str,
    evidence_root: Path,
) -> tuple[Path, dict[str, Any], Path, set[Path], dict[Path, dict[str, Any]]]:
    suite = checked_directory(root, f"{role} suite root")
    relative_path(evidence_root, suite, f"{role} suite root")
    files = scan_regular_tree(suite, f"{role} suite")
    report_path, report = find_report(suite, files, expected_schema, role)
    candidates = [
        suite / name
        for name in ("artifact-manifest.json", "sealed-manifest.json")
        if (suite / name).is_file()
    ]
    valid: list[tuple[Path, set[Path], dict[Path, dict[str, Any]]]] = []
    failures: list[str] = []
    for candidate in candidates:
        try:
            _, sealed, facts = validate_seal(
                suite,
                candidate.resolve(strict=True),
                files,
                role,
            )
            require(
                report_path in sealed,
                f"seal {candidate} does not include the {role} report",
            )
            valid.append((candidate.resolve(strict=True), sealed, facts))
        except AssemblyError as error:
            failures.append(f"{candidate.name}: {error}")
    require(
        len(valid) == 1,
        f"{role} must have exactly one complete top-level seal; "
        f"valid={len(valid)} failures={failures}",
    )
    return report_path, report, valid[0][0], valid[0][1], valid[0][2]


def validate_packaged_candidate(
    value: Any,
    candidate: Mapping[str, Any],
    label: str,
) -> None:
    package = require_mapping(value, label)
    require(
        package.get("schemaVersion") == PACKAGED_CANDIDATE_SCHEMA,
        f"{label} schema is unsupported",
    )
    expected = {
        "sourceCommit": candidate["sourceCommit"],
        "sourceTreeIdentitySHA256": candidate["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": candidate["runtimeManifestFileSHA256"],
        "runtimeArtifactSetSHA256": candidate["runtimeArtifactSetSHA256"],
        "runtimeSourceRevision": candidate["runtimeSourceRevision"],
        "releaseConfigurationSHA256": candidate["releaseConfigurationSHA256"],
        "applicationArchiveSHA256": candidate["appBundleSHA256"],
        "bundleIdentifier": candidate["bundleIdentifier"],
        "productVersion": candidate["productVersion"],
        "productBuild": candidate["productBuild"],
        "buildConfiguration": "Release",
    }
    for key, expected_value in expected.items():
        require(
            package.get(key) == expected_value,
            f"{label}.{key} differs from the inner candidate",
        )


def validate_report_candidate(
    role: str,
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
) -> None:
    if role in FULL_CANDIDATE_ROLES:
        require(
            report.get("candidate") == candidate,
            f"{role} report candidate differs from the inner candidate",
        )
        return
    if role == "quality":
        identities = require_mapping(report.get("identities"), "quality.identities")
        for key in (
            "sourceCommit",
            "sourceTreeIdentitySHA256",
            "runtimeManifestSHA256",
            "runtimeSourceRevision",
        ):
            require(
                identities.get(key) == candidate[key],
                f"quality.identities.{key} differs from the inner candidate",
            )
        validate_packaged_candidate(
            identities.get("packagedCandidateIdentity"),
            candidate,
            "quality packaged candidate",
        )
        return
    require(
        role == "same_scope_performance",
        f"candidate validation is unimplemented for role: {role}",
    )
    summary = require_mapping(report.get("candidate"), "performance.candidate")
    expected = {
        "sourceRevision": candidate["sourceCommit"],
        "sourceTreeSHA256": candidate["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
    }
    for key, expected_value in expected.items():
        require(summary.get(key) == expected_value, f"performance.candidate.{key} differs from the inner candidate")
    validate_packaged_candidate(
        summary.get("packagedCandidateIdentity"),
        candidate,
        "performance packaged candidate",
    )


def collect_evidence_files(
    evidence_root: Path,
    suite_roots: Mapping[str, Path],
    output: Path,
    sealed_facts: Mapping[Path, Mapping[str, Any]],
) -> tuple[list[Path], dict[str, list[Path]]]:
    roots = list(suite_roots.values())
    for index, first in enumerate(roots):
        for second in roots[index + 1 :]:
            require(
                first != second
                and first not in second.parents
                and second not in first.parents,
                "suite roots must be distinct and non-overlapping",
            )
    files = scan_regular_tree(evidence_root, "evidence root")
    require(output not in files, "output already exists")
    by_hash: dict[str, list[Path]] = {}
    for path in files:
        require(
            any(path == root or root in path.parents for root in roots),
            f"unexpected file outside the eight suite roots: {path}",
        )
        if path in sealed_facts:
            identity = require_hex(
                sealed_facts[path]["sha256"],
                64,
                f"sealed evidence artifact {path}.sha256",
            )
            by_hash.setdefault(identity, []).append(path)
    for matches in by_hash.values():
        matches.sort(
            key=lambda item: relative_path(
                evidence_root,
                item,
                "evidence artifact",
            )
        )
    return files, by_hash


def binding_for(
    pointer: str,
    report: Mapping[str, Any],
    sealed_paths: set[Path],
    sealed_facts: Mapping[Path, Mapping[str, Any]],
    evidence_root: Path,
    by_hash: Mapping[str, Sequence[Path]],
    role: str,
) -> dict[str, Any]:
    identity = require_hex(
        json_pointer(report, pointer, f"{role} binding {pointer}"),
        64,
        f"{role} report identity {pointer}",
    )
    matches = [path for path in by_hash.get(identity, ()) if path in sealed_paths]
    require(
        matches,
        f"{role} binding {pointer} has no sealed role artifact with SHA-256 {identity}",
    )
    expected_name = BINDING_BASENAME_REQUIREMENTS.get((role, pointer))
    if expected_name is not None:
        matches = [path for path in matches if path.name == expected_name]
        require(
            matches,
            f"{role} binding {pointer} has no evidence artifact named {expected_name}",
        )
    matches.sort(
        key=lambda path: relative_path(
            evidence_root,
            path,
            f"{role} binding target",
        )
    )
    result = descriptor_from_seal(matches[0], evidence_root, sealed_facts)
    return {"jsonPointer": pointer, **result}


def validate_output_path(
    path: Path,
    evidence_root: Path,
    suite_roots: Mapping[str, Path],
) -> Path:
    raw = path.expanduser()
    require(not raw.is_symlink(), "output cannot be a symbolic link")
    try:
        output = raw.resolve()
    except (OSError, ValueError) as error:
        raise AssemblyError(f"output path is invalid: {error}") from error
    require(not output.exists(), f"output already exists: {output}")
    require(
        output.parent == evidence_root,
        "output must be a new direct child of the evidence root",
    )
    require(
        all(
            output != root and root not in output.parents
            for root in suite_roots.values()
        ),
        "output cannot be inside a sealed suite",
    )
    return output


def assemble_index(
    *,
    candidate_path: Path,
    evidence_root: Path,
    suite_roots: Mapping[str, Path],
    contract_path: Path = DEFAULT_CONTRACT,
    output_path: Path | None = None,
) -> dict[str, Any]:
    root = checked_directory(evidence_root, "evidence root")
    _, contract = validate_contract(contract_path)
    _, candidate = validate_candidate(candidate_path, contract)
    expected_roles = set(EXPECTED_ROLES)
    observed_roles = set(suite_roots)
    require(
        observed_roles == expected_roles,
        f"suite role set mismatch; missing={sorted(expected_roles-observed_roles)}, "
        f"unexpected={sorted(observed_roles-expected_roles)}",
    )
    resolved_roots = {
        role: checked_directory(path, f"{role} suite root")
        for role, path in suite_roots.items()
    }
    output = validate_output_path(
        output_path or (root / "release-candidate-evidence.json"),
        root,
        resolved_roots,
    )

    reports: dict[
        str,
        tuple[
            Path,
            dict[str, Any],
            Path,
            set[Path],
            dict[Path, dict[str, Any]],
        ],
    ] = {}
    for role in EXPECTED_ROLES:
        reports[role] = validate_suite(
            resolved_roots[role],
            role,
            contract["evidenceSchemas"][role],
            root,
        )
        validate_report_candidate(role, reports[role][1], candidate)

    sealed_facts: dict[Path, dict[str, Any]] = {}
    for role in EXPECTED_ROLES:
        for path, facts in reports[role][4].items():
            require(
                path not in sealed_facts,
                f"evidence artifact belongs to multiple role seals: {path}",
            )
            sealed_facts[path] = facts
    _, by_hash = collect_evidence_files(
        root,
        resolved_roots,
        output,
        sealed_facts,
    )
    entries: list[dict[str, Any]] = []
    binding_contract = require_mapping(contract["identityBindings"], "identityBindings")
    for role in EXPECTED_ROLES:
        report_path, report, seal_path, sealed_paths, role_facts = reports[role]
        pointers = binding_contract[role]
        bindings = [
            binding_for(
                pointer,
                report,
                sealed_paths,
                role_facts,
                root,
                by_hash,
                role,
            )
            for pointer in pointers
        ]
        contract_pointer = (
            "/identities/contractSHA256"
            if role == "quality"
            else "/contractSHA256"
        )
        contract_identity = require_hex(
            json_pointer(report, contract_pointer, f"{role} report contract"),
            64,
            f"{role} report contract",
        )
        require(
            any(item["jsonPointer"] == contract_pointer for item in bindings),
            f"{role} does not bind its report contract",
        )
        entries.append(
            {
                "role": role,
                **descriptor_from_seal(report_path, root, role_facts),
                "contractSHA256": contract_identity,
                "sealedManifest": descriptor(seal_path, root),
                "identityBindings": bindings,
            }
        )
    return {
        "schemaVersion": INDEX_SCHEMA,
        "candidate": candidate,
        "waivers": [],
        "evidence": entries,
    }


def write_index(path: Path, value: Mapping[str, Any]) -> None:
    temporary = path.parent / f".{path.name}.assembling"
    require(not temporary.exists(), f"temporary output already exists: {temporary}")
    data = canonical_bytes(value) + b"\n"
    try:
        descriptor_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor_fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path, follow_symlinks=False)
        try:
            temporary.unlink()
        except BaseException:
            path.unlink(missing_ok=True)
            raise
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def parse_suite(value: str) -> tuple[str, Path]:
    role, separator, raw_path = value.partition("=")
    require(separator == "=" and role != "" and raw_path != "", "--suite must be ROLE=ROOT")
    require(role in EXPECTED_ROLES, f"unexpected suite role: {role}")
    return role, Path(raw_path)


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True, help="inner candidate-identity.json")
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--suite", action="append", required=True, metavar="ROLE=ROOT")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    parsed: dict[str, Path] = {}
    for value in arguments.suite:
        role, path = parse_suite(value)
        require(role not in parsed, f"duplicate suite role: {role}")
        parsed[role] = path
    index = assemble_index(
        candidate_path=arguments.candidate,
        evidence_root=arguments.evidence_root,
        suite_roots=parsed,
        contract_path=arguments.contract,
        output_path=arguments.output,
    )
    output = validate_output_path(
        arguments.output,
        checked_directory(arguments.evidence_root, "evidence root"),
        {
            role: checked_directory(path, f"{role} suite root")
            for role, path in parsed.items()
        },
    )
    write_index(output, index)
    print(f"{sha256(output)}  {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssemblyError, OSError, KeyError, TypeError) as error:
        print(f"release evidence index assembly failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
