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


def validate_contract(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise SupportCaptureError("support contract must be an object")
    expected_keys = {
        "schemaVersion",
        "buildConfiguration",
        "expectedSkippedTests",
        "machineClasses",
        "minimumPassingTestCount",
        "project",
        "releaseConfigurationPath",
        "runtimeResourcePath",
        "scheme",
        "unexpectedSkipAllowance",
    }
    if set(document) != expected_keys:
        raise SupportCaptureError("support contract field set is not canonical")
    if document.get("schemaVersion") != "mirmir-ash-v4-support-matrix-contract-v1":
        raise SupportCaptureError("unsupported support-matrix contract")
    if document.get("buildConfiguration") != "Release":
        raise SupportCaptureError("support matrix must use Release builds")
    for key in (
        "project",
        "releaseConfigurationPath",
        "runtimeResourcePath",
        "scheme",
    ):
        if not isinstance(document.get(key), str) or not document[key]:
            raise SupportCaptureError(f"support contract has invalid {key}")
    minimum = document.get("minimumPassingTestCount")
    if isinstance(minimum, bool) or not isinstance(minimum, int) or minimum < 300:
        raise SupportCaptureError("support contract weakens minimum test coverage")
    rows = document.get("machineClasses")
    if not isinstance(rows, list) or len(rows) != 2:
        raise SupportCaptureError("support contract must define exactly two machine classes")
    identifiers = {row.get("id") for row in rows if isinstance(row, dict)}
    if identifiers != {"reference", "supported"}:
        raise SupportCaptureError("support contract omits reference or supported class")
    expected_rows = {
        (
            "reference",
            "arm64",
            "native_apple_silicon",
        ),
        (
            "supported",
            "x86_64",
            "rosetta_2_compatibility",
        ),
    }
    observed_rows = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {
            "id",
            "destinationArchitecture",
            "runtimeMode",
        }:
            raise SupportCaptureError("support machine-class row is not canonical")
        observed_rows.add(
            (row["id"], row["destinationArchitecture"], row["runtimeMode"])
        )
    if observed_rows != expected_rows:
        raise SupportCaptureError("support architecture matrix was narrowed or changed")
    expected_skips = document.get("expectedSkippedTests")
    if not isinstance(expected_skips, list) or len(expected_skips) != len(set(expected_skips)):
        raise SupportCaptureError("support contract expected-skip set is invalid")
    if document.get("unexpectedSkipAllowance") != 0:
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
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGNING_REQUIRED=YES",
    ]
    process = run(command, cwd=worktree, transcript=transcript, require_success=False)
    if not result_bundle.is_dir():
        raise SupportCaptureError(f"{machine_class} did not produce an xcresult bundle")
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
        or result != "Succeeded"
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
    candidate = p06.parse_candidate(candidate_path)
    if p06.sha256(application_archive) != candidate["appBundleSHA256"]:
        raise SupportCaptureError("support matrix application archive differs from candidate")
    contract = validate_contract(p06.load_json(contract_path))
    if p06.source_tree_identity(repository, candidate["sourceCommit"]) != candidate[
        "sourceTreeIdentitySHA256"
    ]:
        raise SupportCaptureError("candidate source tree is stale")
    for relative, local in {
        "script/v4/capture_support_matrix_v4.py": Path(__file__).resolve(),
        "script/v4/support-matrix-contract-v1.json": contract_path,
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

        shutil.copy2(contract_path, staging / "suite-contract.json")
        shutil.copy2(runtime_path / "runtime-manifest.json", staging / "runtime-manifest.json")
        shutil.copy2(release_path, staging / "Release.xcconfig")
        shutil.copy2(application_archive, staging / application_archive.name)
        shutil.copy2(Path(__file__).resolve(), staging / "capture-tool.py")
        rows = [
            capture_row(
                row_contract=row,
                contract=contract,
                worktree=worktree,
                staging=staging,
                temporary=temporary,
                candidate=candidate,
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
                "identities": {"captureSourceSHA256": p06.sha256(staging / "capture-tool.py")},
                "declaredSupportedMachineClassIDs": ["reference", "supported"],
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
