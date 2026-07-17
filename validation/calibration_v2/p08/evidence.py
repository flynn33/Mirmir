"""Fail-closed P08 evidence verification and atomic G08 promotion.

The supported staging workflow supplies a preserved pre-G07 native envelope,
its identity-bound seal, derived evidence documents, and the raw ``.xcresult``,
``.trace``, and ``.gputrace`` bundles they bind.  This module does not execute
a benchmark and has no default measurements.  It reopens the preserved bytes,
derives every G08 predicate from preregistered policy, and atomically publishes
only a closure whose pre-G07 checks remain satisfied.
"""

from __future__ import annotations

from decimal import Decimal, ROUND_CEILING
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
from typing import Any, Mapping, Sequence

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = CALIBRATION_ROOT / "schemas"
TOLERANCES_PATH = (
    CALIBRATION_ROOT / "contracts" / "metric-performance-tolerances-v1.json"
)
LOCKED_METRIC_POLICY_SCHEMA = SCHEMA_ROOT / "locked-metric-policy-v2.schema.json"
CANDIDATE_EVALUATION_SCHEMA = SCHEMA_ROOT / "candidate-evaluation-v2.schema.json"
COMMON_SCHEMA = SCHEMA_ROOT / "p08-common-v1.schema.json"
NATIVE_SCHEMA = SCHEMA_ROOT / "p08-native-measurements-v1.schema.json"
NATIVE_FILENAME = "p08-native-measurements.json"
PRE_G07_MANIFEST_FILENAME = "p08-pre-g07-manifest.json"

ARTIFACT_SCHEMAS = {
    "metal-parity.json": SCHEMA_ROOT / "p08-metal-parity-v1.schema.json",
    "performance-results.json": (
        SCHEMA_ROOT / "p08-performance-results-v1.schema.json"
    ),
    "resource-ring-results.json": (
        SCHEMA_ROOT / "p08-resource-ring-results-v1.schema.json"
    ),
    "instruments-manifest.json": (
        SCHEMA_ROOT / "p08-instruments-manifest-v1.schema.json"
    ),
    "gpu-capture-manifest.json": (
        SCHEMA_ROOT / "p08-gpu-capture-manifest-v1.schema.json"
    ),
}
G08_GATE_FILENAME = "g08-gate-manifest.json"
G08_GATE_SCHEMA = SCHEMA_ROOT / "g08-gate-manifest-v1.schema.json"
ROUTES = ("direct_2x", "direct_3_over_2")
PHASE_COUNTS = {"direct_2x": 4, "direct_3_over_2": 9}
PLANES = ("y", "cbcr")
DESCRIPTOR_IDS = tuple(range(16))
PERFORMANCE_MODES = ("compute_only", "end_to_end")
PERFORMANCE_FIXTURE_SHA256 = {
    "direct_2x": "fd07d42fa717c64abb26af145dd156b7479f2df29f9d151904ec2f62e88b22ae",
    "direct_3_over_2": "219ae4f012a50d4f22a515544fd1f05aa0ff933782a45fc0b779437b9414dce0",
}
PROFILE_TOOLS = ("time_profiler", "allocations", "metal_system_trace")
BUNDLED_RELEASE_RESOURCES = (
    ("lut_manifest_v3", "lut_manifest", "lut-manifest-v3.json"),
    (
        "locked_compiler_input_v2",
        "locked_compiler_input_v2",
        "locked-compiler-input-v2.json",
    ),
    ("locked_mapping", "locked_mapping", "locked-mapping.json"),
    ("direct2x_lut", "direct2x_lut", "direct2x.ashlut"),
    ("direct3over2_lut", "direct3over2_lut", "direct3over2.ashlut"),
    (
        "native_lut_parity_manifest_v3",
        "native_parity_manifest",
        "native-lut-parity-manifest-v3.json",
    ),
)
CHECK_IDS = (
    "metal_execution",
    "parity_coverage",
    "numeric_parity",
    "exact_state_message_lut",
    "same_device_determinism",
    "performance_protocol",
    "same_machine_speedup",
    "frames_per_second",
    "dispatch_overhead_budget",
    "calibration_estimate_error",
    "no_runtime_tree_or_cpu_loop",
    "no_production_wait",
    "no_avoidable_readback",
    "resource_ring_and_memory",
    "profile_and_capture_closure",
)
HASH_SCOPE = "canonical sorted-key compact UTF-8 JSON excluding /artifact_sha256"
TREE_HASH_SCOPE = (
    "SHA-256 of canonical sorted-key compact UTF-8 JSON array of ascending "
    "relative directory/file records; files bind path, size_bytes, and SHA-256"
)
MAX_JSON_BYTES = 32 * 1024 * 1024
FORMULA_TOLERANCE = Decimal("1e-12")


class P08EvidenceError(ValueError):
    """P08 input evidence is absent, mutable, ambiguous, or inconsistent."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise P08EvidenceError(message)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_absolute(path: Path, label: str) -> Path:
    _require(isinstance(path, Path) and path.is_absolute(), f"{label} is not absolute")
    if len(path.parts) >= 2 and path.parts[1] == "var":
        path = Path("/private/var").joinpath(*path.parts[2:])
    normalized = Path(os.path.normpath(os.fspath(path)))
    _require(normalized == path, f"{label} is not lexically normalized")
    return path


def _strict_directory(path: Path, label: str) -> Path:
    path = _canonical_absolute(path, label)
    cursor = Path(path.anchor)
    for part in path.parts[1:]:
        cursor /= part
        try:
            metadata = os.lstat(cursor)
        except OSError as error:
            raise P08EvidenceError(f"{label} is absent") from error
        _require(
            stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
            f"{label} traverses a symbolic link or non-directory",
        )
    return path


def _strict_absent(path: Path, label: str) -> Path:
    path = _canonical_absolute(path, label)
    _strict_directory(path.parent, f"{label} parent")
    _require(not os.path.lexists(path), f"{label} already exists")
    return path


def _strict_file(path: Path, label: str, *, allow_empty: bool = False) -> Path:
    path = _canonical_absolute(path, label)
    _strict_directory(path.parent, f"{label} parent")
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise P08EvidenceError(f"{label} is absent") from error
    _require(
        stat.S_ISREG(metadata.st_mode)
        and not stat.S_ISLNK(metadata.st_mode)
        and metadata.st_nlink == 1
        and (allow_empty or metadata.st_size > 0),
        f"{label} is linked, empty, or not a singular regular file",
    )
    return path


def _safe_relative(value: object, label: str) -> PurePosixPath:
    _require(isinstance(value, str) and bool(value), f"{label} is empty")
    parsed = PurePosixPath(str(value))
    _require(
        not parsed.is_absolute()
        and parsed.as_posix() == value
        and "\\" not in str(value)
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"{label} is unsafe",
    )
    return parsed


def _read_regular(path: Path, label: str, *, maximum: int | None = None) -> bytes:
    path = _strict_file(path, label)
    payload = path.read_bytes()
    _require(
        maximum is None or len(payload) <= maximum,
        f"{label} exceeds its byte limit",
    )
    return payload


def _reject_constant(value: str) -> None:
    raise P08EvidenceError(f"JSON contains a nonfinite constant: {value}")


def _pairs_object(pairs: Sequence[tuple[str, Any]]) -> Mapping[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise P08EvidenceError(f"JSON contains a duplicate key: {key}")
        document[key] = value
    return document


def _decode_json(payload: bytes, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(
            payload.decode("utf-8", "strict"),
            object_pairs_hook=_pairs_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise P08EvidenceError(f"{label} is not strict UTF-8 JSON") from error
    _require(isinstance(value, dict), f"{label} is not a JSON object")
    return value


def _read_json(path: Path, label: str) -> tuple[bytes, Mapping[str, Any]]:
    payload = _read_regular(path, label, maximum=MAX_JSON_BYTES)
    return payload, _decode_json(payload, label)


def _schema_validator(schema_path: Path) -> Draft202012Validator:
    dependency_paths = (COMMON_SCHEMA, *ARTIFACT_SCHEMAS.values())
    registry = Registry()
    for dependency_path in dependency_paths:
        dependency_payload, dependency = _read_json(
            dependency_path,
            f"P08 schema dependency {dependency_path.name}",
        )
        del dependency_payload
        registry = registry.with_resource(
            str(dependency["$id"]),
            Resource.from_contents(dependency),
        )
    schema_payload, schema = _read_json(schema_path, f"schema {schema_path.name}")
    del schema_payload
    return Draft202012Validator(
        schema,
        registry=registry,
        format_checker=FormatChecker(),
    )


def _validate_schema(document: Mapping[str, Any], schema_path: Path, label: str) -> None:
    errors = sorted(
        _schema_validator(schema_path).iter_errors(document),
        key=lambda error: [str(item) for item in error.absolute_path],
    )
    if errors:
        rendered = []
        for error in errors:
            location = "/".join(str(item) for item in error.absolute_path) or "<root>"
            rendered.append(f"{location}: {error.message}")
        raise P08EvidenceError(f"{label} violates schema: {'; '.join(rendered)}")


def _self_hash(document: Mapping[str, Any], field: str = "artifact_sha256") -> str:
    unhashed = dict(document)
    unhashed.pop(field, None)
    return canonical_sha256(unhashed)


def _validate_artifact(
    document: Mapping[str, Any],
    schema_path: Path,
    label: str,
) -> None:
    _validate_schema(document, schema_path, label)
    _require(
        document.get("artifact_sha256") == _self_hash(document),
        f"{label} self-hash differs",
    )


def _decimal(value: object, label: str) -> Decimal:
    _require(
        not isinstance(value, bool) and isinstance(value, (int, float)),
        f"{label} is not numeric",
    )
    try:
        result = Decimal(str(value))
    except Exception as error:
        raise P08EvidenceError(f"{label} is not finite decimal data") from error
    _require(result.is_finite(), f"{label} is not finite")
    return result


def _close(reported: object, computed: Decimal, label: str) -> bool:
    observed = _decimal(reported, label)
    scale = max(Decimal(1), abs(observed), abs(computed))
    return abs(observed - computed) <= FORMULA_TOLERANCE * scale


def _percentile_linear(values: Sequence[Decimal], probability: Decimal) -> Decimal:
    _require(bool(values), "percentile values are empty")
    ordered = sorted(values)
    _require(
        Decimal(0) <= probability <= Decimal(1),
        "percentile probability is outside zero through one",
    )
    position = Decimal(len(ordered) - 1) * probability
    lower = int(position)
    upper = lower if position == Decimal(lower) else lower + 1
    if lower == upper:
        return ordered[lower]
    fraction = position - Decimal(lower)
    return ordered[lower] + ((ordered[upper] - ordered[lower]) * fraction)


def _tree_inventory(root: Path, label: str) -> tuple[list[Mapping[str, Any]], int, int]:
    root = _strict_directory(root, label)
    records: list[Mapping[str, Any]] = []
    file_count = 0
    total_size = 0
    for current_name, directory_names, file_names in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        _require(current.resolve(strict=True) == current, f"{label} contains an alias")
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = current / name
            metadata = os.lstat(path)
            relative = path.relative_to(root).as_posix()
            _require(
                stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
                f"{label} contains a linked or special directory: {relative}",
            )
            records.append({"kind": "directory", "path": relative})
        for name in file_names:
            path = current / name
            metadata = os.lstat(path)
            relative = path.relative_to(root).as_posix()
            _require(
                stat.S_ISREG(metadata.st_mode)
                and not stat.S_ISLNK(metadata.st_mode)
                and metadata.st_nlink == 1,
                f"{label} contains a linked or special file: {relative}",
            )
            payload = path.read_bytes()
            _require(len(payload) == metadata.st_size, f"{label} file changed: {relative}")
            records.append(
                {
                    "kind": "file",
                    "path": relative,
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
            file_count += 1
            total_size += len(payload)
    records.sort(key=lambda row: (str(row["path"]), str(row["kind"])))
    _require(file_count > 0 and total_size > 0, f"{label} has no nonempty evidence")
    return records, file_count, total_size


def tree_binding(path: Path, *, relative_path: str) -> Mapping[str, Any]:
    """Collect one immutable directory-tree binding without interpreting it."""

    relative = _safe_relative(relative_path, "tree binding relative path").as_posix()
    records, file_count, total_size = _tree_inventory(path, "evidence tree")
    return {
        "path": relative,
        "tree_sha256": canonical_sha256(records),
        "file_count": file_count,
        "directory_count": sum(row["kind"] == "directory" for row in records),
        "total_size_bytes": total_size,
        "hash_scope": TREE_HASH_SCOPE,
    }


def file_binding(path: Path, *, relative_path: str) -> Mapping[str, Any]:
    """Collect one immutable regular-file binding without interpreting it."""

    relative = _safe_relative(relative_path, "file binding relative path").as_posix()
    payload = _read_regular(path, "evidence file")
    return {"path": relative, "sha256": _sha256(payload), "size_bytes": len(payload)}


def _git(repository_root: Path, arguments: Sequence[str], label: str) -> bytes:
    try:
        completed = subprocess.run(
            ["git", "-C", os.fspath(repository_root), *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **os.environ,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            },
        )
    except OSError as error:
        raise P08EvidenceError(f"{label} could not execute Git") from error
    _require(
        completed.returncode == 0,
        f"{label} failed: {completed.stderr.decode('utf-8', 'replace').strip()}",
    )
    return completed.stdout


def repository_identity(repository_root: Path) -> Mapping[str, str]:
    """Hash the exact clean tracked source bytes at one Git commit."""

    repository_root = _strict_directory(repository_root, "P08 repository root")
    top = _git(repository_root, ("rev-parse", "--show-toplevel"), "Git root query")
    _require(
        Path(top.decode("utf-8", "strict").strip()).resolve(strict=True)
        == repository_root,
        "P08 repository root is not the Git top level",
    )
    _git(
        repository_root,
        ("diff", "--quiet", "--no-ext-diff", "HEAD", "--"),
        "tracked source cleanliness",
    )
    _git(
        repository_root,
        ("diff", "--cached", "--quiet", "--no-ext-diff", "HEAD", "--"),
        "staged source cleanliness",
    )
    untracked_payload = _git(
        repository_root,
        ("ls-files", "--others", "--exclude-standard", "-z"),
        "untracked source inventory",
    )
    untracked = [
        item.decode("utf-8", "strict")
        for item in untracked_payload.split(b"\0")
        if item
    ]
    _require(
        not untracked,
        "untracked source inventory is not empty"
        + (f": {untracked[0]}" if untracked else ""),
    )
    commit = _git(repository_root, ("rev-parse", "HEAD"), "Git HEAD query").decode(
        "ascii", "strict"
    ).strip()
    raw_paths = _git(
        repository_root,
        ("ls-files", "-z", "--cached"),
        "tracked source inventory",
    )
    paths = [item.decode("utf-8", "strict") for item in raw_paths.split(b"\0") if item]
    _require(
        paths == sorted(paths) and len(paths) == len(set(paths)),
        "tracked source order differs",
    )
    records: list[Mapping[str, Any]] = []
    for relative_text in paths:
        relative = _safe_relative(relative_text, "tracked source path")
        path = repository_root / relative
        payload = _read_regular(path, f"tracked source {relative_text}", maximum=None)
        metadata = os.lstat(path)
        records.append(
            {
                "path": relative_text,
                "sha256": _sha256(payload),
                "size_bytes": len(payload),
                "executable": bool(stat.S_IMODE(metadata.st_mode) & 0o111),
            }
        )
    _require(records, "tracked source inventory is empty")
    return {"source_commit": commit, "source_tree_sha256": canonical_sha256(records)}


def _verify_tree_binding(
    staging_root: Path,
    value: object,
    *,
    suffix: str,
    label: str,
) -> None:
    _require(isinstance(value, dict), f"{label} tree binding is absent")
    relative = _safe_relative(value.get("path"), f"{label} path")
    _require(relative.as_posix().endswith(suffix), f"{label} has the wrong bundle type")
    actual = tree_binding(
        staging_root / relative,
        relative_path=relative.as_posix(),
    )
    _require(actual == value, f"{label} tree bytes differ")


def _verify_file_binding(
    staging_root: Path,
    value: object,
    *,
    label: str,
) -> tuple[bytes, Mapping[str, Any]]:
    _require(isinstance(value, dict), f"{label} file binding is absent")
    relative = _safe_relative(value.get("path"), f"{label} path")
    path = staging_root / relative
    payload, document = _read_json(path, label)
    _require(
        value
        == {
            "path": relative.as_posix(),
            "sha256": _sha256(payload),
            "size_bytes": len(payload),
        },
        f"{label} file bytes differ",
    )
    return payload, document


def _verify_regular_binding(
    staging_root: Path,
    value: object,
    *,
    label: str,
) -> bytes:
    _require(isinstance(value, dict), f"{label} file binding is absent")
    relative = _safe_relative(value.get("path"), f"{label} path")
    payload = _read_regular(staging_root / relative, label)
    _require(
        value
        == {
            "path": relative.as_posix(),
            "sha256": _sha256(payload),
            "size_bytes": len(payload),
        },
        f"{label} file bytes differ",
    )
    return payload


def _load_tolerances() -> tuple[bytes, Mapping[str, Any]]:
    payload, document = _read_json(TOLERANCES_PATH, "metric-performance tolerances")
    try:
        validate_schema(
            document,
            SCHEMA_ROOT / "metric-performance-tolerances-v1.schema.json",
        )
    except ValueError as error:
        raise P08EvidenceError("metric-performance tolerances violate schema") from error
    return payload, document


def _validate_identity(
    staging_root: Path,
    identity: Mapping[str, Any],
    repository_root: Path,
) -> tuple[Mapping[str, Any], Mapping[str, Any], Mapping[str, Any]]:
    observed_source = repository_identity(repository_root)
    _require(
        identity.get("source_commit") == observed_source["source_commit"]
        and identity.get("source_tree_sha256")
        == observed_source["source_tree_sha256"],
        "P08 source identity differs from the clean tracked repository bytes",
    )
    _require(
        identity.get("device_identity_sha256")
        == canonical_sha256(identity.get("device")),
        "P08 device identity self-hash differs",
    )
    tolerance_payload, tolerances = _load_tolerances()
    _require(
        identity.get("metric_tolerances_file_sha256") == _sha256(tolerance_payload),
        "P08 tolerance contract binding differs",
    )

    release_identity = identity.get("p06_release_bundle")
    _require(isinstance(release_identity, dict), "P06 V3 release binding is absent")
    release_payload, release = _verify_file_binding(
        staging_root,
        release_identity.get("file"),
        label="P06 V3 release bundle",
    )
    _require(
        release_payload == canonical_json_bytes(release) + b"\n",
        "P06 V3 release bundle is not canonical one-LF JSON",
    )
    try:
        validate_schema(release, SCHEMA_ROOT / "p06-release-bundle-v3.schema.json")
    except ValueError as error:
        raise P08EvidenceError("P06 V3 release bundle violates schema") from error
    release_hash = release.get("artifact_sha256")
    _require(
        release_hash
        == canonical_sha256(
            {key: value for key, value in release.items() if key != "artifact_sha256"}
        )
        and release_identity.get("artifact_sha256") == release_hash
        and release.get("configuration_id") == identity.get("configuration_id"),
        "P06 V3 release identity differs",
    )

    g07_identity = identity.get("g07_publication")
    _require(isinstance(g07_identity, dict), "G07 publication binding is absent")
    g07_payload, g07 = _verify_file_binding(
        staging_root,
        g07_identity.get("file"),
        label="G07 publication",
    )
    _require(
        g07_payload == canonical_json_bytes(g07) + b"\n",
        "G07 publication is not canonical one-LF JSON",
    )
    try:
        validate_schema(g07, SCHEMA_ROOT / "p07-g07-publication-v2.schema.json")
    except ValueError as error:
        raise P08EvidenceError("G07 publication violates schema") from error
    g07_hash = g07.get("manifest_sha256")
    g07_p06 = g07.get("p06_v2_identity")
    _require(
        g07_hash
        == canonical_sha256(
            {key: value for key, value in g07.items() if key != "manifest_sha256"}
        )
        and g07_identity.get("manifest_sha256") == g07_hash
        and g07.get("status") == "pass"
        and g07.get("gate_pass") is True
        and isinstance(g07_p06, dict)
        and g07_p06.get("p06_release_bundle_artifact_sha256") == release_hash
        and g07_p06.get("selected_evaluation_artifact_sha256")
        == identity.get("selected_evaluation_artifact_sha256"),
        "G07 publication does not pass over the exact P06 V3 release identity",
    )

    selected_payload, selected = _verify_file_binding(
        staging_root,
        identity.get("selected_evaluation_file"),
        label="selected P06 evaluation",
    )
    _require(
        selected_payload == canonical_json_bytes(selected) + b"\n",
        "selected P06 evaluation is not canonical one-LF JSON",
    )
    try:
        validate_schema(selected, CANDIDATE_EVALUATION_SCHEMA)
    except ValueError as error:
        raise P08EvidenceError("selected P06 evaluation violates schema") from error
    selected_evaluation = selected.get("evaluation")
    selected_checks = selected.get("checks")
    selected_objective = (
        selected_evaluation.get("objective")
        if isinstance(selected_evaluation, dict)
        else None
    )
    selected_artifact_hash = selected.get("artifact_sha256")
    selected_semantic_hash = selected.get("evaluation_semantic_sha256")
    selected_evidence_hash = selected.get("evidence_sha256")
    _require(
        selected_artifact_hash
        == canonical_sha256(
            {
                key: value
                for key, value in selected.items()
                if key != "artifact_sha256"
            }
        )
        and selected_evidence_hash
        == canonical_sha256(
            {
                key: value
                for key, value in selected.items()
                if key not in {"evidence_sha256", "artifact_sha256"}
            }
        )
        and isinstance(selected_evaluation, dict)
        and selected_semantic_hash == canonical_sha256(selected_evaluation)
        and selected.get("split") == "validation"
        and selected.get("evaluation_status") == "feasible"
        and selected_evaluation.get("feasible") is True
        and selected_evaluation.get("failure_reasons") == []
        and isinstance(selected_checks, list)
        and bool(selected_checks)
        and all(
            isinstance(check, dict) and check.get("status") == "pass"
            for check in selected_checks
        )
        and isinstance(selected_objective, dict)
        and _decimal(
            selected_objective.get("estimated_dispatch_cost"),
            "selected calibration estimated dispatch cost",
        )
        > 0
        and identity.get("selected_evaluation_artifact_sha256")
        == selected_artifact_hash
        and g07_p06.get("selected_evaluation_file_sha256")
        == _sha256(selected_payload)
        and g07_p06.get("selected_evaluation_artifact_sha256")
        == selected_artifact_hash
        and g07_p06.get("selected_evaluation_semantic_sha256")
        == selected_semantic_hash
        and g07_p06.get("candidate_vector_sha256")
        == selected.get("candidate_vector_sha256")
        and selected.get("shared_bank_configuration_sha256")
        == release.get("shared_bank_configuration_sha256"),
        "selected P06 evaluation content differs from the release and G07 identity",
    )

    _verify_tree_binding(
        staging_root,
        identity.get("production_app_bundle"),
        suffix=".app",
        label="P08 production app bundle",
    )
    app_binding = identity.get("production_app_bundle")
    _require(isinstance(app_binding, dict), "P08 production app binding is absent")
    app_relative = _safe_relative(app_binding.get("path"), "P08 app path")
    app_root = _strict_directory(
        staging_root / app_relative,
        "P08 production app bundle",
    )
    _require(
        not os.path.lexists(app_root / "Contents" / "PlugIns"),
        "P08 production app bundle contains a hosted test plug-in",
    )
    executable_payload = _verify_regular_binding(
        staging_root,
        identity.get("production_executable"),
        label="P08 production executable",
    )
    metal_payload = _verify_regular_binding(
        staging_root,
        identity.get("metal_library"),
        label="P08 Metal library",
    )
    del executable_payload, metal_payload
    bundled = identity.get("bundled_release_resources")
    _require(
        isinstance(bundled, dict),
        "P08 bundled release resource bindings are absent",
    )
    bundled_root = bundled.get("root")
    _require(isinstance(bundled_root, dict), "P08 bundled release root is absent")
    expected_resource_root = app_relative.joinpath(
        "Contents", "Resources", "ASH", "LockedV3"
    )
    _require(
        bundled_root.get("path") == expected_resource_root.as_posix(),
        "P08 bundled release root is not the app LockedV3 resource root",
    )
    _verify_tree_binding(
        staging_root,
        bundled_root,
        suffix="/Contents/Resources/ASH/LockedV3",
        label="P08 bundled release resource root",
    )
    resource_root = _strict_directory(
        staging_root / expected_resource_root,
        "P08 bundled release resource root",
    )
    expected_resource_names = [row[2] for row in BUNDLED_RELEASE_RESOURCES]
    _require(
        sorted(os.listdir(resource_root)) == sorted(expected_resource_names)
        and bundled_root.get("file_count") == len(BUNDLED_RELEASE_RESOURCES)
        and bundled_root.get("directory_count") == 0,
        "P08 bundled release resource closure is not the exact authorized six files",
    )
    bundled_payloads: dict[str, bytes] = {}
    for key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES:
        binding = bundled.get(key)
        _require(isinstance(binding, dict), f"P08 bundled {filename} binding is absent")
        _require(
            binding.get("path") == expected_resource_root.joinpath(filename).as_posix(),
            f"P08 bundled {filename} path differs",
        )
        bundled_payloads[key] = _verify_regular_binding(
            staging_root,
            binding,
            label=f"P08 bundled {filename}",
        )

    route_files = identity.get("route_lut_files")
    _require(isinstance(route_files, dict), "P08 route LUT bindings are absent")
    _require(
        route_files.get("direct_2x") == bundled.get("direct2x_lut")
        and route_files.get("direct_3_over_2") == bundled.get("direct3over2_lut"),
        "P08 route LUT bindings do not identify the bundled release LUTs",
    )
    route_payloads = {
        route: _verify_regular_binding(
            staging_root,
            route_files.get(route),
            label=f"P08 {route} LUT",
        )
        for route in ROUTES
    }

    locked = identity.get("locked_metric_policy")
    _require(isinstance(locked, dict), "P08 locked metric policy binding is absent")
    policy_payload, policy = _verify_file_binding(
        staging_root,
        locked.get("file"),
        label="locked metric policy",
    )
    _require(
        policy_payload == canonical_json_bytes(policy) + b"\n",
        "locked metric policy is not canonical one-LF JSON",
    )
    try:
        validate_schema(policy, LOCKED_METRIC_POLICY_SCHEMA)
    except ValueError as error:
        raise P08EvidenceError("locked metric policy violates schema") from error
    policy_hash = policy.get("policy_sha256")
    _require(
        policy_hash
        == canonical_sha256(
            {key: value for key, value in policy.items() if key != "policy_sha256"}
        )
        and locked.get("policy_sha256") == policy_hash,
        "locked metric policy self-hash differs",
    )
    release_tolerances = policy.get("release_tolerances")
    _require(isinstance(release_tolerances, dict), "locked release tolerances are absent")
    _require(
        release_tolerances.get("contract_sha256") == _sha256(tolerance_payload),
        "locked metric policy uses another tolerance contract",
    )
    budget = release_tolerances.get("dispatch_overhead_budget")
    _require(isinstance(budget, dict), "locked dispatch-overhead budget is absent")
    measured = _decimal(
        budget.get("measured_validation_p95_percent"),
        "locked validation dispatch p95",
    )
    derived = max(
        5,
        int((measured + Decimal("5")).to_integral_value(rounding=ROUND_CEILING)),
    )
    _require(
        derived <= 25
        and budget.get("derived_budget_percent") == derived
        and budget.get("uncertainty_margin_percentage_points") == 5.0
        and budget.get("derivation_formula")
        == "max(5, ceil(measured_validation_p95_percent + 5))"
        and budget.get("locked_before_g08") is True
        and budget.get("post_g08_adjustment_allowed") is False
        and locked.get("dispatch_overhead_budget") == budget,
        "G06 dispatch-overhead budget is not the preregistered locked derivation",
    )

    release_artifacts = release.get("artifacts")
    _require(isinstance(release_artifacts, list), "P06 V3 release artifacts are absent")
    by_id = {
        row.get("id"): row for row in release_artifacts if isinstance(row, dict)
    }
    policy_binding = locked.get("file")
    selected_binding = identity.get("selected_evaluation_file")
    _require(isinstance(policy_binding, dict), "locked metric policy file is absent")
    _require(
        isinstance(selected_binding, dict),
        "selected P06 evaluation file binding is absent",
    )
    selected_release_binding = by_id.get("selected_evaluation", {})
    selected_release_path = PurePosixPath(
        str(selected_release_binding.get("path", ""))
    )
    _require(
        by_id.get("locked_metric_policy", {}).get("sha256")
        == policy_binding.get("sha256")
        and by_id.get("locked_metric_policy", {}).get("size_bytes")
        == policy_binding.get("size_bytes")
        and by_id.get("direct2x_lut", {}).get("sha256")
        == _sha256(route_payloads["direct_2x"])
        and by_id.get("direct2x_lut", {}).get("size_bytes")
        == len(route_payloads["direct_2x"])
        and by_id.get("direct3over2_lut", {}).get("sha256")
        == _sha256(route_payloads["direct_3_over_2"])
        and by_id.get("direct3over2_lut", {}).get("size_bytes")
        == len(route_payloads["direct_3_over_2"])
        and selected_release_binding.get("sha256")
        == selected_binding.get("sha256")
        and selected_release_binding.get("size_bytes")
        == selected_binding.get("size_bytes")
        and selected_release_path.stem == selected_binding.get("sha256")
        and g07_p06.get("selected_evaluation_file_sha256")
        == by_id.get("selected_evaluation", {}).get("sha256")
        and g07_p06.get("shared_bank_configuration_sha256")
        == release.get("shared_bank_configuration_sha256"),
        "P08 locked policy or route LUT bytes differ from the P06 release",
    )
    for key, artifact_id, filename in BUNDLED_RELEASE_RESOURCES:
        release_binding = by_id.get(artifact_id)
        payload = bundled_payloads[key]
        _require(
            isinstance(release_binding, dict)
            and release_binding.get("path") == filename
            and release_binding.get("sha256") == _sha256(payload)
            and release_binding.get("size_bytes") == len(payload),
            f"bundled {filename} bytes differ from the exact P06 release binding",
        )
    return tolerances, budget, selected


def _verify_raw_artifacts(
    staging_root: Path,
    documents: Mapping[str, Mapping[str, Any]],
) -> None:
    _verify_tree_binding(
        staging_root,
        documents["metal-parity.json"].get("xctest_result_bundle"),
        suffix=".xcresult",
        label="Metal parity XCTest result",
    )
    _verify_tree_binding(
        staging_root,
        documents["performance-results.json"].get("benchmark_result_bundle"),
        suffix=".xcresult",
        label="performance benchmark result",
    )
    _verify_tree_binding(
        staging_root,
        documents["resource-ring-results.json"].get("xctest_result_bundle"),
        suffix=".xcresult",
        label="resource-ring XCTest result",
    )
    instruments = documents["instruments-manifest.json"]
    profiles = instruments.get("profiles")
    _require(isinstance(profiles, list), "Instruments profiles are absent")
    expected_profiles = [
        (tool, route) for tool in PROFILE_TOOLS for route in ROUTES
    ]
    _require(
        [
            (row.get("tool"), row.get("route"))
            for row in profiles
            if isinstance(row, dict)
        ]
        == expected_profiles,
        "Instruments profile coverage or order differs",
    )
    profile_paths: set[str] = set()
    for row in profiles:
        assert isinstance(row, dict)
        archive = row.get("archive")
        _verify_tree_binding(
            staging_root,
            archive,
            suffix=".trace",
            label=f"{row['tool']} {row['route']} trace",
        )
        assert isinstance(archive, dict)
        profile_paths.add(str(archive["path"]))
    _require(len(profile_paths) == 6, "Instruments profiles reuse a trace archive")

    captures = documents["gpu-capture-manifest.json"].get("captures")
    _require(isinstance(captures, list), "GPU captures are absent")
    _require(
        [row.get("route") for row in captures if isinstance(row, dict)]
        == list(ROUTES),
        "GPU capture route coverage or order differs",
    )
    capture_paths: set[str] = set()
    for row in captures:
        assert isinstance(row, dict)
        archive = row.get("archive")
        _verify_tree_binding(
            staging_root,
            archive,
            suffix=".gputrace",
            label=f"{row['route']} GPU capture",
        )
        assert isinstance(archive, dict)
        capture_paths.add(str(archive["path"]))
    _require(len(capture_paths) == 2, "GPU routes reuse a capture archive")


def _verify_staging_closure(
    staging_root: Path,
    documents: Mapping[str, Mapping[str, Any]],
) -> None:
    expected_top_level = set(ARTIFACT_SCHEMAS) | {
        NATIVE_FILENAME,
        PRE_G07_MANIFEST_FILENAME,
        "inputs",
        "raw",
    }
    _require(
        set(os.listdir(staging_root)) == expected_top_level,
        "P08 staging top-level closure differs",
    )
    for filename in ARTIFACT_SCHEMAS:
        _strict_file(staging_root / filename, f"P08 staged {filename}")
    _strict_file(
        staging_root / NATIVE_FILENAME,
        "P08 preserved native measurements",
    )
    _strict_file(
        staging_root / PRE_G07_MANIFEST_FILENAME,
        "P08 preserved pre-G07 seal",
    )
    inputs_root = _strict_directory(staging_root / "inputs", "P08 inputs root")
    raw_root = _strict_directory(staging_root / "raw", "P08 raw root")

    identity = documents["metal-parity.json"]["evidence_identity"]
    input_bindings = [
        identity["p06_release_bundle"]["file"],
        identity["selected_evaluation_file"],
        identity["g07_publication"]["file"],
        identity["locked_metric_policy"]["file"],
        identity["production_executable"],
        identity["metal_library"],
        *[
            identity["bundled_release_resources"][key]
            for key, _artifact_id, _filename in BUNDLED_RELEASE_RESOURCES
        ],
        *[identity["route_lut_files"][route] for route in ROUTES],
    ]
    app_relative = _safe_relative(
        identity["production_app_bundle"]["path"],
        "P08 production app binding",
    )
    _require(
        len(app_relative.parts) == 2
        and app_relative.parts[0] == "inputs"
        and app_relative.suffix == ".app",
        "P08 production app is not a direct inputs app bundle",
    )
    input_names: list[str] = [app_relative.parts[1]]
    for index, binding in enumerate(input_bindings):
        relative = _safe_relative(binding["path"], f"P08 input binding {index}")
        _require(
            len(relative.parts) >= 2
            and relative.parts[0] == "inputs"
            and (
                len(relative.parts) == 2
                or relative.parts[1] == app_relative.parts[1]
            ),
            f"P08 input binding is outside the direct inputs/app closure: {relative}",
        )
        input_names.append(relative.parts[1])
    _require(
        set(os.listdir(inputs_root)) == set(input_names),
        "P08 inputs closure differs",
    )
    _strict_directory(
        staging_root / app_relative,
        "P08 staged production app bundle",
    )
    for index, binding in enumerate(input_bindings):
        relative = _safe_relative(binding["path"], f"P08 input binding {index}")
        _strict_file(staging_root / relative, f"P08 bound input {relative}")

    instruments = documents["instruments-manifest.json"]
    captures = documents["gpu-capture-manifest.json"]
    tree_bindings = [
        documents["metal-parity.json"]["xctest_result_bundle"],
        documents["performance-results.json"]["benchmark_result_bundle"],
        documents["resource-ring-results.json"]["xctest_result_bundle"],
        *[row["archive"] for row in instruments["profiles"]],
        *[row["archive"] for row in captures["captures"]],
    ]
    raw_names: list[str] = []
    for index, binding in enumerate(tree_bindings):
        relative = _safe_relative(binding["path"], f"P08 raw binding {index}")
        _require(
            len(relative.parts) == 2 and relative.parts[0] == "raw",
            f"P08 raw binding is not a direct raw child: {relative}",
        )
        raw_names.append(relative.parts[1])
    _require(
        len(raw_names) == len(set(raw_names))
        and set(os.listdir(raw_root)) == set(raw_names),
        "P08 raw closure differs",
    )
    for name in raw_names:
        _strict_directory(raw_root / name, f"P08 bound raw tree {name}")


def _expected_raw_bindings(
    documents: Mapping[str, Mapping[str, Any]],
) -> Mapping[str, Mapping[str, Any]]:
    bindings: dict[str, Mapping[str, Any]] = {
        "metal-parity.xcresult": documents["metal-parity.json"]["xctest_result_bundle"],
        "performance.xcresult": documents["performance-results.json"][
            "benchmark_result_bundle"
        ],
        "resource-ring.xcresult": documents["resource-ring-results.json"][
            "xctest_result_bundle"
        ],
    }
    for row in documents["instruments-manifest.json"]["profiles"]:
        binding = row["archive"]
        name = PurePosixPath(str(binding["path"])).name
        bindings[name] = binding
    for row in documents["gpu-capture-manifest.json"]["captures"]:
        binding = row["archive"]
        name = PurePosixPath(str(binding["path"])).name
        bindings[name] = binding
    return bindings


def _verify_preserved_pre_g07_provenance(
    *,
    staging_root: Path,
    documents: Mapping[str, Mapping[str, Any]],
    checks: Sequence[Mapping[str, Any]],
) -> None:
    identity = documents["metal-parity.json"]["evidence_identity"]
    seal_identity = identity.get("pre_g07_seal")
    native_identity = identity.get("pre_g07_native_measurements")
    _require(isinstance(seal_identity, dict), "P08 pre-G07 seal binding is absent")
    _require(
        isinstance(native_identity, dict),
        "P08 pre-G07 native-measurement binding is absent",
    )
    seal_payload, seal = _verify_file_binding(
        staging_root,
        seal_identity.get("file"),
        label="preserved P08 pre-G07 seal",
    )
    _require(
        seal_payload == canonical_json_bytes(seal) + b"\n",
        "preserved P08 pre-G07 seal is not canonical one-LF JSON",
    )
    expected_seal_fields = {
        "schema_version",
        "artifact_kind",
        "run_id",
        "source_identity",
        "native_measurements",
        "production_app_bundle",
        "input_files",
        "raw_archives",
        "available_checks_all_satisfied",
        "checks_sha256",
        "g08_claimed",
        "g07_publication_manifest_sha256",
        "holdout_accessed",
        "hash_scope",
        "artifact_sha256",
    }
    seal_unhashed = dict(seal)
    seal_hash = seal_unhashed.pop("artifact_sha256", None)
    _require(
        set(seal) == expected_seal_fields
        and seal.get("schema_version") == "1.0.0"
        and seal.get("artifact_kind") == "p08_pre_g07_seal"
        and seal.get("run_id") == identity.get("run_id")
        and seal.get("source_identity")
        == {
            "source_commit": identity.get("source_commit"),
            "source_tree_sha256": identity.get("source_tree_sha256"),
        }
        and seal.get("available_checks_all_satisfied") is True
        and all(row.get("status") == "pass" for row in checks)
        and seal.get("checks_sha256") == canonical_sha256(checks)
        and seal.get("g08_claimed") is False
        and seal.get("g07_publication_manifest_sha256") is None
        and seal.get("holdout_accessed") is False
        and seal.get("hash_scope") == HASH_SCOPE
        and seal_hash == canonical_sha256(seal_unhashed)
        and seal_identity.get("artifact_sha256") == seal_hash,
        "preserved P08 pre-G07 seal identity, checks, or self-hash differs",
    )

    native_payload, native = _verify_file_binding(
        staging_root,
        native_identity.get("file"),
        label="preserved P08 native measurements",
    )
    _require(
        native_payload == canonical_json_bytes(native) + b"\n",
        "preserved P08 native measurements are not canonical one-LF JSON",
    )
    _validate_artifact(native, NATIVE_SCHEMA, "preserved P08 native measurements")
    _require(
        seal.get("native_measurements") == native_identity.get("file")
        and native_identity.get("artifact_sha256") == native.get("artifact_sha256"),
        "preserved P08 native measurements differ from the pre-G07 seal",
    )

    execution = native.get("execution_identity")
    _require(isinstance(execution, dict), "preserved native execution identity is absent")
    bundled = identity["bundled_release_resources"]
    expected_resources = [
        {
            "filename": filename,
            "sha256": bundled[key]["sha256"],
            "size_bytes": bundled[key]["size_bytes"],
        }
        for key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES
    ]
    _require(
        native.get("run_id") == identity.get("run_id")
        and execution.get("source_commit") == identity.get("source_commit")
        and execution.get("source_tree_sha256") == identity.get("source_tree_sha256")
        and execution.get("configuration_id") == identity.get("configuration_id")
        and execution.get("p06_release_bundle_artifact_sha256")
        == identity["p06_release_bundle"]["artifact_sha256"]
        and execution.get("selected_evaluation_artifact_sha256")
        == identity.get("selected_evaluation_artifact_sha256")
        and execution.get("g07_publication_manifest_sha256") is None
        and execution.get("holdout_accessed") is False
        and execution.get("production_app_tree_sha256")
        == identity["production_app_bundle"]["tree_sha256"]
        and execution.get("production_executable_sha256")
        == identity["production_executable"]["sha256"]
        and execution.get("metal_library_sha256") == identity["metal_library"]["sha256"]
        and execution.get("bundled_release_resources") == expected_resources
        and native.get("device") == identity.get("device")
        and native.get("device_identity_sha256") == identity.get("device_identity_sha256"),
        "promoted P08 identity differs from the preserved native execution identity",
    )

    _require(
        seal.get("production_app_bundle") == identity.get("production_app_bundle"),
        "promoted production app differs from the pre-G07 seal",
    )
    expected_inputs = {
        "locked-metric-policy.json": identity["locked_metric_policy"]["file"],
        "p06-release.json": identity["p06_release_bundle"]["file"],
        "selected-evaluation.json": identity["selected_evaluation_file"],
    }
    input_rows = seal.get("input_files")
    _require(isinstance(input_rows, list), "pre-G07 sealed input bindings are absent")
    _require(
        input_rows
        == [
            {"id": name, **expected_inputs[name]}
            for name in sorted(expected_inputs)
        ],
        "promoted P08 input files differ from the pre-G07 seal",
    )
    expected_raw = _expected_raw_bindings(documents)
    raw_rows = seal.get("raw_archives")
    _require(isinstance(raw_rows, list), "pre-G07 sealed raw bindings are absent")
    _require(
        raw_rows
        == [
            {"name": name, **expected_raw[name]}
            for name in sorted(expected_raw)
        ],
        "promoted P08 raw archives differ from the pre-G07 seal",
    )

    parity = documents["metal-parity.json"]
    performance = documents["performance-results.json"]
    resources = documents["resource-ring-results.json"]
    instruments = documents["instruments-manifest.json"]
    captures = documents["gpu-capture-manifest.json"]
    _require(
        native.get("metal_parity")
        == {
            "same_device_repeat_minimum": parity["same_device_repeat_minimum"],
            "pixel_determinism_scope": parity["pixel_determinism_scope"],
            "routes": parity["routes"],
        }
        and native.get("performance")
        == {
            "measurement_protocol": performance["measurement_protocol"],
            "measurements": performance["measurements"],
        }
        and native.get("resource_ring")
        == {
            "measurement_protocol": resources["measurement_protocol"],
            "routes": resources["routes"],
        },
        "promoted P08 measurements differ from the preserved native envelope",
    )
    native_instruments = native.get("instruments")
    native_captures = native.get("gpu_capture")
    _require(
        isinstance(native_instruments, dict)
        and native_instruments.get("xctrace_version") == instruments.get("xctrace_version")
        and native_instruments.get("route_observations")
        == instruments.get("route_observations")
        and native_instruments.get("profiles")
        == [
            {
                "tool": row["tool"],
                "route": row["route"],
                "archive_name": PurePosixPath(str(row["archive"]["path"])).name,
            }
            for row in instruments["profiles"]
        ]
        and isinstance(native_captures, dict)
        and native_captures.get("capture_tool") == captures.get("capture_tool")
        and native_captures.get("captures")
        == [
            {
                **{key: value for key, value in row.items() if key != "archive"},
                "archive_name": PurePosixPath(str(row["archive"]["path"])).name,
            }
            for row in captures["captures"]
        ],
        "promoted profile or capture evidence differs from the native envelope",
    )


def _check(
    check_id: str,
    passed: bool,
    evidence_ids: Sequence[str],
    observed: Mapping[str, str | int | float | bool],
) -> Mapping[str, Any]:
    _require(check_id in CHECK_IDS, f"unknown G08 check: {check_id}")
    return {
        "check_id": check_id,
        "status": "pass" if passed else "fail",
        "evidence_ids": list(evidence_ids),
        "observed": dict(observed),
    }


def _parity_checks(document: Mapping[str, Any], limits: Mapping[str, Any]) -> Mapping[str, bool]:
    routes = document["routes"]
    coverage = True
    numeric = True
    exact = True
    deterministic = True
    absolute_limit = Decimal(
        limits["numeric_conformance"]["cpu_float32_vs_metal_normalized_absolute"]["numerator"]
    ) / Decimal(
        limits["numeric_conformance"]["cpu_float32_vs_metal_normalized_absolute"]["denominator"]
    )
    rms_limit = Decimal(
        limits["numeric_conformance"]["cpu_float32_vs_metal_normalized_rms"]["numerator"]
    ) / Decimal(
        limits["numeric_conformance"]["cpu_float32_vs_metal_normalized_rms"]["denominator"]
    )
    code_limit = int(
        limits["numeric_conformance"]["quantized_output_code_maximum_difference"]
    )
    for route_document, route in zip(routes, ROUTES):
        rows = route_document["rows"]
        expected = [
            (plane, phase, descriptor)
            for plane in PLANES
            for phase in range(PHASE_COUNTS[route])
            for descriptor in DESCRIPTOR_IDS
        ]
        observed = [
            (row["plane"], row["phase_ordinal"], row["descriptor_id"])
            for row in rows
        ]
        coverage = coverage and observed == expected
        for row in rows:
            numeric = numeric and (
                row["finite"] is True
                and _decimal(
                    row["maximum_normalized_absolute_error"],
                    "maximum normalized absolute error",
                )
                <= absolute_limit
                and _decimal(row["normalized_rms_error"], "normalized RMS error")
                <= rms_limit
                and row["maximum_output_code_difference"] <= code_limit
            )
            exact = exact and all(
                row[field] is True
                for field in (
                    "state_bytes_equal",
                    "message_bytes_equal",
                    "lut_lookup_bytes_equal",
                )
            )
            repeats = row["metal_repeat_output_sha256_values"]
            deterministic = deterministic and len(repeats) >= 2 and len(set(repeats)) == 1
    return {
        "coverage": coverage,
        "numeric": numeric,
        "exact": exact,
        "deterministic": deterministic,
    }


def _performance_checks(
    document: Mapping[str, Any],
    identity: Mapping[str, Any],
    limits: Mapping[str, Any],
    budget: Mapping[str, Any],
    selected_evaluation: Mapping[str, Any],
) -> Mapping[str, bool]:
    rows = document["measurements"]
    coverage = [(row["route"], row["mode"]) for row in rows] == [
        (route, mode) for route in ROUTES for mode in PERFORMANCE_MODES
    ]
    formulas = coverage
    speed = coverage
    fps = coverage
    overhead = coverage
    estimate = coverage
    deterministic = coverage
    performance = limits["performance"]
    protocol = document["measurement_protocol"]
    selected_estimate = _decimal(
        selected_evaluation["evaluation"]["objective"][
            "estimated_dispatch_cost"
        ],
        "selected calibration estimated dispatch cost",
    )
    route_conditions = {
        "direct_2x": {
            "fixture_id": "img9200_exact_1080p_3f.mp4",
            "fixture_file_sha256": PERFORMANCE_FIXTURE_SHA256["direct_2x"],
            "source_width": 1920,
            "source_height": 1080,
            "destination_width": 3840,
            "destination_height": 2160,
            "fixture_frame_count": 3,
            "average_bit_rate": 24_883_200,
        },
        "direct_3_over_2": {
            "fixture_id": "img9200_exact_720p_1f.mp4",
            "fixture_file_sha256": PERFORMANCE_FIXTURE_SHA256["direct_3_over_2"],
            "source_width": 1280,
            "source_height": 720,
            "destination_width": 1920,
            "destination_height": 1080,
            "fixture_frame_count": 1,
            "average_bit_rate": 6_220_800,
        },
    }
    for row in rows:
        cpu = _decimal(row["cpu_reference_elapsed_seconds"], "CPU elapsed seconds")
        full = _decimal(row["full_ash_metal_elapsed_seconds"], "Metal elapsed seconds")
        fixed = _decimal(
            row["same_bank_fixed_metal_elapsed_seconds"],
            "fixed Metal elapsed seconds",
        )
        cpu_frames = Decimal(row["cpu_reference_frames"])
        full_frames = Decimal(row["full_ash_metal_frames"])
        fixed_frames = Decimal(row["same_bank_fixed_metal_frames"])
        full_gpu_samples = [
            _decimal(value, "full ASH GPU time sample")
            for value in row["full_ash_gpu_time_samples_seconds"]
        ]
        fixed_gpu_samples = [
            _decimal(value, "fixed Metal GPU time sample")
            for value in row["same_bank_fixed_gpu_time_samples_seconds"]
        ]
        _require(
            len(full_gpu_samples) == len(fixed_gpu_samples),
            "full and fixed Metal GPU timing sample counts differ",
        )
        paired_overhead = [
            ((full_sample - fixed_sample) / fixed_sample) * Decimal(100)
            for full_sample, fixed_sample in zip(full_gpu_samples, fixed_gpu_samples)
        ]
        expected_overhead_p95 = _percentile_linear(
            paired_overhead,
            Decimal("0.95"),
        )
        expected_speed = (cpu / cpu_frames) / (full / full_frames)
        expected_fps = full_frames / full
        target_luma_pixels = Decimal(row["target_luma_pixel_count"])
        analysis_cells = Decimal(row["analysis_cell_count"])
        actual_luma_invocations = Decimal(
            row["actual_luma_operator_invocation_count"]
        )
        candidate_luma_invocations = Decimal(
            row["candidate_luma_operator_invocation_count"]
        )
        numerical_fallback_invocations = Decimal(
            row["luma_numerical_fallback_invocation_count"]
        )
        expected_measured_cost = (
            analysis_cells + actual_luma_invocations
        ) / target_luma_pixels
        maximum_candidate_invocations = (
            Decimal(protocol["maximum_operator_evaluations_per_output_cell"])
            * target_luma_pixels
        )
        expected_estimate_error = (
            abs(expected_measured_cost - selected_estimate) / selected_estimate
        )
        conditions = row["benchmark_conditions"]
        route_condition = route_conditions[row["route"]]
        decoded_frames = conditions["ordered_decoded_frames"]
        semantic_conditions = (
            all(
                conditions[field] == expected
                for field, expected in route_condition.items()
                if field != "average_bit_rate"
            )
            and row["input_sha256"] == conditions["fixture_file_sha256"]
            and [frame["frame_ordinal"] for frame in decoded_frames]
            == list(range(route_condition["fixture_frame_count"]))
            and len(decoded_frames) == route_condition["fixture_frame_count"]
            and decoded_frames[0]["presentation_timestamp_value"] == 0
            and (
                row["route"] != "direct_2x"
                or [
                    (
                        frame["presentation_timestamp_value"],
                        frame["presentation_timestamp_timescale"],
                    )
                    for frame in decoded_frames
                ]
                == [(0, 60), (1, 60), (2, 60)]
            )
            and conditions["measurement_scope"] == row["mode"]
            and conditions["writer_settings"]["execution_scope"]
            == (
                "not_executed_compute_only"
                if row["mode"] == "compute_only"
                else "production_end_to_end"
            )
            and conditions["writer_settings"]["average_bit_rate"]
            == route_condition["average_bit_rate"]
            and row["full_ash_conditions_sha256"]
            == canonical_sha256(conditions)
            and row["fixed_metal_conditions_sha256"]
            == canonical_sha256(conditions)
            and row["target_luma_pixel_count"]
            == route_condition["destination_width"]
            * route_condition["destination_height"]
            * row["full_ash_metal_frames"]
        )
        formula_row = (
            semantic_conditions
            and row["cpu_reference_frames"] == protocol["cpu_reference_frames"]
            and row["full_ash_metal_warmup_frames"] == protocol["warmup_frames"]
            and row["same_bank_fixed_metal_warmup_frames"]
            == protocol["warmup_frames"]
            and row["full_ash_metal_frames"] == protocol["measurement_frames"]
            and row["same_bank_fixed_metal_frames"]
            == protocol["measurement_frames"]
            and len(full_gpu_samples) == row["full_ash_metal_frames"]
            and len(fixed_gpu_samples) == row["same_bank_fixed_metal_frames"]
            and target_luma_pixels % full_frames == 0
            and analysis_cells % full_frames == 0
            and target_luma_pixels
            <= candidate_luma_invocations
            <= maximum_candidate_invocations
            and numerical_fallback_invocations <= target_luma_pixels
            and actual_luma_invocations
            == candidate_luma_invocations + numerical_fallback_invocations
            and _close(row["same_machine_speedup"], expected_speed, "reported speedup")
            and _close(row["frames_per_second"], expected_fps, "reported FPS")
            and _close(
                row["ash_dispatch_overhead_p95_percent"],
                expected_overhead_p95,
                "reported ASH dispatch overhead p95",
            )
            and _close(
                row["calibration_estimated_dispatch_cost"],
                selected_estimate,
                "reported calibration estimated dispatch cost",
            )
            and _close(
                row["measured_luma_dispatch_cost"],
                expected_measured_cost,
                "reported measured luma dispatch cost",
            )
            and _close(
                row["calibration_estimate_relative_error"],
                expected_estimate_error,
                "reported calibration estimate error",
            )
            and row["calibration_estimate_source_artifact_sha256"]
            == identity["selected_evaluation_artifact_sha256"]
        )
        formulas = formulas and formula_row
        if row["mode"] == "end_to_end":
            speed = speed and expected_speed >= _decimal(
                performance["same_machine_speedup_minimum"],
                "minimum speedup",
            )
            fps = fps and expected_fps >= _decimal(
                performance["same_machine_frames_per_second_minimum"],
                "minimum FPS",
            )
        overhead = overhead and expected_overhead_p95 <= Decimal(
            int(budget["derived_budget_percent"])
        )
        estimate = estimate and expected_estimate_error <= _decimal(
            performance["calibration_estimate_relative_error_maximum"],
            "maximum estimate error",
        )
        repeats = row["repeat_output_sha256_values"]
        deterministic = deterministic and len(repeats) >= 2 and len(set(repeats)) == 1
    return {
        "protocol": coverage and formulas,
        "speed": speed and formulas,
        "fps": fps and formulas,
        "overhead": overhead and formulas,
        "estimate": estimate and formulas,
        "deterministic": deterministic,
    }


def _resource_checks(
    document: Mapping[str, Any],
    limits: Mapping[str, Any],
    performance_document: Mapping[str, Any],
) -> Mapping[str, bool]:
    rows = document["routes"]
    route_coverage = [row["route"] for row in rows] == list(ROUTES)
    bounded = route_coverage
    memory = route_coverage
    deterministic = route_coverage
    performance = limits["performance"]
    compute_conditions = {
        row["route"]: row["full_ash_conditions_sha256"]
        for row in performance_document["measurements"]
        if row["mode"] == "compute_only"
    }
    maximum_in_flight = int(performance["default_in_flight_frames_maximum"])
    memory_limit = _decimal(
        performance["memory_stability"]["rss_or_footprint_drift_percent_maximum"],
        "maximum memory drift",
    )
    for row in rows:
        start = Decimal(row["memory_bytes_after_warmup"])
        end = Decimal(row["memory_bytes_after_measurement"])
        expected_drift = max(Decimal(0), end - start) / start * Decimal(100)
        bounded = bounded and (
            row["configured_capacity"] == maximum_in_flight
            and row["observed_frames"]
            == document["measurement_protocol"]["measurement_frames"]
            and row["maximum_observed_in_flight"] <= maximum_in_flight
            and row["in_flight_after_drain"] == 0
            and row["resource_failure_count"] == 0
            and row["live_frame_resources_returned_to_bound"] is True
            and row["live_frame_resource_bound"] == maximum_in_flight
            and row["live_frame_resources_after_drain"]
            <= row["live_frame_resource_bound"]
        )
        memory = memory and (
            _close(row["memory_drift_percent"], expected_drift, "memory drift")
            and expected_drift <= memory_limit
        )
        repeats = row["repeat_output_sha256_values"]
        deterministic = deterministic and len(repeats) >= 2 and len(set(repeats)) == 1
    protocol = document["measurement_protocol"] == {
        "warmup_frames": int(performance["memory_stability"]["warmup_frames"]),
        "measurement_frames": int(performance["memory_stability"]["measurement_frames"]),
    } and all(
        row["benchmark_conditions_sha256"] == compute_conditions.get(row["route"])
        for row in rows
    )
    return {
        "protocol": protocol and route_coverage,
        "bounded": bounded,
        "memory": memory,
        "deterministic": deterministic,
    }


def _instruments_checks(
    document: Mapping[str, Any],
    limits: Mapping[str, Any],
    performance_document: Mapping[str, Any],
) -> Mapping[str, bool]:
    observations = document["route_observations"]
    coverage = [row["route"] for row in observations] == list(ROUTES)
    metal = coverage
    no_tree_cpu = coverage
    no_wait = coverage
    no_readback = coverage
    performance = limits["performance"]
    end_to_end_conditions = {
        row["route"]: row["full_ash_conditions_sha256"]
        for row in performance_document["measurements"]
        if row["mode"] == "end_to_end"
    }
    for row in observations:
        observed_frames = row["observed_frames"]
        expected_command_buffers = (
            observed_frames
            + performance_document["measurement_protocol"]["warmup_frames"]
        )
        metal = metal and (
            observed_frames == 300
            and row["analysis_gpu_frame_count"] == observed_frames
            and row["reconstruction_gpu_frame_count"] == observed_frames
            and row["benchmark_conditions_sha256"]
            == end_to_end_conditions.get(row["route"])
        )
        no_tree_cpu = no_tree_cpu and (
            row["full_frame_cpu_reconstruction_loop_count"]
            <= performance["full_frame_cpu_reconstruction_loops_maximum"]
            * observed_frames
            and row["runtime_leaf_tree_generation_count"]
            <= performance["runtime_leaf_tree_generations_per_frame_maximum"]
            * observed_frames
            and row["candidate_evaluation_maximum_from_gpu_summary"]
            <= performance["candidate_evaluations_per_output_cell_maximum"]
        )
        no_wait = no_wait and (
            row["command_completion_mode"] == "asynchronous_completion_handler"
            and row["submitted_command_buffer_count"] == expected_command_buffers
            and row["completed_command_buffer_count"] == expected_command_buffers
            and row["failed_command_buffer_count"] == 0
            and row["command_buffer_observation_count"] == expected_command_buffers
            and row["command_buffer_error_observation_count"] == 0
        )
        no_readback = no_readback and (
            row["avoidable_full_frame_gpu_readback_count"]
            <= performance["avoidable_full_frame_gpu_readbacks_per_frame_maximum"]
            * observed_frames
        )
    return {
        "metal": metal,
        "no_tree_cpu": no_tree_cpu,
        "no_wait": no_wait,
        "no_readback": no_readback,
    }


def _capture_check(document: Mapping[str, Any]) -> bool:
    captures = document["captures"]
    if [row["route"] for row in captures] != list(ROUTES):
        return False
    for row in captures:
        route = row["route"]
        expected_phases = list(range(PHASE_COUNTS[route]))
        coverage = row["plane_coverage"]
        if (
            row["capture_succeeded"] is not True
            or row["capture_scope"]
            != "exhaustive synthetic route-plane-phase-descriptor parity fixtures; not a natural-frame coverage claim"
            or row["command_buffer_count"] < 1
            or row["compute_encoder_count"] < 1
            or not row["kernel_names"]
            or row["command_buffer_status"] != "completed"
            or row["command_buffer_error"] is not None
            or [item["plane"] for item in coverage] != list(PLANES)
            or any(item["phase_ordinals"] != expected_phases for item in coverage)
            or any(item["descriptor_ids"] != list(DESCRIPTOR_IDS) for item in coverage)
        ):
            return False
    return True


def _gate_checks(
    documents: Mapping[str, Mapping[str, Any]],
    tolerances: Mapping[str, Any],
    budget: Mapping[str, Any],
    selected_evaluation: Mapping[str, Any],
) -> list[Mapping[str, Any]]:
    identity = documents["metal-parity.json"]["evidence_identity"]
    parity = _parity_checks(documents["metal-parity.json"], tolerances)
    performance = _performance_checks(
        documents["performance-results.json"],
        identity,
        tolerances,
        budget,
        selected_evaluation,
    )
    resources = _resource_checks(
        documents["resource-ring-results.json"],
        tolerances,
        documents["performance-results.json"],
    )
    instruments = _instruments_checks(
        documents["instruments-manifest.json"],
        tolerances,
        documents["performance-results.json"],
    )
    capture = _capture_check(documents["gpu-capture-manifest.json"])
    deterministic = (
        parity["deterministic"]
        and performance["deterministic"]
        and resources["deterministic"]
    )
    checks = [
        _check(
            "metal_execution",
            instruments["metal"] and capture,
            ("instruments_manifest", "gpu_capture_manifest"),
            {"both_routes_full_frame_metal": instruments["metal"] and capture},
        ),
        _check(
            "parity_coverage",
            parity["coverage"],
            ("metal_parity",),
            {"expected_route_plane_phase_descriptor_rows": 416},
        ),
        _check(
            "numeric_parity",
            parity["numeric"],
            ("metal_parity",),
            {
                "absolute_error_numerator": 2,
                "absolute_error_denominator": 65535,
                "rms_error_numerator": 1,
                "rms_error_denominator": 65535,
                "maximum_code_difference": 1,
            },
        ),
        _check(
            "exact_state_message_lut",
            parity["exact"],
            ("metal_parity",),
            {"all_exact": parity["exact"]},
        ),
        _check(
            "same_device_determinism",
            deterministic,
            ("metal_parity", "performance_results", "resource_ring_results"),
            {"minimum_repeats": 2, "decoded_pixels_identical": deterministic},
        ),
        _check(
            "performance_protocol",
            performance["protocol"] and resources["protocol"],
            ("performance_results", "resource_ring_results"),
            {
                "warmup_frames": 30,
                "measurement_frames": 300,
                "compute_and_end_to_end": True,
            },
        ),
        _check(
            "same_machine_speedup",
            performance["speed"],
            ("performance_results",),
            {"minimum": 20.0},
        ),
        _check(
            "frames_per_second",
            performance["fps"],
            ("performance_results",),
            {"minimum": 0.982},
        ),
        _check(
            "dispatch_overhead_budget",
            performance["overhead"],
            ("performance_results",),
            {
                "locked_budget_percent": int(budget["derived_budget_percent"]),
                "locked_before_g08": True,
            },
        ),
        _check(
            "calibration_estimate_error",
            performance["estimate"],
            ("performance_results",),
            {"maximum_relative_error": 0.2},
        ),
        _check(
            "no_runtime_tree_or_cpu_loop",
            instruments["no_tree_cpu"],
            ("instruments_manifest",),
            {"cpu_full_frame_loops_maximum": 0, "runtime_tree_maximum": 0, "candidate_maximum": 2},
        ),
        _check(
            "no_production_wait",
            instruments["no_wait"],
            ("instruments_manifest",),
            {"wait_until_completed_maximum": 0},
        ),
        _check(
            "no_avoidable_readback",
            instruments["no_readback"],
            ("instruments_manifest",),
            {"full_frame_readbacks_per_frame_maximum": 0},
        ),
        _check(
            "resource_ring_and_memory",
            resources["bounded"] and resources["memory"],
            ("resource_ring_results", "instruments_manifest"),
            {"maximum_in_flight": 3, "maximum_memory_drift_percent": 10.0},
        ),
        _check(
            "profile_and_capture_closure",
            capture,
            ("instruments_manifest", "gpu_capture_manifest"),
            {
                "time_profiler": True,
                "allocations": True,
                "metal_trace": True,
                "gpu_capture": capture,
            },
        ),
    ]
    _require([row["check_id"] for row in checks] == list(CHECK_IDS), "G08 check order differs")
    return checks


def _write_replace(path: Path, payload: bytes, label: str) -> None:
    _strict_file(path, label)
    temporary = path.with_name(f".{path.name}.canonical")
    _require(not os.path.lexists(temporary), f"{label} canonical temporary exists")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o644)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            _require(written > 0, f"{label} canonical write stalled")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)


def _write_new(path: Path, payload: bytes, label: str) -> None:
    _require(not os.path.lexists(path), f"{label} already exists")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o644)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            _require(written > 0, f"{label} write stalled")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _evidence_binding(path: Path, identifier: str) -> Mapping[str, Any]:
    payload, document = _read_json(path, f"G08 evidence {identifier}")
    return {
        "id": identifier,
        "path": path.name,
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
        "artifact_sha256": document["artifact_sha256"],
    }


def _load_documents(staging_root: Path) -> Mapping[str, Mapping[str, Any]]:
    documents: dict[str, Mapping[str, Any]] = {}
    for filename, schema in ARTIFACT_SCHEMAS.items():
        _, document = _read_json(staging_root / filename, f"P08 {filename}")
        _validate_artifact(document, schema, f"P08 {filename}")
        documents[filename] = document
    identities = [document["evidence_identity"] for document in documents.values()]
    _require(
        all(identity == identities[0] for identity in identities[1:]),
        "P08 artifacts do not share one exact source/release/device identity",
    )
    return documents


def _validate_gate(document: Mapping[str, Any]) -> None:
    _validate_artifact(document, G08_GATE_SCHEMA, "G08 gate manifest")
    checks = document["checks"]
    all_pass = all(row["status"] == "pass" for row in checks)
    _require(
        [row["check_id"] for row in checks] == list(CHECK_IDS)
        and document["all_mandatory_checks_passed"] is all_pass
        and document["status"] == ("pass" if all_pass else "fail"),
        "G08 gate status does not equal its mandatory checks",
    )


def _finalize_promoted_g08(
    *,
    repository_root: Path,
    staging_root: Path,
    output_root: Path,
) -> Mapping[str, Any]:
    """Validate a promoted pre-G07 closure and atomically publish G08."""

    repository_root = _strict_directory(repository_root, "P08 repository root")
    staging_root = _strict_directory(staging_root, "G08 staging root")
    output_root = _strict_absent(output_root, "G08 output root")
    expected_parent = _strict_directory(
        repository_root / "Artifacts" / "ASH",
        "P08 artifact parent",
    )
    _require(
        output_root.parent == expected_parent
        and output_root.relative_to(repository_root).parts[:2]
        == ("Artifacts", "ASH")
        and len(output_root.relative_to(repository_root).parts) == 3,
        "G08 output is not an exact direct Artifacts/ASH run descendant",
    )
    _require(
        staging_root.parent == output_root.parent
        and staging_root.name == f".{output_root.name}.partial",
        "G08 staging root is not the deterministic hidden output sibling",
    )
    _require(
        not os.path.lexists(staging_root / G08_GATE_FILENAME),
        "caller supplied a G08 decision instead of measurements",
    )
    documents = _load_documents(staging_root)
    identity = documents["metal-parity.json"]["evidence_identity"]
    _require(
        identity["run_id"] == output_root.name,
        "P08 run ID does not equal the exact Artifacts/ASH output directory name",
    )
    _verify_staging_closure(staging_root, documents)
    tolerances, budget, selected_evaluation = _validate_identity(
        staging_root,
        identity,
        repository_root,
    )
    _verify_raw_artifacts(staging_root, documents)
    checks = _gate_checks(
        documents,
        tolerances,
        budget,
        selected_evaluation,
    )
    _verify_preserved_pre_g07_provenance(
        staging_root=staging_root,
        documents=documents,
        checks=checks,
    )

    for filename, document in documents.items():
        payload = canonical_json_bytes(document) + b"\n"
        _write_replace(staging_root / filename, payload, f"P08 {filename}")
    evidence = [
        _evidence_binding(staging_root / filename, identifier)
        for filename, identifier in (
            ("metal-parity.json", "metal_parity"),
            ("performance-results.json", "performance_results"),
            ("resource-ring-results.json", "resource_ring_results"),
            ("instruments-manifest.json", "instruments_manifest"),
            ("gpu-capture-manifest.json", "gpu_capture_manifest"),
        )
    ]
    all_pass = all(row["status"] == "pass" for row in checks)
    gate_core: Mapping[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g08_gate_manifest",
        "gate_id": "G08",
        "evidence_identity": identity,
        "status": "pass" if all_pass else "fail",
        "all_mandatory_checks_passed": all_pass,
        "checks": checks,
        "evidence": evidence,
        "holdout_accessed": False,
        "raw_artifacts_preserved": True,
        "hash_scope": HASH_SCOPE,
    }
    gate = {**gate_core, "artifact_sha256": canonical_sha256(gate_core)}
    _validate_gate(gate)
    _write_new(
        staging_root / G08_GATE_FILENAME,
        canonical_json_bytes(gate) + b"\n",
        "G08 gate manifest",
    )
    directory_descriptor = os.open(
        staging_root,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
    os.rename(staging_root, output_root)
    parent_descriptor = os.open(
        output_root.parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
    _, reopened = _read_json(output_root / G08_GATE_FILENAME, "published G08 gate")
    _validate_gate(reopened)
    _require(reopened == gate, "published G08 gate changed after atomic rename")
    return gate


__all__ = [
    "ARTIFACT_SCHEMAS",
    "BUNDLED_RELEASE_RESOURCES",
    "CHECK_IDS",
    "DESCRIPTOR_IDS",
    "G08_GATE_FILENAME",
    "G08_GATE_SCHEMA",
    "HASH_SCOPE",
    "PERFORMANCE_MODES",
    "PHASE_COUNTS",
    "PLANES",
    "PROFILE_TOOLS",
    "P08EvidenceError",
    "ROUTES",
    "TREE_HASH_SCOPE",
    "file_binding",
    "repository_identity",
    "tree_binding",
]
