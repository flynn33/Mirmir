from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2.corrective_diagnostics import (
    ANISOTROPY_CELLS,
    COMPOSITION_SPECS,
    COORDINATE_CELLS,
    RISK_THRESHOLD_BANDS,
    RISK_WEIGHT_PAIRS,
    ROUTES,
    ROUTE_BLOCK_SPECS,
    CorrectiveDiagnosticContractError,
    artifact_file_binding,
    canonical_artifact_file_bytes,
    contract_route_for_evaluator_route,
    coordinate_anisotropy_dimension_contract,
    evaluator_route_for_contract_route,
    risk_state_dimension_contract,
    validate_coordinate_anisotropy_artifact,
    validate_corrective_diagnostic_envelope,
    validate_risk_state_artifact,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def seal(document: dict, field: str) -> dict:
    document.pop(field, None)
    document[field] = canonical_sha256(document)
    return document


def rebind_sha256(route: str, original: str, serialized: str, applied: bool) -> str:
    payload = bytearray(
        b"MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0"
    )
    for value in (route, original, serialized):
        payload.extend(value.encode("utf-8"))
        payload.append(0)
    payload.append(1 if applied else 0)
    return hashlib.sha256(payload).hexdigest()


def metric_values(*, decoded: bool) -> dict:
    return {
        "y_psnr_db": 41.0,
        "cb_psnr_db": 42.0,
        "cr_psnr_db": 43.0,
        "y_ssim": 0.99,
        "cb_ssim": 0.98,
        "cr_ssim": 0.97,
        "y_ms_ssim": 0.96,
        "cb_ms_ssim": 0.95,
        "cr_ms_ssim": 0.94,
        "writer_y_psnr_contribution_db": 0.125 if decoded else None,
    }


def live_guard_fixture() -> dict:
    return {
        "verification_status": "pass",
        "access_status": "unopened",
        "access_count": 0,
        "open_intent_anchor_present": False,
        "pixel_content_included": False,
    }


def native_provenance_fixture() -> dict:
    return {
        "candidate_vector_sha256": digest("base-candidate"),
        "shared_bank_configuration_sha256": digest("shared-bank"),
        "mapping_sha256": digest("mapping"),
        "operator_bank_sha256": digest("operator-bank"),
        "metric_policy_sha256": digest("metric-policy"),
        "calibration_plan_sha256": digest("calibration-plan"),
        "corpus_lock_bundle_sha256": digest("corpus-lock"),
        "candidate_lut_runtime_manifest_sha256": digest(
            "candidate-lut-runtime"
        ),
    }


def original_output_manifest_fixture(
    native_record: dict,
) -> list[dict[str, object]]:
    request = native_record["request"]
    diagnostic = native_record["response"]["corrective_diagnostic"]
    frame = request["frame"]
    width = frame["output_width"]
    height = frame["output_height"]
    size_bytes = width * height + (width // 2) * (height // 2) * 2
    rows = [
        {
            "original_name": Path(descriptor["output_path"]).name,
            "sha256": cell["output_nv12_sha256"],
            "size_bytes": size_bytes,
        }
        for descriptor, cell in zip(
            request["output_descriptors"],
            diagnostic["cells"],
        )
    ]
    production = diagnostic["production_v2_reference"]
    rows.append(
        {
            "original_name": Path(
                request["production_v2_reference_output_path"]
            ).name,
            "sha256": production["output_nv12_sha256"],
            "size_bytes": size_bytes,
        }
    )
    rows.sort(key=lambda row: str(row["original_name"]))
    return rows


def completed_execution_evidence_fixture(
    native_records: list[dict],
) -> dict:
    work_root = f"/tmp/.mirmir-corrective-execution-{'0' * 32}"
    empty_sha256 = hashlib.sha256(b"").hexdigest()
    input_stubs = [
        {
            "name": f"{record['input_nv12_sha256']}.nv12",
            "device": 1,
            "inode": 1000 + ordinal,
            "size_bytes": 0,
            "sha256": empty_sha256,
        }
        for ordinal, record in enumerate(native_records)
    ]
    input_receipt = seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": (
                "p06_corrective_development_input_sanitation_receipt"
            ),
            "status": "sanitized_retained",
            "retained_directory_identity": {"device": 1, "inode": 900},
            "retained_stub_count": len(input_stubs),
            "retained_stubs": input_stubs,
            "retained_stub_manifest_sha256": canonical_sha256(input_stubs),
            "original_input_manifest_sha256": digest(
                "original-input-manifest"
            ),
        },
        "receipt_sha256",
    )
    native_receipts = []
    recursive_entries = [
        {"relative_path": "inputs", "entry_kind": "directory"},
        {"relative_path": "journal", "entry_kind": "directory"},
    ]
    recursive_entries.extend(
        {
            "relative_path": f"inputs/{row['name']}",
            "entry_kind": "regular_file",
            "size_bytes": 0,
            "file_sha256": empty_sha256,
        }
        for row in input_stubs
    )
    input_payload = canonical_artifact_file_bytes(input_receipt)
    recursive_entries.append(
        {
            "relative_path": "input-sanitation-receipt.json",
            "entry_kind": "regular_file",
            "size_bytes": len(input_payload),
            "file_sha256": hashlib.sha256(input_payload).hexdigest(),
        }
    )
    for receipt_ordinal in range(18):
        directory_name = f".mirmir-corrective-quarantine-{receipt_ordinal:02d}"
        original_output_manifest = original_output_manifest_fixture(
            native_records[receipt_ordinal]
        )
        retained_stubs = []
        recursive_entries.append(
            {"relative_path": directory_name, "entry_kind": "directory"}
        )
        for stub_ordinal, original_output in enumerate(
            original_output_manifest
        ):
            retained_name = (
                f".owned-sanitized-stub-{receipt_ordinal:02d}-{stub_ordinal:02d}"
            )
            retained_stubs.append(
                {
                    "original_name": original_output["original_name"],
                    "retained_name": retained_name,
                    "device": 1,
                    "inode": 2000 + receipt_ordinal * 17 + stub_ordinal,
                    "size_bytes": 0,
                    "sha256": empty_sha256,
                }
            )
            recursive_entries.append(
                {
                    "relative_path": f"{directory_name}/{retained_name}",
                    "entry_kind": "regular_file",
                    "size_bytes": 0,
                    "file_sha256": empty_sha256,
                }
            )
        native_receipts.append(
            {
                "status": "sanitized_retained",
                "retained_transaction_path": f"{work_root}/{directory_name}",
                "retained_transaction_identity": {
                    "device": 1,
                    "inode": 1500 + receipt_ordinal,
                },
                "retained_stub_count": 17,
                "retained_stubs": retained_stubs,
                "retained_stub_manifest_sha256": canonical_sha256(
                    retained_stubs
                ),
                "original_output_manifest_sha256": canonical_sha256(
                    original_output_manifest
                ),
            }
        )
    journal_entry_bindings = []
    previous_entry_sha256 = hashlib.sha256(
        b"MIRMIR-P06-CORRECTIVE-DIAGNOSTIC-JOURNAL-V1\0"
    ).hexdigest()
    for ordinal in range(36):
        entry_kind = "call-evidence" if ordinal % 2 == 0 else "output-cleanup"
        request_ordinal = ordinal // 2
        name = f"{ordinal:06d}-{entry_kind}.json"
        if entry_kind == "call-evidence":
            entry_sha256 = digest(f"journal-entry-self-{ordinal:02d}")
            file_sha256 = digest(f"journal-entry-{ordinal:02d}")
            size_bytes = 100 + ordinal
        else:
            cleanup_unsealed = {
                "schema_version": "1.0.0",
                "artifact_kind": (
                    "p06_corrective_diagnostic_call_journal_entry"
                ),
                "sequence_ordinal": ordinal,
                "request_ordinal": request_ordinal,
                "entry_kind": entry_kind,
                "previous_entry_sha256": previous_entry_sha256,
                "evidence": {
                    "native_record_sha256": native_records[
                        request_ordinal
                    ]["native_record_sha256"],
                    "output_cleanup_status": "sanitized_retained",
                    "native_cleanup_receipt": native_receipts[
                        request_ordinal
                    ],
                },
            }
            entry_sha256 = canonical_sha256(cleanup_unsealed)
            cleanup_document = {
                **cleanup_unsealed,
                "entry_sha256": entry_sha256,
            }
            cleanup_payload = canonical_artifact_file_bytes(
                cleanup_document
            )
            file_sha256 = hashlib.sha256(cleanup_payload).hexdigest()
            size_bytes = len(cleanup_payload)
        journal_entry_bindings.append(
            {
                "name": name,
                "sequence_ordinal": ordinal,
                "request_ordinal": request_ordinal,
                "entry_kind": entry_kind,
                "previous_entry_sha256": previous_entry_sha256,
                "entry_sha256": entry_sha256,
                "file_sha256": file_sha256,
                "size_bytes": size_bytes,
            }
        )
        recursive_entries.append(
            {
                "relative_path": f"journal/{name}",
                "entry_kind": "regular_file",
                "size_bytes": size_bytes,
                "file_sha256": file_sha256,
            }
        )
        previous_entry_sha256 = entry_sha256
    recursive_entries.sort(key=lambda row: str(row["relative_path"]))
    return seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_corrective_prepublication_execution_closure",
            "status": "sanitation_and_journal_closed_pending_publication",
            "work_root_path": work_root,
            "work_root_identity": {"device": 1, "inode": 800},
            "journal": {
                "entry_count": 36,
                "evidence_count": 18,
                "completed_call_count": 18,
                "tail_sha256": previous_entry_sha256,
            },
            "journal_entry_bindings": journal_entry_bindings,
            "journal_entry_binding_manifest_sha256": canonical_sha256(
                journal_entry_bindings
            ),
            "input_sanitation_receipt": input_receipt,
            "input_sanitation_receipt_file_sha256": hashlib.sha256(
                input_payload
            ).hexdigest(),
            "native_sanitation_receipt_count": 18,
            "native_retained_stub_count": 306,
            "native_sanitation_receipts": native_receipts,
            "native_sanitation_receipt_manifest_sha256": canonical_sha256(
                native_receipts
            ),
            "recursive_entry_count": len(recursive_entries),
            "recursive_entries": recursive_entries,
            "recursive_manifest_sha256": canonical_sha256(recursive_entries),
            "expected_executor_publication_receipt_name": (
                "executor-publication-receipt.json"
            ),
        },
        "prepublication_closure_sha256",
    )


def native_records_fixture() -> list[dict]:
    records = []
    configuration_id = f"ash-p06-{digest('configuration')[:24]}"
    for record_ordinal, route in enumerate(ROUTES):
        evaluator_route = evaluator_route_for_contract_route(route)
        entry_count = 4096 if route == "direct_2x" else 9216
        provenance = native_provenance_fixture()
        request_id = digest(f"native-request-id-{route}")
        descriptors = []
        cells = []
        for ordinal, coordinate in enumerate(COORDINATE_CELLS):
            for anisotropy_index, anisotropy in enumerate(ANISOTROPY_CELLS):
                cell_ordinal = ordinal * len(ANISOTROPY_CELLS) + anisotropy_index
                block_id = (
                    f"{route}-{coordinate['cell_id']}-{anisotropy['cell_id']}"
                )
                output_path = f"/tmp/mirmir-contract-{route}-{cell_ordinal}.nv12"
                descriptors.append(
                    {
                        "ordinal": cell_ordinal,
                        "coordinate_cell_id": coordinate["cell_id"],
                        "anisotropy_cell_id": anisotropy["cell_id"],
                        "output_path": output_path,
                    }
                )

                def plane(channel: str, policy: str, strength: int) -> dict:
                    sample_count = 4
                    return {
                        "coordinate_policy": policy,
                        "anisotropy_strength_q12": strength,
                        "sample_count": sample_count,
                        "output_plane_sha256": digest(
                            f"output-plane-{block_id}-{channel}"
                        ),
                        "normalized_plane_sha256": digest(
                            f"normalized-plane-{block_id}-{channel}"
                        ),
                        "source_aligned_entry_flag_sample_count": 0,
                        "source_aligned_sample_preservation_count": (
                            sample_count
                            if policy == "source_aligned_rational"
                            else 0
                        ),
                        "numerical_fallback_count": 0,
                    }

                cells.append(
                    {
                        "ordinal": cell_ordinal,
                        "block_id": block_id,
                        "coordinate_cell_id": coordinate["cell_id"],
                        "anisotropy_cell_id": anisotropy["cell_id"],
                        "output_path": output_path,
                        "output_nv12_sha256": digest(f"output-nv12-{block_id}"),
                        "output_frame_sha256": digest(
                            f"output-frame-{block_id}"
                        ),
                        "planes": {
                            "y": plane(
                                "y",
                                coordinate["luma_coordinate_policy"],
                                anisotropy["luma_anisotropy_strength_q12"],
                            ),
                            "cb": plane(
                                "cb",
                                coordinate["chroma_coordinate_policy"],
                                anisotropy["chroma_anisotropy_strength_q12"],
                            ),
                            "cr": plane(
                                "cr",
                                coordinate["chroma_coordinate_policy"],
                                anisotropy["chroma_anisotropy_strength_q12"],
                            ),
                        },
                    }
                )
        production_path = f"/tmp/mirmir-contract-production-{route}.nv12"
        request = {
            "schema_version": "1.0.0",
            "operation": "diagnose_corrective_frame",
            "configuration_id": configuration_id,
            "compiler_inputs_sha256": digest("compiler-inputs"),
            "coordinate_model_contract_path": "/tmp/coordinate-contract.json",
            "coordinate_model_contract_sha256": digest("coordinate-contract"),
            "analysis_grid_source_step": 2,
            "output_descriptors": descriptors,
            "production_v2_reference_output_path": production_path,
            "frame": {
                "request_id": request_id,
                "route": evaluator_route,
                "input_path": f"/tmp/{digest(f'input-nv12-{route}')}.nv12",
                "input_sha256": digest(f"input-nv12-{route}"),
                "input_width": 2 if route == "direct_2x" else 4,
                "input_height": 2 if route == "direct_2x" else 4,
                "output_path": production_path,
                "output_width": 4 if route == "direct_2x" else 6,
                "output_height": 4 if route == "direct_2x" else 6,
                "pixel_format": "420v",
                "matrix": "BT.709",
                "range": "video",
                "chroma_siting": "left",
            },
        }
        risk_cells = []
        for ordinal in range(30):
            weight_index = ordinal // len(RISK_THRESHOLD_BANDS)
            band_index = ordinal % len(RISK_THRESHOLD_BANDS)
            risk_cells.append(
                {
                    "ordinal": ordinal,
                    "cell_id": f"weight-{weight_index:02d}-band-{band_index:02d}",
                    "risk_weight_pair": dict(RISK_WEIGHT_PAIRS[weight_index]),
                    "risk_threshold_band": dict(RISK_THRESHOLD_BANDS[band_index]),
                    "risk_zero_count": 2,
                    "risk_one_count": 2,
                    "risk_proxy_minimum_unorm15": ordinal,
                    "risk_proxy_maximum_unorm15": ordinal + 1,
                    "risk_proxy_value_count": 4,
                    "risk_proxy_vector_sha256": digest(
                        f"risk-vector-{route}-{ordinal}"
                    ),
                }
            )
        diagnostic = {
            "schema_version": "1.0.0",
            "status": "development_diagnostic_no_selection",
            "split": "development",
            "validation_accessed": False,
            "holdout_accessed": False,
            "selected_winner": None,
            "request_id": request_id,
            "target_route": route,
            "configuration_id": configuration_id,
            "compiler_inputs_sha256": digest("compiler-inputs"),
            **provenance,
            "native_invocation_proof": {
                "protocol": "serve-candidate/diagnose_corrective_frame-v1",
                "process_id": 4242,
                "executable_sha256": digest("native-executable"),
                "source_manifest_sha256": digest("native-sources"),
            },
            "input_sha256": request["frame"]["input_sha256"],
            "coordinate_model_contract_file_sha256": digest(
                "coordinate-contract"
            ),
            "coordinate_oracle_matrix_sha256": digest(
                "coordinate-oracles"
            ),
            "coordinate_experiment_dimensions_sha256": digest(
                "coordinate-dimensions"
            ),
            "analysis_grid_source_step": 2,
            "analysis_cell_count": 4,
            "output_plane_hash_contract": "active-nv12-code-bytes-sha256-v1",
            "normalized_plane_hash_contract": (
                "mirmir-ash-normalized-plane-f64-be-v1"
            ),
            "analysis_grid_hash_contract": "mirmir-ash-analysis-grid-v3-be-v1",
            "analysis_grid_sha256": digest(f"analysis-grid-{route}"),
            "generic_lut": {
                "whole_file_sha256": digest(f"generic-lut-file-{route}"),
                "payload_sha256": digest(f"generic-lut-payload-{route}"),
                "entry_count": entry_count,
                "parameter_count": 1,
                "header_crc32": "0x00000000",
                "payload_crc32": "0x00000000",
                "offline_path_evaluation_count": entry_count * 81,
                "runtime_tree_generation_count": 0,
                "maximum_operator_evaluations": 2,
                "serialization_rebind_contract": (
                    "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
                ),
                "original_coordinate_policy": "source_aligned_rational",
                "serialized_coordinate_policy": "half_pixel_center",
                "serialization_rebind_applied": True,
                "serialization_rebind_sha256": rebind_sha256(
                    route,
                    "source_aligned_rational",
                    "half_pixel_center",
                    True,
                ),
            },
            "session_counters": {
                "input_decode_count": 1,
                "analysis_grid_build_count": 1,
                "generic_compile_count_for_route": 1,
                "generic_dispatch_count": 1,
                "plane_diagnostic_count": 4,
                "risk_diagnostic_count": 1,
                "production_v2_dispatch_count": 1,
                "output_write_count": 17,
                "output_reopen_count": 17,
            },
            "production_v2_reference": {
                "output_path": production_path,
                "output_nv12_sha256": digest(
                    f"production-v2-output-nv12-{route}"
                ),
                "output_frame_sha256": digest(
                    f"production-v2-output-frame-{route}"
                ),
                "planes": {
                    channel: {
                        "output_plane_sha256": digest(
                            f"production-v2-output-plane-{route}-{channel}"
                        ),
                        "normalized_plane_sha256": digest(
                            f"production-v2-normalized-plane-{route}-{channel}"
                        ),
                    }
                    for channel in ("y", "cb", "cr")
                },
                "lut_whole_file_sha256": digest(
                    f"production-lut-file-{route}"
                ),
                "lut_payload_sha256": digest(
                    f"production-lut-payload-{route}"
                ),
                "lut_entry_count": entry_count,
            },
            "cells": cells,
            "risk_state": {
                "analysis_grid_source_step": 2,
                "analysis_cell_count": 4,
                "baseline_analysis_grid_sha256": digest(f"risk-grid-{route}"),
                "cells": risk_cells,
            },
        }
        response = {
            "schema_version": "1.0.0",
            "status": "ok",
            "request_sha256": canonical_sha256(request),
            "corrective_diagnostic": diagnostic,
        }
        records.append(
            seal(
                {
                    "ordinal": record_ordinal,
                    "source_asset_id": "synthetic-contract-fixture",
                    "degradation_profile_id": "synthetic-degradation-profile",
                    "target_route": route,
                    "input_frame_sha256": digest(f"input-frame-{route}"),
                    "input_nv12_sha256": request["frame"]["input_sha256"],
                    "request": request,
                    "response": response,
                    "request_sha256": canonical_sha256(request),
                    "response_sha256": canonical_sha256(response),
                    "native_diagnostic_sha256": canonical_sha256(diagnostic),
                },
                "native_record_sha256",
            )
        )
    expanded = []
    for base in records:
        route = str(base["target_route"])
        count = 12 if route == "direct_2x" else 6
        for route_ordinal in range(count):
            request = copy.deepcopy(base["request"])
            response = copy.deepcopy(base["response"])
            request_id = digest(
                f"native-request-id-{route}-{route_ordinal:02d}"
            )
            request["frame"]["request_id"] = request_id
            input_nv12_sha256 = digest(
                f"input-nv12-{route}-{route_ordinal:02d}"
            )
            request["frame"]["input_sha256"] = input_nv12_sha256
            request["frame"]["input_path"] = (
                f"/tmp/{input_nv12_sha256}.nv12"
            )
            diagnostic = response["corrective_diagnostic"]
            diagnostic["request_id"] = request_id
            diagnostic["input_sha256"] = input_nv12_sha256
            response["request_sha256"] = canonical_sha256(request)
            source_id = f"synthetic-{route}-source-{route_ordinal:02d}"
            profile_id = f"synthetic-{route}-profile-{route_ordinal % 3:02d}"
            input_frame_hash = digest(
                f"input-frame-{route}-{route_ordinal:02d}"
            )
            expanded.append(
                seal(
                    {
                        "ordinal": len(expanded),
                        "source_asset_id": source_id,
                        "degradation_profile_id": profile_id,
                        "target_route": route,
                        "input_frame_sha256": input_frame_hash,
                        "input_nv12_sha256": input_nv12_sha256,
                        "request": request,
                        "response": response,
                        "request_sha256": canonical_sha256(request),
                        "response_sha256": canonical_sha256(response),
                        "native_diagnostic_sha256": canonical_sha256(
                            diagnostic
                        ),
                    },
                    "native_record_sha256",
                )
            )
    return expanded


def reseal_coordinate_native_record(document: dict, ordinal: int) -> None:
    """Rebind every coordinate-artifact reference after native-record mutation."""

    record = document["native_records"][ordinal]
    old_hash = record["native_record_sha256"]
    request = record["request"]
    response = record["response"]
    response["request_sha256"] = canonical_sha256(request)
    diagnostic = response["corrective_diagnostic"]
    record["request_sha256"] = canonical_sha256(request)
    record["response_sha256"] = canonical_sha256(response)
    record["native_diagnostic_sha256"] = canonical_sha256(diagnostic)
    seal(record, "native_record_sha256")
    new_hash = record["native_record_sha256"]
    for block in document["route_cell_blocks"]:
        changed = False
        for observation in block["observations"]:
            if observation["native_record_sha256"] == old_hash:
                observation["native_record_sha256"] = new_hash
                seal(observation, "observation_sha256")
                changed = True
        if changed:
            block["native_execution_sha256"] = canonical_sha256(
                [
                    observation["native_record_sha256"]
                    for observation in block["observations"]
                ]
            )
            seal(block, "block_sha256")
    reference = document["production_v2_reference"]
    for observation in reference["observations"]:
        if observation["native_record_sha256"] == old_hash:
            observation["native_record_sha256"] = new_hash
            seal(observation, "observation_sha256")
    reference["reference_evaluation_sha256"] = canonical_sha256(
        reference["observations"]
    )
    seal(document, "artifact_sha256")


def coordinate_fixture() -> dict:
    native_records = native_records_fixture()
    live_guard = live_guard_fixture()
    native_records_by_route = {
        route: [row for row in native_records if row["target_route"] == route]
        for route in ROUTES
    }
    native_record_hash_by_route = {
        route: rows[0]["native_record_sha256"]
        for route, rows in native_records_by_route.items()
    }
    coordinate_by_id = {row["cell_id"]: row for row in COORDINATE_CELLS}
    anisotropy_by_id = {row["cell_id"]: row for row in ANISOTROPY_CELLS}
    route_luts = []
    for index, route in enumerate(ROUTES):
        original = "source_aligned_rational"
        serialized = "half_pixel_center"
        route_luts.append(
            {
                "route": route,
                "whole_file_sha256": digest(f"generic-lut-file-{route}"),
                "payload_sha256": digest(f"generic-lut-payload-{route}"),
                "entry_count": 4096 if route == "direct_2x" else 9216,
                "serialization_rebind_contract": (
                    "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
                ),
                "original_coordinate_policy": original,
                "serialized_coordinate_policy": serialized,
                "serialization_rebind_applied": True,
                "serialization_rebind_sha256": rebind_sha256(
                    route,
                    original,
                    serialized,
                    True,
                ),
            }
        )
    input_bindings = {
        "base_candidate_vector_sha256": digest("base-candidate"),
        "base_adapter_configuration_sha256": digest("base-adapter"),
        "compiler_inputs_sha256": digest("compiler-inputs"),
        "native_configuration_provenance": native_provenance_fixture(),
        "mapping_sha256": digest("mapping"),
        "coordinate_model_contract_file_sha256": digest("coordinate-contract"),
        "coordinate_oracle_matrix_sha256": digest("coordinate-oracles"),
        "coordinate_experiment_dimensions_sha256": digest("coordinate-dimensions"),
        "video_profile_contract_file_sha256": digest("video-contract-file"),
        "video_profile_contract_sha256": digest("video-contract"),
        "quality_harness_implementation_manifest_file_sha256": digest(
            "quality-implementation-file"
        ),
        "quality_harness_implementation_manifest_sha256": digest(
            "quality-implementation"
        ),
        "g04_lock_file_sha256": digest("g04-lock"),
        "g05_lock_file_sha256": digest("g05-lock"),
        "corrective_preregistration_file_sha256": digest(
            "corrective-preregistration-file"
        ),
        "corrective_preregistration_sha256": digest(
            "corrective-preregistration"
        ),
        "generic_phase_compiler_source_sha256": digest("generic-compiler-source"),
        "generic_phase_compilation_manifest_sha256": canonical_sha256(route_luts),
        "native_executable_sha256": digest("native-executable"),
        "native_source_manifest_sha256": digest("native-sources"),
        "development_sample_lock_file_sha256": digest("development-sample-lock-file"),
        "development_sample_lock_manifest_sha256": digest("development-sample-lock-manifest"),
        "expected_observation_count_by_route": {
            "direct_2x": 12,
            "direct_3_over_2": 6,
        },
        "development_sample_dimension_sha256": digest(
            "development-sample-dimension"
        ),
        "degradation_profile_dimension_sha256": digest(
            "degradation-profile-dimension"
        ),
        "corpus_lock_bundle_sha256": digest("corpus-lock"),
        "live_holdout_preopen_verification": live_guard,
        "live_holdout_preopen_verification_sha256": canonical_sha256(
            live_guard
        ),
        "degradation_policy_sha256": digest("degradation-policy"),
        "metric_policy_sha256": digest("metric-policy"),
        "writer_settings_sha256": digest("writer-settings"),
        "output_plane_hash_contract": "active-nv12-code-bytes-sha256-v1",
        "normalized_plane_hash_contract": "mirmir-ash-normalized-plane-f64-be-v1",
        "analysis_grid_hash_contract": "mirmir-ash-analysis-grid-v3-be-v1",
        "generic_route_luts": route_luts,
        "completed_execution_evidence": completed_execution_evidence_fixture(
            native_records
        ),
    }
    lut_by_route = {row["route"]: row for row in route_luts}
    blocks = []
    for ordinal, (route, coordinate_id, anisotropy_id) in enumerate(ROUTE_BLOCK_SPECS):
        block_id = f"{route}-{coordinate_id}-{anisotropy_id}"
        coordinate = coordinate_by_id[coordinate_id]
        anisotropy = anisotropy_by_id[anisotropy_id]
        input_frame_sha256 = digest(f"input-frame-{route}")
        output_frame_sha256 = digest(f"output-frame-{block_id}")

        def plane(channel: str, policy: str, strength: int) -> dict:
            sample_count = 4
            return seal(
                {
                    "coordinate_policy": policy,
                    "anisotropy_strength_q12": strength,
                    "sample_count": sample_count,
                    "output_plane_sha256": digest(f"output-plane-{block_id}-{channel}"),
                    "normalized_plane_sha256": digest(
                        f"normalized-plane-{block_id}-{channel}"
                    ),
                    "source_aligned_entry_flag_sample_count": 0,
                    "source_aligned_sample_preservation_count": (
                        sample_count if policy == "source_aligned_rational" else 0
                    ),
                    "numerical_fallback_count": 0,
                },
                "plane_evidence_sha256",
            )

        planes = {
            "y": plane(
                "y",
                coordinate["luma_coordinate_policy"],
                anisotropy["luma_anisotropy_strength_q12"],
            ),
            "cb": plane(
                "cb",
                coordinate["chroma_coordinate_policy"],
                anisotropy["chroma_anisotropy_strength_q12"],
            ),
            "cr": plane(
                "cr",
                coordinate["chroma_coordinate_policy"],
                anisotropy["chroma_anisotropy_strength_q12"],
            ),
        }
        rows = []
        for decoded in (False, True):
            domain = "container_decoded" if decoded else "engine_raw"
            rows.append(
                seal(
                    {
                        "block_id": block_id,
                        "target_route": route,
                        "input_frame_sha256": input_frame_sha256,
                        "comparison_domain": domain,
                        "candidate_output_frame_sha256": (
                            digest(f"decoded-output-{block_id}")
                            if decoded
                            else output_frame_sha256
                        ),
                        "writer_evidence_sha256": (
                            digest(f"writer-evidence-{block_id}") if decoded else None
                        ),
                        "metrics": metric_values(decoded=decoded),
                    },
                    "metric_row_sha256",
                )
            )
        observation = seal(
            {
                "block_id": block_id,
                "target_route": route,
                "source_asset_id": "synthetic-contract-fixture",
                "source_family_id": "synthetic-contract-family",
                "categories": ["contract-test"],
                "degradation_profile_id": "synthetic-degradation-profile",
                "degradation_profile_sha256": digest("synthetic-degradation-profile"),
                "input_frame_sha256": input_frame_sha256,
                "candidate_output_nv12_sha256": digest(f"output-nv12-{block_id}"),
                "candidate_output_frame_sha256": output_frame_sha256,
                "planes": planes,
                "metric_rows": rows,
                "native_record_sha256": native_record_hash_by_route[route],
            },
            "observation_sha256",
        )
        observations = []
        for native_record in native_records_by_route[route]:
            expanded_observation = copy.deepcopy(observation)
            expanded_observation["source_asset_id"] = native_record[
                "source_asset_id"
            ]
            expanded_observation["source_family_id"] = (
                f"family-{native_record['source_asset_id']}"
            )
            expanded_observation["degradation_profile_id"] = native_record[
                "degradation_profile_id"
            ]
            expanded_observation["degradation_profile_sha256"] = digest(
                str(native_record["degradation_profile_id"])
            )
            expanded_observation["input_frame_sha256"] = native_record[
                "input_frame_sha256"
            ]
            expanded_observation["native_record_sha256"] = native_record[
                "native_record_sha256"
            ]
            for metric_row in expanded_observation["metric_rows"]:
                metric_row["input_frame_sha256"] = native_record[
                    "input_frame_sha256"
                ]
                seal(metric_row, "metric_row_sha256")
            seal(expanded_observation, "observation_sha256")
            observations.append(expanded_observation)
        blocks.append(
            seal(
                {
                    "ordinal": ordinal,
                    "block_id": block_id,
                    "target_route": route,
                    "coordinate_cell_id": coordinate_id,
                    "anisotropy_cell_id": anisotropy_id,
                    "generic_lut_whole_file_sha256": lut_by_route[route][
                        "whole_file_sha256"
                    ],
                    "generic_lut_payload_sha256": lut_by_route[route]["payload_sha256"],
                    "native_execution_sha256": canonical_sha256(
                        [
                            row["native_record_sha256"]
                            for row in observations
                        ]
                    ),
                    "observations": observations,
                },
                "block_sha256",
            )
        )
    block_by_id = {row["block_id"]: row for row in blocks}
    compositions = []
    for ordinal, (composition_id, direct2_id, direct3_id) in enumerate(COMPOSITION_SPECS):
        compositions.append(
            seal(
                {
                    "ordinal": ordinal,
                    "composition_id": composition_id,
                    "direct_2x_block_id": direct2_id,
                    "direct_2x_block_sha256": block_by_id[direct2_id]["block_sha256"],
                    "direct_3_over_2_block_id": direct3_id,
                    "direct_3_over_2_block_sha256": block_by_id[direct3_id]["block_sha256"],
                },
                "composition_sha256",
            )
        )
    production_route_luts = [
        {
            "route": route,
            "whole_file_sha256": digest(f"production-v2-lut-file-{route}"),
            "payload_sha256": digest(f"production-v2-lut-payload-{route}"),
            "entry_count": 4096 if route == "direct_2x" else 9216,
        }
        for index, route in enumerate(ROUTES)
    ]
    reference_observations = []
    for route in ROUTES:
        template = next(
            block["observations"][0]
            for block in blocks
            if block["target_route"] == route
        )
        output_frame_sha256 = digest(f"production-v2-output-frame-{route}")
        rows = []
        for decoded in (False, True):
            rows.append(
                seal(
                    {
                        "target_route": route,
                        "input_frame_sha256": template["input_frame_sha256"],
                        "comparison_domain": (
                            "container_decoded" if decoded else "engine_raw"
                        ),
                        "candidate_output_frame_sha256": (
                            digest(f"production-v2-decoded-frame-{route}")
                            if decoded
                            else output_frame_sha256
                        ),
                        "writer_evidence_sha256": (
                            digest(f"production-v2-writer-{route}")
                            if decoded
                            else None
                        ),
                        "metrics": metric_values(decoded=decoded),
                    },
                    "metric_row_sha256",
                )
            )
        reference_observations.append(
            seal(
                {
                    "target_route": route,
                    "source_asset_id": template["source_asset_id"],
                    "source_family_id": template["source_family_id"],
                    "categories": template["categories"],
                    "degradation_profile_id": template[
                        "degradation_profile_id"
                    ],
                    "degradation_profile_sha256": template[
                        "degradation_profile_sha256"
                    ],
                    "input_frame_sha256": template["input_frame_sha256"],
                    "candidate_output_nv12_sha256": digest(
                        f"production-v2-output-nv12-{route}"
                    ),
                    "candidate_output_frame_sha256": output_frame_sha256,
                    "planes": {
                        channel: {
                            "output_plane_sha256": digest(
                                f"production-v2-output-plane-{route}-{channel}"
                            ),
                            "normalized_plane_sha256": digest(
                                f"production-v2-normalized-plane-{route}-{channel}"
                            ),
                        }
                        for channel in ("y", "cb", "cr")
                    },
                    "metric_rows": rows,
                    "native_record_sha256": native_record_hash_by_route[route],
                },
                "observation_sha256",
            )
        )
    expanded_reference_observations = []
    for template in reference_observations:
        route = str(template["target_route"])
        for native_record in native_records_by_route[route]:
            observation = copy.deepcopy(template)
            observation["source_asset_id"] = native_record["source_asset_id"]
            observation["source_family_id"] = (
                f"family-{native_record['source_asset_id']}"
            )
            observation["degradation_profile_id"] = native_record[
                "degradation_profile_id"
            ]
            observation["degradation_profile_sha256"] = digest(
                str(native_record["degradation_profile_id"])
            )
            observation["input_frame_sha256"] = native_record[
                "input_frame_sha256"
            ]
            observation["native_record_sha256"] = native_record[
                "native_record_sha256"
            ]
            for metric_row in observation["metric_rows"]:
                metric_row["input_frame_sha256"] = native_record[
                    "input_frame_sha256"
                ]
                seal(metric_row, "metric_row_sha256")
            seal(observation, "observation_sha256")
            expanded_reference_observations.append(observation)
    reference_observations = expanded_reference_observations
    reference_manifest = {
        "candidate_vector_sha256": input_bindings[
            "base_candidate_vector_sha256"
        ],
        "adapter_configuration_sha256": input_bindings[
            "base_adapter_configuration_sha256"
        ],
        "compiler_inputs_sha256": input_bindings["compiler_inputs_sha256"],
        "route_luts": production_route_luts,
    }
    reference_output_manifest = [
        {
            "target_route": row["target_route"],
            "source_asset_id": row["source_asset_id"],
            "degradation_profile_id": row["degradation_profile_id"],
            "input_frame_sha256": row["input_frame_sha256"],
            "candidate_output_nv12_sha256": row[
                "candidate_output_nv12_sha256"
            ],
            "candidate_output_frame_sha256": row[
                "candidate_output_frame_sha256"
            ],
            "planes": row["planes"],
        }
        for row in reference_observations
    ]
    return seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_open_development_coordinate_anisotropy_diagnostic",
            "status": "development_diagnostic_no_selection",
            "split": "development",
            "validation_accessed": False,
            "holdout_accessed": False,
            "selected_winner": None,
            "input_bindings": input_bindings,
            "dimension_contract": coordinate_anisotropy_dimension_contract(),
            "native_records": native_records,
            "production_v2_reference": {
                "reference_manifest_sha256": canonical_sha256(
                    reference_manifest
                ),
                "candidate_vector_sha256": input_bindings["base_candidate_vector_sha256"],
                "adapter_configuration_sha256": input_bindings[
                    "base_adapter_configuration_sha256"
                ],
                "compiler_inputs_sha256": input_bindings["compiler_inputs_sha256"],
                "reference_evaluation_sha256": canonical_sha256(
                    reference_observations
                ),
                "reference_output_manifest_sha256": canonical_sha256(
                    reference_output_manifest
                ),
                "route_luts": production_route_luts,
                "observations": reference_observations,
            },
            "route_cell_blocks": blocks,
            "full_corpus_compositions": compositions,
        },
        "artifact_sha256",
    )


def risk_fixture() -> dict:
    native_records = native_records_fixture()
    live_guard = live_guard_fixture()
    records = []
    for record_ordinal, native_record in enumerate(native_records):
        route = str(native_record["target_route"])
        cells = []
        for ordinal in range(30):
            weight_index = ordinal // len(RISK_THRESHOLD_BANDS)
            band_index = ordinal % len(RISK_THRESHOLD_BANDS)
            cells.append(
                seal(
                    {
                        "ordinal": ordinal,
                        "cell_id": f"weight-{weight_index:02d}-band-{band_index:02d}",
                        "risk_weight_pair": dict(RISK_WEIGHT_PAIRS[weight_index]),
                        "risk_threshold_band": dict(RISK_THRESHOLD_BANDS[band_index]),
                        "risk_zero_count": 2,
                        "risk_one_count": 2,
                        "risk_proxy_minimum_unorm15": ordinal,
                        "risk_proxy_maximum_unorm15": ordinal + 1,
                        "risk_proxy_value_count": 4,
                        "risk_proxy_vector_sha256": digest(
                            f"risk-vector-{route}-{ordinal}"
                        ),
                    },
                    "cell_sha256",
                )
            )
        records.append(
            seal(
                {
                    "ordinal": record_ordinal,
                    "source_asset_id": native_record["source_asset_id"],
                    "degradation_profile_id": native_record[
                        "degradation_profile_id"
                    ],
                    "degradation_profile_sha256": digest(
                        str(native_record["degradation_profile_id"])
                    ),
                    "target_route": route,
                    "input_frame_sha256": native_record[
                        "input_frame_sha256"
                    ],
                    "analysis_grid_source_step": 2,
                    "analysis_cell_count": 4,
                    "baseline_analysis_grid_sha256": digest(f"risk-grid-{route}"),
                    "native_execution_sha256": native_record[
                        "native_record_sha256"
                    ],
                    "cells": cells,
                },
                "frame_route_record_sha256",
            )
        )
    return seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_open_development_risk_state_diagnostic",
            "status": "development_diagnostic_no_selection",
            "split": "development",
            "validation_accessed": False,
            "holdout_accessed": False,
            "selected_winner": None,
            "input_bindings": {
                "base_candidate_vector_sha256": digest("base-candidate"),
                "base_adapter_configuration_sha256": digest("base-adapter"),
                "compiler_inputs_sha256": digest("compiler-inputs"),
                "native_configuration_provenance": native_provenance_fixture(),
                "mapping_sha256": digest("mapping"),
                "risk_state_diagnostic_source_sha256": digest("risk-source"),
                "coordinate_model_contract_file_sha256": digest(
                    "coordinate-contract"
                ),
                "coordinate_oracle_matrix_sha256": digest(
                    "coordinate-oracles"
                ),
                "coordinate_experiment_dimensions_sha256": digest(
                    "coordinate-dimensions"
                ),
                "video_profile_contract_file_sha256": digest(
                    "video-contract-file"
                ),
                "video_profile_contract_sha256": digest("video-contract"),
                "quality_harness_implementation_manifest_file_sha256": digest(
                    "quality-implementation-file"
                ),
                "quality_harness_implementation_manifest_sha256": digest(
                    "quality-implementation"
                ),
                "g04_lock_file_sha256": digest("g04-lock"),
                "g05_lock_file_sha256": digest("g05-lock"),
                "corrective_preregistration_file_sha256": digest(
                    "corrective-preregistration-file"
                ),
                "corrective_preregistration_sha256": digest(
                    "corrective-preregistration"
                ),
                "native_executable_sha256": digest("native-executable"),
                "native_source_manifest_sha256": digest("native-sources"),
                "development_sample_lock_file_sha256": digest(
                    "development-sample-lock-file"
                ),
                "development_sample_lock_manifest_sha256": digest(
                    "development-sample-lock-manifest"
                ),
                "expected_observation_count_by_route": {
                    "direct_2x": 12,
                    "direct_3_over_2": 6,
                },
                "development_sample_dimension_sha256": digest(
                    "development-sample-dimension"
                ),
                "degradation_profile_dimension_sha256": digest(
                    "degradation-profile-dimension"
                ),
                "corpus_lock_bundle_sha256": digest("corpus-lock"),
                "live_holdout_preopen_verification": live_guard,
                "live_holdout_preopen_verification_sha256": canonical_sha256(
                    live_guard
                ),
                "degradation_policy_sha256": digest("degradation-policy"),
                "analysis_grid_hash_contract": (
                    "mirmir-ash-analysis-grid-v3-be-v1"
                ),
                "completed_execution_evidence": (
                    completed_execution_evidence_fixture(native_records)
                ),
            },
            "dimension_contract": risk_state_dimension_contract(),
            "native_records": native_records,
            "frame_route_records": records,
        },
        "artifact_sha256",
    )


def envelope_fixture(coordinate: dict, risk: dict) -> dict:
    return seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_open_development_corrective_diagnostic_envelope",
            "status": "development_diagnostic_no_selection",
            "split": "development",
            "validation_accessed": False,
            "holdout_accessed": False,
            "selected_winner": None,
            "coordinate_anisotropy_artifact": artifact_file_binding(coordinate),
            "risk_state_artifact": artifact_file_binding(risk),
        },
        "envelope_sha256",
    )


class CorrectiveDiagnosticContractTests(unittest.TestCase):
    def test_generic_route_lut_schema_accepts_legacy_or_split_policy_provenance(self):
        schema_path = (
            Path(__file__).resolve().parents[1]
            / "schemas/coordinate-anisotropy-diagnostic-v1.schema.json"
        )
        root_schema = json.loads(schema_path.read_text(encoding="utf-8"))
        wrapper = {
            "$schema": root_schema["$schema"],
            "$defs": root_schema["$defs"],
            "$ref": "#/$defs/diagnosticGenericRouteLUT",
        }
        validator = Draft202012Validator(wrapper)
        common = {
            "route": "direct_2x",
            "whole_file_sha256": digest("generic-file"),
            "payload_sha256": digest("generic-payload"),
            "entry_count": 4096,
            "serialization_rebind_contract": (
                "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
            ),
            "serialization_rebind_applied": True,
            "serialization_rebind_sha256": digest("rebind"),
        }
        legacy = {
            **common,
            "original_coordinate_policy": "source_aligned_rational",
            "serialized_coordinate_policy": "half_pixel_center",
        }
        split = {
            **common,
            "original_luma_coordinate_policy": "source_aligned_rational",
            "original_chroma_coordinate_policy": "half_pixel_center",
            "serialized_luma_coordinate_policy": "half_pixel_center",
            "serialized_chroma_coordinate_policy": "half_pixel_center",
        }
        self.assertEqual(list(validator.iter_errors(legacy)), [])
        self.assertEqual(list(validator.iter_errors(split)), [])
        mixed = {**legacy, **split}
        self.assertNotEqual(list(validator.iter_errors(mixed)), [])

    def setUp(self) -> None:
        self.coordinate = coordinate_fixture()
        self.risk = risk_fixture()

    def assert_coordinate_rejected(self, document: dict) -> None:
        with self.assertRaises(CorrectiveDiagnosticContractError):
            validate_coordinate_anisotropy_artifact(document)

    def assert_risk_rejected(self, document: dict) -> None:
        with self.assertRaises(CorrectiveDiagnosticContractError):
            validate_risk_state_artifact(document)

    def test_positive_artifacts_have_exact_dimensions_and_validate(self) -> None:
        self.assertEqual(len(ROUTE_BLOCK_SPECS), 32)
        self.assertEqual(len(COMPOSITION_SPECS), 31)
        self.assertEqual(len(self.risk["frame_route_records"][0]["cells"]), 30)
        self.assertEqual(
            validate_coordinate_anisotropy_artifact(self.coordinate),
            self.coordinate,
        )
        self.assertEqual(validate_risk_state_artifact(self.risk), self.risk)

    def test_route_transport_mapping_is_explicit_and_rejects_aliases(self) -> None:
        self.assertEqual(evaluator_route_for_contract_route("direct_2x"), "direct-2x")
        self.assertEqual(
            evaluator_route_for_contract_route("direct_3_over_2"),
            "direct-3over2",
        )
        self.assertEqual(contract_route_for_evaluator_route("direct-2x"), "direct_2x")
        self.assertEqual(
            contract_route_for_evaluator_route("direct-3over2"),
            "direct_3_over_2",
        )
        invalid_contract_routes = (
            "direct" + "2x",
            "direct" + "3over2",
            "direct-2x",
            "direct-3over2",
            "direct_3over2",
        )
        invalid_evaluator_routes = (
            "direct" + "2x",
            "direct" + "3over2",
            "direct_2x",
            "direct_3_over_2",
            "direct-3-over-2",
        )
        for route in invalid_contract_routes:
            with self.subTest(contract_route=route):
                with self.assertRaises(CorrectiveDiagnosticContractError):
                    evaluator_route_for_contract_route(route)
        for route in invalid_evaluator_routes:
            with self.subTest(evaluator_route=route):
                with self.assertRaises(CorrectiveDiagnosticContractError):
                    contract_route_for_evaluator_route(route)

    def test_coordinate_schema_rejects_missing_extra_selection_and_access(self) -> None:
        missing = copy.deepcopy(self.coordinate)
        del missing["input_bindings"]
        self.assert_coordinate_rejected(missing)

        extra = copy.deepcopy(self.coordinate)
        extra["undeclared"] = False
        self.assert_coordinate_rejected(extra)

        for field, value in (
            ("selected_winner", "forbidden"),
            ("validation_accessed", True),
            ("holdout_accessed", True),
        ):
            altered = copy.deepcopy(self.coordinate)
            altered[field] = value
            with self.subTest(field=field):
                self.assert_coordinate_rejected(altered)

    def test_live_holdout_guard_object_and_hash_are_fail_closed(self) -> None:
        altered = copy.deepcopy(self.coordinate)
        altered["input_bindings"]["live_holdout_preopen_verification"][
            "access_count"
        ] = 1
        seal(altered, "artifact_sha256")
        self.assert_coordinate_rejected(altered)

        altered = copy.deepcopy(self.risk)
        altered["input_bindings"][
            "live_holdout_preopen_verification_sha256"
        ] = digest("wrong-live-guard")
        seal(altered, "artifact_sha256")
        self.assert_risk_rejected(altered)

    def test_resealed_completed_execution_closure_omission_and_tamper_are_rejected(
        self,
    ) -> None:
        omitted = copy.deepcopy(self.coordinate)
        omitted["input_bindings"]["completed_execution_evidence"] = {}
        seal(omitted, "artifact_sha256")
        self.assert_coordinate_rejected(omitted)

        stub = copy.deepcopy(self.coordinate)
        closure = stub["input_bindings"]["completed_execution_evidence"]
        receipt = closure["native_sanitation_receipts"][0]
        receipt["retained_stubs"][0]["sha256"] = digest("nonempty-stub")
        receipt["retained_stub_manifest_sha256"] = canonical_sha256(
            receipt["retained_stubs"]
        )
        closure["native_sanitation_receipt_manifest_sha256"] = canonical_sha256(
            closure["native_sanitation_receipts"]
        )
        seal(closure, "prepublication_closure_sha256")
        seal(stub, "artifact_sha256")
        self.assert_coordinate_rejected(stub)

        extra_recursive = copy.deepcopy(self.risk)
        closure = extra_recursive["input_bindings"][
            "completed_execution_evidence"
        ]
        closure["recursive_entries"].append(
            {
                "relative_path": "foreign-extra.bin",
                "entry_kind": "regular_file",
                "size_bytes": 0,
                "file_sha256": hashlib.sha256(b"").hexdigest(),
            }
        )
        closure["recursive_entries"].sort(
            key=lambda row: row["relative_path"]
        )
        closure["recursive_entry_count"] = len(
            closure["recursive_entries"]
        )
        closure["recursive_manifest_sha256"] = canonical_sha256(
            closure["recursive_entries"]
        )
        seal(closure, "prepublication_closure_sha256")
        seal(extra_recursive, "artifact_sha256")
        self.assert_risk_rejected(extra_recursive)

        omitted_input = copy.deepcopy(self.coordinate)
        closure = omitted_input["input_bindings"][
            "completed_execution_evidence"
        ]
        input_receipt = closure["input_sanitation_receipt"]
        removed = input_receipt["retained_stubs"].pop()
        input_receipt["retained_stub_count"] = len(
            input_receipt["retained_stubs"]
        )
        input_receipt["retained_stub_manifest_sha256"] = canonical_sha256(
            input_receipt["retained_stubs"]
        )
        seal(input_receipt, "receipt_sha256")
        input_payload = canonical_artifact_file_bytes(input_receipt)
        closure["input_sanitation_receipt_file_sha256"] = hashlib.sha256(
            input_payload
        ).hexdigest()
        closure["recursive_entries"] = [
            row
            for row in closure["recursive_entries"]
            if row["relative_path"]
            not in {
                f"inputs/{removed['name']}",
                "input-sanitation-receipt.json",
            }
        ]
        closure["recursive_entries"].append(
            {
                "relative_path": "input-sanitation-receipt.json",
                "entry_kind": "regular_file",
                "size_bytes": len(input_payload),
                "file_sha256": hashlib.sha256(input_payload).hexdigest(),
            }
        )
        closure["recursive_entries"].sort(
            key=lambda row: row["relative_path"]
        )
        closure["recursive_entry_count"] = len(
            closure["recursive_entries"]
        )
        closure["recursive_manifest_sha256"] = canonical_sha256(
            closure["recursive_entries"]
        )
        seal(closure, "prepublication_closure_sha256")
        seal(omitted_input, "artifact_sha256")
        self.assert_coordinate_rejected(omitted_input)

    def test_resealed_input_receipt_recursive_size_tamper_is_rejected(
        self,
    ) -> None:
        altered = copy.deepcopy(self.coordinate)
        closure = altered["input_bindings"]["completed_execution_evidence"]
        receipt_row = next(
            row
            for row in closure["recursive_entries"]
            if row["relative_path"] == "input-sanitation-receipt.json"
        )
        receipt_row["size_bytes"] += 1
        closure["recursive_manifest_sha256"] = canonical_sha256(
            closure["recursive_entries"]
        )
        seal(closure, "prepublication_closure_sha256")
        seal(altered, "artifact_sha256")
        self.assert_coordinate_rejected(altered)

    def test_resealed_native_output_manifest_tamper_is_rejected(
        self,
    ) -> None:
        altered = copy.deepcopy(self.coordinate)
        closure = altered["input_bindings"]["completed_execution_evidence"]
        closure["native_sanitation_receipts"][0][
            "original_output_manifest_sha256"
        ] = digest("resealed-wrong-original-output-manifest")
        closure["native_sanitation_receipt_manifest_sha256"] = canonical_sha256(
            closure["native_sanitation_receipts"]
        )
        seal(closure, "prepublication_closure_sha256")
        seal(altered, "artifact_sha256")
        self.assert_coordinate_rejected(altered)

    def test_resealed_native_sanitation_receipt_permutation_is_rejected(
        self,
    ) -> None:
        altered = copy.deepcopy(self.coordinate)
        closure = altered["input_bindings"]["completed_execution_evidence"]
        receipts = closure["native_sanitation_receipts"]
        receipts[0], receipts[1] = receipts[1], receipts[0]
        closure["native_sanitation_receipt_manifest_sha256"] = canonical_sha256(
            receipts
        )
        seal(closure, "prepublication_closure_sha256")
        seal(altered, "artifact_sha256")
        self.assert_coordinate_rejected(altered)

    def test_resealed_native_descriptor_cell_and_session_counter_tamper_is_rejected(
        self,
    ) -> None:
        descriptor = copy.deepcopy(self.coordinate)
        descriptor["native_records"][0]["request"]["output_descriptors"][0][
            "coordinate_cell_id"
        ] = "wrong-coordinate-cell"
        reseal_coordinate_native_record(descriptor, 0)
        self.assert_coordinate_rejected(descriptor)

        cell_path = copy.deepcopy(self.coordinate)
        cell_path["native_records"][0]["response"][
            "corrective_diagnostic"
        ]["cells"][0]["output_path"] = "/tmp/wrong-native-cell.nv12"
        reseal_coordinate_native_record(cell_path, 0)
        self.assert_coordinate_rejected(cell_path)

        missing_counter = copy.deepcopy(self.coordinate)
        del missing_counter["native_records"][0]["response"][
            "corrective_diagnostic"
        ]["session_counters"]["output_reopen_count"]
        reseal_coordinate_native_record(missing_counter, 0)
        self.assert_coordinate_rejected(missing_counter)

        wrong_counter = copy.deepcopy(self.coordinate)
        wrong_counter["native_records"][0]["response"][
            "corrective_diagnostic"
        ]["session_counters"]["output_write_count"] = 16
        reseal_coordinate_native_record(wrong_counter, 0)
        self.assert_coordinate_rejected(wrong_counter)

    def test_resealed_native_frame_invocation_and_provenance_tamper_is_rejected(
        self,
    ) -> None:
        frame = copy.deepcopy(self.coordinate)
        frame["native_records"][0]["request"]["frame"]["matrix"] = "BT.601"
        reseal_coordinate_native_record(frame, 0)
        self.assert_coordinate_rejected(frame)

        missing_invocation = copy.deepcopy(self.coordinate)
        del missing_invocation["native_records"][0]["response"][
            "corrective_diagnostic"
        ]["native_invocation_proof"]
        reseal_coordinate_native_record(missing_invocation, 0)
        self.assert_coordinate_rejected(missing_invocation)

        invocation = copy.deepcopy(self.coordinate)
        invocation["native_records"][0]["response"][
            "corrective_diagnostic"
        ]["native_invocation_proof"]["process_id"] = 0
        reseal_coordinate_native_record(invocation, 0)
        self.assert_coordinate_rejected(invocation)

        provenance = copy.deepcopy(self.coordinate)
        provenance["native_records"][0]["response"][
            "corrective_diagnostic"
        ]["operator_bank_sha256"] = digest("wrong-operator-bank")
        reseal_coordinate_native_record(provenance, 0)
        self.assert_coordinate_rejected(provenance)

    def test_native_configuration_id_uses_locked_configuration_grammar(
        self,
    ) -> None:
        native_record = self.coordinate["native_records"][0]
        self.assertEqual(
            native_record["request"]["configuration_id"],
            f"ash-p06-{digest('configuration')[:24]}",
        )

        malformed = copy.deepcopy(self.coordinate)
        malformed_record = malformed["native_records"][0]
        malformed_record["request"]["configuration_id"] = "Ash-p06-invalid"
        malformed_record["response"]["corrective_diagnostic"][
            "configuration_id"
        ] = "Ash-p06-invalid"
        reseal_coordinate_native_record(malformed, 0)
        self.assert_coordinate_rejected(malformed)

    def test_coordinate_rejects_block_reorder_missing_and_extra(self) -> None:
        reordered = copy.deepcopy(self.coordinate)
        reordered["route_cell_blocks"][0:2] = reversed(
            reordered["route_cell_blocks"][0:2]
        )
        seal(reordered, "artifact_sha256")
        self.assert_coordinate_rejected(reordered)

        missing = copy.deepcopy(self.coordinate)
        missing["route_cell_blocks"].pop()
        self.assert_coordinate_rejected(missing)

        extra = copy.deepcopy(self.coordinate)
        extra["route_cell_blocks"].append(copy.deepcopy(extra["route_cell_blocks"][-1]))
        self.assert_coordinate_rejected(extra)

    def test_coordinate_rejects_altered_dimensions_and_production_binding(self) -> None:
        dimensions = copy.deepcopy(self.coordinate)
        dimensions["dimension_contract"]["coordinate_cells"].reverse()
        seal(dimensions, "artifact_sha256")
        self.assert_coordinate_rejected(dimensions)

        production = copy.deepcopy(self.coordinate)
        production["production_v2_reference"]["candidate_vector_sha256"] = digest(
            "different-base-candidate"
        )
        seal(production, "artifact_sha256")
        self.assert_coordinate_rejected(production)

        lut = copy.deepcopy(self.coordinate)
        block = lut["route_cell_blocks"][0]
        block["generic_lut_payload_sha256"] = digest("different-generic-lut")
        seal(block, "block_sha256")
        seal(lut, "artifact_sha256")
        self.assert_coordinate_rejected(lut)

    def test_coordinate_rejects_plane_metric_and_recursive_hash_mutations(self) -> None:
        recursive_hash = copy.deepcopy(self.coordinate)
        recursive_hash["route_cell_blocks"][0]["observations"][0]["planes"]["y"][
            "plane_evidence_sha256"
        ] = digest("altered-plane-self-hash")
        self.assert_coordinate_rejected(recursive_hash)

        entry_flag = copy.deepcopy(self.coordinate)
        block = entry_flag["route_cell_blocks"][0]
        observation = block["observations"][0]
        plane = observation["planes"]["y"]
        plane["source_aligned_entry_flag_sample_count"] = 1
        seal(plane, "plane_evidence_sha256")
        seal(observation, "observation_sha256")
        seal(block, "block_sha256")
        seal(entry_flag, "artifact_sha256")
        self.assert_coordinate_rejected(entry_flag)

        row_order = copy.deepcopy(self.coordinate)
        block = row_order["route_cell_blocks"][0]
        observation = block["observations"][0]
        observation["metric_rows"].reverse()
        seal(observation, "observation_sha256")
        seal(block, "block_sha256")
        seal(row_order, "artifact_sha256")
        self.assert_coordinate_rejected(row_order)

        writer = copy.deepcopy(self.coordinate)
        block = writer["route_cell_blocks"][0]
        observation = block["observations"][0]
        row = observation["metric_rows"][0]
        row["writer_evidence_sha256"] = digest("forbidden-raw-writer-evidence")
        seal(row, "metric_row_sha256")
        seal(observation, "observation_sha256")
        seal(block, "block_sha256")
        seal(writer, "artifact_sha256")
        self.assert_coordinate_rejected(writer)

        normalized = copy.deepcopy(self.coordinate)
        block = normalized["route_cell_blocks"][0]
        observation = block["observations"][0]
        plane = observation["planes"]["y"]
        plane["normalized_plane_sha256"] = "invalid"
        self.assert_coordinate_rejected(normalized)

    def test_hash_contract_identifiers_are_exact_and_independent(self) -> None:
        for field, value in (
            ("output_plane_hash_contract", "wrong-output-plane-contract"),
            ("normalized_plane_hash_contract", "wrong-normalized-plane-contract"),
            ("analysis_grid_hash_contract", "wrong-analysis-grid-contract"),
        ):
            altered = copy.deepcopy(self.coordinate)
            altered["input_bindings"][field] = value
            seal(altered, "artifact_sha256")
            with self.subTest(coordinate_field=field):
                self.assert_coordinate_rejected(altered)

        risk = copy.deepcopy(self.risk)
        risk["input_bindings"]["analysis_grid_hash_contract"] = (
            "wrong-analysis-grid-contract"
        )
        seal(risk, "artifact_sha256")
        self.assert_risk_rejected(risk)

    def test_coordinate_rejects_duplicate_observation(self) -> None:
        duplicate = copy.deepcopy(self.coordinate)
        block = duplicate["route_cell_blocks"][0]
        block["observations"].append(copy.deepcopy(block["observations"][0]))
        seal(block, "block_sha256")
        seal(duplicate, "artifact_sha256")
        self.assert_coordinate_rejected(duplicate)

    def test_coordinate_rejects_composition_reorder_missing_and_altered_binding(self) -> None:
        reordered = copy.deepcopy(self.coordinate)
        reordered["full_corpus_compositions"][0:2] = reversed(
            reordered["full_corpus_compositions"][0:2]
        )
        seal(reordered, "artifact_sha256")
        self.assert_coordinate_rejected(reordered)

        missing = copy.deepcopy(self.coordinate)
        missing["full_corpus_compositions"].pop()
        self.assert_coordinate_rejected(missing)

        altered = copy.deepcopy(self.coordinate)
        composition = altered["full_corpus_compositions"][0]
        composition["direct_2x_block_sha256"] = digest("different-block")
        seal(composition, "composition_sha256")
        seal(altered, "artifact_sha256")
        self.assert_coordinate_rejected(altered)

    def test_risk_schema_rejects_missing_extra_selection_and_access(self) -> None:
        missing = copy.deepcopy(self.risk)
        del missing["input_bindings"]
        self.assert_risk_rejected(missing)

        extra = copy.deepcopy(self.risk)
        extra["undeclared"] = False
        self.assert_risk_rejected(extra)

        for field, value in (
            ("selected_winner", "forbidden"),
            ("validation_accessed", True),
            ("holdout_accessed", True),
        ):
            altered = copy.deepcopy(self.risk)
            altered[field] = value
            with self.subTest(field=field):
                self.assert_risk_rejected(altered)

    def test_risk_rejects_cell_reorder_missing_extra_and_hash_mutation(self) -> None:
        reordered = copy.deepcopy(self.risk)
        record = reordered["frame_route_records"][0]
        record["cells"][0:2] = reversed(record["cells"][0:2])
        seal(record, "frame_route_record_sha256")
        seal(reordered, "artifact_sha256")
        self.assert_risk_rejected(reordered)

        missing = copy.deepcopy(self.risk)
        missing["frame_route_records"][0]["cells"].pop()
        self.assert_risk_rejected(missing)

        extra = copy.deepcopy(self.risk)
        cells = extra["frame_route_records"][0]["cells"]
        cells.append(copy.deepcopy(cells[-1]))
        self.assert_risk_rejected(extra)

        recursive_hash = copy.deepcopy(self.risk)
        recursive_hash["frame_route_records"][0]["cells"][0]["cell_sha256"] = digest(
            "altered-risk-cell-self-hash"
        )
        self.assert_risk_rejected(recursive_hash)

    def test_risk_rejects_altered_dimensions_counts_extrema_and_route_coverage(self) -> None:
        dimensions = copy.deepcopy(self.risk)
        dimensions["dimension_contract"]["risk_weight_pairs"].reverse()
        seal(dimensions, "artifact_sha256")
        self.assert_risk_rejected(dimensions)

        counts = copy.deepcopy(self.risk)
        record = counts["frame_route_records"][0]
        cell = record["cells"][0]
        cell["risk_zero_count"] = 3
        seal(cell, "cell_sha256")
        seal(record, "frame_route_record_sha256")
        seal(counts, "artifact_sha256")
        self.assert_risk_rejected(counts)

        extrema = copy.deepcopy(self.risk)
        record = extrema["frame_route_records"][0]
        cell = record["cells"][0]
        cell["risk_proxy_minimum_unorm15"] = 2
        cell["risk_proxy_maximum_unorm15"] = 1
        seal(cell, "cell_sha256")
        seal(record, "frame_route_record_sha256")
        seal(extrema, "artifact_sha256")
        self.assert_risk_rejected(extrema)

        coverage = copy.deepcopy(self.risk)
        record = coverage["frame_route_records"][12]
        record["target_route"] = ROUTES[0]
        seal(record, "frame_route_record_sha256")
        seal(coverage, "artifact_sha256")
        self.assert_risk_rejected(coverage)

    def test_risk_rejects_duplicate_frame_route_identity(self) -> None:
        duplicate = copy.deepcopy(self.risk)
        record = copy.deepcopy(duplicate["frame_route_records"][0])
        record["ordinal"] = 2
        seal(record, "frame_route_record_sha256")
        duplicate["frame_route_records"].append(record)
        seal(duplicate, "artifact_sha256")
        self.assert_risk_rejected(duplicate)

    def test_canonical_file_and_envelope_bind_both_siblings(self) -> None:
        coordinate_payload = canonical_artifact_file_bytes(self.coordinate)
        risk_payload = canonical_artifact_file_bytes(self.risk)
        self.assertTrue(coordinate_payload.endswith(b"\n"))
        self.assertNotIn(b"\n", coordinate_payload[:-1])
        self.assertEqual(json.loads(coordinate_payload), self.coordinate)

        envelope = envelope_fixture(self.coordinate, self.risk)
        self.assertEqual(
            validate_corrective_diagnostic_envelope(
                envelope,
                coordinate_artifact_payload=coordinate_payload,
                risk_state_artifact_payload=risk_payload,
            ),
            envelope,
        )

    def test_envelope_rejects_binding_selection_access_and_noncanonical_siblings(self) -> None:
        coordinate_payload = canonical_artifact_file_bytes(self.coordinate)
        risk_payload = canonical_artifact_file_bytes(self.risk)
        envelope = envelope_fixture(self.coordinate, self.risk)

        binding = copy.deepcopy(envelope)
        binding["coordinate_anisotropy_artifact"]["file_sha256"] = digest(
            "different-coordinate-file"
        )
        seal(binding, "envelope_sha256")
        with self.assertRaises(CorrectiveDiagnosticContractError):
            validate_corrective_diagnostic_envelope(
                binding,
                coordinate_artifact_payload=coordinate_payload,
                risk_state_artifact_payload=risk_payload,
            )

        for field, value in (
            ("selected_winner", "forbidden"),
            ("validation_accessed", True),
            ("holdout_accessed", True),
        ):
            altered = copy.deepcopy(envelope)
            altered[field] = value
            with self.subTest(field=field):
                with self.assertRaises(CorrectiveDiagnosticContractError):
                    validate_corrective_diagnostic_envelope(
                        altered,
                        coordinate_artifact_payload=coordinate_payload,
                        risk_state_artifact_payload=risk_payload,
                    )

        pretty_coordinate = json.dumps(self.coordinate, indent=2).encode("utf-8") + b"\n"
        with self.assertRaises(CorrectiveDiagnosticContractError):
            validate_corrective_diagnostic_envelope(
                envelope,
                coordinate_artifact_payload=pretty_coordinate,
                risk_state_artifact_payload=risk_payload,
            )

        duplicate_key_coordinate = coordinate_payload.replace(
            b'{"artifact_kind":',
            b'{"artifact_kind":"duplicate","artifact_kind":',
            1,
        )
        with self.assertRaises(CorrectiveDiagnosticContractError):
            validate_corrective_diagnostic_envelope(
                envelope,
                coordinate_artifact_payload=duplicate_key_coordinate,
                risk_state_artifact_payload=risk_payload,
            )

        nonstandard_number_coordinate = coordinate_payload.replace(b"41.0", b"NaN", 1)
        with self.assertRaises(CorrectiveDiagnosticContractError):
            validate_corrective_diagnostic_envelope(
                envelope,
                coordinate_artifact_payload=nonstandard_number_coordinate,
                risk_state_artifact_payload=risk_payload,
            )


if __name__ == "__main__":
    unittest.main()
