from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path
from types import SimpleNamespace
from typing import Mapping
from unittest import mock

import numpy as np
import pytest

from validation.calibration_v2.corrective_diagnostic_executor import (
    COORDINATE_ARTIFACT_NAME,
    ENVELOPE_NAME,
    RISK_ARTIFACT_NAME,
    CorrectiveDiagnosticExecutionError,
    CorrectiveDiagnosticExecutor,
    FAILURE_MANIFEST_NAME,
    JOURNAL_DIRECTORY_NAME,
    _CorrectiveExecutionJournal,
    publish_corrective_diagnostic_bundle,
)
from validation.calibration_v2.corrective_diagnostics import (
    ANISOTROPY_CELLS,
    COORDINATE_CELLS,
    RISK_THRESHOLD_BANDS,
    RISK_WEIGHT_PAIRS,
)
from validation.calibration_v2.tests.test_corrective_diagnostics import (
    coordinate_fixture,
    envelope_fixture,
    risk_fixture,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
from validation.quality.src.mirmir_quality.production_dry_run import (
    _planar_to_video_range_nv12,
)


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def assert_self_hash(document: dict[str, object], field: str) -> None:
    unsealed = dict(document)
    recorded = unsealed.pop(field)
    assert recorded == canonical_sha256(unsealed)


def frame(seed: int, *, height: int = 96, width: int = 96) -> PlanarFrame:
    y = np.linspace(0.1, 0.9, height * width, dtype=np.float64).reshape(
        height,
        width,
    )
    y = np.clip(y + seed * 0.0001, 0.0, 1.0)
    cb = np.full((height // 2, width // 2), 0.02 + seed * 0.0001)
    cr = np.full((height // 2, width // 2), -0.03 + seed * 0.0001)
    return PlanarFrame(y=y, cb=cb, cr=cr)


def rebind_sha(route: str, original: str) -> str:
    serialized = "half_pixel_center"
    applied = original != serialized
    payload = bytearray(
        b"MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0"
    )
    for value in (route, original, serialized):
        payload.extend(value.encode("utf-8"))
        payload.append(0)
    payload.append(1 if applied else 0)
    return hashlib.sha256(payload).hexdigest()


class FakeBound:
    def __init__(self, loaded: list[tuple[dict, PlanarFrame]]) -> None:
        samples = []
        profiles = []
        for index, (asset, target) in enumerate(loaded):
            route = "direct-2x" if index < 4 else "direct-3over2"
            samples.append(
                {
                    "source_asset_id": asset["source_asset_id"],
                    "target_route": route,
                    "target_frame_sha256": frame_sha256(target),
                }
            )
        for route in ("direct-2x", "direct-3over2"):
            for ordinal, kind in enumerate(
                (
                    "lowpass_decimate",
                    "camera_blur_decimate",
                    "codec_quantized_proxy",
                )
            ):
                profiles.append(
                    {
                        "id": f"{route}-profile-{ordinal}",
                        "kind": kind,
                        "target_route": route,
                    }
                )
        degradation = {"status": "locked", "profiles": profiles}
        degradation["policy_sha256"] = canonical_sha256(degradation)
        metric = {"status": "development_seed"}
        metric["policy_sha256"] = canonical_sha256(metric)
        self.documents = {
            "development_sample_lock": {
                "manifest_sha256": digest("development-manifest"),
                "samples": samples,
            },
            "corpus_lock": {"manifest_sha256": digest("corpus")},
            "degradation_policy": degradation,
            "metric_policy_seed": metric,
            "quality_harness_implementation_manifest": {
                "manifest_sha256": digest("quality-implementation")
            },
            "live_holdout_preopen_verification": {
                "verification_status": "pass",
                "access_status": "unopened",
                "access_count": 0,
                "open_intent_anchor_present": False,
                "pixel_content_included": False,
            },
        }
        self._records = {
            "development_sample_lock": {
                "sha256": digest("development-lock-file")
            },
            "quality_harness_implementation_manifest": {
                "sha256": digest("quality-implementation-file")
            },
        }
        self.verify_count = 0
        self.fail_at_verify: int | None = None

    def record(self, identifier: str) -> dict:
        return self._records[identifier]

    def verify_unchanged(self) -> None:
        self.verify_count += 1
        if self.fail_at_verify == self.verify_count:
            raise ValueError("live guard changed")


class FakeCache:
    def __init__(self, route_by_profile: dict[str, str]) -> None:
        self.route_by_profile = route_by_profile
        self.calls: list[tuple[str, str]] = []
        self.frames: dict[tuple[str, str], PlanarFrame] = {}

    def get_or_create(self, **kwargs: object) -> PlanarFrame:
        source_id = str(kwargs["source_asset_id"])
        profile_id = str(kwargs["profile_id"])
        key = (source_id, profile_id)
        self.calls.append(key)
        if key not in self.frames:
            route = self.route_by_profile[profile_id]
            target = kwargs["target_frame"]
            assert isinstance(target, PlanarFrame)
            ratio = 2 if route == "direct-2x" else 3 / 2
            height = int(target.y.shape[0] / ratio)
            width = int(target.y.shape[1] / ratio)
            self.frames[key] = frame(
                len(self.frames) + 20,
                height=height,
                width=width,
            )
        return self.frames[key]


class FakeWriter:
    settings_sha256 = digest("writer-settings")

    def __init__(self, *, interrupt_at: int | None = None) -> None:
        self.calls = 0
        self.interrupt_at = interrupt_at

    def round_trip(self, *, control_key: str, frame: PlanarFrame, context: object):
        self.calls += 1
        if self.interrupt_at == self.calls:
            raise KeyboardInterrupt()
        decoded = PlanarFrame(
            y=np.clip(frame.y * 0.999, 0.0, 1.0),
            cb=np.clip(frame.cb * 0.999, -0.5, 0.5),
            cr=np.clip(frame.cr * 0.999, -0.5, 0.5),
        )
        return SimpleNamespace(
            decoded_frame=decoded,
            evidence_sha256=digest(f"writer-{control_key}"),
        )


class FakeNative:
    def __init__(self, vector: dict[str, object], *, release_failure: bool = False) -> None:
        self.configuration = {
            "configuration_id": digest("configuration"),
            "serialized_candidate_vector_sha256": digest("candidate"),
            "candidate_vector": dict(vector),
            "compiler_inputs_sha256": digest("compiler"),
            "corpus_lock_bundle_sha256": digest("corpus-bundle"),
            "mapping_sha256": digest("mapping"),
            "shared_bank_configuration_sha256": digest("shared-bank"),
            "operator_bank_sha256": digest("operator-bank"),
            "metric_policy_sha256": digest("metric-policy"),
            "calibration_plan_sha256": digest("calibration-plan"),
            "candidate_lut_runtime_manifest_sha256": digest(
                "candidate-lut-runtime"
            ),
            "swift_cli": {
                "executable_sha256": digest("native-executable"),
                "source_manifest_sha256": digest("native-source"),
            },
        }
        self.calls: list[dict[str, object]] = []
        self.releases = 0
        self.release_failure = release_failure
        self.raw_by_request: dict[str, PlanarFrame] = {}
        self.output_manifests: dict[
            str,
            list[dict[str, object]],
        ] = {}

    def diagnose_corrective_frame(self, document: Mapping[str, object]):
        request = json.loads(json.dumps(document))
        self.calls.append(request)
        frame_request = request["frame"]
        route = str(frame_request["route"])
        contract_route = (
            "direct_2x" if route == "direct-2x" else "direct_3_over_2"
        )
        height = int(frame_request["output_height"])
        width = int(frame_request["output_width"])
        raw = frame(len(self.calls) + 40, height=height, width=width)
        self.raw_by_request[str(frame_request["request_id"])] = raw
        raw_payload = _planar_to_video_range_nv12(raw)
        raw_nv12_hash = hashlib.sha256(raw_payload).hexdigest()
        raw_frame_hash = frame_sha256(raw)
        original = str(
            self.configuration["candidate_vector"][
                f"{contract_route}_coordinate_policy"
            ]
        )
        descriptors = request["output_descriptors"]
        cells = []
        for descriptor in descriptors:
            ordinal = int(descriptor["ordinal"])
            coordinate = COORDINATE_CELLS[ordinal // 4]
            anisotropy = ANISOTROPY_CELLS[ordinal % 4]

            def plane(channel: str) -> dict[str, object]:
                luma = channel == "y"
                policy = (
                    coordinate["luma_coordinate_policy"]
                    if luma
                    else coordinate["chroma_coordinate_policy"]
                )
                strength = (
                    anisotropy["luma_anisotropy_strength_q12"]
                    if luma
                    else anisotropy["chroma_anisotropy_strength_q12"]
                )
                return {
                    "coordinate_policy": policy,
                    "anisotropy_strength_q12": strength,
                    "sample_count": width * height if luma else width * height // 4,
                    "output_plane_sha256": digest(
                        f"output-plane-{len(self.calls)}-{ordinal}-{channel}"
                    ),
                    "normalized_plane_sha256": digest(
                        f"normalized-plane-{len(self.calls)}-{ordinal}-{channel}"
                    ),
                    "source_aligned_entry_flag_sample_count": 0,
                    "source_aligned_sample_preservation_count": 0,
                    "numerical_fallback_count": 0,
                }

            cells.append(
                {
                    "ordinal": ordinal,
                    "block_id": (
                        f"{contract_route}-{coordinate['cell_id']}-"
                        f"{anisotropy['cell_id']}"
                    ),
                    "coordinate_cell_id": coordinate["cell_id"],
                    "anisotropy_cell_id": anisotropy["cell_id"],
                    "output_path": descriptor["output_path"],
                    "output_nv12_sha256": raw_nv12_hash,
                    "output_frame_sha256": raw_frame_hash,
                    "planes": {
                        channel: plane(channel) for channel in ("y", "cb", "cr")
                    },
                }
            )
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
                        f"risk-{len(self.calls)}-{ordinal}"
                    ),
                }
            )
        production_planes = {
            channel: {
                "output_plane_sha256": digest(
                    f"production-output-{len(self.calls)}-{channel}"
                ),
                "normalized_plane_sha256": digest(
                    f"production-normalized-{len(self.calls)}-{channel}"
                ),
            }
            for channel in ("y", "cb", "cr")
        }
        coordinate_contract = json.loads(
            Path(str(request["coordinate_model_contract_path"])).read_bytes()
        )
        diagnostic = {
            "schema_version": "1.0.0",
            "status": "development_diagnostic_no_selection",
            "split": "development",
            "validation_accessed": False,
            "holdout_accessed": False,
            "selected_winner": None,
            "request_id": frame_request["request_id"],
            "target_route": contract_route,
            "configuration_id": self.configuration["configuration_id"],
            "compiler_inputs_sha256": self.configuration[
                "compiler_inputs_sha256"
            ],
            "candidate_vector_sha256": self.configuration[
                "serialized_candidate_vector_sha256"
            ],
            "shared_bank_configuration_sha256": self.configuration[
                "shared_bank_configuration_sha256"
            ],
            "mapping_sha256": self.configuration["mapping_sha256"],
            "operator_bank_sha256": self.configuration[
                "operator_bank_sha256"
            ],
            "metric_policy_sha256": self.configuration[
                "metric_policy_sha256"
            ],
            "calibration_plan_sha256": self.configuration[
                "calibration_plan_sha256"
            ],
            "corpus_lock_bundle_sha256": self.configuration[
                "corpus_lock_bundle_sha256"
            ],
            "candidate_lut_runtime_manifest_sha256": self.configuration[
                "candidate_lut_runtime_manifest_sha256"
            ],
            "native_invocation_proof": {
                "protocol": "serve-candidate/diagnose_corrective_frame-v1",
                "process_id": 4242,
                "executable_sha256": self.configuration["swift_cli"][
                    "executable_sha256"
                ],
                "source_manifest_sha256": self.configuration["swift_cli"][
                    "source_manifest_sha256"
                ],
            },
            "input_sha256": frame_request["input_sha256"],
            "coordinate_model_contract_file_sha256": request[
                "coordinate_model_contract_sha256"
            ],
            "coordinate_oracle_matrix_sha256": canonical_sha256(
                coordinate_contract["coordinate_oracles"]
            ),
            "coordinate_experiment_dimensions_sha256": canonical_sha256(
                coordinate_contract["experiment_dimensions"]
            ),
            "analysis_grid_source_step": request[
                "analysis_grid_source_step"
            ],
            "analysis_cell_count": 4,
            "output_plane_hash_contract": "active-nv12-code-bytes-sha256-v1",
            "normalized_plane_hash_contract": (
                "mirmir-ash-normalized-plane-f64-be-v1"
            ),
            "analysis_grid_hash_contract": "mirmir-ash-analysis-grid-v3-be-v1",
            "analysis_grid_sha256": digest(
                f"analysis-grid-{len(self.calls)}"
            ),
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
            "generic_lut": {
                "whole_file_sha256": digest(f"generic-file-{contract_route}"),
                "payload_sha256": digest(f"generic-payload-{contract_route}"),
                "entry_count": 4096 if route == "direct-2x" else 9216,
                "serialization_rebind_contract": (
                    "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
                ),
                "original_coordinate_policy": original,
                "serialized_coordinate_policy": "half_pixel_center",
                "serialization_rebind_applied": original != "half_pixel_center",
                "serialization_rebind_sha256": rebind_sha(
                    contract_route,
                    original,
                ),
            },
            "production_v2_reference": {
                "output_path": request["production_v2_reference_output_path"],
                "output_nv12_sha256": raw_nv12_hash,
                "output_frame_sha256": raw_frame_hash,
                "planes": production_planes,
                "lut_whole_file_sha256": digest(
                    f"production-file-{contract_route}"
                ),
                "lut_payload_sha256": digest(
                    f"production-payload-{contract_route}"
                ),
                "lut_entry_count": 4096 if route == "direct-2x" else 9216,
            },
            "cells": cells,
            "risk_state": {
                "analysis_grid_source_step": 1,
                "analysis_cell_count": 4,
                "baseline_analysis_grid_sha256": digest(
                    f"analysis-grid-{len(self.calls)}"
                ),
                "cells": risk_cells,
            },
        }
        output_manifest = [
            {
                "original_name": Path(str(descriptor["output_path"])).name,
                "sha256": cell["output_nv12_sha256"],
                "size_bytes": len(raw_payload),
            }
            for descriptor, cell in zip(descriptors, cells)
        ]
        output_manifest.append(
            {
                "original_name": Path(
                    str(request["production_v2_reference_output_path"])
                ).name,
                "sha256": diagnostic["production_v2_reference"][
                    "output_nv12_sha256"
                ],
                "size_bytes": len(raw_payload),
            }
        )
        output_manifest.sort(key=lambda row: str(row["original_name"]))
        self.output_manifests[str(frame_request["request_id"])] = output_manifest
        return {
            "schema_version": "1.0.0",
            "status": "ok",
            "request_sha256": canonical_sha256(request),
            "corrective_diagnostic": diagnostic,
        }

    def reopen_corrective_frame_output(
        self,
        document: Mapping[str, object],
        path: Path,
        *,
        width: int,
        height: int,
    ) -> PlanarFrame:
        request_id = str(document["frame"]["request_id"])
        return self.raw_by_request[request_id]

    def release_corrective_frame_outputs(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        self.releases += 1
        if self.release_failure:
            raise ValueError("release tamper")
        empty_sha256 = hashlib.sha256(b"").hexdigest()
        output_manifest = self.output_manifests[
            str(document["frame"]["request_id"])
        ]
        output_root = Path(
            str(document["production_v2_reference_output_path"])
        ).parent
        retained = output_root.parent / (
            f".synthetic-native-sanitized-{self.releases:02d}"
        )
        retained.mkdir(mode=0o700)
        retained_stubs = []
        for ordinal, original_output in enumerate(output_manifest):
            retained_name = f".owned-sanitized-stub-{ordinal:02d}"
            retained_path = retained / retained_name
            retained_path.write_bytes(b"")
            metadata = retained_path.stat()
            retained_stubs.append(
                {
                    "original_name": original_output["original_name"],
                    "retained_name": retained_name,
                    "device": metadata.st_dev,
                    "inode": metadata.st_ino,
                    "size_bytes": metadata.st_size,
                    "sha256": empty_sha256,
                }
            )
        retained_metadata = retained.stat()
        return {
            "status": "sanitized_retained",
            "retained_transaction_path": str(retained),
            "retained_transaction_identity": {
                "device": retained_metadata.st_dev,
                "inode": retained_metadata.st_ino,
            },
            "retained_stub_count": 17,
            "retained_stubs": retained_stubs,
            "retained_stub_manifest_sha256": canonical_sha256(
                retained_stubs
            ),
            "original_output_manifest_sha256": canonical_sha256(
                output_manifest
            ),
        }


def fake_metrics(*_: object, **__: object) -> dict[str, object]:
    return {
        "y_psnr_db": 40.0,
        "cb_psnr_db": 41.0,
        "cr_psnr_db": 42.0,
        "y_ssim": 0.99,
        "cb_ssim": 0.98,
        "cr_ssim": 0.97,
        "y_ms_ssim": 0.96,
        "cb_ms_ssim": 0.95,
        "cr_ms_ssim": 0.94,
        "writer_y_psnr_contribution_db": None,
    }


def make_executor(tmp_path: Path, *, writer: FakeWriter, release_failure: bool = False):
    loaded = []
    for index in range(6):
        loaded.append(
            (
                {
                    "source_asset_id": f"development-{index}",
                    "source_family_id": f"family-{index}",
                    "categories": [f"category-{index}"],
                },
                frame(index),
            )
        )
    bound = FakeBound(loaded)
    route_by_profile = {
        str(profile["id"]): str(profile["target_route"])
        for profile in bound.documents["degradation_policy"]["profiles"]
    }
    cache = FakeCache(route_by_profile)
    vector = {
        "direct_2x_analysis_grid_source_step": 1,
        "direct_3_over_2_analysis_grid_source_step": 1,
        "direct_2x_coordinate_policy": "source_aligned_rational",
        "direct_3_over_2_coordinate_policy": "source_aligned_rational",
    }
    native = FakeNative(vector, release_failure=release_failure)
    executor = CorrectiveDiagnosticExecutor(
        repository_root=Path(__file__).resolve().parents[3],
        output_root=tmp_path / "published",
        work_parent=tmp_path,
        bound_inputs=bound,
        loaded_development_samples=loaded,
        degradation_cache=cache,  # type: ignore[arg-type]
        native=native,
        writer=writer,  # type: ignore[arg-type]
        candidate_vector=vector,
        coordinate_contract_path=(
            Path(__file__).resolve().parents[1]
            / "contracts/coordinate-model-contract-v3.json"
        ),
        video_profile_contract_path=(
            Path(__file__).resolve().parents[1]
            / "contracts/video-profile-contract-v1.json"
        ),
        g04_lock_file_sha256=digest("g04"),
        g05_lock_file_sha256=digest("g05"),
        corrective_preregistration_file_sha256=digest(
            "corrective-preregistration-file"
        ),
        corrective_preregistration_sha256=digest(
            "corrective-preregistration"
        ),
    )
    return executor, bound, cache, native


def test_executor_uses_one_native_call_per_development_frame_route_and_two_domains(
    tmp_path: Path,
) -> None:
    writer = FakeWriter()
    executor, bound, cache, native = make_executor(tmp_path, writer=writer)
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ):
        published = executor.run()

    assert published == tmp_path / "published"
    assert len(native.calls) == 18
    assert native.releases == 18
    assert len(cache.calls) == 18
    assert len(set(cache.calls)) == 18
    assert writer.calls == 18 * 17
    assert bound.verify_count == 40
    coordinate = json.loads((published / COORDINATE_ARTIFACT_NAME).read_bytes())
    risk = json.loads((published / RISK_ARTIFACT_NAME).read_bytes())
    envelope = json.loads((published / ENVELOPE_NAME).read_bytes())
    assert len(coordinate["route_cell_blocks"]) == 32
    assert len(coordinate["full_corpus_compositions"]) == 31
    assert all(
        len(block["observations"])
        == (12 if block["target_route"] == "direct_2x" else 6)
        for block in coordinate["route_cell_blocks"]
    )
    assert len(coordinate["production_v2_reference"]["observations"]) == 18
    assert len(risk["frame_route_records"]) == 18
    assert all(len(record["cells"]) == 30 for record in risk["frame_route_records"])
    assert coordinate["selected_winner"] is None
    assert risk["selected_winner"] is None
    assert envelope["selected_winner"] is None
    assert [
        row["comparison_domain"]
        for row in coordinate["route_cell_blocks"][0]["observations"][0][
            "metric_rows"
        ]
    ] == ["engine_raw", "container_decoded"]
    completed = executor.completed_evidence_path
    assert completed is not None and completed.is_dir()
    assert completed.parent == tmp_path
    assert completed.name.startswith(".mirmir-corrective-execution-")
    assert list(tmp_path.glob(".mirmir-corrective-execution-*")) == [completed]
    completed_binding = executor.completed_evidence_binding
    assert isinstance(completed_binding, dict)
    assert_self_hash(
        completed_binding,
        "completed_evidence_binding_sha256",
    )
    assert completed_binding["work_root_path"] == str(completed)
    assert completed_binding["prepublication_execution_closure"] == coordinate[
        "input_bindings"
    ]["completed_execution_evidence"]
    publication_receipt = json.loads(
        (completed / "executor-publication-receipt.json").read_bytes()
    )
    assert_self_hash(publication_receipt, "receipt_sha256")
    assert publication_receipt["status"] == (
        "executor_publication_validated_pending_cli_resource_close"
    )
    input_receipt = json.loads(
        (completed / "input-sanitation-receipt.json").read_bytes()
    )
    assert_self_hash(input_receipt, "receipt_sha256")
    assert input_receipt["status"] == "sanitized_retained"
    retained_inputs = completed / "inputs"
    assert input_receipt["retained_stub_count"] == len(
        list(retained_inputs.iterdir())
    )
    assert all(path.stat().st_size == 0 for path in retained_inputs.iterdir())


def test_executor_releases_and_preserves_work_on_writer_interruption(
    tmp_path: Path,
) -> None:
    writer = FakeWriter(interrupt_at=1)
    executor, _, _, native = make_executor(tmp_path, writer=writer)
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ), pytest.raises(KeyboardInterrupt) as captured:
        executor.run()
    assert native.releases == 1
    assert not (tmp_path / "published").exists()
    preserved = captured.value.preserved_work_path
    assert preserved.is_dir()
    failure = json.loads((preserved / FAILURE_MANIFEST_NAME).read_bytes())
    assert_self_hash(failure, "failure_record_sha256")
    assert failure["journal_entry_count"] == 0
    assert failure["completed_call_count"] == 0
    assert failure["outputs_cleanup_state"] == "sanitized_retained"
    assert failure["validation_accessed"] is False
    assert failure["holdout_accessed"] is False
    shutil.rmtree(preserved)


def test_executor_preserves_work_when_native_release_reports_tamper(tmp_path: Path) -> None:
    writer = FakeWriter()
    executor, _, _, native = make_executor(
        tmp_path,
        writer=writer,
        release_failure=True,
    )
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ), pytest.raises(ValueError, match="release tamper") as captured:
        executor.run()
    assert native.releases == 1
    preserved = captured.value.preserved_work_path
    assert preserved.is_dir()
    failure = json.loads((preserved / FAILURE_MANIFEST_NAME).read_bytes())
    assert_self_hash(failure, "failure_record_sha256")
    assert failure["journal_entry_count"] == 1
    assert failure["journal_evidence_count"] == 1
    assert failure["completed_call_count"] == 0
    assert failure["outputs_cleanup_state"] == "failed"
    journal_entries = sorted((preserved / JOURNAL_DIRECTORY_NAME).iterdir())
    assert len(journal_entries) == 1
    entry = json.loads(journal_entries[0].read_bytes())
    assert_self_hash(entry, "entry_sha256")
    assert entry["entry_sha256"] == failure["journal_tail_sha256"]
    shutil.rmtree(preserved)


def test_failure_manifest_binds_completed_hash_chain_and_fresh_guard(
    tmp_path: Path,
) -> None:
    writer = FakeWriter(interrupt_at=18)
    executor, bound, _, native = make_executor(tmp_path, writer=writer)
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ), pytest.raises(KeyboardInterrupt) as captured:
        executor.run()

    assert native.releases == 2
    preserved = captured.value.preserved_work_path
    failure = json.loads((preserved / FAILURE_MANIFEST_NAME).read_bytes())
    assert_self_hash(failure, "failure_record_sha256")
    assert failure["journal_entry_count"] == 2
    assert failure["journal_evidence_count"] == 1
    assert failure["completed_call_count"] == 1
    assert failure["outputs_cleanup_state"] == "sanitized_retained"
    assert failure["guard_evidence"]["verify_unchanged_status"] == "pass"
    assert failure["guard_verification_count"] == bound.verify_count
    entries = [
        json.loads(path.read_bytes())
        for path in sorted((preserved / JOURNAL_DIRECTORY_NAME).iterdir())
    ]
    previous = _CorrectiveExecutionJournal._GENESIS_SHA256
    for ordinal, entry in enumerate(entries):
        assert entry["sequence_ordinal"] == ordinal
        assert entry["request_ordinal"] == 0
        assert entry["previous_entry_sha256"] == previous
        assert_self_hash(entry, "entry_sha256")
        previous = entry["entry_sha256"]
    assert previous == failure["journal_tail_sha256"]
    assert entries[0]["entry_kind"] == "call-evidence"
    assert len(entries[0]["evidence"]["coordinate_observations"]) == 16
    assert len(
        entries[0]["evidence"]["production_v2_observation"]["metric_rows"]
    ) == 2
    assert entries[1]["evidence"]["output_cleanup_status"] == "sanitized_retained"
    assert entries[1]["evidence"]["native_cleanup_receipt"][
        "retained_stub_count"
    ] == 17
    shutil.rmtree(preserved)


def test_full_journal_reopen_rejects_tamper_before_publication(
    tmp_path: Path,
) -> None:
    writer = FakeWriter()
    executor, _, _, _ = make_executor(tmp_path, writer=writer)
    original = _CorrectiveExecutionJournal.validate_complete

    def tamper_then_validate(
        journal: _CorrectiveExecutionJournal,
        expected: object,
    ) -> None:
        first = journal.paths[0]
        first.write_bytes(first.read_bytes() + b" ")
        original(journal, expected)  # type: ignore[arg-type]

    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ), mock.patch.object(
        _CorrectiveExecutionJournal,
        "validate_complete",
        autospec=True,
        side_effect=tamper_then_validate,
    ), pytest.raises(CorrectiveDiagnosticExecutionError) as captured:
        executor.run()

    assert not (tmp_path / "published").exists()
    preserved = captured.value.preserved_work_path
    failure = json.loads((preserved / FAILURE_MANIFEST_NAME).read_bytes())
    assert failure["completed_call_count"] == 18
    assert failure["journal_entry_count"] == 36
    assert failure["error_chain"][0]["error_type"].endswith(
        "CorrectiveDiagnosticExecutionError"
    )
    shutil.rmtree(preserved)


def test_precommit_guard_failure_never_publishes_success_bundle(
    tmp_path: Path,
) -> None:
    writer = FakeWriter()
    executor, bound, _, _ = make_executor(tmp_path, writer=writer)
    bound.fail_at_verify = 39
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ), pytest.raises(ValueError, match="live guard changed") as captured:
        executor.run()

    assert not (tmp_path / "published").exists()
    preserved = captured.value.preserved_work_path
    failure = json.loads((preserved / FAILURE_MANIFEST_NAME).read_bytes())
    assert failure["guard_evidence"]["verify_unchanged_status"] == "pass"
    assert failure["published_bundle_state"] == "not_published"
    assert failure["completed_call_count"] == 18
    assert not list(tmp_path.glob(".published.mirmir-uncommitted-*"))
    shutil.rmtree(preserved)


def test_postpublication_completion_finalization_failure_quarantines_bundle_and_records_failure(
    tmp_path: Path,
) -> None:
    writer = FakeWriter()
    executor, _, _, _ = make_executor(tmp_path, writer=writer)
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._finalize_completed_execution_evidence",
        side_effect=OSError("completion finalization failed"),
    ), pytest.raises(
        CorrectiveDiagnosticExecutionError,
        match="completion evidence finalization failed",
    ) as captured:
        executor.run()

    assert not (tmp_path / "published").exists()
    quarantines = list(tmp_path.glob(".published.mirmir-untrusted-*"))
    assert len(quarantines) == 1
    preserved = captured.value.preserved_work_path
    failure = json.loads((preserved / FAILURE_MANIFEST_NAME).read_bytes())
    assert_self_hash(failure, "failure_record_sha256")
    assert failure["published_bundle_state"] == "quarantined_untrusted"
    assert failure["untrusted_bundle_path"] == str(quarantines[0])
    assert failure["completed_call_count"] == 18
    shutil.rmtree(preserved)
    shutil.rmtree(quarantines[0])


def test_postcommit_guard_failure_quarantines_success_name_and_records_failure(
    tmp_path: Path,
) -> None:
    writer = FakeWriter()
    executor, bound, _, _ = make_executor(tmp_path, writer=writer)
    bound.fail_at_verify = 40
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor.corpus_metric_bundle",
        side_effect=fake_metrics,
    ), mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._validate_writer_round_trip",
        side_effect=lambda **kwargs: kwargs["result"].decoded_frame,
    ), pytest.raises(ValueError, match="live guard changed") as captured:
        executor.run()

    assert not (tmp_path / "published").exists()
    quarantines = list(tmp_path.glob(".published.mirmir-untrusted-*"))
    assert len(quarantines) == 1
    preserved = captured.value.preserved_work_path
    failure = json.loads((preserved / FAILURE_MANIFEST_NAME).read_bytes())
    assert_self_hash(failure, "failure_record_sha256")
    assert failure["published_bundle_state"] == "quarantined_untrusted"
    assert failure["untrusted_bundle_path"] == str(quarantines[0])
    assert failure["completed_call_count"] == 18
    shutil.rmtree(preserved)
    shutil.rmtree(quarantines[0])


def test_bundle_publication_is_no_overwrite_and_cleans_interrupted_staging(
    tmp_path: Path,
) -> None:
    coordinate = coordinate_fixture()
    risk = risk_fixture()
    envelope = envelope_fixture(coordinate, risk)
    destination = tmp_path / "bundle"
    publish_corrective_diagnostic_bundle(
        destination,
        coordinate_artifact=coordinate,
        risk_artifact=risk,
        envelope=envelope,
    )
    with pytest.raises(FileExistsError):
        publish_corrective_diagnostic_bundle(
            destination,
            coordinate_artifact=coordinate,
            risk_artifact=risk,
            envelope=envelope,
        )
    assert not list(tmp_path.glob(".bundle.mirmir-uncommitted-*"))

    interrupted = tmp_path / "interrupted"
    with mock.patch(
        "validation.calibration_v2.corrective_diagnostic_executor._write_new_regular",
        side_effect=KeyboardInterrupt(),
    ), pytest.raises(KeyboardInterrupt):
        publish_corrective_diagnostic_bundle(
            interrupted,
            coordinate_artifact=coordinate,
            risk_artifact=risk,
            envelope=envelope,
        )
    assert not interrupted.exists()
    assert not list(tmp_path.glob(".interrupted.mirmir-uncommitted-*"))


def test_executor_module_has_no_validation_or_holdout_pixel_loader_dependency() -> None:
    source = (
        Path(__file__).resolve().parents[1]
        / "corrective_diagnostic_executor.py"
    ).read_text(encoding="utf-8")
    forbidden = "load_" + "validation_samples"
    assert forbidden not in source
    assert "load_sample_split" not in source
    assert "load_holdout" not in source
