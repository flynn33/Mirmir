"""Publish the exact selected P06 V2 candidate as one atomic V3 release.

The selected candidate's mapping, operator bank, compiler input, and route LUT
bytes are already content-addressed by its schema-2 evaluation.  This module
therefore copies and reopens those exact measured bytes.  Selection authority
is added only by the enclosing evidence closure and release bundle; candidate
bytes are never rewritten after selection.
"""

from __future__ import annotations

from datetime import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
from typing import Dict, Mapping, Sequence, Tuple

from validation.calibration_v2.calibration_persistence_v2 import (
    FileBindingV2,
    authority_bindings_v2,
    canonical_json_file_bytes_v2,
    finalize_artifact_sha256_v2,
)
from validation.calibration_v2.production_candidate_provider_v2 import (
    SourceGateEvidenceV2,
)
from validation.calibration_v2.native_adapter.factory import (
    NativeCompiledConfigurationV2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    ATTEMPT_LEDGER_KIND,
    NEIGHBOR_MANIFEST_KIND,
    SELECTION_KIND,
)
from validation.calibration_v2.p07.execution_authority_v2 import (
    build_document as build_p07_execution_authority_v2,
    publish_new as publish_p07_execution_authority_v2,
)
from validation.calibration_v2.production_coordinator_v2 import (
    P06ProductionRunResultV2,
    RunArtifactProvenanceV2,
)
from validation.calibration_v2.production_factory import (
    ProductionCalibrationAssembly,
)
from validation.calibration_v2.reference.lut_oracle_v2 import (
    ROUTES,
    compile_all_route_bytes_v2,
    load_locked_compiler_input_v2,
    validate_lut_v2,
)
from validation.calibration_v2.release_lock import (
    _RELEASE_ARTIFACTS_V3,
    build_p06_release_bundle_v3_manifest,
)
from validation.calibration_v2.release_orchestrator import (
    build_p06_release_transaction,
)
from validation.calibration_v2.shared_bank_artifacts_v2 import (
    SharedBankArtifactMaterializerV2,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


_ZERO_SHA256 = "0" * 64
_EVIDENCE_CLOSURE_SCHEMA = (
    Path(__file__).resolve().parent / "schemas/p06-evidence-closure-v2.schema.json"
)
_BASELINE_BUDGET = (
    Path(__file__).resolve().parent
    / "contracts/baseline-ablation-budget-v2.json"
)
_FIXED_RELEASE_PATHS = dict(_RELEASE_ARTIFACTS_V3)


class ProductionReleaseV3Error(ValueError):
    """The selected run or release composition is incomplete or mutable."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and value != _ZERO_SHA256
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _require_live_holdout_preopen_v3(value: object) -> Mapping[str, object]:
    """Accept only the schema-owned unopened receipt fields."""

    if (
        not isinstance(value, Mapping)
        or value.get("verification_status") != "pass"
        or value.get("access_status") != "unopened"
        or value.get("access_count") != 0
        or value.get("open_intent_anchor_present") is not False
        or value.get("pixel_content_included") is not False
    ):
        raise ProductionReleaseV3Error(
            "live holdout preopen verification is absent or accessed"
        )
    return value


def _safe_relative(value: object, *, label: str) -> str:
    if type(value) is not str:
        raise ProductionReleaseV3Error(f"{label} path is absent")
    parsed = PurePosixPath(value)
    if (
        parsed.is_absolute()
        or parsed.as_posix() != value
        or any(part in {"", ".", ".."} for part in parsed.parts)
        or "\\" in value
    ):
        raise ProductionReleaseV3Error(f"{label} path is unsafe")
    return value


def _read_regular(path: Path, *, label: str) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise ProductionReleaseV3Error(f"{label} is absent") from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        raise ProductionReleaseV3Error(
            f"{label} is linked or is not one regular file"
        )
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ProductionReleaseV3Error(f"{label} changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    ):
        raise ProductionReleaseV3Error(f"{label} changed while reading")
    return b"".join(chunks)


def _parse_json(payload: bytes, *, label: str) -> Dict[str, object]:
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProductionReleaseV3Error(f"{label} is not JSON") from error
    if type(value) is not dict:
        raise ProductionReleaseV3Error(f"{label} is not an object")
    return value


def _write_new(
    path: Path,
    payload: bytes,
    *,
    executable: bool = False,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o700 if executable else 0o600)
    except FileExistsError:
        if _read_regular(path, label=f"existing {path.name}") != payload:
            raise ProductionReleaseV3Error(
                f"published release path identifies different bytes: {path}"
            )
        return
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise ProductionReleaseV3Error(
                    "release publication made no progress"
                )
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    reopened = _read_regular(path, label=f"published {path.name}")
    if reopened != payload:
        raise ProductionReleaseV3Error(
            f"published release bytes changed: {path.name}"
        )


def _binding(path: Path, relative: str) -> Mapping[str, object]:
    payload = _read_regular(path, label=relative)
    return {
        "path": relative,
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _file_binding(
    identifier: str,
    path: Path,
    relative: str,
) -> Mapping[str, object]:
    return {"id": identifier, **_binding(path, relative)}


def _copy_binding(
    *,
    source_root: Path,
    release_root: Path,
    binding: Mapping[str, object],
    target_relative: str | None = None,
    label: str,
) -> Mapping[str, object]:
    source_relative = _safe_relative(binding.get("path"), label=label)
    source = source_root.joinpath(*PurePosixPath(source_relative).parts)
    payload = _read_regular(source, label=label)
    if (
        binding.get("sha256") != _sha256(payload)
        or binding.get("size_bytes") != len(payload)
    ):
        raise ProductionReleaseV3Error(f"{label} binding changed")
    relative = target_relative or source_relative
    relative = _safe_relative(relative, label=f"{label} destination")
    destination = release_root.joinpath(*PurePosixPath(relative).parts)
    _write_new(destination, payload)
    if _read_regular(destination, label=f"copied {label}") != payload:
        raise ProductionReleaseV3Error(f"{label} differs after release copy")
    return _binding(destination, relative)


def _copy_path(
    *,
    source: Path,
    release_root: Path,
    relative: str,
    label: str,
    executable: bool = False,
) -> Mapping[str, object]:
    payload = _read_regular(source, label=label)
    target = release_root.joinpath(*PurePosixPath(relative).parts)
    _write_new(target, payload, executable=executable)
    return _binding(target, relative)


def _project_non_ash_release_artifacts(
    *,
    calibration_root: Path,
    release_root: Path,
    control_bundle: Mapping[str, object],
) -> None:
    rows = control_bundle.get("dependency_bindings")
    if type(rows) is not list:
        raise ProductionReleaseV3Error(
            "selected control authorization dependencies are absent"
        )
    matches: Dict[str, Tuple[Mapping[str, object], Mapping[str, object]]] = {}
    for row in rows:
        if type(row) is not dict:
            raise ProductionReleaseV3Error(
                "selected control authorization dependency is invalid"
            )
        _copy_binding(
            source_root=calibration_root,
            release_root=release_root,
            binding=row,
            label="selected control dependency",
        )
        kind = row.get("artifact_kind")
        if kind not in {ATTEMPT_LEDGER_KIND, NEIGHBOR_MANIFEST_KIND, SELECTION_KIND}:
            continue
        payload = _read_regular(
            calibration_root.joinpath(
                *PurePosixPath(_safe_relative(row.get("path"), label="non-ASH")).parts
            ),
            label="selected non-ASH artifact",
        )
        document = _parse_json(payload, label="selected non-ASH artifact")
        if kind == ATTEMPT_LEDGER_KIND:
            target = "non_ash_development_attempt_ledger"
        elif kind == NEIGHBOR_MANIFEST_KIND:
            target = "non_ash_validation_neighbor_manifest"
        elif "validation_selection_sha256" in document:
            target = "non_ash_validation_selection"
        elif "development_selection_sha256" in document:
            target = "non_ash_development_selection"
        else:
            raise ProductionReleaseV3Error(
                "non-ASH selection stage cannot be identified"
            )
        prior = matches.get(target)
        value = (row, document)
        if prior is not None and prior != value:
            raise ProductionReleaseV3Error(
                f"selected non-ASH release artifact is ambiguous: {target}"
            )
        matches[target] = value
    required = {
        "non_ash_development_attempt_ledger",
        "non_ash_development_selection",
        "non_ash_validation_neighbor_manifest",
        "non_ash_validation_selection",
    }
    if set(matches) != required:
        raise ProductionReleaseV3Error(
            "selected non-ASH release closure is incomplete"
        )
    for identifier in sorted(required):
        _copy_binding(
            source_root=calibration_root,
            release_root=release_root,
            binding=matches[identifier][0],
            target_relative=str(_FIXED_RELEASE_PATHS[identifier]),
            label=identifier,
        )


def _crc32(value: int) -> str:
    return f"0x{value:08X}"


def _route_record(
    *,
    route_name: str,
    payload: bytes,
    configuration: object,
) -> Mapping[str, object]:
    route = ROUTES[route_name]
    validated = validate_lut_v2(
        payload,
        expected_configuration=configuration,
        expected_route=route,
    )
    selection = configuration.routes[route_name]
    runtime_route = "direct-2x" if route_name == "direct_2x" else "direct-3over2"
    return {
        "route": runtime_route,
        "route_id": route.route_id,
        "scale_numerator": route.scale_numerator,
        "scale_denominator": route.scale_denominator,
        "phase_count": route.phase_count,
        "context_count": 4,
        "valid_state_count": 256,
        "plane_count": validated.plane_count,
        "luma_coordinate_policy": selection.luma_coordinate_policy,
        "chroma_coordinate_policy": selection.chroma_coordinate_policy,
        "analysis_grid_source_step": selection.analysis_grid_source_step,
        "entry_count": validated.entry_count,
        "parameter_count": validated.parameter_count,
        "path": route.filename,
        "whole_file_size_bytes": len(payload),
        "whole_file_sha256": validated.whole_file_sha256,
        "payload_sha256": validated.payload_sha256,
        "header_crc32": _crc32(validated.header_crc32),
        "payload_crc32": _crc32(validated.payload_crc32),
    }


def _native_parity_and_manifest(
    *,
    repository_root: Path,
    release_root: Path,
    compiled: NativeCompiledConfigurationV2,
) -> None:
    compiler_path = release_root / "locked-compiler-input-v2.json"
    configuration = load_locked_compiler_input_v2(compiler_path)
    independent = compile_all_route_bytes_v2(configuration)
    production_source = _binding(
        release_root / "sources/production-swift-source-manifest.json",
        "sources/production-swift-source-manifest.json",
    )
    independent_sources = (
        "validation/calibration_v2/reference/lut_oracle_v2.py",
        "validation/calibration_v2/reference/lut_oracle.py",
    )
    source_rows = []
    for relative in independent_sources:
        payload = _read_regular(repository_root / relative, label=relative)
        source_rows.append(
            {"path": relative, "sha256": _sha256(payload), "size_bytes": len(payload)}
        )
    independent_source_document = {
        "schema_version": "2.0.0",
        "implementation_role": "independent_test_python_format_1_2",
        "sources": source_rows,
    }
    independent_source_payload = canonical_json_file_bytes_v2(
        independent_source_document
    )
    independent_source_path = (
        release_root / "sources/independent-python-source-manifest-v2.json"
    )
    _write_new(independent_source_path, independent_source_payload)
    independent_source = _binding(
        independent_source_path,
        "sources/independent-python-source-manifest-v2.json",
    )

    comparisons = []
    route_records = []
    for route_name, runtime_name in (
        ("direct_2x", "direct-2x"),
        ("direct_3_over_2", "direct-3over2"),
    ):
        filename = ROUTES[route_name].filename
        production_payload = _read_regular(
            release_root / filename,
            label=f"production {runtime_name} LUT",
        )
        independent_payload = independent[route_name]
        if production_payload != independent_payload:
            first = next(
                (
                    index
                    for index, values in enumerate(
                        zip(production_payload, independent_payload)
                    )
                    if values[0] != values[1]
                ),
                min(len(production_payload), len(independent_payload)),
            )
            failure = {
                "schema_version": "3.0.0",
                "artifact_kind": "p06_native_lut_parity_failure_v3",
                "status": "failed_preserved",
                "route": runtime_name,
                "first_differing_byte_offset": first,
                "holdout_accessed": False,
            }
            failure["manifest_sha256"] = canonical_sha256(failure)
            _write_new(
                release_root / "native-lut-parity-failure-v3.json",
                canonical_json_file_bytes_v2(failure),
            )
            raise ProductionReleaseV3Error(
                f"native and independent format-1.2 LUTs differ: {runtime_name}"
            )
        independent_relative = f"independent/{filename}"
        _write_new(release_root / independent_relative, independent_payload)
        record = _route_record(
            route_name=route_name,
            payload=production_payload,
            configuration=configuration,
        )
        route_records.append(record)
        comparisons.append(
            {
                "route": runtime_name,
                "production_swift": _binding(
                    release_root / filename,
                    filename,
                ),
                "independent_test_python": _binding(
                    release_root / independent_relative,
                    independent_relative,
                ),
                "byte_identical": True,
                "payload_hash_identical": True,
                "first_differing_byte_offset": None,
            }
        )
    parity = {
        "schema_version": "3.0.0",
        "manifest_id": "mirmir-native-lut-parity-v3",
        "status": "pass",
        "configuration_id": configuration.configuration_id,
        "compiler_input": _binding(
            compiler_path,
            "locked-compiler-input-v2.json",
        ),
        "input_hashes": dict(configuration.hash_bindings),
        "implementations": {
            "production_swift": production_source,
            "independent_test_python": independent_source,
        },
        "routes": comparisons,
        "all_routes_byte_identical": True,
        "holdout_accessed": False,
    }
    parity["manifest_sha256"] = canonical_sha256(parity)
    parity_path = release_root / "native-lut-parity-manifest-v3.json"
    _write_new(parity_path, canonical_json_file_bytes_v2(parity))

    lut_manifest = {
        "schema_version": "3.0.0",
        "manifest_id": "mirmir-ash-route-luts-v3",
        "status": "locked_before_p07",
        "configuration_id": configuration.configuration_id,
        "compiler_input": _binding(
            compiler_path,
            "locked-compiler-input-v2.json",
        ),
        "hash_bindings": dict(configuration.hash_bindings),
        "routes": route_records,
        "runtime_load_policy": {
            "immutability": (
                "validate complete bytes before publication and retain immutable bytes"
            ),
            "load_frequency": "once_per_route_per_configuration",
            "per_frame_load_count": 0,
            "runtime_tree_generation_count": 0,
            "maximum_operator_evaluations_per_output_cell": 2,
        },
        "native_parity_manifest": _binding(
            parity_path,
            "native-lut-parity-manifest-v3.json",
        ),
        "holdout_accessed": False,
    }
    lut_manifest["manifest_sha256"] = canonical_sha256(lut_manifest)
    _write_new(
        release_root / "lut-manifest-v3.json",
        canonical_json_file_bytes_v2(lut_manifest),
    )


def _evidence_closure(
    *,
    release_root: Path,
    run_id: str,
    configuration_id: str,
    shared_bank_sha256: str,
    input_bundle_sha256: str,
    corpus_lock_bundle_sha256: str,
    gate_evidence: Sequence[SourceGateEvidenceV2],
    project_commit: str,
    selection_binding: Mapping[str, object],
    evaluation_binding: Mapping[str, object],
    run_binding: Mapping[str, object],
    artifact_manifest_binding: Mapping[str, object],
) -> Mapping[str, object]:
    gate_rows = []
    components = []
    for gate in gate_evidence:
        relative = gate.binding.path
        reopened = _binding(release_root / relative, relative)
        if reopened != {
            "path": gate.binding.path,
            "sha256": gate.binding.sha256,
            "size_bytes": gate.binding.size_bytes,
        }:
            raise ProductionReleaseV3Error(
                f"{gate.gate_id} gate receipt changed in release"
            )
        gate_rows.append({"gate_id": gate.gate_id, "binding": reopened})
        aggregate = {"id": f"{gate.gate_id.lower()}_semantic_receipt", **reopened}
        components.append(
            {
                "component_id": f"current_source_{gate.gate_id.lower()}",
                "owning_gate": gate.gate_id,
                "implementation_scope": {
                    "kind": "production",
                    "production_caller": (
                        "validation.calibration_v2.production_release_v3"
                    ),
                },
                "focused_and_dependent_tests": [aggregate],
                "telemetry": {"applicable": False, "bindings": []},
                "fault_injection_evidence": [aggregate],
                "artifact_bindings": [aggregate],
                "local_green_commit": project_commit,
                "all_six_closure_items_present": True,
            }
        )
    compiler_ids = (
        "locked_mapping",
        "locked_operator_bank",
        "locked_metric_policy",
        "locked_compiler_input_v2",
        "direct2x_lut",
        "direct3over2_lut",
        "native_parity_manifest",
        "lut_manifest",
        "configuration_lock",
    )
    compiler_evidence = [
        _file_binding(
            identifier,
            release_root / str(_FIXED_RELEASE_PATHS[identifier]),
            str(_FIXED_RELEASE_PATHS[identifier]),
        )
        for identifier in compiler_ids
    ]
    document = {
        "schema_version": "2.0.1",
        "artifact_kind": "p06_evidence_closure_v2",
        "authority_bindings": authority_bindings_v2(),
        "run_id": run_id,
        "configuration_id": configuration_id,
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "input_bundle_sha256": input_bundle_sha256,
        "corpus_lock_bundle_sha256": corpus_lock_bundle_sha256,
        "calibration_run_ledger": dict(run_binding),
        "calibration_selection": dict(selection_binding),
        "selected_evaluation": dict(evaluation_binding),
        "gate_evidence": gate_rows,
        "component_closures": components,
        "compiler_lut_configuration_evidence": compiler_evidence,
        "preserved_failures": [],
        "artifact_manifest": dict(artifact_manifest_binding),
        "holdout_accessed": False,
        "status": "closed_before_p07",
        "data_access": {
            "development_accessed": True,
            "validation_accessed": True,
            "holdout_accessed": False,
            "release_locks_written": False,
        },
        "artifact_sha256": _ZERO_SHA256,
    }
    finalized = dict(finalize_artifact_sha256_v2(document))
    validate_schema(finalized, _EVIDENCE_CLOSURE_SCHEMA)
    return finalized


def _artifact_provenance(
    provenance: RunArtifactProvenanceV2,
) -> Mapping[str, Mapping[str, object]]:
    value = {
        "producer": provenance.producer,
        "command": provenance.command,
        "platform": provenance.platform,
        "gate_bindings": list(provenance.gate_ids),
    }
    return {identifier: dict(value) for identifier, _ in _RELEASE_ARTIFACTS_V3}


def _publish_release_v3(
    *,
    assembly: ProductionCalibrationAssembly,
    run_result: P06ProductionRunResultV2,
    source_gates: Tuple[SourceGateEvidenceV2, ...],
    provenance: RunArtifactProvenanceV2,
    repository_root: Path,
    calibration_run_root: Path,
    release_root: Path,
    native_cache_root: Path,
    open_split_root: Path,
    evidence_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    p04_quality_root: Path,
    transaction_id: str,
    locked_utc: str,
    bound_inputs: object,
    test_evidence_paths: Mapping[str, Path],
    preserved_failure_paths: Mapping[str, Path],
) -> Mapping[str, object]:
    del p04_quality_root
    if preserved_failure_paths or tuple(test_evidence_paths) != (
        "G04",
        "G05",
        "G06",
    ):
        raise ProductionReleaseV3Error(
            "V3 release publisher gate evidence handoff differs"
        )
    if (
        type(assembly) is not ProductionCalibrationAssembly
        or type(run_result) is not P06ProductionRunResultV2
        or type(provenance) is not RunArtifactProvenanceV2
        or bound_inputs is not assembly.adapter_factory.bound
        or tuple(gate.gate_id for gate in source_gates)
        != ("G04", "G05", "G06")
    ):
        raise ProductionReleaseV3Error("V3 production composition identity differs")
    bound_inputs.verify_unchanged()
    calibration = calibration_run_root.resolve(strict=True)
    release = release_root.resolve(strict=True)

    selection_binding = _copy_binding(
        source_root=calibration,
        release_root=release,
        binding={
            "path": run_result.selection_binding.path,
            "sha256": run_result.selection_binding.sha256,
            "size_bytes": run_result.selection_binding.size_bytes,
        },
        target_relative="calibration-selection-v2.json",
        label="calibration selection V2",
    )
    selection = _parse_json(
        _read_regular(
            release / "calibration-selection-v2.json",
            label="calibration selection V2",
        ),
        label="calibration selection V2",
    )
    selected = selection.get("selected")
    if type(selected) is not dict or type(selected.get("evaluation")) is not dict:
        raise ProductionReleaseV3Error("selected evaluation binding is absent")
    evaluation_binding = _copy_binding(
        source_root=calibration,
        release_root=release,
        binding=selected["evaluation"],
        label="selected evaluation V2",
    )
    evaluation = _parse_json(
        _read_regular(
            release / str(evaluation_binding["path"]),
            label="selected evaluation V2",
        ),
        label="selected evaluation V2",
    )
    if PurePosixPath(str(evaluation_binding["path"])).stem != evaluation_binding["sha256"]:
        raise ProductionReleaseV3Error(
            "selected evaluation is not addressed by its exact bytes"
        )
    run_binding = _copy_binding(
        source_root=calibration,
        release_root=release,
        binding={
            "path": run_result.run_ledger_binding.path,
            "sha256": run_result.run_ledger_binding.sha256,
            "size_bytes": run_result.run_ledger_binding.size_bytes,
        },
        target_relative="calibration-run-ledger-v2.json",
        label="calibration run ledger V2",
    )
    admission_binding = _copy_binding(
        source_root=calibration,
        release_root=release,
        binding=selection["validation_candidate_development_evidence"],
        target_relative="validation-candidate-development-evidence-v2.json",
        label="validation candidate development evidence V2",
    )
    del admission_binding
    _copy_binding(
        source_root=calibration,
        release_root=release,
        binding={
            "path": run_result.attempt_ledger_binding.path,
            "sha256": run_result.attempt_ledger_binding.sha256,
            "size_bytes": run_result.attempt_ledger_binding.size_bytes,
        },
        target_relative="attempts-v2.ndjson",
        label="calibration attempt ledger V2",
    )
    artifact_manifest_binding = _copy_binding(
        source_root=calibration,
        release_root=release,
        binding={
            "path": run_result.artifact_manifest_binding.path,
            "sha256": run_result.artifact_manifest_binding.sha256,
            "size_bytes": run_result.artifact_manifest_binding.size_bytes,
        },
        target_relative="artifact-manifest-v2.json",
        label="calibration artifact manifest V2",
    )

    control_binding = selection.get("selected_control_authorization_bundle")
    if type(control_binding) is not dict:
        raise ProductionReleaseV3Error(
            "selected control authorization bundle is absent"
        )
    _copy_binding(
        source_root=calibration,
        release_root=release,
        binding=control_binding,
        label="selected control authorization bundle",
    )
    control_bundle = _parse_json(
        _read_regular(
            calibration.joinpath(
                *PurePosixPath(
                    _safe_relative(control_binding["path"], label="control bundle")
                ).parts
            ),
            label="selected control authorization bundle",
        ),
        label="selected control authorization bundle",
    )
    _project_non_ash_release_artifacts(
        calibration_root=calibration,
        release_root=release,
        control_bundle=control_bundle,
    )
    for source_binding in evaluation.get("source_evidence_sha256_bindings", []):
        if type(source_binding) is not dict:
            raise ProductionReleaseV3Error("selected source evidence is invalid")
        _copy_binding(
            source_root=calibration,
            release_root=release,
            binding=source_binding,
            label="selected source evidence",
        )

    _copy_path(
        source=_BASELINE_BUDGET,
        release_root=release,
        relative="baseline-ablation-budget-v2.json",
        label="baseline ablation budget V2",
    )
    live = _require_live_holdout_preopen_v3(
        getattr(bound_inputs, "live_holdout_preopen_verification", None)
    )
    _write_new(
        release / "live-holdout-preopen-verification.json",
        canonical_json_file_bytes_v2(live),
    )

    physical_items = evaluation.get("physical_candidate_items")
    if type(physical_items) is not list:
        raise ProductionReleaseV3Error("selected physical candidate is absent")
    physical = {str(row[0]): row[1] for row in physical_items}
    materializer = SharedBankArtifactMaterializerV2(repository_root)
    logical = {
        name: physical[name] for name in materializer.plan.logical_parameter_order
    }
    compiled = assembly.adapter_factory.compile_candidate_configuration(logical)
    if type(compiled) is not NativeCompiledConfigurationV2:
        raise ProductionReleaseV3Error(
            "selected candidate did not compile as format 1.2"
        )
    compiler_payload = _read_regular(
        compiled.compiler_input_path,
        label="selected compiler input V2",
    )
    compiler_binding = evaluation.get("compiler_input")
    if (
        type(compiler_binding) is not dict
        or compiler_binding.get("file_sha256") != _sha256(compiler_payload)
        or evaluation.get("candidate_vector_sha256")
        != compiled.configuration.get("serialized_candidate_vector_sha256")
        or evaluation.get("shared_bank_configuration_sha256")
        != compiled.configuration.get("shared_bank_configuration_sha256")
    ):
        raise ProductionReleaseV3Error(
            "selected evaluation compiler or candidate identity differs"
        )
    _copy_path(
        source=compiled.mapping_path,
        release_root=release,
        relative="locked-mapping.json",
        label="exact selected candidate mapping",
    )
    _copy_path(
        source=compiled.operator_bank_path,
        release_root=release,
        relative="locked-operator-bank.json",
        label="exact selected candidate operator bank",
    )
    _write_new(release / "locked-compiler-input-v2.json", compiler_payload)
    route_bindings = evaluation.get("route_lut_bindings")
    if type(route_bindings) is not list or len(route_bindings) != 2:
        raise ProductionReleaseV3Error("selected route LUT bindings are absent")
    for row, runtime_route, filename in zip(
        route_bindings,
        ("direct-2x", "direct-3over2"),
        ("direct2x.ashlut", "direct3over2.ashlut"),
    ):
        source = compiled.route_paths[runtime_route]
        payload = _read_regular(source, label=f"selected {runtime_route} LUT")
        if (
            type(row) is not dict
            or row.get("route") != runtime_route
            or row.get("whole_file_sha256") != _sha256(payload)
        ):
            raise ProductionReleaseV3Error(
                f"selected evaluation LUT identity differs: {runtime_route}"
            )
        _write_new(release / filename, payload)
    _copy_path(
        source=compiled.runtime_manifest_path,
        release_root=release,
        relative="candidate-lut-runtime-manifest-v2.json",
        label="candidate runtime manifest V2",
    )
    _copy_path(
        source=assembly.adapter_factory.builder.executable.path,
        release_root=release,
        relative="bin/ash-calibration-cli",
        label="production Swift executable",
        executable=True,
    )
    _copy_path(
        source=assembly.adapter_factory.builder.executable.source_manifest_path,
        release_root=release,
        relative="sources/production-swift-source-manifest.json",
        label="production Swift source manifest",
    )

    metric_policy = compiled.configuration.get("candidate_artifacts", {}).get(
        "metric_policy"
    )
    if not isinstance(metric_policy, Mapping):
        raise ProductionReleaseV3Error("selected metric policy is absent")
    metric_payload = canonical_json_bytes(metric_policy)
    compiler = _parse_json(compiler_payload, label="selected compiler input V2")
    hashes = compiler.get("hash_bindings")
    if (
        type(hashes) is not dict
        or hashes.get("metric_policy_sha256") != _sha256(metric_payload)
    ):
        raise ProductionReleaseV3Error("selected metric policy identity differs")
    _write_new(release / "locked-metric-policy.json", metric_payload)
    quality = {
        "schema_version": "2.0.0",
        "artifact_kind": "p06_locked_quality_policy_v2",
        "status": "locked_before_p07",
        "run_id": selection["run_id"],
        "shared_bank_configuration_sha256": selection[
            "shared_bank_configuration_sha256"
        ],
        "selected_control_authorization_bundle": dict(control_binding),
        "control_selections": control_bundle["control_selections"],
        "holdout_accessed": False,
    }
    quality["manifest_sha256"] = canonical_sha256(quality)
    _write_new(
        release / "locked-quality-policy.json",
        canonical_json_file_bytes_v2(quality),
    )

    _native_parity_and_manifest(
        repository_root=repository_root,
        release_root=release,
        compiled=compiled,
    )
    configuration_lock = {
        "schema_version": "2.0.0",
        "artifact_kind": "p06_configuration_lock_v2",
        "status": "locked_before_p07",
        "locked_utc": locked_utc,
        "configuration_id": compiled.configuration["configuration_id"],
        "candidate_vector_sha256": evaluation["candidate_vector_sha256"],
        "shared_bank_configuration_sha256": evaluation[
            "shared_bank_configuration_sha256"
        ],
        "calibration_selection": selection_binding,
        "selected_evaluation": evaluation_binding,
        "configuration_files": [
            _file_binding(
                identifier,
                release / str(_FIXED_RELEASE_PATHS[identifier]),
                str(_FIXED_RELEASE_PATHS[identifier]),
            )
            for identifier in (
                "locked_mapping",
                "locked_operator_bank",
                "locked_quality_policy",
                "locked_metric_policy",
                "locked_compiler_input_v2",
                "direct2x_lut",
                "direct3over2_lut",
                "native_parity_manifest",
                "lut_manifest",
            )
        ],
        "candidate_bytes_rewritten_after_selection": False,
        "holdout_accessed": False,
    }
    configuration_lock["manifest_sha256"] = canonical_sha256(configuration_lock)
    _write_new(
        release / "configuration-lock-v2.json",
        canonical_json_file_bytes_v2(configuration_lock),
    )

    for gate in source_gates:
        source = calibration / gate.binding.path
        _copy_binding(
            source_root=calibration,
            release_root=release,
            binding={
                "path": gate.binding.path,
                "sha256": gate.binding.sha256,
                "size_bytes": gate.binding.size_bytes,
            },
            label=f"{gate.gate_id} semantic receipt",
        )
        if test_evidence_paths[gate.gate_id].resolve(strict=True) != source.resolve(
            strict=True
        ):
            raise ProductionReleaseV3Error(
                f"{gate.gate_id} transaction handoff path differs"
            )
    closure = _evidence_closure(
        release_root=release,
        run_id=str(selection["run_id"]),
        configuration_id=str(compiled.configuration["configuration_id"]),
        shared_bank_sha256=str(selection["shared_bank_configuration_sha256"]),
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        corpus_lock_bundle_sha256=str(hashes["corpus_lock_bundle_sha256"]),
        gate_evidence=source_gates,
        project_commit=provenance.project_commit,
        selection_binding=selection_binding,
        evaluation_binding=evaluation_binding,
        run_binding=run_binding,
        artifact_manifest_binding=artifact_manifest_binding,
    )
    _write_new(
        release / "p06-evidence-closure-v2.json",
        canonical_json_file_bytes_v2(closure),
    )

    support_roots = {
        "open_split": open_split_root,
        "calibration_evidence": evidence_root.parent,
        "native_cache": native_cache_root.parent,
        "production_writer": writer_root.parent,
        "dispatch_measurement": dispatch_measurement_root.parent,
        "calibration_run": calibration.parent,
    }
    support_paths = {
        "open_split": open_split_root / "quality-corpus-v1",
        "calibration_evidence": evidence_root,
        "native_cache": native_cache_root,
        "production_writer": writer_root,
        "dispatch_measurement": dispatch_measurement_root,
        "calibration_run": calibration,
    }
    authority = build_p07_execution_authority_v2(
        configuration_id=str(compiled.configuration["configuration_id"]),
        candidate_vector_sha256=str(evaluation["candidate_vector_sha256"]),
        shared_bank_configuration_sha256=str(
            evaluation["shared_bank_configuration_sha256"]
        ),
        calibration_plan_v2_file_sha256=str(
            bound_inputs.record("calibration_plan")["sha256"]
        ),
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        corpus_lock_bundle_sha256=str(hashes["corpus_lock_bundle_sha256"]),
        raw_output_contract_sha256=str(
            compiled.configuration["raw_output_contract_sha256"]
        ),
        release_root=release,
        repository_root=repository_root,
        candidate_runtime_manifest_path=(
            release / "candidate-lut-runtime-manifest-v2.json"
        ),
        native_executable_path=release / "bin/ash-calibration-cli",
        native_source_manifest_path=(
            release / "sources/production-swift-source-manifest.json"
        ),
        production_writer_executable_path=assembly.writer.executable_path,
        p00_executable_path=assembly.adapter_factory.p00_builder.executable.path,
        product_settings_source_path=assembly.writer.product_settings_source_path,
        support_evidence_roots=support_roots,
        support_evidence_paths=support_paths,
    )
    authority_binding = publish_p07_execution_authority_v2(
        release / "p07-production-execution-authority-v2.json",
        authority,
    )
    bound_inputs.verify_unchanged()
    bundle = build_p06_release_bundle_v3_manifest(
        release_root=release,
        output_path=release / "p06-release-bundle.json",
        configuration_id=str(compiled.configuration["configuration_id"]),
        locked_utc=locked_utc,
        shared_bank_configuration_sha256=str(
            selection["shared_bank_configuration_sha256"]
        ),
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        corpus_lock_bundle_sha256=str(hashes["corpus_lock_bundle_sha256"]),
        selected_evaluation_path=str(evaluation_binding["path"]),
        authorized_execution_bindings_sha256=str(authority_binding["sha256"]),
        artifact_provenance=_artifact_provenance(provenance),
        support_evidence_roots=support_roots,
        transaction_id=transaction_id,
    )
    bound_inputs.verify_unchanged()
    return bundle


def build_p06_release_transaction_v3(
    *,
    repository_root: Path,
    calibration_run_root: Path,
    release_root: Path,
    native_cache_root: Path,
    open_split_root: Path,
    evidence_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    locked_utc: str,
    bound_inputs: object,
    assembly: ProductionCalibrationAssembly,
    run_result: P06ProductionRunResultV2,
    source_gates: Tuple[SourceGateEvidenceV2, ...],
    provenance: RunArtifactProvenanceV2,
) -> Mapping[str, object]:
    """Use the hardened transaction shell with only the schema-3 publisher."""

    if not isinstance(locked_utc, str):
        raise ProductionReleaseV3Error("V3 release timestamp is invalid")
    try:
        parsed = datetime.fromisoformat(locked_utc.replace("Z", "+00:00"))
    except (TypeError, ValueError) as error:
        raise ProductionReleaseV3Error("V3 release timestamp is invalid") from error
    if (
        parsed.tzinfo is None
        or parsed.utcoffset() is None
        or parsed.utcoffset().total_seconds() != 0
        or not locked_utc.endswith("Z")
    ):
        raise ProductionReleaseV3Error("V3 release timestamp lacks UTC authority")
    gate_paths = {
        gate.gate_id: calibration_run_root / gate.binding.path
        for gate in source_gates
    }

    def publish_v3(**arguments: object) -> Mapping[str, object]:
        return _publish_release_v3(
            assembly=assembly,
            run_result=run_result,
            source_gates=source_gates,
            provenance=provenance,
            **arguments,
        )

    return build_p06_release_transaction(
        repository_root=repository_root,
        calibration_run_root=calibration_run_root,
        release_root=release_root,
        native_cache_root=native_cache_root,
        open_split_root=open_split_root,
        evidence_root=evidence_root,
        writer_root=writer_root,
        dispatch_measurement_root=dispatch_measurement_root,
        p04_quality_root=repository_root,
        locked_utc=locked_utc,
        bound_inputs=bound_inputs,
        test_evidence_paths=gate_paths,
        preserved_failure_paths={},
        _release_publisher=publish_v3,
    )


__all__ = [
    "ProductionReleaseV3Error",
    "build_p06_release_transaction_v3",
]
