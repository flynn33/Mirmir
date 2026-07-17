"""Stage immutable pre-G07 P08 measurements and promote them after G07."""

from __future__ import annotations

from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
from typing import Any, Mapping

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

from validation.calibration_v2.p08.evidence import (
    ARTIFACT_SCHEMAS,
    BUNDLED_RELEASE_RESOURCES,
    HASH_SCOPE,
    PROFILE_TOOLS,
    P08EvidenceError,
    ROUTES,
    _gate_checks,
    _load_tolerances,
    _read_json,
    _safe_relative,
    _strict_absent,
    _strict_directory,
    _strict_file,
    _finalize_promoted_g08,
    file_binding,
    repository_identity,
    tree_binding,
)
from validation.calibration_v2.release_lock import (
    ReleaseLockError,
    validate_p06_release_bundle_manifest,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


SCHEMA_ROOT = Path(__file__).resolve().parents[1] / "schemas"
NATIVE_SCHEMA = SCHEMA_ROOT / "p08-native-measurements-v1.schema.json"
NATIVE_FILENAME = "p08-native-measurements.json"
PRE_G07_MANIFEST_FILENAME = "p08-pre-g07-manifest.json"
XCTEST_ARCHIVES = {
    "metal_parity": "metal-parity.xcresult",
    "performance": "performance.xcresult",
    "resource_ring": "resource-ring.xcresult",
}
PROFILE_ARCHIVES = tuple(
    (tool, route, f"{tool}-{route}.trace")
    for tool in PROFILE_TOOLS
    for route in ROUTES
)
CAPTURE_ARCHIVES = tuple((route, f"{route}.gputrace") for route in ROUTES)


def _sha256_file(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _native_validator() -> Draft202012Validator:
    registry = Registry()
    dependencies = [
        SCHEMA_ROOT / "p08-common-v1.schema.json",
        *ARTIFACT_SCHEMAS.values(),
    ]
    for path in dependencies:
        document = json.loads(path.read_text(encoding="utf-8"))
        registry = registry.with_resource(
            str(document["$id"]),
            Resource.from_contents(document),
        )
    schema = json.loads(NATIVE_SCHEMA.read_text(encoding="utf-8"))
    return Draft202012Validator(
        schema,
        registry=registry,
        format_checker=FormatChecker(),
    )


def validate_native_measurements(path: Path) -> tuple[bytes, Mapping[str, Any]]:
    """Reopen one canonical native fragment without making a gate claim."""

    payload, document = _read_json(path, "P08 native measurements")
    if payload != canonical_json_bytes(document) + b"\n":
        raise P08EvidenceError("P08 native measurements are not canonical one-LF JSON")
    errors = sorted(
        _native_validator().iter_errors(document),
        key=lambda error: [str(item) for item in error.absolute_path],
    )
    if errors:
        location = "/".join(str(item) for item in errors[0].absolute_path) or "<root>"
        raise P08EvidenceError(
            f"P08 native measurements violate schema at {location}: {errors[0].message}"
        )
    unhashed = dict(document)
    declared = unhashed.pop("artifact_sha256")
    if declared != canonical_sha256(unhashed):
        raise P08EvidenceError("P08 native measurements self-hash differs")
    if document["device_identity_sha256"] != canonical_sha256(document["device"]):
        raise P08EvidenceError("P08 native device identity self-hash differs")
    return payload, document


def _copy_file(source: Path, destination: Path) -> None:
    source = _strict_file(source, f"P08 source file {source.name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    _strict_absent(destination, f"P08 destination file {destination.name}")
    source_payload = source.read_bytes()
    shutil.copy2(source, destination, follow_symlinks=False)
    if _strict_file(destination, f"P08 copied file {destination.name}").read_bytes() != source_payload:
        raise P08EvidenceError(f"P08 copied file changed: {destination.name}")


def _copy_tree(source: Path, destination: Path, relative_path: str) -> Mapping[str, Any]:
    source = _strict_directory(source, f"P08 source tree {source.name}")
    source_binding = tree_binding(source, relative_path=relative_path)
    _strict_absent(destination, f"P08 destination tree {destination.name}")
    shutil.copytree(source, destination, symlinks=False, copy_function=shutil.copy2)
    copied = tree_binding(destination, relative_path=relative_path)
    if copied != source_binding:
        raise P08EvidenceError(f"P08 copied tree changed: {destination.name}")
    return copied


def _release_artifacts(release: Mapping[str, Any]) -> Mapping[str, Mapping[str, Any]]:
    rows = release.get("artifacts")
    if not isinstance(rows, list):
        raise P08EvidenceError("P06 V3 release artifact list is absent")
    return {
        str(row["id"]): row
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }


def _release_path(root: Path, row: Mapping[str, Any], label: str) -> Path:
    relative = _safe_relative(row.get("path"), label)
    return _strict_file(root.joinpath(*relative.parts), label)


def _verify_app_and_native_identity(
    *,
    repository_root: Path,
    native: Mapping[str, Any],
    release: Mapping[str, Any],
    release_root: Path,
    app: Path,
) -> None:
    source = repository_identity(repository_root)
    execution = native["execution_identity"]
    if any(execution[field] != source[field] for field in source):
        raise P08EvidenceError("native measurements use another source identity")
    if (
        execution["configuration_id"] != release["configuration_id"]
        or execution["p06_release_bundle_artifact_sha256"]
        != release["artifact_sha256"]
        or execution["g07_publication_manifest_sha256"] is not None
        or execution["holdout_accessed"] is not False
    ):
        raise P08EvidenceError("native measurements use another P06/pre-G07 identity")
    artifacts = _release_artifacts(release)
    selected = artifacts.get("selected_evaluation")
    if (
        not isinstance(selected, dict)
        or execution["selected_evaluation_artifact_sha256"]
        != json.loads(_release_path(release_root, selected, "selected evaluation").read_bytes())[
            "artifact_sha256"
        ]
    ):
        raise P08EvidenceError("native selected-evaluation identity differs")
    if app.name != "Mirmir.app":
        raise P08EvidenceError("P08 Release app name differs")
    if os.path.lexists(app / "Contents/PlugIns"):
        raise P08EvidenceError("P08 Release app contains a hosted test plug-in")
    app_tree = tree_binding(app, relative_path="Mirmir.app")
    executable = _strict_file(app / "Contents/MacOS/Mirmir", "Release executable")
    metallib = _strict_file(
        app / "Contents/Resources/default.metallib",
        "Release Metal library",
    )
    if (
        execution["production_app_tree_sha256"] != app_tree["tree_sha256"]
        or execution["production_executable_sha256"] != _sha256_file(executable)
        or execution["metal_library_sha256"] != _sha256_file(metallib)
    ):
        raise P08EvidenceError("native app, executable, or Metal library identity differs")
    locked = _strict_directory(
        app / "Contents/Resources/ASH/LockedV3",
        "Release app LockedV3 resources",
    )
    expected_names = [row[2] for row in BUNDLED_RELEASE_RESOURCES]
    if sorted(os.listdir(locked)) != sorted(expected_names):
        raise P08EvidenceError("Release app does not contain the exact authorized six files")
    native_rows = execution["bundled_release_resources"]
    for native_row, (_key, artifact_id, filename) in zip(
        native_rows,
        BUNDLED_RELEASE_RESOURCES,
    ):
        bundled_path = _strict_file(locked / filename, f"bundled {filename}")
        released_path = _release_path(release_root, artifacts[artifact_id], filename)
        payload = bundled_path.read_bytes()
        if (
            payload != released_path.read_bytes()
            or native_row
            != {
                "filename": filename,
                "sha256": _sha256_file(bundled_path),
                "size_bytes": len(payload),
            }
        ):
            raise P08EvidenceError(f"bundled {filename} differs from P06/native identity")


def _measurement_documents(
    native: Mapping[str, Any],
    *,
    identity: Mapping[str, Any],
    raw_bindings: Mapping[str, Mapping[str, Any]],
) -> Mapping[str, Mapping[str, Any]]:
    captures = []
    for row in native["gpu_capture"]["captures"]:
        output = dict(row)
        archive_name = output.pop("archive_name")
        output["archive"] = raw_bindings[archive_name]
        captures.append(output)
    profiles = [
        {
            "tool": row["tool"],
            "route": row["route"],
            "archive": raw_bindings[row["archive_name"]],
        }
        for row in native["instruments"]["profiles"]
    ]
    return {
        "metal-parity.json": {
            "evidence_identity": identity,
            "xctest_result_bundle": raw_bindings["metal-parity.xcresult"],
            **native["metal_parity"],
        },
        "performance-results.json": {
            "evidence_identity": identity,
            "benchmark_result_bundle": raw_bindings["performance.xcresult"],
            **native["performance"],
        },
        "resource-ring-results.json": {
            "evidence_identity": identity,
            "xctest_result_bundle": raw_bindings["resource-ring.xcresult"],
            **native["resource_ring"],
        },
        "instruments-manifest.json": {
            "evidence_identity": identity,
            "xctrace_version": native["instruments"]["xctrace_version"],
            "profiles": profiles,
            "route_observations": native["instruments"]["route_observations"],
        },
        "gpu-capture-manifest.json": {
            "evidence_identity": identity,
            "capture_tool": native["gpu_capture"]["capture_tool"],
            "captures": captures,
        },
    }


def _write_pre_g07_manifest(
    *,
    staging: Path,
    native: Mapping[str, Any],
    source_identity: Mapping[str, Any],
    checks: list[Mapping[str, Any]],
    app_binding: Mapping[str, Any],
    input_bindings: Mapping[str, Mapping[str, Any]],
    raw_bindings: Mapping[str, Mapping[str, Any]],
) -> Mapping[str, Any]:
    document: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p08_pre_g07_seal",
        "run_id": native["run_id"],
        "source_identity": dict(source_identity),
        "native_measurements": file_binding(
            staging / NATIVE_FILENAME,
            relative_path=NATIVE_FILENAME,
        ),
        "production_app_bundle": dict(app_binding),
        "input_files": [
            {"id": name, **input_bindings[name]}
            for name in sorted(input_bindings)
        ],
        "raw_archives": [
            {"name": name, **raw_bindings[name]}
            for name in sorted(raw_bindings)
        ],
        "available_checks_all_satisfied": all(
            row.get("status") == "pass" for row in checks
        ),
        "checks_sha256": canonical_sha256(checks),
        "g08_claimed": False,
        "g07_publication_manifest_sha256": None,
        "holdout_accessed": False,
        "hash_scope": HASH_SCOPE,
    }
    document["artifact_sha256"] = canonical_sha256(document)
    path = staging / PRE_G07_MANIFEST_FILENAME
    _strict_absent(path, "P08 pre-G07 seal")
    payload = canonical_json_bytes(document) + b"\n"
    with path.open("xb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    reopened_payload, reopened = _read_json(path, "P08 pre-G07 seal")
    if reopened_payload != payload or reopened != document:
        raise P08EvidenceError("P08 pre-G07 seal changed on reopen")
    return document


def _reopen_pre_g07_manifest(
    *,
    pre: Path,
    native: Mapping[str, Any],
    source_identity: Mapping[str, Any],
) -> Mapping[str, Any]:
    payload, document = _read_json(
        pre / PRE_G07_MANIFEST_FILENAME,
        "P08 pre-G07 seal",
    )
    if payload != canonical_json_bytes(document) + b"\n":
        raise P08EvidenceError("P08 pre-G07 seal is not canonical one-LF JSON")
    expected_fields = {
        "schema_version", "artifact_kind", "run_id", "source_identity",
        "native_measurements", "production_app_bundle", "input_files",
        "raw_archives", "available_checks_all_satisfied", "checks_sha256",
        "g08_claimed", "g07_publication_manifest_sha256", "holdout_accessed",
        "hash_scope", "artifact_sha256",
    }
    unhashed = dict(document)
    declared = unhashed.pop("artifact_sha256", None)
    if (
        set(document) != expected_fields
        or document.get("schema_version") != "1.0.0"
        or document.get("artifact_kind") != "p08_pre_g07_seal"
        or document.get("run_id") != native["run_id"]
        or document.get("source_identity") != source_identity
        or document.get("available_checks_all_satisfied") is not True
        or document.get("g08_claimed") is not False
        or document.get("g07_publication_manifest_sha256") is not None
        or document.get("holdout_accessed") is not False
        or document.get("hash_scope") != HASH_SCOPE
        or declared != canonical_sha256(unhashed)
    ):
        raise P08EvidenceError("P08 pre-G07 seal identity or self-hash differs")
    expected_native = file_binding(
        pre / NATIVE_FILENAME,
        relative_path=NATIVE_FILENAME,
    )
    if document.get("native_measurements") != expected_native:
        raise P08EvidenceError("P08 native measurements changed after pre-G07 sealing")
    inputs = _strict_directory(pre / "inputs", "P08 sealed inputs root")
    app_names = [name for name in os.listdir(inputs) if name.endswith(".app")]
    if len(app_names) != 1:
        raise P08EvidenceError("P08 sealed app closure differs")
    app_name = app_names[0]
    if app_name != "Mirmir.app" or os.path.lexists(
        inputs / app_name / "Contents/PlugIns"
    ):
        raise P08EvidenceError("P08 sealed app is not the ordinary production bundle")
    expected_app = tree_binding(
        inputs / app_name,
        relative_path=f"inputs/{app_name}",
    )
    if document.get("production_app_bundle") != expected_app:
        raise P08EvidenceError("P08 production app changed after pre-G07 sealing")
    execution = native.get("execution_identity")
    if (
        not isinstance(execution, dict)
        or expected_app["tree_sha256"] != execution.get("production_app_tree_sha256")
        or _sha256_file(
            _strict_file(
                inputs / app_name / "Contents/MacOS/Mirmir",
                "P08 sealed production executable",
            )
        )
        != execution.get("production_executable_sha256")
        or _sha256_file(
            _strict_file(
                inputs / app_name / "Contents/Resources/default.metallib",
                "P08 sealed Metal library",
            )
        )
        != execution.get("metal_library_sha256")
    ):
        raise P08EvidenceError("P08 sealed app differs from native execution identity")
    locked = _strict_directory(
        inputs / app_name / "Contents/Resources/ASH/LockedV3",
        "P08 sealed release resources",
    )
    native_resources = execution.get("bundled_release_resources")
    if (
        sorted(os.listdir(locked))
        != sorted(row[2] for row in BUNDLED_RELEASE_RESOURCES)
        or not isinstance(native_resources, list)
        or len(native_resources) != len(BUNDLED_RELEASE_RESOURCES)
    ):
        raise P08EvidenceError("P08 sealed release-resource closure differs")
    for native_row, (_key, _artifact_id, filename) in zip(
        native_resources,
        BUNDLED_RELEASE_RESOURCES,
    ):
        resource = _strict_file(locked / filename, f"P08 sealed {filename}")
        payload = resource.read_bytes()
        if native_row != {
            "filename": filename,
            "sha256": _sha256_file(resource),
            "size_bytes": len(payload),
        }:
            raise P08EvidenceError(
                f"P08 sealed {filename} differs from native execution identity"
            )
    expected_input_names = {
        "locked-metric-policy.json",
        "p06-release.json",
        "selected-evaluation.json",
    }
    input_rows = document.get("input_files")
    if (
        not isinstance(input_rows, list)
        or len(input_rows) != len(expected_input_names)
        or any(not isinstance(row, dict) for row in input_rows)
        or {row.get("id") for row in input_rows} != expected_input_names
    ):
        raise P08EvidenceError("P08 sealed input-file identity differs")
    for row in input_rows:
        name = row["id"]
        expected = file_binding(
            inputs / name,
            relative_path=f"inputs/{name}",
        )
        if row != {"id": name, **expected}:
            raise P08EvidenceError(f"P08 sealed input changed: {name}")
    raw = _strict_directory(pre / "raw", "P08 sealed raw root")
    expected_raw_names = {
        *XCTEST_ARCHIVES.values(),
        *[row[2] for row in PROFILE_ARCHIVES],
        *[row[1] for row in CAPTURE_ARCHIVES],
    }
    raw_rows = document.get("raw_archives")
    if (
        not isinstance(raw_rows, list)
        or len(raw_rows) != len(expected_raw_names)
        or any(not isinstance(row, dict) for row in raw_rows)
        or {row.get("name") for row in raw_rows} != expected_raw_names
        or set(os.listdir(raw)) != expected_raw_names
    ):
        raise P08EvidenceError("P08 sealed raw-archive closure differs")
    for row in raw_rows:
        name = row["name"]
        expected = tree_binding(raw / name, relative_path=f"raw/{name}")
        if row != {"name": name, **expected}:
            raise P08EvidenceError(f"P08 raw archive changed after sealing: {name}")
    if set(os.listdir(pre)) != {
        NATIVE_FILENAME,
        PRE_G07_MANIFEST_FILENAME,
        "inputs",
        "raw",
    }:
        raise P08EvidenceError("P08 pre-G07 sealed top-level closure differs")
    return document


def stage_pre_g07(
    *,
    repository_root: Path,
    native_measurements: Path,
    p06_release_root: Path,
    release_app: Path,
    raw_archives: Mapping[str, Path],
) -> Mapping[str, Any]:
    """Stage and evaluate P08 without publishing or claiming G08."""

    repository_root = _strict_directory(repository_root, "P08 repository root")
    native_payload, native = validate_native_measurements(native_measurements)
    release_root = _strict_directory(p06_release_root, "P06 release root")
    try:
        release = validate_p06_release_bundle_manifest(
            release_root=release_root,
            manifest_path=release_root / "p06-release-bundle.json",
        )
    except (ReleaseLockError, ValueError) as error:
        raise P08EvidenceError(f"P06 V3 release reopening failed: {error}") from error
    app = _strict_directory(release_app, "P08 Release app")
    _verify_app_and_native_identity(
        repository_root=repository_root,
        native=native,
        release=release,
        release_root=release_root,
        app=app,
    )
    expected_raw_names = {
        *XCTEST_ARCHIVES.values(),
        *[row[2] for row in PROFILE_ARCHIVES],
        *[row[1] for row in CAPTURE_ARCHIVES],
    }
    if set(raw_archives) != expected_raw_names:
        raise P08EvidenceError("pre-G07 raw archive argument closure differs")
    run_id = native["run_id"]
    artifact_parent = _strict_directory(
        repository_root / "Artifacts/ASH",
        "P08 artifact parent",
    )
    staging = _strict_absent(
        artifact_parent / f".{run_id}.p08-pre-g07",
        "P08 pre-G07 staging root",
    )
    staging.mkdir()
    (staging / "inputs").mkdir()
    (staging / "raw").mkdir()
    _copy_file(native_measurements, staging / NATIVE_FILENAME)
    if (staging / NATIVE_FILENAME).read_bytes() != native_payload:
        raise P08EvidenceError("staged native measurement bytes changed")
    app_relative = f"inputs/{app.name}"
    app_binding = _copy_tree(app, staging / app_relative, app_relative)
    artifacts = _release_artifacts(release)
    input_sources = {
        "p06-release.json": release_root / "p06-release-bundle.json",
        "selected-evaluation.json": _release_path(
            release_root, artifacts["selected_evaluation"], "selected evaluation"
        ),
        "locked-metric-policy.json": _release_path(
            release_root, artifacts["locked_metric_policy"], "locked metric policy"
        ),
    }
    input_bindings: dict[str, Mapping[str, Any]] = {}
    for name, source in input_sources.items():
        _copy_file(source, staging / "inputs" / name)
        input_bindings[name] = file_binding(
            staging / "inputs" / name,
            relative_path=f"inputs/{name}",
        )
    raw_bindings: dict[str, Mapping[str, Any]] = {}
    for name in sorted(expected_raw_names):
        source = _strict_directory(raw_archives[name], f"raw archive {name}")
        if source.name != name:
            raise P08EvidenceError(f"raw archive basename differs: {name}")
        raw_bindings[name] = _copy_tree(source, staging / "raw" / name, f"raw/{name}")
    selected = json.loads((staging / "inputs/selected-evaluation.json").read_bytes())
    policy = json.loads((staging / "inputs/locked-metric-policy.json").read_bytes())
    tolerances_payload, tolerances = _load_tolerances()
    if policy["release_tolerances"]["contract_sha256"] != __import__("hashlib").sha256(
        tolerances_payload
    ).hexdigest():
        raise P08EvidenceError("pre-G07 locked tolerance binding differs")
    budget = policy["release_tolerances"]["dispatch_overhead_budget"]
    provisional_identity = {
        "selected_evaluation_artifact_sha256": selected["artifact_sha256"]
    }
    documents = _measurement_documents(
        native,
        identity=provisional_identity,
        raw_bindings=raw_bindings,
    )
    checks = _gate_checks(documents, tolerances, budget, selected)
    seal = _write_pre_g07_manifest(
        staging=staging,
        native=native,
        source_identity=repository_identity(repository_root),
        checks=checks,
        app_binding=app_binding,
        input_bindings=input_bindings,
        raw_bindings=raw_bindings,
    )
    return {
        "artifact_kind": "p08_pre_g07_validation_result",
        "run_id": run_id,
        "staging_root": os.fspath(staging),
        "pre_g07_seal_artifact_sha256": seal["artifact_sha256"],
        "available_checks_all_satisfied": all(row["status"] == "pass" for row in checks),
        "checks": checks,
        "g08_claimed": False,
        "g08_gate_manifest_written": False,
        "g07_publication_bound": False,
        "holdout_accessed": False,
    }


def promote_after_g07(
    *,
    repository_root: Path,
    pre_g07_root: Path,
    g07_publication: Path,
) -> Mapping[str, Any]:
    """Promote unchanged native/raw bytes and bind the later G07 publication."""

    repository_root = _strict_directory(repository_root, "P08 repository root")
    pre = _strict_directory(pre_g07_root, "P08 pre-G07 staging root")
    native_payload, native = validate_native_measurements(pre / NATIVE_FILENAME)
    if pre.name != f".{native['run_id']}.p08-pre-g07":
        raise P08EvidenceError("pre-G07 staging root name differs")
    source = repository_identity(repository_root)
    execution = native["execution_identity"]
    if any(execution[field] != source[field] for field in source):
        raise P08EvidenceError("pre-G07 source identity is no longer current")
    seal = _reopen_pre_g07_manifest(
        pre=pre,
        native=native,
        source_identity=source,
    )
    output = _strict_absent(
        repository_root / "Artifacts/ASH" / native["run_id"],
        "G08 output root",
    )
    staging = _strict_absent(
        output.parent / f".{output.name}.partial",
        "G08 staging root",
    )
    staging.mkdir()
    (staging / "inputs").mkdir()
    (staging / "raw").mkdir()
    _copy_file(pre / NATIVE_FILENAME, staging / NATIVE_FILENAME)
    if (staging / NATIVE_FILENAME).read_bytes() != native_payload:
        raise P08EvidenceError("promoted native fragment bytes changed")
    native_binding = file_binding(
        staging / NATIVE_FILENAME,
        relative_path=NATIVE_FILENAME,
    )
    if native_binding != seal["native_measurements"]:
        raise P08EvidenceError(
            "promoted native fragment differs from the pre-G07 seal"
        )
    _copy_file(
        pre / PRE_G07_MANIFEST_FILENAME,
        staging / PRE_G07_MANIFEST_FILENAME,
    )
    seal_binding = file_binding(
        staging / PRE_G07_MANIFEST_FILENAME,
        relative_path=PRE_G07_MANIFEST_FILENAME,
    )
    if (
        (staging / PRE_G07_MANIFEST_FILENAME).read_bytes()
        != canonical_json_bytes(seal) + b"\n"
    ):
        raise P08EvidenceError("promoted pre-G07 seal differs from reopened seal")
    app_names = [name for name in os.listdir(pre / "inputs") if name.endswith(".app")]
    if len(app_names) != 1:
        raise P08EvidenceError("pre-G07 app closure differs")
    app_name = app_names[0]
    promoted_app_binding = _copy_tree(
        pre / "inputs" / app_name,
        staging / "inputs" / app_name,
        f"inputs/{app_name}",
    )
    if promoted_app_binding != seal["production_app_bundle"]:
        raise P08EvidenceError("promoted app differs from the pre-G07 seal")
    sealed_inputs = {
        row["id"]: {key: value for key, value in row.items() if key != "id"}
        for row in seal["input_files"]
    }
    for name in (
        "p06-release.json",
        "selected-evaluation.json",
        "locked-metric-policy.json",
    ):
        _copy_file(pre / "inputs" / name, staging / "inputs" / name)
        promoted_binding = file_binding(
            staging / "inputs" / name,
            relative_path=f"inputs/{name}",
        )
        if promoted_binding != sealed_inputs.get(name):
            raise P08EvidenceError(
                f"promoted input differs from the pre-G07 seal: {name}"
            )
    _copy_file(g07_publication, staging / "inputs/g07-publication.json")
    raw_bindings: dict[str, Mapping[str, Any]] = {}
    sealed_raw = {
        row["name"]: {key: value for key, value in row.items() if key != "name"}
        for row in seal["raw_archives"]
    }
    for name in sorted(os.listdir(pre / "raw")):
        raw_bindings[name] = _copy_tree(
            pre / "raw" / name,
            staging / "raw" / name,
            f"raw/{name}",
        )
        if raw_bindings[name] != sealed_raw.get(name):
            raise P08EvidenceError(
                f"promoted raw archive differs from the pre-G07 seal: {name}"
            )
    app = staging / "inputs" / app_name
    locked_root = app / "Contents/Resources/ASH/LockedV3"
    bundled_bindings = {
        key: file_binding(
            locked_root / filename,
            relative_path=f"inputs/{app_name}/Contents/Resources/ASH/LockedV3/{filename}",
        )
        for key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES
    }
    release_payload, release = _read_json(
        staging / "inputs/p06-release.json", "promoted P06 release"
    )
    selected_payload, selected = _read_json(
        staging / "inputs/selected-evaluation.json", "promoted selected evaluation"
    )
    policy_payload, policy = _read_json(
        staging / "inputs/locked-metric-policy.json", "promoted metric policy"
    )
    g07_payload, g07 = _read_json(
        staging / "inputs/g07-publication.json", "promoted G07 publication"
    )
    del release_payload, selected_payload, policy_payload, g07_payload
    tolerance_payload, _ = _load_tolerances()
    identity = {
        "run_id": native["run_id"],
        **source,
        "configuration_id": release["configuration_id"],
        "p06_release_bundle": {
            "file": file_binding(
                staging / "inputs/p06-release.json",
                relative_path="inputs/p06-release.json",
            ),
            "artifact_sha256": release["artifact_sha256"],
        },
        "selected_evaluation_file": file_binding(
            staging / "inputs/selected-evaluation.json",
            relative_path="inputs/selected-evaluation.json",
        ),
        "selected_evaluation_artifact_sha256": selected["artifact_sha256"],
        "g07_publication": {
            "file": file_binding(
                staging / "inputs/g07-publication.json",
                relative_path="inputs/g07-publication.json",
            ),
            "manifest_sha256": g07["manifest_sha256"],
        },
        "pre_g07_seal": {
            "file": seal_binding,
            "artifact_sha256": seal["artifact_sha256"],
        },
        "pre_g07_native_measurements": {
            "file": native_binding,
            "artifact_sha256": native["artifact_sha256"],
        },
        "metric_tolerances_file_sha256": __import__("hashlib").sha256(
            tolerance_payload
        ).hexdigest(),
        "locked_metric_policy": {
            "file": file_binding(
                staging / "inputs/locked-metric-policy.json",
                relative_path="inputs/locked-metric-policy.json",
            ),
            "policy_sha256": policy["policy_sha256"],
            "dispatch_overhead_budget": policy["release_tolerances"][
                "dispatch_overhead_budget"
            ],
        },
        "production_app_bundle": tree_binding(
            app, relative_path=f"inputs/{app_name}"
        ),
        "production_executable": file_binding(
            app / "Contents/MacOS/Mirmir",
            relative_path=f"inputs/{app_name}/Contents/MacOS/Mirmir",
        ),
        "metal_library": file_binding(
            app / "Contents/Resources/default.metallib",
            relative_path=f"inputs/{app_name}/Contents/Resources/default.metallib",
        ),
        "bundled_release_resources": {
            "root": tree_binding(
                locked_root,
                relative_path=f"inputs/{app_name}/Contents/Resources/ASH/LockedV3",
            ),
            **bundled_bindings,
        },
        "route_lut_files": {
            "direct_2x": bundled_bindings["direct2x_lut"],
            "direct_3_over_2": bundled_bindings["direct3over2_lut"],
        },
        "device": native["device"],
        "device_identity_sha256": native["device_identity_sha256"],
    }
    documents = _measurement_documents(native, identity=identity, raw_bindings=raw_bindings)
    metadata = {
        "metal-parity.json": ("1.0.0", "p08_metal_parity"),
        "performance-results.json": ("1.0.0", "p08_performance_results"),
        "resource-ring-results.json": ("1.0.0", "p08_resource_ring_results"),
        "instruments-manifest.json": ("1.0.0", "p08_instruments_manifest"),
        "gpu-capture-manifest.json": ("1.0.0", "p08_gpu_capture_manifest"),
    }
    for filename, document in documents.items():
        schema_version, artifact_kind = metadata[filename]
        core = {
            "schema_version": schema_version,
            "artifact_kind": artifact_kind,
            **document,
            "hash_scope": HASH_SCOPE,
        }
        sealed = {**core, "artifact_sha256": canonical_sha256(core)}
        (staging / filename).write_bytes(canonical_json_bytes(sealed) + b"\n")
    return _finalize_promoted_g08(
        repository_root=repository_root,
        staging_root=staging,
        output_root=output,
    )


__all__ = [
    "CAPTURE_ARCHIVES",
    "NATIVE_FILENAME",
    "NATIVE_SCHEMA",
    "PRE_G07_MANIFEST_FILENAME",
    "PROFILE_ARCHIVES",
    "XCTEST_ARCHIVES",
    "promote_after_g07",
    "stage_pre_g07",
    "validate_native_measurements",
]
