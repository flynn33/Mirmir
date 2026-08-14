#!/usr/bin/env python3
"""Fail-closed replay evaluator for the deterministic-engine v4 support matrix.

The capture tool owns execution.  This module owns admissibility: it reopens
the sealed evidence, validates every nested descriptor, independently derives
the candidate/runtime/architecture/signing/test summaries, and compares the
published report with that reconstruction.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
from typing import Any, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-ash-v4-support-matrix-contract-v1"
REPORT_SCHEMA = "mirmir-ash-v4-support-matrix-report-v1"
ROW_SCHEMA = "mirmir-ash-v4-support-matrix-row-v1"
SUMMARY_SCHEMA = "mirmir-ash-v4-support-matrix-row-summary-v1"
SIGNING_SCHEMA = "mirmir-ash-v4-support-test-signing-v1"
HARDWARE_SCHEMA = "mirmir-ash-v4-support-hardware-v1"
SOFTWARE_SCHEMA = "mirmir-ash-v4-support-software-v1"
EVIDENCE_SCHEMA = "mirmir-ash-v4-support-matrix-evidence-v1"
RUNTIME_SCHEMA = "ash.p06.runtime-manifest.v1"
RUNTIME_ID = "ash-p06-deterministic-v4"
RUNTIME_STATUS = "release_qualified"
MANIFEST_DOMAIN = b"ash-p06-runtime-manifest-v4\0"
HEX = frozenset("0123456789abcdef")
EXPECTED_SKIPPED_TESTS = [
    "DeterministicMetalBackendTests/testCaptureV3BaselineWhenRequested()",
    "VideoProcessingSessionTests/testCaptureV3EndToEndBaselineWhenRequested()",
]

SCRIPT_DIRECTORY = Path(__file__).resolve().parent


class SupportEvidenceError(ValueError):
    """Support evidence is incomplete, stale, malformed, or contradictory."""


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SupportEvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(token: str) -> Any:
    raise SupportEvidenceError(f"non-finite JSON number: {token}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except SupportEvidenceError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SupportEvidenceError(f"cannot read JSON {path}: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def pretty_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
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
        raise SupportEvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SupportEvidenceError(message)


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be text")
    return value


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    require(type(value) is int and value >= minimum, f"{label} must be an integer >= {minimum}")
    return value


def require_bool(value: Any, label: str, expected: bool | None = None) -> bool:
    require(type(value) is bool, f"{label} must be boolean")
    if expected is not None:
        require(value is expected, f"{label} must be {str(expected).lower()}")
    return value


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, extra={sorted(actual-expected_set)}",
    )


def require_sha256(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(len(text) == 64 and set(text) <= HEX, f"{label} must be a lowercase SHA-256")
    return text


def require_revision(value: Any, label: str, lengths: tuple[int, ...] = (40,)) -> str:
    text = require_string(value, label)
    require(len(text) in lengths and set(text) <= HEX, f"{label} must be a lowercase hexadecimal revision")
    return text


def safe_relative(value: Any, label: str) -> PurePosixPath:
    text = require_string(value, f"{label}.path")
    path = PurePosixPath(text)
    require(
        text == path.as_posix()
        and not path.is_absolute()
        and "\\" not in text
        and all(part not in ("", ".", "..") for part in path.parts),
        f"{label} path is unsafe",
    )
    return path


def checked_file(root: Path, value: Any, label: str) -> Path:
    relative = safe_relative(value, label)
    root = root.resolve(strict=True)
    lexical = root
    for part in relative.parts:
        lexical = lexical / part
        require(not lexical.is_symlink(), f"{label} traverses a symbolic link")
    try:
        resolved = lexical.resolve(strict=True)
    except OSError as error:
        raise SupportEvidenceError(f"{label} is missing: {error}") from error
    require(root in resolved.parents and resolved.is_file(), f"{label} escapes evidence root")
    return resolved


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    evidence = root.resolve(strict=True)
    require(evidence in resolved.parents, f"artifact is outside evidence root: {resolved}")
    return {
        "path": resolved.relative_to(evidence).as_posix(),
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def validate_descriptor(
    root: Path,
    value: Any,
    label: str,
    *,
    allowed_root: Path | None = None,
) -> tuple[dict[str, Any], Path]:
    item = require_mapping(value, label)
    require_exact_keys(item, ("path", "byteCount", "sha256"), label)
    path = checked_file(root, item["path"], label)
    if allowed_root is not None:
        allowed = allowed_root.resolve(strict=True)
        require(allowed in path.parents, f"{label} is outside its row evidence")
    byte_count = require_integer(item["byteCount"], f"{label}.byteCount")
    expected = require_sha256(item["sha256"], f"{label}.sha256")
    require(path.stat().st_size == byte_count, f"{label} byte count mismatch")
    require(sha256_file(path) == expected, f"{label} SHA-256 mismatch")
    return item, path


def regular_files(root: Path, excluded: set[Path] | None = None) -> list[Path]:
    excluded_resolved = {path.resolve() for path in (excluded or set())}
    files: list[Path] = []
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"symbolic link in support evidence: {path}")
        if path.is_file() and path.resolve() not in excluded_resolved:
            files.append(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def validate_root_seal(root: Path) -> set[str]:
    manifest_path = root / "sealed-manifest.json"
    manifest = require_mapping(load_json(manifest_path), "support evidence manifest")
    require_exact_keys(manifest, ("schemaVersion", "artifacts"), "support evidence manifest")
    require(manifest["schemaVersion"] == EVIDENCE_SCHEMA, "support evidence manifest schema mismatch")
    artifacts = require_list(manifest["artifacts"], "support evidence artifacts")
    declared: list[str] = []
    for index, raw in enumerate(artifacts):
        item, _ = validate_descriptor(root, raw, f"support evidence artifact[{index}]")
        require(item["path"] != "sealed-manifest.json", "support evidence seal cannot seal itself")
        require(item["path"] not in declared, f"duplicate sealed artifact: {item['path']}")
        declared.append(item["path"])
    require(declared == sorted(declared), "support evidence artifact order is not canonical")
    actual = [
        path.relative_to(root).as_posix()
        for path in regular_files(root, {manifest_path})
    ]
    require(declared == actual, "support evidence file set differs from the root seal")
    return set(declared)


def validate_candidate(value: Any) -> dict[str, Any]:
    document = require_mapping(value, "candidate input")
    candidate = require_mapping(document.get("candidate", document), "candidate")
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
    require_revision(candidate["runtimeSourceRevision"], "candidate.runtimeSourceRevision", (40, 64))
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"candidate.{key}")
    return dict(candidate)


def validate_contract(value: Any) -> dict[str, Any]:
    contract = require_mapping(value, "support contract")
    require_exact_keys(
        contract,
        {
            "schemaVersion",
            "buildConfiguration",
            "developmentTeam",
            "expectedSkippedTests",
            "machineClasses",
            "minimumPassingTestCount",
            "project",
            "releaseConfigurationPath",
            "runtimeResourcePath",
            "scheme",
            "tools",
            "unexpectedSkipAllowance",
        },
        "support contract",
    )
    require(contract["schemaVersion"] == CONTRACT_SCHEMA, "unsupported support contract")
    require(contract["buildConfiguration"] == "Release", "support matrix must use Release")
    team = require_string(contract["developmentTeam"], "contract.developmentTeam")
    require(len(team) == 10 and team.isalnum() and team == team.upper(), "support development team is invalid")
    expected_paths = {
        "project": "Mirmir.xcodeproj",
        "releaseConfigurationPath": "script/v4/release-candidate-v4.xcconfig",
        "runtimeResourcePath": "Mirmir/Resources/ASH-P06.bundle",
        "scheme": "Mirmir",
    }
    for key, expected in expected_paths.items():
        require(contract[key] == expected, f"contract.{key} differs from the locked path")
    require(
        require_integer(contract["minimumPassingTestCount"], "contract.minimumPassingTestCount", 300) == 300,
        "support minimum passing-test count differs",
    )
    require(
        require_integer(contract["unexpectedSkipAllowance"], "contract.unexpectedSkipAllowance") == 0,
        "support contract permits unexpected skips",
    )
    expected_skips = require_list(contract["expectedSkippedTests"], "contract.expectedSkippedTests")
    require(
        expected_skips == EXPECTED_SKIPPED_TESTS,
        "support expected-skip set is not canonical",
    )
    rows = require_list(contract["machineClasses"], "contract.machineClasses")
    expected_rows = [
        {
            "destinationArchitecture": "arm64",
            "id": "reference",
            "runtimeMode": "native_apple_silicon",
        },
        {
            "destinationArchitecture": "x86_64",
            "id": "supported",
            "runtimeMode": "rosetta_2_compatibility",
        },
    ]
    require(rows == expected_rows, "support architecture matrix differs from the locked matrix")
    tools = require_mapping(contract["tools"], "contract.tools")
    require_exact_keys(tools, ("captureSourceSHA256", "evaluatorSHA256", "runnerSHA256"), "contract.tools")
    for key in tools:
        require_sha256(tools[key], f"contract.tools.{key}")
    return contract


def validate_tool_bindings(root: Path, contract: Mapping[str, Any]) -> dict[str, str]:
    paths = {
        "captureSourceSHA256": root / "capture-tool.py",
        "evaluatorSHA256": root / "support-matrix-evaluator.py",
        "runnerSHA256": root / "support-matrix-runner.sh",
    }
    for key, path in paths.items():
        require(path.is_file() and not path.is_symlink(), f"sealed support tool is missing: {path.name}")
        require(sha256_file(path) == contract["tools"][key], f"sealed support tool identity differs: {key}")
    require(
        sha256_file(Path(__file__).resolve()) == contract["tools"]["evaluatorSHA256"],
        "executing support evaluator differs from the locked evaluator",
    )
    return dict(contract["tools"])


def validate_runtime(path: Path, candidate: Mapping[str, Any]) -> dict[str, Any]:
    document = require_mapping(load_json(path), "runtime manifest")
    raw = path.read_bytes()
    require(raw == canonical_bytes(document), "runtime manifest is not canonical JSON")
    file_identity = sha256_bytes(raw)
    semantic_identity = sha256_bytes(MANIFEST_DOMAIN + canonical_bytes(document))
    require(file_identity == candidate["runtimeManifestFileSHA256"], "runtime manifest file identity differs from candidate")
    require(semantic_identity == candidate["runtimeManifestSHA256"], "runtime semantic identity differs from candidate")
    require(document.get("schemaID") == RUNTIME_SCHEMA, "runtime manifest schema is not P06")
    require(document.get("runtimeID") == RUNTIME_ID, "runtime manifest ID is not production P06")
    require(document.get("releaseStatus") == RUNTIME_STATUS, "runtime manifest is not release-qualified")
    provenance = require_mapping(document.get("provenance"), "runtime provenance")
    source_revision = require_revision(provenance.get("sourceRevision"), "runtime provenance source revision", (40, 64))
    require(source_revision == candidate["runtimeSourceRevision"], "runtime source revision differs from candidate")
    require_sha256(provenance.get("builderSourceSHA256"), "runtime provenance builder")
    require_mapping(provenance.get("toolchain"), "runtime provenance toolchain")
    forbidden = json.dumps(document, sort_keys=True).lower()
    require(
        not any(token in forbidden for token in ("p05", "preview", "development", "dev-runtime")),
        "runtime manifest retains a preview/development identity",
    )
    return {
        "runtimeID": RUNTIME_ID,
        "releaseStatus": RUNTIME_STATUS,
        "semanticManifestSHA256": semantic_identity,
        "manifestFileSHA256": file_identity,
        "sourceRevision": source_revision,
    }


def skipped_identifiers(value: Any) -> set[str]:
    result: set[str] = set()

    def visit(node: Any) -> None:
        if isinstance(node, dict):
            if node.get("result") == "Skipped":
                identifier = node.get("nodeIdentifier")
                require(isinstance(identifier, str) and identifier != "", "skipped test omits nodeIdentifier")
                result.add(identifier)
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(value)
    return result


def summary_counts(summary: Mapping[str, Any]) -> tuple[int, int, int, str]:
    return (
        require_integer(summary.get("passedTests"), "test summary passedTests"),
        require_integer(summary.get("failedTests"), "test summary failedTests"),
        require_integer(summary.get("skippedTests"), "test summary skippedTests"),
        require_string(summary.get("result"), "test summary result"),
    )


def signature_identity(
    text: str,
    *,
    expected_identifier: str,
    expected_team: str,
    expected_architecture: str,
    label: str,
) -> dict[str, Any]:
    fields: dict[str, list[str]] = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator and key and value:
            fields.setdefault(key, []).append(value)
    identifiers = fields.get("Identifier", [])
    formats = fields.get("Format", [])
    teams = fields.get("TeamIdentifier", [])
    authorities = fields.get("Authority", [])
    code_directories = [line for line in text.splitlines() if line.startswith("CodeDirectory ")]
    require(identifiers == [expected_identifier], f"{label} signing identifier differs")
    require(teams == [expected_team], f"{label} signing team differs")
    require(len(formats) == 1 and f"({expected_architecture})" in formats[0], f"{label} signing architecture differs")
    require(len(code_directories) == 1 and "flags=0x10000(runtime)" in code_directories[0], f"{label} lacks hardened runtime")
    require(authorities and authorities[0].startswith("Apple Development:"), f"{label} lacks Apple Development signing")
    return {
        "identifier": identifiers[0],
        "format": formats[0],
        "teamIdentifier": teams[0],
        "leafAuthority": authorities[0],
        "hardenedRuntime": True,
        "executionArchitecture": expected_architecture,
    }


def validate_xcode_command(command_value: Any, contract: Mapping[str, Any], row: Mapping[str, Any]) -> list[str]:
    command = require_list(command_value, "row command")
    require(all(isinstance(item, str) and item for item in command), "row command contains a non-text argument")
    architecture = row["destinationArchitecture"]
    expected: list[str | None] = [
        "xcodebuild",
        "test",
        "-project",
        contract["project"],
        "-scheme",
        contract["scheme"],
        "-configuration",
        "Release",
        "-destination",
        f"platform=macOS,arch={architecture}",
        "-derivedDataPath",
        None,
        "-resultBundlePath",
        None,
        "-xcconfig",
        None,
        f"DEVELOPMENT_TEAM={contract['developmentTeam']}",
        "CODE_SIGN_STYLE=Automatic",
        "CODE_SIGN_IDENTITY=Apple Development",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGNING_REQUIRED=YES",
        "ONLY_ACTIVE_ARCH=YES",
        f"ARCHS={architecture}",
        "ENABLE_TESTABILITY=YES",
    ]
    require(len(command) == len(expected), "row xcode command argument count differs")
    for index, item in enumerate(expected):
        if item is not None:
            require(command[index] == item, f"row xcode command differs at argument {index}")
    derived = Path(command[11])
    result = Path(command[13])
    xcconfig = Path(command[15])
    require(derived.is_absolute() and derived.name == f"DerivedData-{row['id']}", "row derived-data path is not isolated")
    require(result.is_absolute() and result.name == f"{row['id']}.xcresult", "row result-bundle path differs")
    expected_suffix = PurePosixPath(contract["releaseConfigurationPath"]).parts
    require(xcconfig.is_absolute() and tuple(xcconfig.parts[-len(expected_suffix):]) == expected_suffix, "row xcconfig path differs")
    return list(command)


def validate_hardware(value: Any, row: Mapping[str, Any]) -> dict[str, Any]:
    document = require_mapping(value, "hardware summary")
    require_exact_keys(
        document,
        ("schemaVersion", "machineClass", "executionArchitecture", "hardwareModel", "physicalMemoryBytes", "processorBrand"),
        "hardware summary",
    )
    require(document["schemaVersion"] == HARDWARE_SCHEMA, "hardware summary schema mismatch")
    require(document["machineClass"] == row["id"], "hardware machine class differs")
    require(document["executionArchitecture"] == row["destinationArchitecture"], "hardware architecture differs")
    require_string(document["hardwareModel"], "hardware model")
    require_integer(document["physicalMemoryBytes"], "physical memory", 1)
    require_string(document["processorBrand"], "processor brand")
    return document


def validate_software(value: Any, row: Mapping[str, Any]) -> dict[str, Any]:
    document = require_mapping(value, "software summary")
    require_exact_keys(
        document,
        (
            "schemaVersion", "machineClass", "executionArchitecture", "macOSProductVersion",
            "macOSBuildVersion", "xcode", "swift", "metal", "sdkVersion", "sdkBuildVersion",
        ),
        "software summary",
    )
    require(document["schemaVersion"] == SOFTWARE_SCHEMA, "software summary schema mismatch")
    require(document["machineClass"] == row["id"], "software machine class differs")
    require(document["executionArchitecture"] == row["destinationArchitecture"], "software architecture differs")
    for key in ("macOSProductVersion", "macOSBuildVersion", "swift", "metal", "sdkVersion", "sdkBuildVersion"):
        require_string(document[key], f"software {key}")
    xcode = require_list(document["xcode"], "software xcode")
    require(len(xcode) >= 2 and all(isinstance(item, str) and item for item in xcode), "software xcode identity is incomplete")
    return document


ATTESTATION_KEYS = {
    "schemaVersion",
    "id",
    "machineClass",
    "runtimeMode",
    "executionArchitecture",
    "sourceCommit",
    "sourceTreeIdentitySHA256",
    "runtimeManifestSHA256",
    "releaseConfigurationSHA256",
    "appBundleSHA256",
    "command",
    "invocationSHA256",
    "exitStatus",
    "passedTestCount",
    "failedTestCount",
    "skippedTestCount",
    "expectedSkippedTests",
    "unexpectedSkippedTests",
    "hardwareArtifact",
    "softwareArtifact",
    "summaryArtifact",
    "testTreeArtifact",
    "transcriptArtifact",
    "codeSignatureVerificationArtifact",
    "appSignatureArtifact",
    "testSignatureArtifact",
    "signingSummaryArtifact",
    "semanticSummaryArtifact",
    "fullQualificationMatrixPass",
}


def validate_row(
    root: Path,
    row_contract: Mapping[str, Any],
    contract: Mapping[str, Any],
    candidate: Mapping[str, Any],
    runtime: Mapping[str, Any],
    published_row: Any,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    machine_class = row_contract["id"]
    architecture = row_contract["destinationArchitecture"]
    row_id = f"{machine_class}-{architecture}"
    row_root = root / machine_class
    require(row_root.is_dir() and not row_root.is_symlink(), f"support row directory is missing: {machine_class}")
    report_row = require_mapping(published_row, f"published support row {row_id}")
    require_exact_keys(
        report_row,
        (
            "id", "machineClass", "hardwareIdentitySHA256", "softwareImageSHA256",
            "appBundleSHA256", "runtimeManifestSHA256", "fullQualificationMatrixPass",
            "unexpectedSkipCount", "externalEvidenceArtifact",
        ),
        f"published support row {row_id}",
    )
    _, attestation_path = validate_descriptor(
        root,
        report_row["externalEvidenceArtifact"],
        f"support row {row_id} attestation",
        allowed_root=row_root,
    )
    require(attestation_path == row_root / "attestation.json", f"support row {row_id} attestation path differs")
    attestation = require_mapping(load_json(attestation_path), f"support row {row_id} attestation")
    require_exact_keys(attestation, ATTESTATION_KEYS, f"support row {row_id} attestation")
    require(attestation["schemaVersion"] == ROW_SCHEMA, f"support row {row_id} schema mismatch")
    expected_identity = {
        "id": row_id,
        "machineClass": machine_class,
        "runtimeMode": row_contract["runtimeMode"],
        "executionArchitecture": architecture,
        "sourceCommit": candidate["sourceCommit"],
        "sourceTreeIdentitySHA256": candidate["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "releaseConfigurationSHA256": candidate["releaseConfigurationSHA256"],
        "appBundleSHA256": candidate["appBundleSHA256"],
    }
    for key, expected in expected_identity.items():
        require(attestation[key] == expected, f"support row {row_id} {key} differs")

    paths: dict[str, Path] = {}
    descriptor_fields = {
        "hardwareArtifact": "hardware.json",
        "softwareArtifact": "software.json",
        "summaryArtifact": "test-summary.json",
        "testTreeArtifact": "test-tree.json",
        "transcriptArtifact": "xcodebuild.log",
        "codeSignatureVerificationArtifact": "codesign-verification.log",
        "appSignatureArtifact": "app-signature.txt",
        "testSignatureArtifact": "test-signature.txt",
        "signingSummaryArtifact": "signing-summary.json",
        "semanticSummaryArtifact": "semantic-summary.json",
    }
    for field, filename in descriptor_fields.items():
        _, path = validate_descriptor(
            root,
            attestation[field],
            f"support row {row_id}.{field}",
            allowed_root=row_root,
        )
        require(path == row_root / filename, f"support row {row_id}.{field} path differs")
        paths[field] = path
    expected_files = {"attestation.json", *descriptor_fields.values()}
    actual_files = {
        path.relative_to(row_root).as_posix()
        for path in regular_files(row_root)
    }
    require(actual_files == expected_files, f"support row {row_id} artifact set differs")

    command = validate_xcode_command(attestation["command"], contract, row_contract)
    invocation = sha256_bytes(canonical_bytes(command))
    require(attestation["invocationSHA256"] == invocation, f"support row {row_id} invocation identity differs")
    require_integer(attestation["exitStatus"], f"support row {row_id} exit status")
    require(attestation["exitStatus"] == 0, f"support row {row_id} xcodebuild failed")

    transcript = paths["transcriptArtifact"].read_text(encoding="utf-8")
    require("** TEST SUCCEEDED **" in transcript, f"support row {row_id} transcript lacks test success evidence")
    require("** TEST FAILED **" not in transcript, f"support row {row_id} transcript records a test failure")

    summary = require_mapping(load_json(paths["summaryArtifact"]), f"support row {row_id} test summary")
    test_tree = load_json(paths["testTreeArtifact"])
    passed, failed, skipped, result = summary_counts(summary)
    require(result == "Passed", f"support row {row_id} xcresult is not Passed")
    require(passed >= contract["minimumPassingTestCount"], f"support row {row_id} has insufficient passing tests")
    require(failed == 0, f"support row {row_id} contains failed tests")
    devices = require_list(summary.get("devicesAndConfigurations"), f"support row {row_id} devices")
    observed_architectures: set[str] = set()
    for index, raw in enumerate(devices):
        item = require_mapping(raw, f"support row {row_id} device[{index}]")
        device = require_mapping(item.get("device"), f"support row {row_id} device[{index}].device")
        observed_architectures.add(require_string(device.get("architecture"), f"support row {row_id} device architecture"))
    require(observed_architectures == {architecture}, f"support row {row_id} executed on another architecture")
    expected_skips = list(contract["expectedSkippedTests"])
    observed_skips = sorted(skipped_identifiers(test_tree))
    require(observed_skips == expected_skips, f"support row {row_id} exact expected-skip set differs")
    require(skipped == len(expected_skips), f"support row {row_id} skipped-test count differs")
    require(require_integer(attestation["passedTestCount"], f"support row {row_id} attested passed tests") == passed, f"support row {row_id} passed-test count differs")
    require(require_integer(attestation["failedTestCount"], f"support row {row_id} attested failed tests") == failed, f"support row {row_id} failed-test count differs")
    require(require_integer(attestation["skippedTestCount"], f"support row {row_id} attested skipped tests") == skipped, f"support row {row_id} skipped-test count attestation differs")
    require(require_list(attestation["expectedSkippedTests"], f"support row {row_id} attested expected skips") == expected_skips, f"support row {row_id} expected skips differ")
    require(require_list(attestation["unexpectedSkippedTests"], f"support row {row_id} attested unexpected skips") == [], f"support row {row_id} contains unexpected skips")

    hardware = validate_hardware(load_json(paths["hardwareArtifact"]), row_contract)
    software = validate_software(load_json(paths["softwareArtifact"]), row_contract)
    hardware_sha = sha256_file(paths["hardwareArtifact"])
    software_sha = sha256_file(paths["softwareArtifact"])

    verification_text = paths["codeSignatureVerificationArtifact"].read_text(encoding="utf-8")
    require("valid on disk" in verification_text, f"support row {row_id} lacks positive code-signature verification")
    require(
        "satisfies its Designated Requirement" in verification_text,
        f"support row {row_id} lacks designated-requirement verification",
    )
    app_identity = signature_identity(
        paths["appSignatureArtifact"].read_text(encoding="utf-8"),
        expected_identifier="com.mirmir.app",
        expected_team=contract["developmentTeam"],
        expected_architecture=architecture,
        label=f"support row {row_id} app",
    )
    test_identity = signature_identity(
        paths["testSignatureArtifact"].read_text(encoding="utf-8"),
        expected_identifier="com.mirmir.app.tests",
        expected_team=contract["developmentTeam"],
        expected_architecture=architecture,
        label=f"support row {row_id} test bundle",
    )
    signing = {
        "schemaVersion": SIGNING_SCHEMA,
        "developmentTeam": contract["developmentTeam"],
        "app": app_identity,
        "testBundle": test_identity,
        "sameTeamIdentity": app_identity["teamIdentifier"] == test_identity["teamIdentifier"],
        "codeSignatureVerificationPass": True,
    }
    require(signing["sameTeamIdentity"], f"support row {row_id} app/test signing teams differ")
    observed_signing = load_json(paths["signingSummaryArtifact"])
    require(canonical_bytes(observed_signing) == canonical_bytes(signing), f"support row {row_id} signing summary differs from signature evidence")

    semantic_summary = {
        "schemaVersion": SUMMARY_SCHEMA,
        "row": {
            "id": row_id,
            "machineClass": machine_class,
            "runtimeMode": row_contract["runtimeMode"],
            "executionArchitecture": architecture,
        },
        "candidate": {
            "sourceCommit": candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": candidate["sourceTreeIdentitySHA256"],
            "appBundleSHA256": candidate["appBundleSHA256"],
            "releaseConfigurationSHA256": candidate["releaseConfigurationSHA256"],
        },
        "runtime": dict(runtime),
        "build": {
            "buildConfiguration": "Release",
            "command": command,
            "invocationSHA256": invocation,
            "transcriptSHA256": sha256_file(paths["transcriptArtifact"]),
        },
        "signing": {
            "developmentTeam": contract["developmentTeam"],
            "app": app_identity,
            "testBundle": test_identity,
            "sameTeamIdentity": True,
            "codeSignatureVerificationSHA256": sha256_file(paths["codeSignatureVerificationArtifact"]),
            "codeSignatureVerificationPass": True,
        },
        "tests": {
            "result": result,
            "passedTestCount": passed,
            "failedTestCount": failed,
            "skippedTestCount": skipped,
            "minimumPassingTestCount": contract["minimumPassingTestCount"],
            "expectedSkippedTests": expected_skips,
            "observedSkippedTests": observed_skips,
            "unexpectedSkippedTests": [],
            "summarySHA256": sha256_file(paths["summaryArtifact"]),
            "testTreeSHA256": sha256_file(paths["testTreeArtifact"]),
        },
        "environment": {
            "hardwareSHA256": hardware_sha,
            "softwareSHA256": software_sha,
        },
        "allRequiredChecksPassed": True,
    }
    observed_semantic = load_json(paths["semanticSummaryArtifact"])
    require(
        canonical_bytes(observed_semantic) == canonical_bytes(semantic_summary),
        f"support row {row_id} semantic summary differs from independent replay",
    )
    require_bool(attestation["fullQualificationMatrixPass"], f"support row {row_id} fullQualificationMatrixPass", True)

    expected_report_row = {
        "id": row_id,
        "machineClass": machine_class,
        "hardwareIdentitySHA256": hardware_sha,
        "softwareImageSHA256": software_sha,
        "appBundleSHA256": candidate["appBundleSHA256"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "fullQualificationMatrixPass": True,
        "unexpectedSkipCount": 0,
        "externalEvidenceArtifact": descriptor(attestation_path, root),
    }
    require(
        canonical_bytes(report_row) == canonical_bytes(expected_report_row),
        f"published support row {row_id} differs from replayed evidence",
    )
    return expected_report_row, hardware, software


def replay_evidence(root: Path) -> dict[str, Any]:
    root = root.expanduser().resolve(strict=True)
    require(root.is_dir() and not root.is_symlink(), "support evidence root is not a regular directory")
    sealed = validate_root_seal(root)
    required_top = {
        "suite-contract.json",
        "candidate.json",
        "runtime-manifest.json",
        "Release.xcconfig",
        "application-archive.zip",
        "capture-tool.py",
        "support-matrix-evaluator.py",
        "support-matrix-runner.sh",
        "report.json",
    }
    require(required_top.issubset(sealed), "support evidence omits a required top-level artifact")
    row_filenames = {
        "attestation.json",
        "app-signature.txt",
        "codesign-verification.log",
        "hardware.json",
        "semantic-summary.json",
        "signing-summary.json",
        "software.json",
        "test-signature.txt",
        "test-summary.json",
        "test-tree.json",
        "xcodebuild.log",
    }
    expected_sealed = required_top | {
        f"{row['id']}/{filename}"
        for row in validate_contract(load_json(root / "suite-contract.json"))["machineClasses"]
        for filename in row_filenames
    }
    require(sealed == expected_sealed, "support evidence contains an unexpected or missing artifact")
    contract_path = root / "suite-contract.json"
    contract = validate_contract(load_json(contract_path))
    tools = validate_tool_bindings(root, contract)
    candidate = validate_candidate(load_json(root / "candidate.json"))
    require(sha256_file(root / "Release.xcconfig") == candidate["releaseConfigurationSHA256"], "Release configuration differs from candidate")
    require(sha256_file(root / "application-archive.zip") == candidate["appBundleSHA256"], "application archive differs from candidate")
    runtime = validate_runtime(root / "runtime-manifest.json", candidate)

    observed_report = require_mapping(load_json(root / "report.json"), "support report")
    require_exact_keys(
        observed_report,
        (
            "schemaVersion", "contractSHA256", "candidate", "releaseEligible", "identities",
            "declaredSupportedMachineClassIDs", "rows", "supportMatrixGatePass",
        ),
        "support report",
    )
    published_rows = require_list(observed_report["rows"], "support report rows")
    require(len(published_rows) == len(contract["machineClasses"]), "support report row count differs")
    rows: list[dict[str, Any]] = []
    hardware_documents: list[dict[str, Any]] = []
    software_documents: list[dict[str, Any]] = []
    for row_contract, published in zip(contract["machineClasses"], published_rows):
        row, hardware, software = validate_row(
            root,
            row_contract,
            contract,
            candidate,
            runtime,
            published,
        )
        rows.append(row)
        hardware_documents.append(hardware)
        software_documents.append(software)
    normalized_hardware = [
        {key: value for key, value in document.items() if key not in {"machineClass", "executionArchitecture"}}
        for document in hardware_documents
    ]
    normalized_software = [
        {key: value for key, value in document.items() if key not in {"machineClass", "executionArchitecture"}}
        for document in software_documents
    ]
    require(normalized_hardware[0] == normalized_hardware[1], "support rows used different hardware")
    require(normalized_software[0] == normalized_software[1], "support rows used different software images")

    expected_report = {
        "schemaVersion": REPORT_SCHEMA,
        "contractSHA256": sha256_file(contract_path),
        "candidate": candidate,
        "releaseEligible": True,
        "identities": tools,
        "declaredSupportedMachineClassIDs": [row["id"] for row in contract["machineClasses"]],
        "rows": rows,
        "supportMatrixGatePass": True,
    }
    require(
        canonical_bytes(observed_report) == canonical_bytes(expected_report),
        "published support report differs from independent replay",
    )
    return expected_report


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    evaluate = subparsers.add_parser("evaluate", help="recompute and print the semantic report")
    evaluate.add_argument("--evidence", type=Path, required=True)
    verify = subparsers.add_parser("verify", help="recompute and verify the published report and seal")
    verify.add_argument("--evidence", type=Path, required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parser().parse_args(argv)
        report = replay_evidence(arguments.evidence)
        if arguments.command == "evaluate":
            sys.stdout.buffer.write(pretty_bytes(report))
        else:
            print(arguments.evidence.expanduser().resolve() / "report.json")
        return 0
    except (SupportEvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"support-matrix replay failed closed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
