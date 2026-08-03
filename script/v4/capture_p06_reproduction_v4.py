#!/usr/bin/env python3
"""Capture two clean, byte-identical P06 builds as sealed M7 evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIRECTORY / "p06-reproduction-contract-v1.json"
REPORT_SCHEMA = "mirmir-ash-v4-p06-reproduction-report-v1"
MANIFEST_DOMAIN = b"ash-p06-runtime-manifest-v4\0"
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


class CaptureError(ValueError):
    """The release candidate cannot produce admissible P06 evidence."""


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


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CaptureError(f"cannot read JSON {path}: {error}") from error


def require_hex(value: Any, lengths: tuple[int, ...], label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) not in lengths
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise CaptureError(f"{label} is not a lowercase hexadecimal identity")
    return value


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    relative = path.resolve().relative_to(root.resolve()).as_posix()
    return {"path": relative, "byteCount": path.stat().st_size, "sha256": sha256(path)}


def artifact_set_sha(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for relative, identity in sorted(entries):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(identity.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def regular_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for path in root.rglob("*"):
        if path.is_symlink():
            raise CaptureError(f"symbolic links are forbidden in release evidence: {path}")
        if path.is_file():
            files.append(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def bundle_entries(root: Path) -> list[tuple[str, str]]:
    return [
        (path.relative_to(root).as_posix(), sha256(path))
        for path in regular_files(root)
    ]


def compare_directories(first: Path, second: Path, label: str) -> None:
    first_entries = bundle_entries(first)
    second_entries = bundle_entries(second)
    if first_entries != second_entries:
        raise CaptureError(f"{label} file set or bytes differ")


def source_tree_identity(repository: Path, commit: str) -> str:
    process = subprocess.run(
        ["git", "ls-tree", "-r", "-z", "--full-tree", commit],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise CaptureError(
            "cannot resolve source tree: "
            + process.stderr.decode("utf-8", errors="replace").strip()
        )
    return sha256_bytes(b"mirmir-source-tree-v1\0" + process.stdout)


def committed_bytes(repository: Path, commit: str, relative_path: str) -> bytes:
    process = subprocess.run(
        ["git", "show", f"{commit}:{relative_path}"],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise CaptureError(
            f"candidate commit omits {relative_path}: "
            + process.stderr.decode("utf-8", errors="replace").strip()
        )
    return process.stdout


def parse_candidate(path: Path) -> dict[str, Any]:
    document = load_json(path)
    if not isinstance(document, dict):
        raise CaptureError("candidate record must be a JSON object")
    value = document.get("candidate", document)
    if not isinstance(value, dict) or set(value) != CANDIDATE_FIELDS:
        missing = sorted(CANDIDATE_FIELDS - set(value) if isinstance(value, dict) else CANDIDATE_FIELDS)
        unexpected = sorted(set(value) - CANDIDATE_FIELDS if isinstance(value, dict) else set())
        raise CaptureError(
            f"candidate field set mismatch; missing={missing}, unexpected={unexpected}"
        )
    require_hex(value["sourceCommit"], (40,), "candidate.sourceCommit")
    for key in (
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
    ):
        require_hex(value[key], (64,), f"candidate.{key}")
    require_hex(value["runtimeSourceRevision"], (40, 64), "candidate.runtimeSourceRevision")
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        if not isinstance(value[key], str) or not value[key]:
            raise CaptureError(f"candidate.{key} must be a nonempty string")
    return dict(value)


def validate_runtime(runtime_root: Path, candidate: Mapping[str, Any]) -> dict[str, Any]:
    if not runtime_root.is_dir():
        raise CaptureError(f"runtime bundle is not a directory: {runtime_root}")
    manifest_path = runtime_root / "runtime-manifest.json"
    manifest = load_json(manifest_path)
    if not isinstance(manifest, dict):
        raise CaptureError("runtime manifest must be an object")
    raw = manifest_path.read_bytes()
    if raw != canonical_bytes(manifest):
        raise CaptureError("runtime manifest is not canonical JSON")
    if sha256(manifest_path) != candidate["runtimeManifestFileSHA256"]:
        raise CaptureError("candidate raw runtime-manifest identity mismatch")
    semantic = sha256_bytes(MANIFEST_DOMAIN + canonical_bytes(manifest))
    if semantic != candidate["runtimeManifestSHA256"]:
        raise CaptureError("candidate semantic runtime-manifest identity mismatch")
    if manifest.get("schemaID") != "ash.p06.runtime-manifest.v1":
        raise CaptureError("runtime manifest schema is not P06")
    if manifest.get("runtimeID") != "ash-p06-deterministic-v4":
        raise CaptureError("runtime identity is not the production P06 identity")
    if manifest.get("releaseStatus") != "release_qualified":
        raise CaptureError("runtime is not release-qualified")
    provenance = manifest.get("provenance")
    if not isinstance(provenance, dict):
        raise CaptureError("runtime provenance is missing")
    if provenance.get("sourceRevision") != candidate["runtimeSourceRevision"]:
        raise CaptureError("runtime source revision differs from the candidate")
    builder_identity = require_hex(
        provenance.get("builderSourceSHA256"), (64,), "runtime builderSourceSHA256"
    )
    toolchain = provenance.get("toolchain")
    if not isinstance(toolchain, dict):
        raise CaptureError("runtime toolchain image is missing")
    entries = bundle_entries(runtime_root)
    if artifact_set_sha(entries) != candidate["runtimeArtifactSetSHA256"]:
        raise CaptureError("candidate runtime artifact-set identity mismatch")
    forbidden = json.dumps(manifest, sort_keys=True).lower()
    if any(token in forbidden for token in ("p05", "preview", "development", "dev-runtime")):
        raise CaptureError("runtime manifest retains a forbidden preview identity")
    return {"document": manifest, "builderSHA256": builder_identity, "toolchain": toolchain}


def run_checked(
    command: list[str],
    *,
    cwd: Path,
    transcript: Path | None = None,
) -> str:
    process = subprocess.run(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        text=True,
    )
    if transcript is not None:
        transcript.write_text(process.stdout, encoding="utf-8")
    if process.returncode != 0:
        raise CaptureError(
            f"external command failed ({process.returncode}): {' '.join(command)}\n{process.stdout}"
        )
    return process.stdout


def capture_build(
    *,
    repository: Path,
    commit: str,
    identifier: str,
    staging_root: Path,
    temporary_root: Path,
    candidate_runtime: Path,
    candidate: Mapping[str, Any],
) -> dict[str, Any]:
    worktree = temporary_root / f"{identifier}-worktree"
    build_root = temporary_root / f"{identifier}-outputs"
    artifacts_output = build_root / "runtime-inputs"
    runtime_output = build_root / "ASH-P06.bundle"
    provenance_output = build_root / "provenance"
    build_root.mkdir()
    run_checked(
        ["git", "worktree", "add", "--detach", str(worktree), commit],
        cwd=repository,
    )
    load_transcript = staging_root / identifier / "runtime-load-and-tamper-check.log"
    try:
        if run_checked(
            ["git", "status", "--porcelain", "--untracked-files=all"], cwd=worktree
        ).strip():
            raise CaptureError(f"{identifier} detached checkout was not clean before building")
        build_transcript = staging_root / identifier / "build-transcript.log"
        build_transcript.parent.mkdir(parents=True)
        run_checked(
            [
                str(worktree / "script/v4/build_p06_release_runtime.sh"),
                "--artifacts",
                str(artifacts_output),
                "--output",
                str(runtime_output),
                "--provenance",
                str(provenance_output),
            ],
            cwd=worktree,
            transcript=build_transcript,
        )
        if run_checked(
            ["git", "status", "--porcelain", "--untracked-files=all"], cwd=worktree
        ).strip():
            raise CaptureError(f"{identifier} build changed its clean source checkout")
        runtime = validate_runtime(runtime_output, candidate)
        compare_directories(runtime_output, candidate_runtime, f"{identifier} and shipping P06")
        run_checked(
            [
                str(worktree / "script/v4/run_p06_runtime_load_check.sh"),
                str(runtime_output),
                candidate["runtimeManifestSHA256"],
                candidate["runtimeSourceRevision"],
                runtime["builderSHA256"],
            ],
            cwd=worktree,
            transcript=load_transcript,
        )
    finally:
        run_checked(["git", "worktree", "remove", "--force", str(worktree)], cwd=repository)

    evidence_build = staging_root / identifier
    shutil.copytree(runtime_output / "artifacts", evidence_build / "artifacts")
    shutil.copy2(runtime_output / "runtime-manifest.json", evidence_build / "runtime-manifest.json")
    shutil.copytree(provenance_output, evidence_build / "provenance")

    builder_path = evidence_build / "provenance/builder-source-manifest.txt"
    toolchain_path = evidence_build / "provenance/toolchain-image.json"
    if sha256(builder_path) != runtime["builderSHA256"]:
        raise CaptureError(f"{identifier} builder artifact does not reproduce provenance")
    if toolchain_path.read_bytes() != canonical_bytes(runtime["toolchain"]):
        raise CaptureError(f"{identifier} toolchain artifact differs from runtime provenance")

    load_transcript = evidence_build / "runtime-load-and-tamper-check.log"
    load_text = load_transcript.read_text(encoding="utf-8")
    for required_line in (
        "production_loader_acceptance=pass",
        "same_length_artifact_tamper_rejection=pass",
    ):
        if required_line not in load_text.splitlines():
            raise CaptureError(f"{identifier} load-check transcript omits {required_line}")

    artifact_manifest_path = evidence_build / "artifact-manifest.json"
    runtime_paths = [
        path
        for path in regular_files(evidence_build)
        if path.relative_to(evidence_build).as_posix().startswith("artifacts/")
        or path.name == "runtime-manifest.json"
    ]
    write_json(
        artifact_manifest_path,
        {
            "schemaVersion": "mirmir-p06-artifact-manifest-v1",
            "artifacts": [descriptor(path, evidence_build) for path in runtime_paths],
        },
    )
    computed_artifact_set = artifact_set_sha(
        (path.relative_to(evidence_build).as_posix(), sha256(path)) for path in runtime_paths
    )
    if computed_artifact_set != candidate["runtimeArtifactSetSHA256"]:
        raise CaptureError(f"{identifier} sealed artifact set differs from candidate")

    return {
        "id": identifier,
        "runtimeArtifactSetSHA256": computed_artifact_set,
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "builderSHA256": sha256(builder_path),
        "toolchainImageSHA256": sha256(toolchain_path),
        "artifactManifest": descriptor(artifact_manifest_path, staging_root),
        "runtimeManifestArtifact": descriptor(
            evidence_build / "runtime-manifest.json", staging_root
        ),
        "builderArtifact": descriptor(builder_path, staging_root),
        "toolchainImageArtifact": descriptor(toolchain_path, staging_root),
        "loaderEvidenceArtifact": descriptor(load_transcript, staging_root),
        "releaseQualifiedStatus": True,
        "developmentArtifactDependencyCount": 0,
        "p05ProductionDependencyCount": 0,
    }


def capture(arguments: argparse.Namespace) -> Path:
    repository = arguments.repository.expanduser().resolve(strict=True)
    candidate_path = arguments.candidate.expanduser().resolve(strict=True)
    candidate_runtime = arguments.runtime.expanduser().resolve(strict=True)
    release_configuration = arguments.release_configuration.expanduser().resolve(strict=True)
    contract_path = arguments.contract.expanduser().resolve(strict=True)
    output = arguments.output.expanduser().resolve()
    if output.exists():
        raise CaptureError(f"output already exists: {output}")
    if not output.parent.is_dir():
        raise CaptureError(f"output parent is not a directory: {output.parent}")

    candidate = parse_candidate(candidate_path)
    if source_tree_identity(repository, candidate["sourceCommit"]) != candidate["sourceTreeIdentitySHA256"]:
        raise CaptureError("candidate source-tree identity does not match its source commit")
    locked_tools = {
        "script/v4/capture_p06_reproduction_v4.py": Path(__file__).resolve(),
        "script/v4/run_p06_runtime_load_check.sh": repository
        / "script/v4/run_p06_runtime_load_check.sh",
        "script/v4/P06RuntimeLoadCheckMain.swift": repository
        / "script/v4/P06RuntimeLoadCheckMain.swift",
        "script/v4/p06-reproduction-contract-v1.json": contract_path,
    }
    for relative_path, local_path in locked_tools.items():
        if committed_bytes(repository, candidate["sourceCommit"], relative_path) != local_path.read_bytes():
            raise CaptureError(f"qualification tool differs from candidate commit: {relative_path}")
    if sha256(release_configuration) != candidate["releaseConfigurationSHA256"]:
        raise CaptureError("candidate Release configuration identity mismatch")
    runtime = validate_runtime(candidate_runtime, candidate)
    contract = load_json(contract_path)
    if not isinstance(contract, dict) or contract.get("schemaVersion") != "mirmir-ash-v4-p06-reproduction-contract-v1":
        raise CaptureError("unsupported P06 reproduction contract")

    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    temporary_root = Path(tempfile.mkdtemp(prefix="mirmir-p06-reproduction."))
    try:
        shutil.copy2(contract_path, staging / "suite-contract.json")
        shutil.copy2(candidate_runtime / "runtime-manifest.json", staging / "runtime-manifest.json")
        shutil.copy2(release_configuration, staging / "Release.xcconfig")
        shutil.copy2(Path(__file__).resolve(), staging / "capture-tool.py")
        shutil.copy2(
            repository / "script/v4/run_p06_runtime_load_check.sh",
            staging / "runtime-load-check-runner.sh",
        )
        shutil.copy2(
            repository / "script/v4/P06RuntimeLoadCheckMain.swift",
            staging / "runtime-load-check.swift",
        )

        builds = [
            capture_build(
                repository=repository,
                commit=candidate["sourceCommit"],
                identifier=identifier,
                staging_root=staging,
                temporary_root=temporary_root,
                candidate_runtime=candidate_runtime,
                candidate=candidate,
            )
            for identifier in ("clean-build-a", "clean-build-b")
        ]
        if {build["builderSHA256"] for build in builds} != {runtime["builderSHA256"]}:
            raise CaptureError("clean builds changed the P06 builder identity")
        if len({build["toolchainImageSHA256"] for build in builds}) != 1:
            raise CaptureError("clean builds changed the P06 toolchain image")

        report = {
            "schemaVersion": REPORT_SCHEMA,
            "contractSHA256": sha256(staging / "suite-contract.json"),
            "candidate": candidate,
            "releaseEligible": True,
            "identities": {
                "captureSourceSHA256": sha256(staging / "capture-tool.py"),
                "runtimeLoadCheckRunnerSHA256": sha256(
                    staging / "runtime-load-check-runner.sh"
                ),
                "runtimeLoadCheckSourceSHA256": sha256(
                    staging / "runtime-load-check.swift"
                ),
            },
            "buildConfiguration": "Release",
            "sourceCheckoutState": "clean",
            "builds": builds,
            "productionLoaderAcceptancePass": True,
            "tamperRejectionPass": True,
            "p06ReproductionGatePass": True,
        }
        report_path = staging / "report.json"
        write_json(report_path, report)
        manifest_path = staging / "sealed-manifest.json"
        write_json(
            manifest_path,
            {
                "schemaVersion": "mirmir-ash-v4-p06-reproduction-evidence-v1",
                "artifacts": [descriptor(path, staging) for path in regular_files(staging)],
            },
        )
        os.replace(staging, output)
        return output
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(temporary_root, ignore_errors=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--release-configuration", type=Path, required=True)
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
    except (CaptureError, OSError, subprocess.SubprocessError) as error:
        print(f"P06 reproduction capture failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
