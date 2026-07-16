from __future__ import annotations

import hashlib
import json
from pathlib import Path
from copy import deepcopy

import numpy as np
import pytest

from validation.calibration_v2.production_evaluator import (
    ControlWriterSemanticContextV2,
    ProductionEvaluatorError,
    WriterRoundTrip,
    canonical_control_measurement_frame_bytes_v2,
    _validate_writer_round_trip,
)
from validation.calibration_v2.control_authorization_v2 import (
    CONTROL_WRITER_EVIDENCE_BYTES_KIND,
    OUTPUT_MANIFEST_KIND,
    TypedArtifactBindingV2,
    canonical_json_bytes_v2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.production_providers import (
    NativeProductionWriterCapability,
    _normalize_decoded_video_range_nv12,
    _video_range_nv12_to_planar,
    production_writer_settings_document,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.common_writer import (
    PRODUCT_MEDIA_TYPES_PATH,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateContext,
    _planar_to_video_range_nv12,
)


def test_decoded_writer_payload_is_clipped_to_nominal_video_range_with_counts() -> None:
    payload = bytes(
        (
            0,
            15,
            16,
            235,
            236,
            255,
            100,
            200,
            0,
            0,
            255,
            255,
        )
    )
    normalized, evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=4,
        height=2,
    )
    second_normalized, second_evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=4,
        height=2,
    )

    assert normalized == bytes(
        (16, 16, 16, 235, 235, 235, 100, 200, 16, 16, 240, 240)
    )
    assert (second_normalized, second_evidence) == (normalized, evidence)
    assert evidence == {
        "method": "nominal_video_range_clip_v1",
        "nominal_y_code_range": [16, 235],
        "nominal_chroma_code_range": [16, 240],
        "raw_code_ranges": {
            "y": [0, 255],
            "cb": [0, 255],
            "cr": [0, 255],
        },
        "normalized_code_ranges": {
            "y": [16, 235],
            "cb": [16, 240],
            "cr": [16, 240],
        },
        "clipped_sample_counts": {
            "y_below_16": 2,
            "y_above_235": 2,
            "cb_below_16": 1,
            "cb_above_240": 1,
            "cr_below_16": 1,
            "cr_above_240": 1,
        },
        "total_clipped_sample_count": 8,
    }


def test_decoded_writer_payload_preserves_already_legal_bytes() -> None:
    payload = bytes((16, 17, 234, 235, 16, 240))
    normalized, evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=2,
        height=2,
    )

    assert normalized == payload
    assert evidence["total_clipped_sample_count"] == 0


def test_decoded_writer_normalization_preserves_chroma_interleave_positions() -> None:
    payload = bytes((16, 17, 18, 19, 20, 21, 22, 23, 0, 250, 245, 10))
    normalized, evidence = _normalize_decoded_video_range_nv12(
        payload,
        width=4,
        height=2,
    )

    assert normalized[:8] == payload[:8]
    assert normalized[8:][0::2] == bytes((16, 240))
    assert normalized[8:][1::2] == bytes((240, 16))
    assert evidence["clipped_sample_counts"] == {
        "y_below_16": 0,
        "y_above_235": 0,
        "cb_below_16": 1,
        "cb_above_240": 1,
        "cr_below_16": 1,
        "cr_above_240": 1,
    }


@pytest.mark.parametrize(
    ("payload", "width", "height"),
    (
        (bytes(6), 3, 2),
        (bytes(6), 2, 0),
        (bytes(5), 2, 2),
    ),
)
def test_decoded_writer_normalization_rejects_invalid_geometry(
    payload: bytes,
    width: int,
    height: int,
) -> None:
    with pytest.raises(ProductionEvaluatorError):
        _normalize_decoded_video_range_nv12(
            payload,
            width=width,
            height=height,
        )


def test_writer_normalization_evidence_propagates_to_candidate_boundary(
    tmp_path: Path,
) -> None:
    writer = object.__new__(NativeProductionWriterCapability)
    writer._root = tmp_path
    writer._runs = tmp_path / "runs"
    writer._evidence = tmp_path / "evidence"
    writer._runs.mkdir()
    writer._evidence.mkdir()
    writer._settings = {
        "writer_id": "mirmir-product-hevc-avassetwriter-v1",
        "isolation": "one_frame_per_container",
        "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
        "decoded_pixel_normalization": {
            "scope": (
                "reopened isolated production HEVC writer 420v bytes before "
                "PlanarFrame conversion and container-decoded metrics only"
            ),
            "method": "nominal_video_range_clip_v1",
            "nominal_y_code_range": [16, 235],
            "nominal_chroma_code_range": [16, 240],
            "evidence": (
                "bind raw and normalized payload SHA-256 values and sizes, "
                "raw and normalized per-plane code ranges, and exact "
                "six-direction clip counts"
            ),
            "engine_raw_affected": False,
            "uniform_application": (
                "apply identically to every candidate, baseline, fixed "
                "operator, and ablation container-decoded output"
            ),
        },
        "executable_sha256": "1" * 64,
        "product_settings_source_sha256": "2" * 64,
    }
    writer.settings_sha256 = canonical_sha256(writer._settings)
    frame = PlanarFrame(
        y=np.full((2, 2), (100.0 - 16.0) / 219.0),
        cb=np.full((1, 1), (128.0 - 16.0) / 224.0 - 0.5),
        cr=np.full((1, 1), (128.0 - 16.0) / 224.0 - 0.5),
    )
    context = CandidateContext(
        y_shape=(2, 2),
        cb_shape=(1, 1),
        cr_shape=(1, 1),
        target_route="direct-2x",
    )
    input_sha256 = frame_sha256(frame)
    run_key = canonical_sha256(
        {
            "control_key": "focused-control",
            "input_frame_sha256": input_sha256,
            "settings_sha256": writer.settings_sha256,
            "target_route": context.target_route,
            "y_shape": [2, 2],
            "cb_shape": [1, 1],
            "cr_shape": [1, 1],
        }
    )
    paths = writer._paths(run_key)
    paths["decoded_root"].mkdir(parents=True)
    raw_decoded = bytes((16, 100, 235, 236, 128, 128))
    decoded_path = paths["decoded_root"] / "frame-000000.nv12"
    decoded_path.write_bytes(raw_decoded)
    paths["source"].write_bytes(_planar_to_video_range_nv12(frame))
    paths["source_lock"].write_bytes(b"source-lock")
    paths["encoded"].write_bytes(b"encoded")
    report = {
        "artifact_kind": "production_writer_actual_codec",
        "encoder": {
            "product_settings_source": {
                "sha256": writer._settings["product_settings_source_sha256"]
            }
        },
        "encoded": {
            "sha256": hashlib.sha256(b"encoded").hexdigest(),
        },
        "decoder": {
            "frames": [
                {
                    "payload_path": decoded_path.name,
                    "payload_size_bytes": len(raw_decoded),
                    "payload_sha256": hashlib.sha256(raw_decoded).hexdigest(),
                }
            ]
        },
    }
    paths["report"].write_text(
        json.dumps(report, sort_keys=True),
        encoding="utf-8",
    )

    result = writer.round_trip(
        control_key="focused-control",
        frame=frame,
        context=context,
    )
    decoded = _validate_writer_round_trip(
        writer=writer,
        result=result,
        control_key="focused-control",
        raw_frame=frame,
        context=context,
    )
    evidence = writer.reopen_evidence(result.evidence_sha256)

    assert float(np.max(decoded.y)) == 1.0
    assert evidence["raw_decoded_payload_sha256"] == hashlib.sha256(
        raw_decoded
    ).hexdigest()
    assert evidence["raw_decoded_payload_size_bytes"] == len(raw_decoded)
    assert evidence["normalized_decoded_payload_size_bytes"] == len(raw_decoded)
    assert evidence["decoder_legal_range_normalization"][
        "clipped_sample_counts"
    ]["y_above_235"] == 1
    assert evidence["decoder_legal_range_normalization"][
        "raw_code_ranges"
    ]["y"] == [16, 236]
    assert evidence["decoder_legal_range_normalization"][
        "normalized_code_ranges"
    ]["y"] == [16, 235]
    assert evidence["comparison_domain"] == "container_decoded"
    assert evidence["decoded_pixel_normalization"] == writer._settings[
        "decoded_pixel_normalization"
    ]
    assert evidence["decoded_pixel_normalization"]["engine_raw_affected"] is False
    assert result.evidence_sha256 == canonical_sha256(evidence)


def test_control_writer_restart_reopens_receipt_and_rejects_forged_substitution(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable = tmp_path / "locked-production-writer"
    executable.write_bytes(b"locked-production-writer-test-binary")
    executable_sha256 = hashlib.sha256(executable.read_bytes()).hexdigest()
    settings_source_sha256 = hashlib.sha256(
        PRODUCT_MEDIA_TYPES_PATH.read_bytes()
    ).hexdigest()
    settings = production_writer_settings_document(
        executable_sha256=executable_sha256,
        product_settings_source_sha256=settings_source_sha256,
    )
    settings_sha256 = canonical_sha256(settings)
    evidence_root = tmp_path / "writer-evidence"

    def restarted_writer() -> NativeProductionWriterCapability:
        writer = object.__new__(NativeProductionWriterCapability)
        writer._root = evidence_root
        writer._runs = evidence_root / "runs"
        writer._evidence = evidence_root / "evidence"
        writer._runs.mkdir(parents=True, exist_ok=True)
        writer._evidence.mkdir(parents=True, exist_ok=True)
        writer._executable = executable
        writer._authorized_execution = object()
        writer._settings = settings
        writer.settings_sha256 = settings_sha256
        return writer

    producer = restarted_writer()
    raw = PlanarFrame(
        y=np.full((4, 4), (100.0 - 16.0) / 219.0),
        cb=np.full((2, 2), (128.0 - 16.0) / 224.0 - 0.5),
        cr=np.full((2, 2), (128.0 - 16.0) / 224.0 - 0.5),
    )
    decoded_payload = _planar_to_video_range_nv12(raw)
    normalized_payload, normalization = _normalize_decoded_video_range_nv12(
        decoded_payload,
        width=4,
        height=4,
    )
    decoded = _video_range_nv12_to_planar(
        normalized_payload,
        width=4,
        height=4,
    )
    encoded_payload = b"nondeterministic-original-container"
    encoded_sha256 = hashlib.sha256(encoded_payload).hexdigest()
    decoded_payload_sha256 = hashlib.sha256(decoded_payload).hexdigest()
    report = {
        "artifact_kind": "production_writer_actual_codec",
        "encoder": {
            "product_settings_source": {
                "sha256": settings_source_sha256,
            }
        },
        "encoded": {"sha256": encoded_sha256},
        "decoder": {
            "frames": [
                {
                    "payload_sha256": decoded_payload_sha256,
                    "payload_size_bytes": len(decoded_payload),
                }
            ]
        },
    }
    report_payload = canonical_json_bytes(report)
    report_sha256 = hashlib.sha256(report_payload).hexdigest()
    native_record = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_isolated_production_writer_evidence",
        "control_key": "restart-control",
        "input_frame_sha256": frame_sha256(raw),
        "decoded_frame_sha256": frame_sha256(decoded),
        "settings_sha256": settings_sha256,
        "encoded_sha256": encoded_sha256,
        "report_sha256": report_sha256,
        "source_payload_sha256": "5" * 64,
        "source_lock_sha256": "6" * 64,
        "decoded_payload_sha256": decoded_payload_sha256,
        "raw_decoded_payload_sha256": decoded_payload_sha256,
        "raw_decoded_payload_size_bytes": len(decoded_payload),
        "normalized_decoded_payload_sha256": hashlib.sha256(
            normalized_payload
        ).hexdigest(),
        "normalized_decoded_payload_size_bytes": len(normalized_payload),
        "decoded_pixel_normalization": settings[
            "decoded_pixel_normalization"
        ],
        "decoder_legal_range_normalization": normalization,
        "comparison_domain": "container_decoded",
        "target_route": "direct-2x",
        "reopened_and_verified": True,
    }
    native_record_sha256 = canonical_sha256(native_record)
    (producer._evidence / f"{native_record_sha256}.json").write_bytes(
        canonical_json_bytes(native_record)
    )

    restarted = restarted_writer()
    producer_identity = restarted.control_writer_producer_identity_v2()
    output_schema = schema_sha256_for_kind_v2(OUTPUT_MANIFEST_KIND)

    def binding(kind: str, payload: bytes, path: str) -> dict[str, object]:
        return TypedArtifactBindingV2(
            artifact_kind=kind,
            schema_sha256=output_schema,
            path=path,
            sha256=hashlib.sha256(payload).hexdigest(),
            size_bytes=len(payload),
        ).as_document()

    raw_payload = canonical_control_measurement_frame_bytes_v2(raw)
    decoded_frame_payload = canonical_control_measurement_frame_bytes_v2(decoded)
    writer_identity = json.loads(
        producer_identity.authenticated_writer_identity_bytes
    )
    source_profile = {
        "source_asset_id": "restart-source",
        "source_family_id": "restart-family",
        "categories": ["natural"],
        "target_route": "direct-2x",
        "degradation_profile_id": "restart-profile",
        "degradation_profile_sha256": "7" * 64,
        "source_target_provenance": binding(
            "p06_control_source_target_provenance_v2",
            b"source-provenance",
            "source/provenance.json",
        ),
        "degradation_profile": binding(
            "p06_control_degradation_profile_v2",
            b"profile",
            "profiles/profile.json",
        ),
    }
    document = {
        "schema_version": "2.0.0",
        "artifact_kind": CONTROL_WRITER_EVIDENCE_BYTES_KIND,
        "source_profile_identity_sha256": canonical_sha256(source_profile),
        "target_route": "direct-2x",
        "control_key": "restart-control",
        "raw_output": binding(
            "p06_control_output_bytes_v2",
            raw_payload,
            "outputs/raw.bin",
        ),
        "raw_output_frame_sha256": frame_sha256(raw),
        "decoded_output": binding(
            "p06_control_output_bytes_v2",
            decoded_frame_payload,
            "outputs/decoded.bin",
        ),
        "decoded_output_frame_sha256": frame_sha256(decoded),
        "writer_settings": settings,
        "writer_settings_sha256": settings_sha256,
        "authenticated_writer_identity": writer_identity,
        "encoded_container": binding(
            "p06_control_writer_encoded_container_bytes_v2",
            encoded_payload,
            "writer/encoded.bin",
        ),
        "encoded_container_sha256": encoded_sha256,
        "writer_report": binding(
            "p06_control_writer_report_bytes_v2",
            report_payload,
            "writer/report.json",
        ),
        "writer_report_sha256": report_sha256,
        "decoded_payload": binding(
            "p06_control_writer_decoded_payload_bytes_v2",
            decoded_payload,
            "writer/decoded.nv12",
        ),
        "decoded_payload_sha256": decoded_payload_sha256,
        "native_writer_round_trip_record": native_record,
        "native_writer_round_trip_record_sha256": native_record_sha256,
    }
    document_payload = canonical_json_bytes_v2(document)
    document_binding = TypedArtifactBindingV2(
        artifact_kind=CONTROL_WRITER_EVIDENCE_BYTES_KIND,
        schema_sha256=output_schema,
        path="writer/provenance.json",
        sha256=hashlib.sha256(document_payload).hexdigest(),
        size_bytes=len(document_payload),
    )
    request = {
        "control_key": "restart-control",
        "configuration_sha256": "8" * 64,
    }
    scope = {"control_configuration_sha256": "8" * 64}
    degradation_profile = {
        "schema_version": "2.0.0",
        "artifact_kind": "p06_control_degradation_profile_v2",
        "degradation_policy_sha256": "9" * 64,
        "degradation_profile_id": "restart-profile",
        "profile_definition": {
            "id": "restart-profile",
            "target_route": "direct-2x",
        },
    }
    context = ControlWriterSemanticContextV2(
        expected_scope_bytes=canonical_json_bytes_v2(scope),
        expected_control_request_bytes=canonical_json_bytes_v2(request),
        source_profile_identity_bytes=canonical_json_bytes_v2(source_profile),
        degradation_profile_bytes=canonical_json_bytes_v2(degradation_profile),
        raw_output_frame_bytes=raw_payload,
        decoded_output_frame_bytes=decoded_frame_payload,
        decoded_payload_bytes=decoded_payload,
        encoded_container_bytes=encoded_payload,
        writer_report_bytes=report_payload,
        writer_provenance_bytes=document_payload,
        writer_settings_bytes=producer_identity.writer_settings_bytes,
        writer_settings_sha256=producer_identity.writer_settings_sha256,
        authenticated_writer_identity_bytes=(
            producer_identity.authenticated_writer_identity_bytes
        ),
    )

    replay_record = dict(native_record)
    replay_record["encoded_sha256"] = "a" * 64
    replay_record["report_sha256"] = "b" * 64
    original_reopen = NativeProductionWriterCapability.reopen_evidence

    def replay_round_trip(self, **kwargs):
        return WriterRoundTrip(
            decoded_frame=decoded,
            input_frame_sha256=frame_sha256(raw),
            decoded_frame_sha256=frame_sha256(decoded),
            settings_sha256=settings_sha256,
            encoded_sha256="a" * 64,
            report_sha256="b" * 64,
            evidence_sha256=canonical_sha256(replay_record),
            reopened_and_verified=True,
        )

    def reopen_evidence(self, evidence_sha256: str):
        if self is restarted:
            return original_reopen(self, evidence_sha256)
        return deepcopy(replay_record)

    monkeypatch.setattr(
        NativeProductionWriterCapability,
        "round_trip",
        replay_round_trip,
    )
    monkeypatch.setattr(
        NativeProductionWriterCapability,
        "reopen_evidence",
        reopen_evidence,
    )
    assert restarted.control_writer_semantic_verifier(
        document_binding,
        document,
        context,
    ) == document

    forged = deepcopy(document)
    forged_record = deepcopy(native_record)
    forged_record["encoded_sha256"] = "c" * 64
    forged["native_writer_round_trip_record"] = forged_record
    forged["native_writer_round_trip_record_sha256"] = canonical_sha256(
        forged_record
    )
    forged_payload = canonical_json_bytes_v2(forged)
    forged_binding = TypedArtifactBindingV2(
        artifact_kind=CONTROL_WRITER_EVIDENCE_BYTES_KIND,
        schema_sha256=output_schema,
        path="writer/forged-provenance.json",
        sha256=hashlib.sha256(forged_payload).hexdigest(),
        size_bytes=len(forged_payload),
    )
    forged_context = ControlWriterSemanticContextV2(
        expected_scope_bytes=context.expected_scope_bytes,
        expected_control_request_bytes=context.expected_control_request_bytes,
        source_profile_identity_bytes=context.source_profile_identity_bytes,
        degradation_profile_bytes=context.degradation_profile_bytes,
        raw_output_frame_bytes=context.raw_output_frame_bytes,
        decoded_output_frame_bytes=context.decoded_output_frame_bytes,
        decoded_payload_bytes=context.decoded_payload_bytes,
        encoded_container_bytes=context.encoded_container_bytes,
        writer_report_bytes=context.writer_report_bytes,
        writer_provenance_bytes=forged_payload,
        writer_settings_bytes=context.writer_settings_bytes,
        writer_settings_sha256=context.writer_settings_sha256,
        authenticated_writer_identity_bytes=(
            context.authenticated_writer_identity_bytes
        ),
    )
    with pytest.raises(ProductionEvaluatorError, match="producer receipt"):
        restarted.control_writer_semantic_verifier(
            forged_binding,
            forged,
            forged_context,
        )
