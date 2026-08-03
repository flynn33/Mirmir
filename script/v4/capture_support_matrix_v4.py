#!/usr/bin/env python3
"""Run and seal the M7 native/Rosetta release support matrix."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Mapping


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIRECTORY / "support-matrix-contract-v1.json"
DEFAULT_EVALUATOR = SCRIPT_DIRECTORY / "support_matrix_v4.py"
DEFAULT_RUNNER = SCRIPT_DIRECTORY / "run_support_matrix_v4.sh"
EXPECTED_SKIPPED_TESTS = [
    "DeterministicMetalBackendTests/testCaptureV3BaselineWhenRequested()",
    "VideoProcessingSessionTests/testCaptureV3EndToEndBaselineWhenRequested()",
]
P06_SPEC = importlib.util.spec_from_file_location(
    "capture_p06_reproduction_v4_for_support",
    SCRIPT_DIRECTORY / "capture_p06_reproduction_v4.py",
)
if P06_SPEC is None or P06_SPEC.loader is None:
    raise RuntimeError("cannot load shared release identity implementation")
p06 = importlib.util.module_from_spec(P06_SPEC)
P06_SPEC.loader.exec_module(p06)


class SupportCaptureError(ValueError):
    """The support matrix is incomplete, stale, or failed."""


def run(
    command: list[str],
    *,
    cwd: Path,
    transcript: Path | None = None,
    require_success: bool = True,
) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        text=True,
    )
    if transcript is not None:
        transcript.parent.mkdir(parents=True, exist_ok=True)
        transcript.write_text(process.stdout, encoding="utf-8")
    if require_success and process.returncode != 0:
        raise SupportCaptureError(
            f"external command failed ({process.returncode}): {' '.join(command)}\n"
            + process.stdout[-8000:]
        )
    return process


def canonical_command_identity(command: list[str]) -> str:
    return p06.sha256_bytes(p06.canonical_bytes(command))


def skipped_identifiers(document: Any) -> set[str]:
    result: set[str] = set()

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            if value.get("result") == "Skipped":
                identifier = value.get("nodeIdentifier")
                if isinstance(identifier, str) and identifier:
                    result.add(identifier)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(document)
    return result


def summary_counts(summary: Mapping[str, Any]) -> tuple[int, int, int, str]:
    def integer(key: str) -> int:
        value = summary.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise SupportCaptureError(f"xcresult summary has invalid {key}")
        return value

    result = summary.get("result")
    if not isinstance(result, str) or not result:
        raise SupportCaptureError("xcresult summary omits its result")
    return integer("passedTests"), integer("failedTests"), integer("skippedTests"), result


def code_signature_summary(
    detail: str,
    *,
    expected_identifier: str,
    expected_team: str,
    expected_architecture: str,
) -> dict[str, Any]:
    fields: dict[str, list[str]] = {}
    for line in detail.splitlines():
        key, separator, value = line.partition("=")
        if separator and key and value:
            fields.setdefault(key, []).append(value)
    identifier = fields.get("Identifier", [])
    format_value = fields.get("Format", [])
    team = fields.get("TeamIdentifier", [])
    code_directory = [
        line for line in detail.splitlines() if line.startswith("CodeDirectory ")
    ]
    authorities = fields.get("Authority", [])
    if identifier != [expected_identifier]:
        raise SupportCaptureError("support test code-signing identifier differs")
    if team != [expected_team]:
        raise SupportCaptureError("support test code-signing team differs")
    if len(format_value) != 1 or f"({expected_architecture})" not in format_value[0]:
        raise SupportCaptureError("support test code-signing architecture differs")
    if len(code_directory) != 1 or "flags=0x10000(runtime)" not in code_directory[0]:
        raise SupportCaptureError("support test build lacks hardened runtime")
    if not authorities or not authorities[0].startswith("Apple Development:"):
        raise SupportCaptureError("support test build lacks Apple Development signing")
    return {
        "identifier": identifier[0],
        "format": format_value[0],
        "teamIdentifier": team[0],
        "leafAuthority": authorities[0],
        "hardenedRuntime": True,
        "executionArchitecture": expected_architecture,
    }


def environment_documents(machine_class: str, architecture: str) -> tuple[dict[str, Any], dict[str, Any]]:
    def output(command: list[str]) -> str:
        return run(command, cwd=Path.cwd()).stdout.strip()

    hardware = {
        "schemaVersion": "mirmir-ash-v4-support-hardware-v1",
        "machineClass": machine_class,
        "executionArchitecture": architecture,
        "hardwareModel": output(["sysctl", "-n", "hw.model"]),
        "physicalMemoryBytes": int(output(["sysctl", "-n", "hw.memsize"])),
        "processorBrand": output(["sysctl", "-n", "machdep.cpu.brand_string"]),
    }
    software = {
        "schemaVersion": "mirmir-ash-v4-support-software-v1",
        "machineClass": machine_class,
        "executionArchitecture": architecture,
        "macOSProductVersion": output(["sw_vers", "-productVersion"]),
        "macOSBuildVersion": output(["sw_vers", "-buildVersion"]),
        "xcode": output(["xcodebuild", "-version"]).splitlines(),
        "swift": output(["xcrun", "swiftc", "--version"]).splitlines()[0],
        "metal": output(["xcrun", "-sdk", "macosx", "metal", "--version"]).splitlines()[0],
        "sdkVersion": output(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        "sdkBuildVersion": output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
        ),
    }
    return hardware, software


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    return p06.descriptor(path, root)


def seal(root: Path, manifest_path: Path) -> None:
    p06.write_json(
        manifest_path,
        {
            "schemaVersion": "mirmir-ash-v4-support-matrix-evidence-v1",
            "artifacts": [descriptor(path, root) for path in p06.regular_files(root)],
        },
    )


def validate_contract(document: Any, *, verify_tools: bool = False) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise SupportCaptureError("support contract must be an object")
    expected_keys = {
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
    }
    if set(document) != expected_keys:
        raise SupportCaptureError("support contract field set is not canonical")
    if document.get("schemaVersion") != "mirmir-ash-v4-support-matrix-contract-v1":
        raise SupportCaptureError("unsupported support-matrix contract")
    if document.get("buildConfiguration") != "Release":
        raise SupportCaptureError("support matrix must use Release builds")
    development_team = document.get("developmentTeam")
    if (
        not isinstance(development_team, str)
        or len(development_team) != 10
        or not development_team.isalnum()
        or development_team != development_team.upper()
    ):
        raise SupportCaptureError("support contract has invalid Apple development team")
    expected_paths = {
        "project": "Mirmir.xcodeproj",
        "releaseConfigurationPath": "script/v4/release-candidate-v4.xcconfig",
        "runtimeResourcePath": "Mirmir/Resources/ASH-P06.bundle",
        "scheme": "Mirmir",
    }
    for key, expected in expected_paths.items():
        if document.get(key) != expected:
            raise SupportCaptureError(f"support contract has invalid {key}")
    minimum = document.get("minimumPassingTestCount")
    if isinstance(minimum, bool) or not isinstance(minimum, int) or minimum != 300:
        raise SupportCaptureError("support contract changes the locked minimum test coverage")
    rows = document.get("machineClasses")
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
    if rows != expected_rows:
        raise SupportCaptureError("support architecture matrix was narrowed or changed")
    expected_skips = document.get("expectedSkippedTests")
    if (
        not isinstance(expected_skips, list)
        or expected_skips != sorted(set(expected_skips))
        or expected_skips != EXPECTED_SKIPPED_TESTS
    ):
        raise SupportCaptureError("support contract expected-skip set is invalid")
    tools = document.get("tools")
    if not isinstance(tools, dict) or set(tools) != {
        "captureSourceSHA256",
        "evaluatorSHA256",
        "runnerSHA256",
    }:
        raise SupportCaptureError("support contract tool binding set is invalid")
    for key, value in tools.items():
        try:
            p06.require_hex(value, (64,), f"support contract tools.{key}")
        except p06.CaptureError as error:
            raise SupportCaptureError(str(error)) from error
    if verify_tools:
        actual = {
            "captureSourceSHA256": p06.sha256(Path(__file__).resolve()),
            "evaluatorSHA256": p06.sha256(DEFAULT_EVALUATOR),
            "runnerSHA256": p06.sha256(DEFAULT_RUNNER),
        }
        for key, identity in actual.items():
            if tools[key] != identity:
                raise SupportCaptureError(f"support contract tool identity differs: {key}")
    allowance = document.get("unexpectedSkipAllowance")
    if isinstance(allowance, bool) or not isinstance(allowance, int) or allowance != 0:
        raise SupportCaptureError("support contract must fail on every unexpected skip")
    return document


def capture_row(
    *,
    row_contract: Mapping[str, Any],
    contract: Mapping[str, Any],
    worktree: Path,
    staging: Path,
    temporary: Path,
    candidate: Mapping[str, Any],
    runtime_summary: Mapping[str, Any],
) -> dict[str, Any]:
    machine_class = row_contract.get("id")
    architecture = row_contract.get("destinationArchitecture")
    runtime_mode = row_contract.get("runtimeMode")
    if not all(isinstance(item, str) and item for item in (machine_class, architecture, runtime_mode)):
        raise SupportCaptureError("support machine-class declaration is malformed")
    row_root = staging / str(machine_class)
    row_root.mkdir()
    derived_data = temporary / f"DerivedData-{machine_class}"
    result_bundle = temporary / f"{machine_class}.xcresult"
    transcript = row_root / "xcodebuild.log"
    command = [
        "xcodebuild",
        "test",
        "-project",
        str(contract["project"]),
        "-scheme",
        str(contract["scheme"]),
        "-configuration",
        str(contract["buildConfiguration"]),
        "-destination",
        f"platform=macOS,arch={architecture}",
        "-derivedDataPath",
        str(derived_data),
        "-resultBundlePath",
        str(result_bundle),
        "-xcconfig",
        str(worktree / str(contract["releaseConfigurationPath"])),
        f"DEVELOPMENT_TEAM={contract['developmentTeam']}",
        "CODE_SIGN_STYLE=Automatic",
        "CODE_SIGN_IDENTITY=Apple Development",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGNING_REQUIRED=YES",
        "ONLY_ACTIVE_ARCH=YES",
        f"ARCHS={architecture}",
        "ENABLE_TESTABILITY=YES",
    ]
    process = run(command, cwd=worktree, transcript=transcript, require_success=False)
    if not result_bundle.is_dir():
        raise SupportCaptureError(f"{machine_class} did not produce an xcresult bundle")
    product = derived_data / "Build" / "Products" / "Release" / "Mirmir.app"
    test_bundle = product / "Contents" / "PlugIns" / "MirmirTests.xctest"
    if not product.is_dir() or not test_bundle.is_dir():
        raise SupportCaptureError(f"{machine_class} test products are missing")
    signature_verification = row_root / "codesign-verification.log"
    run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(product)],
        cwd=worktree,
        transcript=signature_verification,
    )
    app_signature_path = row_root / "app-signature.txt"
    app_signature = run(
        ["codesign", "--display", "--verbose=4", str(product)],
        cwd=worktree,
        transcript=app_signature_path,
    ).stdout
    test_signature_path = row_root / "test-signature.txt"
    test_signature = run(
        ["codesign", "--display", "--verbose=4", str(test_bundle)],
        cwd=worktree,
        transcript=test_signature_path,
    ).stdout
    app_identity = code_signature_summary(
        app_signature,
        expected_identifier="com.mirmir.app",
        expected_team=str(contract["developmentTeam"]),
        expected_architecture=str(architecture),
    )
    test_identity = code_signature_summary(
        test_signature,
        expected_identifier="com.mirmir.app.tests",
        expected_team=str(contract["developmentTeam"]),
        expected_architecture=str(architecture),
    )
    signing_summary_path = row_root / "signing-summary.json"
    p06.write_json(
        signing_summary_path,
        {
            "schemaVersion": "mirmir-ash-v4-support-test-signing-v1",
            "developmentTeam": contract["developmentTeam"],
            "app": app_identity,
            "testBundle": test_identity,
            "sameTeamIdentity": app_identity["teamIdentifier"]
                == test_identity["teamIdentifier"],
            "codeSignatureVerificationPass": True,
        },
    )
    summary_process = run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(result_bundle),
            "--format",
            "json",
        ],
        cwd=worktree,
    )
    tests_process = run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            str(result_bundle),
            "--format",
            "json",
        ],
        cwd=worktree,
    )
    try:
        summary = json.loads(summary_process.stdout)
        tests = json.loads(tests_process.stdout)
    except json.JSONDecodeError as error:
        raise SupportCaptureError(f"{machine_class} xcresult JSON is invalid") from error
    if not isinstance(summary, dict):
        raise SupportCaptureError(f"{machine_class} xcresult summary is not an object")
    passed, failed, skipped, result = summary_counts(summary)
    expected_skips = set(contract["expectedSkippedTests"])
    observed_skips = skipped_identifiers(tests)
    unexpected_skips = sorted(observed_skips - expected_skips)
    missing_expected_skips = sorted(expected_skips - observed_skips)
    device_architectures = {
        item.get("device", {}).get("architecture")
        for item in summary.get("devicesAndConfigurations", [])
        if isinstance(item, dict) and isinstance(item.get("device"), dict)
    }
    if device_architectures != {architecture}:
        raise SupportCaptureError(
            f"{machine_class} executed on {sorted(str(item) for item in device_architectures)}, "
            f"not {architecture}"
        )
    if (
        process.returncode != 0
        or result != "Passed"
        or failed != 0
        or passed < int(contract["minimumPassingTestCount"])
        or skipped != len(expected_skips)
        or observed_skips != expected_skips
    ):
        raise SupportCaptureError(
            f"{machine_class} matrix failed: exit={process.returncode}, result={result}, "
            f"passed={passed}, failed={failed}, skipped={skipped}, "
            f"unexpected={unexpected_skips}, missingExpected={missing_expected_skips}"
        )
    summary_path = row_root / "test-summary.json"
    tests_path = row_root / "test-tree.json"
    p06.write_json(summary_path, summary)
    p06.write_json(tests_path, tests)
    hardware, software = environment_documents(str(machine_class), str(architecture))
    hardware_path = row_root / "hardware.json"
    software_path = row_root / "software.json"
    p06.write_json(hardware_path, hardware)
    p06.write_json(software_path, software)
    semantic_summary_path = row_root / "semantic-summary.json"
    p06.write_json(
        semantic_summary_path,
        {
            "schemaVersion": "mirmir-ash-v4-support-matrix-row-summary-v1",
            "row": {
                "id": f"{machine_class}-{architecture}",
                "machineClass": machine_class,
                "runtimeMode": runtime_mode,
                "executionArchitecture": architecture,
            },
            "candidate": {
                "sourceCommit": candidate["sourceCommit"],
                "sourceTreeIdentitySHA256": candidate["sourceTreeIdentitySHA256"],
                "appBundleSHA256": candidate["appBundleSHA256"],
                "releaseConfigurationSHA256": candidate["releaseConfigurationSHA256"],
            },
            "runtime": dict(runtime_summary),
            "build": {
                "buildConfiguration": "Release",
                "command": command,
                "invocationSHA256": canonical_command_identity(command),
                "transcriptSHA256": p06.sha256(transcript),
            },
            "signing": {
                "developmentTeam": contract["developmentTeam"],
                "app": app_identity,
                "testBundle": test_identity,
                "sameTeamIdentity": True,
                "codeSignatureVerificationSHA256": p06.sha256(signature_verification),
                "codeSignatureVerificationPass": True,
            },
            "tests": {
                "result": result,
                "passedTestCount": passed,
                "failedTestCount": failed,
                "skippedTestCount": skipped,
                "minimumPassingTestCount": contract["minimumPassingTestCount"],
                "expectedSkippedTests": sorted(expected_skips),
                "observedSkippedTests": sorted(observed_skips),
                "unexpectedSkippedTests": unexpected_skips,
                "summarySHA256": p06.sha256(summary_path),
                "testTreeSHA256": p06.sha256(tests_path),
            },
            "environment": {
                "hardwareSHA256": p06.sha256(hardware_path),
                "softwareSHA256": p06.sha256(software_path),
            },
            "allRequiredChecksPassed": True,
        },
    )
    attestation_path = row_root / "attestation.json"
    p06.write_json(
        attestation_path,
        {
            "schemaVersion": "mirmir-ash-v4-support-matrix-row-v1",
            "id": f"{machine_class}-{architecture}",
            "machineClass": machine_class,
            "runtimeMode": runtime_mode,
            "executionArchitecture": architecture,
            "sourceCommit": candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": candidate["sourceTreeIdentitySHA256"],
            "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
            "releaseConfigurationSHA256": candidate["releaseConfigurationSHA256"],
            "appBundleSHA256": candidate["appBundleSHA256"],
            "command": command,
            "invocationSHA256": canonical_command_identity(command),
            "exitStatus": process.returncode,
            "passedTestCount": passed,
            "failedTestCount": failed,
            "skippedTestCount": skipped,
            "expectedSkippedTests": sorted(expected_skips),
            "unexpectedSkippedTests": unexpected_skips,
            "hardwareArtifact": descriptor(hardware_path, staging),
            "softwareArtifact": descriptor(software_path, staging),
            "summaryArtifact": descriptor(summary_path, staging),
            "testTreeArtifact": descriptor(tests_path, staging),
            "transcriptArtifact": descriptor(transcript, staging),
            "codeSignatureVerificationArtifact": descriptor(
                signature_verification, staging
            ),
            "appSignatureArtifact": descriptor(app_signature_path, staging),
            "testSignatureArtifact": descriptor(test_signature_path, staging),
            "signingSummaryArtifact": descriptor(signing_summary_path, staging),
            "semanticSummaryArtifact": descriptor(semantic_summary_path, staging),
            "fullQualificationMatrixPass": True,
        },
    )
    return {
        "id": f"{machine_class}-{architecture}",
        "machineClass": machine_class,
        "hardwareIdentitySHA256": p06.sha256(hardware_path),
        "softwareImageSHA256": p06.sha256(software_path),
        "appBundleSHA256": candidate["appBundleSHA256"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "fullQualificationMatrixPass": True,
        "unexpectedSkipCount": 0,
        "externalEvidenceArtifact": descriptor(attestation_path, staging),
    }


def capture(arguments: argparse.Namespace) -> Path:
    repository = arguments.repository.expanduser().resolve(strict=True)
    candidate_path = arguments.candidate.expanduser().resolve(strict=True)
    contract_path = arguments.contract.expanduser().resolve(strict=True)
    application_archive = arguments.application_archive.expanduser().resolve(strict=True)
    output = arguments.output.expanduser().resolve()
    if output.exists() or not output.parent.is_dir():
        raise SupportCaptureError("support output must be a new path under an existing parent")
    if not application_archive.is_file() or application_archive.is_symlink():
        raise SupportCaptureError("support matrix application archive is not a regular file")
    candidate = p06.parse_candidate(candidate_path)
    if p06.sha256(application_archive) != candidate["appBundleSHA256"]:
        raise SupportCaptureError("support matrix application archive differs from candidate")
    contract = validate_contract(p06.load_json(contract_path), verify_tools=True)
    if p06.source_tree_identity(repository, candidate["sourceCommit"]) != candidate[
        "sourceTreeIdentitySHA256"
    ]:
        raise SupportCaptureError("candidate source tree is stale")
    for relative, local in {
        "script/v4/capture_support_matrix_v4.py": Path(__file__).resolve(),
        "script/v4/support-matrix-contract-v1.json": contract_path,
        "script/v4/support_matrix_v4.py": DEFAULT_EVALUATOR,
        "script/v4/run_support_matrix_v4.sh": DEFAULT_RUNNER,
    }.items():
        if p06.committed_bytes(repository, candidate["sourceCommit"], relative) != local.read_bytes():
            raise SupportCaptureError(f"support qualification input is not committed: {relative}")

    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    temporary = Path(tempfile.mkdtemp(prefix="mirmir-support-matrix."))
    worktree = temporary / "worktree"
    run(
        ["git", "worktree", "add", "--detach", str(worktree), candidate["sourceCommit"]],
        cwd=repository,
    )
    try:
        if run(
            ["git", "status", "--porcelain", "--untracked-files=all"], cwd=worktree
        ).stdout.strip():
            raise SupportCaptureError("support-matrix source checkout is not clean")
        runtime_path = worktree / str(contract["runtimeResourcePath"])
        runtime = p06.validate_runtime(runtime_path, candidate)
        if not runtime["document"]:
            raise SupportCaptureError("production P06 did not validate")
        release_path = worktree / str(contract["releaseConfigurationPath"])
        if p06.sha256(release_path) != candidate["releaseConfigurationSHA256"]:
            raise SupportCaptureError("support matrix Release configuration differs from candidate")

        runtime_summary = {
            "runtimeID": runtime["document"]["runtimeID"],
            "releaseStatus": runtime["document"]["releaseStatus"],
            "semanticManifestSHA256": candidate["runtimeManifestSHA256"],
            "manifestFileSHA256": candidate["runtimeManifestFileSHA256"],
            "sourceRevision": candidate["runtimeSourceRevision"],
        }

        shutil.copy2(contract_path, staging / "suite-contract.json")
        shutil.copy2(candidate_path, staging / "candidate.json")
        shutil.copy2(runtime_path / "runtime-manifest.json", staging / "runtime-manifest.json")
        shutil.copy2(release_path, staging / "Release.xcconfig")
        shutil.copy2(application_archive, staging / "application-archive.zip")
        shutil.copy2(Path(__file__).resolve(), staging / "capture-tool.py")
        shutil.copy2(DEFAULT_EVALUATOR, staging / "support-matrix-evaluator.py")
        shutil.copy2(DEFAULT_RUNNER, staging / "support-matrix-runner.sh")
        rows = [
            capture_row(
                row_contract=row,
                contract=contract,
                worktree=worktree,
                staging=staging,
                temporary=temporary,
                candidate=candidate,
                runtime_summary=runtime_summary,
            )
            for row in contract["machineClasses"]
        ]
        if run(
            ["git", "status", "--porcelain", "--untracked-files=all"], cwd=worktree
        ).stdout.strip():
            raise SupportCaptureError("support-matrix tests changed their clean source checkout")
        report_path = staging / "report.json"
        p06.write_json(
            report_path,
            {
                "schemaVersion": "mirmir-ash-v4-support-matrix-report-v1",
                "contractSHA256": p06.sha256(staging / "suite-contract.json"),
                "candidate": candidate,
                "releaseEligible": True,
                "identities": {
                    "captureSourceSHA256": p06.sha256(staging / "capture-tool.py"),
                    "evaluatorSHA256": p06.sha256(staging / "support-matrix-evaluator.py"),
                    "runnerSHA256": p06.sha256(staging / "support-matrix-runner.sh"),
                },
                "declaredSupportedMachineClassIDs": [
                    row["id"] for row in contract["machineClasses"]
                ],
                "rows": rows,
                "supportMatrixGatePass": True,
            },
        )
        seal(staging, staging / "sealed-manifest.json")
        os.replace(staging, output)
        return output
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        run(
            ["git", "worktree", "remove", "--force", str(worktree)],
            cwd=repository,
            require_success=False,
        )
        shutil.rmtree(temporary, ignore_errors=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--application-archive", type=Path, required=True)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    output = capture(parse_arguments())
    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SupportCaptureError, p06.CaptureError, OSError, ValueError) as error:
        print(f"support matrix failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
