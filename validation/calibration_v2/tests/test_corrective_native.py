from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import pytest

from validation.calibration_v2 import corrective_native as native
from validation.calibration_v2.corrective_diagnostics import (
    ANISOTROPY_CELLS,
    COORDINATE_CELLS,
    RISK_THRESHOLD_BANDS,
    RISK_WEIGHT_PAIRS,
)
from validation.calibration_v2.native_adapter.factory import (
    NativeAdapterError,
    NativeSwiftSession,
)
from validation.quality.src.mirmir_quality.arrays import frame_sha256
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_sha256,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    _video_range_nv12_to_planar,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
CONTRACT_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/contracts/coordinate-model-contract-v3.json"
)


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def rebind_sha256(route: str, original: str) -> str:
    serialized = "half_pixel_center"
    payload = bytearray(
        b"MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0"
    )
    for value in (route, original, serialized):
        payload.extend(value.encode("utf-8"))
        payload.append(0)
    payload.append(1 if original != serialized else 0)
    return hashlib.sha256(payload).hexdigest()


def split_rebind_sha256(
    route: str,
    original_luma: str,
    original_chroma: str,
) -> str:
    serialized_luma = "half_pixel_center"
    serialized_chroma = "half_pixel_center"
    payload = bytearray(
        b"MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0"
    )
    for value in (
        route,
        original_luma,
        original_chroma,
        serialized_luma,
        serialized_chroma,
    ):
        payload.extend(value.encode("utf-8"))
        payload.append(0)
    payload.append(
        1
        if original_luma != serialized_luma
        or original_chroma != serialized_chroma
        else 0
    )
    return hashlib.sha256(payload).hexdigest()


def configuration() -> dict[str, object]:
    route_lut = {
        "whole_file_sha256": digest("production-lut-file"),
        "payload_sha256": digest("production-lut-payload"),
        "entry_count": 4096,
    }
    return {
        "configuration_id": digest("configuration"),
        "compiler_inputs_sha256": digest("compiler-inputs"),
        "serialized_candidate_vector_sha256": digest("candidate-vector"),
        "candidate_vector": {
            "direct_2x_analysis_grid_source_step": 1,
            "direct_2x_coordinate_policy": "source_aligned_rational",
        },
        "shared_bank_configuration_sha256": digest("shared-bank"),
        "mapping_sha256": digest("mapping"),
        "operator_bank_sha256": digest("operator-bank"),
        "metric_policy_sha256": digest("metric-policy"),
        "calibration_plan_sha256": digest("calibration-plan"),
        "corpus_lock_bundle_sha256": digest("corpus-lock-bundle"),
        "candidate_lut_runtime_manifest_sha256": digest("runtime-manifest"),
        "route_luts": {"direct-2x": route_lut},
    }


def request_fixture(tmp_path: Path) -> tuple[dict[str, object], dict[str, object]]:
    input_path = tmp_path / "input.nv12"
    input_payload = bytes((16, 64, 128, 235, 128, 128))
    input_path.write_bytes(input_payload)
    output_directory = tmp_path / "native-transaction"
    descriptors = []
    for ordinal, (coordinate, anisotropy) in enumerate(
        (coordinate, anisotropy)
        for coordinate in COORDINATE_CELLS
        for anisotropy in ANISOTROPY_CELLS
    ):
        descriptors.append(
            {
                "ordinal": ordinal,
                "coordinate_cell_id": coordinate["cell_id"],
                "anisotropy_cell_id": anisotropy["cell_id"],
                "output_path": str(output_directory / f"cell-{ordinal:02d}.nv12"),
            }
        )
    production = output_directory / "production-v2.nv12"
    config = configuration()
    request = {
        "schema_version": "1.0.0",
        "operation": "diagnose_corrective_frame",
        "configuration_id": config["configuration_id"],
        "compiler_inputs_sha256": config["compiler_inputs_sha256"],
        "coordinate_model_contract_path": str(CONTRACT_PATH),
        "coordinate_model_contract_sha256": hashlib.sha256(
            CONTRACT_PATH.read_bytes()
        ).hexdigest(),
        "analysis_grid_source_step": 1,
        "output_descriptors": descriptors,
        "production_v2_reference_output_path": str(production),
        "frame": {
            "request_id": digest("request-id"),
            "route": "direct-2x",
            "input_path": str(input_path),
            "input_sha256": hashlib.sha256(input_payload).hexdigest(),
            "input_width": 2,
            "input_height": 2,
            "output_path": str(production),
            "output_width": 4,
            "output_height": 4,
            "pixel_format": "420v",
            "matrix": "BT.709",
            "range": "video",
            "chroma_siting": "left",
        },
    }
    return request, config


def output_payload(seed: int = 0) -> bytes:
    y = bytes(((16 + seed + index) % 220) + 16 for index in range(16))
    chroma = bytes((128 + seed, 128 - seed)) * 4
    return y + chroma


def output_hashes(payload: bytes) -> dict[str, str]:
    frame = _video_range_nv12_to_planar(payload, width=4, height=4)
    chroma = payload[16:]
    return {
        "output_nv12_sha256": hashlib.sha256(payload).hexdigest(),
        "output_frame_sha256": frame_sha256(frame),
        "y": hashlib.sha256(payload[:16]).hexdigest(),
        "cb": hashlib.sha256(chroma[0::2]).hexdigest(),
        "cr": hashlib.sha256(chroma[1::2]).hexdigest(),
    }


def prepared_binding(
    tmp_path: Path,
) -> tuple[
    dict[str, object],
    dict[str, object],
    native.CorrectiveNativeRequestBinding,
    bytes,
]:
    request, config = request_fixture(tmp_path)
    binding = native.validate_corrective_native_request(
        request,
        configuration=config,
        require_outputs_absent=True,
    )
    payload = output_payload()
    for path in binding.output_paths:
        path.write_bytes(payload)
    native.capture_corrective_native_outputs(binding, require_all=True)
    return request, config, binding, payload


def response_fixture(
    request: dict[str, object],
    config: dict[str, object],
    binding: native.CorrectiveNativeRequestBinding,
    payload: bytes,
    *,
    process_id: int,
    executable_sha256: str,
    source_manifest_sha256: str,
) -> dict[str, object]:
    hashes = output_hashes(payload)
    cells = []
    for ordinal, path in enumerate(binding.output_paths[:-1]):
        coordinate = COORDINATE_CELLS[ordinal // len(ANISOTROPY_CELLS)]
        anisotropy = ANISOTROPY_CELLS[ordinal % len(ANISOTROPY_CELLS)]

        def plane(channel: str) -> dict[str, object]:
            luma = channel == "y"
            policy = str(
                coordinate[
                    "luma_coordinate_policy"
                    if luma
                    else "chroma_coordinate_policy"
                ]
            )
            samples = 16 if luma else 4
            return {
                "coordinate_policy": policy,
                "anisotropy_strength_q12": int(
                    anisotropy[
                        "luma_anisotropy_strength_q12"
                        if luma
                        else "chroma_anisotropy_strength_q12"
                    ]
                ),
                "sample_count": samples,
                "output_plane_sha256": hashes[channel],
                "normalized_plane_sha256": digest(
                    f"normalized-{ordinal}-{channel}"
                ),
                "source_aligned_entry_flag_sample_count": 0,
                "source_aligned_sample_preservation_count": (
                    samples if policy == "source_aligned_rational" else 0
                ),
                "numerical_fallback_count": 0,
            }

        coordinate_id = str(coordinate["cell_id"])
        anisotropy_id = str(anisotropy["cell_id"])
        cells.append(
            {
                "ordinal": ordinal,
                "block_id": f"direct_2x-{coordinate_id}-{anisotropy_id}",
                "coordinate_cell_id": coordinate_id,
                "anisotropy_cell_id": anisotropy_id,
                "output_path": str(path),
                "output_nv12_sha256": hashes["output_nv12_sha256"],
                "output_frame_sha256": hashes["output_frame_sha256"],
                "planes": {
                    channel: plane(channel) for channel in ("y", "cb", "cr")
                },
            }
        )
    analysis_count = 4
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
                "risk_proxy_value_count": analysis_count,
                "risk_proxy_vector_sha256": digest(f"risk-{ordinal}"),
            }
        )
    frame = request["frame"]
    assert isinstance(frame, dict)
    route_luts = config["route_luts"]
    assert isinstance(route_luts, dict)
    production_lut = route_luts["direct-2x"]
    assert isinstance(production_lut, dict)
    analysis_grid_hash = digest("analysis-grid")
    diagnostic = {
        "schema_version": "1.0.0",
        "status": "development_diagnostic_no_selection",
        "split": "development",
        "validation_accessed": False,
        "holdout_accessed": False,
        "selected_winner": None,
        "request_id": frame["request_id"],
        "target_route": "direct_2x",
        "configuration_id": config["configuration_id"],
        "compiler_inputs_sha256": config["compiler_inputs_sha256"],
        "candidate_vector_sha256": config["serialized_candidate_vector_sha256"],
        "shared_bank_configuration_sha256": config[
            "shared_bank_configuration_sha256"
        ],
        "mapping_sha256": config["mapping_sha256"],
        "operator_bank_sha256": config["operator_bank_sha256"],
        "metric_policy_sha256": config["metric_policy_sha256"],
        "calibration_plan_sha256": config["calibration_plan_sha256"],
        "corpus_lock_bundle_sha256": config["corpus_lock_bundle_sha256"],
        "candidate_lut_runtime_manifest_sha256": config[
            "candidate_lut_runtime_manifest_sha256"
        ],
        "native_invocation_proof": {
            "protocol": "serve-candidate/diagnose_corrective_frame-v1",
            "process_id": process_id,
            "executable_sha256": executable_sha256,
            "source_manifest_sha256": source_manifest_sha256,
        },
        "input_sha256": frame["input_sha256"],
        "coordinate_model_contract_file_sha256": (
            binding.coordinate_contract_sha256
        ),
        "coordinate_oracle_matrix_sha256": (
            binding.coordinate_oracle_matrix_sha256
        ),
        "coordinate_experiment_dimensions_sha256": (
            binding.coordinate_experiment_dimensions_sha256
        ),
        "analysis_grid_source_step": 1,
        "analysis_cell_count": analysis_count,
        "output_plane_hash_contract": "active-nv12-code-bytes-sha256-v1",
        "normalized_plane_hash_contract": (
            "mirmir-ash-normalized-plane-f64-be-v1"
        ),
        "analysis_grid_hash_contract": "mirmir-ash-analysis-grid-v3-be-v1",
        "analysis_grid_sha256": analysis_grid_hash,
        "generic_lut": {
            "whole_file_sha256": digest("generic-lut-file"),
            "payload_sha256": digest("generic-lut-payload"),
            "entry_count": 4096,
            "parameter_count": 1,
            "header_crc32": "0x1234ABCD",
            "payload_crc32": "0x5678EFAB",
            "offline_path_evaluation_count": 4096 * 81,
            "runtime_tree_generation_count": 0,
            "maximum_operator_evaluations": 2,
            "serialization_rebind_contract": (
                "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
            ),
            "original_coordinate_policy": "source_aligned_rational",
            "serialized_coordinate_policy": "half_pixel_center",
            "serialization_rebind_applied": True,
            "serialization_rebind_sha256": rebind_sha256(
                "direct_2x",
                "source_aligned_rational",
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
            "output_path": str(binding.output_paths[-1]),
            "output_nv12_sha256": hashes["output_nv12_sha256"],
            "output_frame_sha256": hashes["output_frame_sha256"],
            "planes": {
                channel: {
                    "output_plane_sha256": hashes[channel],
                    "normalized_plane_sha256": digest(
                        f"production-normalized-{channel}"
                    ),
                }
                for channel in ("y", "cb", "cr")
            },
            "lut_whole_file_sha256": production_lut["whole_file_sha256"],
            "lut_payload_sha256": production_lut["payload_sha256"],
            "lut_entry_count": 4096,
        },
        "cells": cells,
        "risk_state": {
            "analysis_grid_source_step": 1,
            "analysis_cell_count": analysis_count,
            "baseline_analysis_grid_sha256": analysis_grid_hash,
            "cells": risk_cells,
        },
    }
    return {
        "schema_version": "1.0.0",
        "status": "ok",
        "request_sha256": canonical_sha256(request),
        "corrective_diagnostic": diagnostic,
    }


@pytest.mark.skipif(
    native._RENAMEATX_NP is None,
    reason="Darwin exclusive rename is required for sanitation isolation",
)
def test_strict_response_reopens_all_outputs_and_cleanup_is_durable(
    tmp_path: Path,
) -> None:
    request, config, binding, payload = prepared_binding(tmp_path)
    executable_hash = digest("native-executable")
    source_hash = digest("native-source-manifest")
    response = response_fixture(
        request,
        config,
        binding,
        payload,
        process_id=os.getpid(),
        executable_sha256=executable_hash,
        source_manifest_sha256=source_hash,
    )
    try:
        validated = native.validate_corrective_native_response(
            response,
            binding=binding,
            configuration=config,
            native_executable_sha256=executable_hash,
            native_source_manifest_sha256=source_hash,
            native_process_id=os.getpid(),
        )
        assert validated == response
        reopened = native.reopen_corrective_output_frame(
            binding,
            binding.output_paths[0],
            width=4,
            height=4,
        )
        assert reopened.y.shape == (4, 4)
        receipt = native.cleanup_corrective_native_outputs(binding)
        assert not binding.output_directory.exists()
        assert receipt["status"] == "sanitized_retained"
        retained = Path(str(receipt["retained_transaction_path"]))
        assert retained.is_dir()
        retained_metadata = retained.stat()
        assert receipt["retained_transaction_identity"] == {
            "device": retained_metadata.st_dev,
            "inode": retained_metadata.st_ino,
        }
        stubs = receipt["retained_stubs"]
        assert isinstance(stubs, list) and len(stubs) == 17
        assert receipt["retained_stub_count"] == len(stubs)
        assert receipt["retained_stub_manifest_sha256"] == canonical_sha256(
            stubs
        )
        assert {path.name for path in retained.iterdir()} == {
            row["retained_name"] for row in stubs
        }
        empty_sha256 = hashlib.sha256(b"").hexdigest()
        for row in stubs:
            retained_stub = retained / row["retained_name"]
            metadata = retained_stub.stat()
            assert retained_stub.read_bytes() == b""
            assert row["device"] == metadata.st_dev
            assert row["inode"] == metadata.st_ino
            assert row["size_bytes"] == metadata.st_size == 0
            assert row["sha256"] == empty_sha256
    finally:
        native.close_corrective_native_binding(binding)


def test_strict_response_accepts_split_plane_serialization_provenance(
    tmp_path: Path,
) -> None:
    request, config, binding, payload = prepared_binding(tmp_path)
    candidate = config["candidate_vector"]
    assert isinstance(candidate, dict)
    candidate.pop("direct_2x_coordinate_policy")
    candidate["direct_2x_luma_coordinate_policy"] = (
        "source_aligned_rational"
    )
    candidate["direct_2x_chroma_coordinate_policy"] = "half_pixel_center"
    executable_hash = digest("native-executable")
    source_hash = digest("native-source-manifest")
    response = response_fixture(
        request,
        config,
        binding,
        payload,
        process_id=os.getpid(),
        executable_sha256=executable_hash,
        source_manifest_sha256=source_hash,
    )
    diagnostic = response["corrective_diagnostic"]
    assert isinstance(diagnostic, dict)
    generic = diagnostic["generic_lut"]
    assert isinstance(generic, dict)
    generic.pop("original_coordinate_policy")
    generic.pop("serialized_coordinate_policy")
    generic.update(
        {
            "original_luma_coordinate_policy": "source_aligned_rational",
            "original_chroma_coordinate_policy": "half_pixel_center",
            "serialized_luma_coordinate_policy": "half_pixel_center",
            "serialized_chroma_coordinate_policy": "half_pixel_center",
            "serialization_rebind_applied": True,
            "serialization_rebind_sha256": split_rebind_sha256(
                "direct_2x",
                "source_aligned_rational",
                "half_pixel_center",
            ),
        }
    )
    try:
        validated = native.validate_corrective_native_response(
            response,
            binding=binding,
            configuration=config,
            native_executable_sha256=executable_hash,
            native_source_manifest_sha256=source_hash,
            native_process_id=os.getpid(),
        )
        assert validated == response
    finally:
        native.close_corrective_native_binding(binding)


def test_replaced_captured_leaf_is_preserved_without_mutation(tmp_path: Path) -> None:
    _, _, binding, _ = prepared_binding(tmp_path)
    replaced = binding.output_paths[0]
    replaced.unlink()
    foreign_payload = output_payload(3)
    replaced.write_bytes(foreign_payload)
    try:
        with pytest.raises(native.CorrectiveNativeContractError) as captured:
            native.cleanup_corrective_native_outputs(binding)
        assert captured.value.preserved_transaction_path == binding.output_directory
        assert replaced.read_bytes() == foreign_payload
    finally:
        native.close_corrective_native_binding(binding)


@pytest.mark.skipif(
    native._RENAMEATX_NP is None,
    reason="Darwin exclusive rename is required for the replacement race",
)
def test_replacement_at_final_isolation_boundary_preserves_foreign_leaf(
    tmp_path: Path,
) -> None:
    _, _, binding, _ = prepared_binding(tmp_path)
    original = native._rename_exclusive_at
    injected = False
    foreign_payload = output_payload(5)

    def replace_before_sanitation(
        source_name: str,
        destination_name: str,
        *,
        directory_descriptor: int,
    ) -> None:
        nonlocal injected
        if source_name.startswith(".owned-output-") and not injected:
            injected = True
            os.unlink(source_name, dir_fd=directory_descriptor)
            descriptor = os.open(
                source_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=directory_descriptor,
            )
            try:
                os.write(descriptor, foreign_payload)
            finally:
                os.close(descriptor)
        original(
            source_name,
            destination_name,
            directory_descriptor=directory_descriptor,
        )

    try:
        with mock.patch.object(
            native,
            "_rename_exclusive_at",
            side_effect=replace_before_sanitation,
        ), pytest.raises(native.CorrectiveNativeContractError) as captured:
            native.cleanup_corrective_native_outputs(binding)
        assert injected
        preserved = captured.value.preserved_transaction_path
        assert preserved.is_dir()
        assert any(path.read_bytes() == foreign_payload for path in preserved.iterdir())
    finally:
        native.close_corrective_native_binding(binding)


@pytest.mark.skipif(
    native._RENAMEATX_NP is None,
    reason="Darwin exclusive rename is required for sanitation isolation",
)
def test_late_fsync_failure_reports_irreversible_sanitation_progress(
    tmp_path: Path,
) -> None:
    _, _, binding, _ = prepared_binding(tmp_path)
    try:
        with mock.patch.object(
            native.os,
            "fsync",
            side_effect=OSError("late directory fsync failure"),
        ), pytest.raises(native.CorrectiveNativeContractError) as captured:
            native.cleanup_corrective_native_outputs(binding)
        assert "after irreversible progress" in str(captured.value)
        assert not hasattr(captured.value, "preserved_transaction_path")
        assert not binding.output_directory.exists()
        assert captured.value.sanitized_transaction_path.is_dir()
    finally:
        native.close_corrective_native_binding(binding)


def test_missing_exclusive_rename_preserves_original_transaction(tmp_path: Path) -> None:
    _, _, binding, _ = prepared_binding(tmp_path)
    try:
        with mock.patch.object(
            native,
            "_RENAMEATX_NP",
            None,
        ), pytest.raises(native.CorrectiveNativeContractError) as captured:
            native.cleanup_corrective_native_outputs(binding)
        assert captured.value.preserved_transaction_path == binding.output_directory
        assert binding.output_directory.is_dir()
        assert len(list(binding.output_directory.iterdir())) == 17
    finally:
        native.close_corrective_native_binding(binding)


@pytest.mark.skipif(
    native._RENAMEATX_NP is None,
    reason="Darwin exclusive rename is required for interruption quarantine",
)
def test_cleanup_interruption_before_sanitation_preserves_quarantine(
    tmp_path: Path,
) -> None:
    _, _, binding, _ = prepared_binding(tmp_path)
    original = native._rename_exclusive_at
    calls = 0

    def interrupt_leaf(
        source_name: str,
        destination_name: str,
        *,
        directory_descriptor: int,
    ) -> None:
        nonlocal calls
        calls += 1
        if calls == 2:
            raise KeyboardInterrupt()
        original(
            source_name,
            destination_name,
            directory_descriptor=directory_descriptor,
        )

    try:
        with mock.patch.object(
            native,
            "_rename_exclusive_at",
            side_effect=interrupt_leaf,
        ), pytest.raises(native.CorrectiveNativeContractError) as captured:
            native.cleanup_corrective_native_outputs(binding)
        assert isinstance(captured.value.cleanup_failures[0], KeyboardInterrupt)
        assert captured.value.preserved_transaction_path.is_dir()
    finally:
        native.close_corrective_native_binding(binding)


@pytest.mark.skipif(
    native._RENAMEATX_NP is None,
    reason="Darwin exclusive rename is required for sanitation quarantine",
)
def test_successful_sanitation_never_calls_unlink_on_a_leaf(tmp_path: Path) -> None:
    _, _, binding, _ = prepared_binding(tmp_path)
    foreign = tmp_path / "foreign-evidence.bin"
    foreign_payload = b"foreign-bytes-must-survive"
    foreign.write_bytes(foreign_payload)
    real_unlink = native.os.unlink

    def replace_then_unlink(*args: object, **kwargs: object) -> None:
        raise AssertionError(
            "identity-conditioned unlink is unavailable; sanitation must retain stubs"
        )

    try:
        with mock.patch.object(
            native.os,
            "unlink",
            side_effect=replace_then_unlink,
        ) as unlink:
            receipt = native.cleanup_corrective_native_outputs(binding)
        unlink.assert_not_called()
        assert receipt["status"] == "sanitized_retained"
        assert foreign.read_bytes() == foreign_payload
    finally:
        native.close_corrective_native_binding(binding)
        if foreign.exists():
            real_unlink(foreign)


class _ProcessStub:
    def __init__(self) -> None:
        self.killed = False
        self.waited = False
        self.pid = 321

    def poll(self) -> int | None:
        return -9 if self.killed else None

    def kill(self) -> None:
        self.killed = True

    def wait(self, timeout: float | None = None) -> int:
        self.waited = True
        return -9


def test_corrective_transport_timeout_kills_and_poisons_session() -> None:
    session = object.__new__(NativeSwiftSession)
    session.configuration = SimpleNamespace(configuration={})
    session._corrective_output_bindings = {}
    session._poisoned = False
    session.process = _ProcessStub()
    session._send = mock.Mock(
        side_effect=NativeAdapterError("native session response timed out")
    )
    binding = object()
    document = {"request": "synthetic-timeout"}

    with mock.patch.object(
        native,
        "validate_corrective_native_request",
        return_value=binding,
    ) as validate_request, mock.patch.object(
        native,
        "capture_corrective_native_outputs",
    ) as capture, mock.patch.object(
        native,
        "cleanup_corrective_native_outputs",
    ) as cleanup, mock.patch.object(
        native,
        "close_corrective_native_binding",
    ) as close, pytest.raises(
        NativeAdapterError,
        match="response timed out",
    ):
        session.diagnose_corrective_frame(document)

    assert session._poisoned is True
    assert session.process.killed is True
    assert session.process.waited is True
    capture.assert_called_once_with(binding, require_all=False)
    cleanup.assert_called_once_with(binding)
    close.assert_called_once_with(binding)
    with pytest.raises(NativeAdapterError, match="session is poisoned"):
        session.diagnose_corrective_frame(document)
    assert validate_request.call_count == 1


def test_malformed_corrective_response_kills_and_poisons_before_recovery() -> None:
    session = object.__new__(NativeSwiftSession)
    session.configuration = SimpleNamespace(configuration={})
    session.executable = SimpleNamespace(
        sha256=digest("native-executable"),
        source_manifest_sha256=digest("native-sources"),
    )
    session._corrective_output_bindings = {}
    session._poisoned = False
    session.process = _ProcessStub()
    session._send = mock.Mock(return_value={"malformed": True})
    binding = object()
    document = {"request": "synthetic-malformed-response"}

    def capture_after_send(value: object, *, require_all: bool) -> None:
        assert value is binding
        if not require_all:
            assert session._poisoned is True
            assert session.process.killed is True
            assert session.process.waited is True

    with mock.patch.object(
        native,
        "validate_corrective_native_request",
        return_value=binding,
    ), mock.patch.object(
        native,
        "capture_corrective_native_outputs",
        side_effect=capture_after_send,
    ) as capture, mock.patch.object(
        native,
        "validate_corrective_native_response",
        side_effect=native.CorrectiveNativeContractError(
            "malformed corrective response"
        ),
    ), mock.patch.object(
        native,
        "cleanup_corrective_native_outputs",
    ) as cleanup, mock.patch.object(
        native,
        "close_corrective_native_binding",
    ) as close, pytest.raises(
        NativeAdapterError,
        match="malformed corrective response",
    ):
        session.diagnose_corrective_frame(document)

    assert session._poisoned is True
    assert session.process.killed is True
    assert session.process.waited is True
    assert capture.call_args_list == [
        mock.call(binding, require_all=True),
        mock.call(binding, require_all=False),
    ]
    cleanup.assert_called_once_with(binding)
    close.assert_called_once_with(binding)


def test_post_send_output_recovery_errors_remain_distinct_after_poisoning() -> None:
    session = object.__new__(NativeSwiftSession)
    session.configuration = SimpleNamespace(configuration={})
    session.executable = SimpleNamespace(
        sha256=digest("native-executable"),
        source_manifest_sha256=digest("native-sources"),
    )
    session._corrective_output_bindings = {}
    session._poisoned = False
    session.process = _ProcessStub()
    session._send = mock.Mock(return_value={"schema_version": "1.0.0"})
    binding = object()
    document = {"request": "synthetic-output-recovery-failure"}
    primary = native.CorrectiveNativeContractError("required output missing")
    capture_recovery = OSError("recovery capture failed")
    cleanup_recovery = OSError("recovery sanitation failed")
    capture_calls = 0

    def capture(value: object, *, require_all: bool) -> None:
        nonlocal capture_calls
        assert value is binding
        capture_calls += 1
        if require_all:
            raise primary
        assert session._poisoned is True
        assert session.process.killed is True
        raise capture_recovery

    with mock.patch.object(
        native,
        "validate_corrective_native_request",
        return_value=binding,
    ), mock.patch.object(
        native,
        "capture_corrective_native_outputs",
        side_effect=capture,
    ), mock.patch.object(
        native,
        "cleanup_corrective_native_outputs",
        side_effect=cleanup_recovery,
    ), mock.patch.object(
        native,
        "close_corrective_native_binding",
    ) as close, pytest.raises(
        NativeAdapterError,
        match="termination, or output recovery failed",
    ) as captured:
        session.diagnose_corrective_frame(document)

    assert capture_calls == 2
    assert session._poisoned is True
    assert session.process.killed is True
    assert captured.value.primary_error is primary
    assert captured.value.termination_error is None
    assert captured.value.capture_error is capture_recovery
    assert captured.value.cleanup_error is cleanup_recovery
    close.assert_called_once_with(binding)
