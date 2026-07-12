"""Machine-readable analytic metric conformance suite."""

from __future__ import annotations

import hashlib
import math
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

from .arrays import PlanarFrame, frame_sha256, normalize_code_plane
from .fixtures import locked_analytic_fixture_frames, step_fixture
from .json_tools import manifest_sha256, read_json, validate_schema
from .metrics import (
    alias_energy,
    channel_psnr,
    chroma_edge_displacement,
    edge_location_error,
    ms_ssim,
    ms_ssim_detail,
    psnr,
    ringing,
    ssim,
    thin_line_retention,
)


def _locked_nonidentical_fixture() -> tuple[np.ndarray, np.ndarray, Dict[str, object]]:
    vector_path = Path(__file__).resolve().parents[2] / "reference" / "metric-vectors-v1.json"
    vector = read_json(vector_path)
    definition = vector["fixture"]
    height, width = definition["dimensions"]
    yy, xx = np.indices((height, width), dtype=np.float64)
    x = xx / (width - 1)
    y = yy / (height - 1)
    checker = ((xx // 4 + yy // 6) % 2).astype(np.float64)
    reference = np.clip(0.50 * x + 0.25 * y + 0.25 * checker, 0.0, 1.0)
    candidate = np.roll(reference, shift=(1, -1), axis=(0, 1))
    candidate = np.clip(
        0.965 * candidate
        + 0.0175
        + 0.0125 * np.sin((3.0 * xx + 5.0 * yy) * 2.0 * np.pi / 37.0),
        0.0,
        1.0,
    )
    reference_digest = hashlib.sha256(
        np.asarray(reference, dtype="<f8").tobytes(order="C")
    ).hexdigest()
    candidate_digest = hashlib.sha256(
        np.asarray(candidate, dtype="<f8").tobytes(order="C")
    ).hexdigest()
    if reference_digest != definition["reference_f64le_sha256"]:
        raise ValueError("independent SSIM reference fixture hash mismatch")
    if candidate_digest != definition["candidate_f64le_sha256"]:
        raise ValueError("independent SSIM candidate fixture hash mismatch")
    return reference, candidate, vector


def _locked_analytic_fixtures(metric_policy_sha256: str) -> Dict[str, object]:
    quality_root = Path(__file__).resolve().parents[2]
    policy = read_json(quality_root / "policies" / "metric-policy.json")
    if (
        policy.get("policy_sha256") != metric_policy_sha256
        or manifest_sha256(policy, "policy_sha256") != metric_policy_sha256
    ):
        raise ValueError("metric policy does not match analytic fixture request")
    binding = policy.get("analytic_fixture_manifest")
    if (
        not isinstance(binding, dict)
        or binding.get("path") != "reference/analytic-fixtures-v2.json"
    ):
        raise ValueError("metric policy lacks the locked analytic fixture manifest")
    path = quality_root / str(binding["path"])
    payload = path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != binding.get("file_sha256"):
        raise ValueError("analytic fixture file SHA-256 mismatch")
    manifest = read_json(path)
    if (
        manifest.get("schema_version") != "2.0.0"
        or manifest.get("artifact_kind") != "metric_analytic_fixture_manifest"
        or manifest.get("manifest_sha256") != binding.get("manifest_sha256")
        or manifest_sha256(manifest) != binding.get("manifest_sha256")
    ):
        raise ValueError("analytic fixture manifest identity or self-hash mismatch")
    validate_schema(
        manifest,
        quality_root / "schemas" / "analytic-fixtures-v2.schema.json",
    )
    return manifest


def _f64le_sha256(values: np.ndarray) -> str:
    return hashlib.sha256(
        np.asarray(values, dtype="<f8").tobytes(order="C")
    ).hexdigest()


def _packed_mask_sha256(values: np.ndarray) -> str:
    return hashlib.sha256(
        np.packbits(
            np.asarray(values, dtype=bool).reshape(-1),
            bitorder="big",
        ).tobytes()
    ).hexdigest()


def _analytic_reference(
    definition: Dict[str, object],
) -> Tuple[PlanarFrame, Optional[np.ndarray]]:
    degradation = read_json(
        Path(__file__).resolve().parents[2] / "policies" / "degradation-policy.json"
    )
    frame, _, support = locked_analytic_fixture_frames(definition, degradation)
    return frame, support


def _case(case_id: str, metric: str, expected: object, actual: object, passed: bool) -> Dict[str, object]:
    return {
        "case_id": case_id,
        "metric": metric,
        "expected": expected,
        "actual": actual,
        "pass": bool(passed),
    }


def run_metric_conformance(metric_policy_sha256: str) -> Dict[str, object]:
    cases: List[Dict[str, object]] = []
    analytic_fixtures = _locked_analytic_fixtures(metric_policy_sha256)
    fixture_definitions = analytic_fixtures.get("fixtures")
    if not isinstance(fixture_definitions, list) or len(fixture_definitions) != 14:
        raise ValueError("analytic fixture manifest must contain fourteen route fixtures")
    base = np.full((64, 64), 0.4, dtype=np.float64)

    identical = psnr(base, base.copy())
    cases.append(
        _case(
            "identical-psnr",
            "Y PSNR",
            {"value": None, "exact_match": True},
            identical,
            identical["value"] is None and identical["exact_match"] is True,
        )
    )

    offset = psnr(base, base + 0.1)
    cases.append(
        _case(
            "constant-offset-psnr",
            "Y PSNR",
            20.0,
            offset["value"],
            math.isclose(float(offset["value"]), 20.0, abs_tol=1e-12),
        )
    )

    identical_ssim = ssim(base, base.copy())
    cases.append(
        _case("identical-ssim", "SSIM", 1.0, identical_ssim, math.isclose(identical_ssim, 1.0, abs_tol=1e-12))
    )
    identical_ms_ssim = ms_ssim(base, base.copy())
    cases.append(
        _case(
            "identical-ms-ssim",
            "MS-SSIM",
            1.0,
            identical_ms_ssim,
            math.isclose(identical_ms_ssim, 1.0, abs_tol=1e-12),
        )
    )

    oracle_reference, oracle_candidate, locked_vector = _locked_nonidentical_fixture()
    locked_expected = locked_vector["expected"]
    oracle_ssim = ssim(oracle_reference, oracle_candidate)
    cases.append(
        _case(
            "independent-nonidentical-ssim",
            "SSIM",
            locked_expected["ssim"],
            oracle_ssim,
            math.isclose(
                oracle_ssim,
                float(locked_expected["ssim"]),
                rel_tol=0.0,
                abs_tol=2e-12,
            ),
        )
    )
    oracle_ms_ssim = ms_ssim_detail(oracle_reference, oracle_candidate)
    expected_contributions = locked_expected["scale_contrast_structure_means"]
    contributions_match = all(
        math.isclose(actual, float(expected), rel_tol=0.0, abs_tol=2e-12)
        for actual, expected in zip(
            oracle_ms_ssim["scale_contrast_structure_means"],
            expected_contributions,
        )
    )
    scale_ssim_match = all(
        math.isclose(actual, float(expected), rel_tol=0.0, abs_tol=2e-12)
        for actual, expected in zip(
            oracle_ms_ssim["scale_ssim_means"],
            locked_expected["scale_ssim_means"],
        )
    )
    cases.append(
        _case(
            "independent-nonidentical-ms-ssim",
            "MS-SSIM",
            locked_expected,
            oracle_ms_ssim,
            len(oracle_ms_ssim["scale_contrast_structure_means"]) == 5
            and len(expected_contributions) == 5
            and contributions_match
            and scale_ssim_match
            and math.isclose(
                float(oracle_ms_ssim["value"]),
                float(locked_expected["ms_ssim"]),
                rel_tol=0.0,
                abs_tol=2e-12,
            ),
        )
    )

    edge_definitions = [
        definition
        for definition in fixture_definitions
        if isinstance(definition, dict)
        and definition.get("fixture_kind") == "edge_profile"
    ]
    if len(edge_definitions) != 6:
        raise ValueError("analytic fixture manifest must contain six route edge profiles")
    for definition in edge_definitions:
        support = definition["measurement_support"]
        normal = support.get("normal_xy")
        center = support.get("center_xy")
        if (
            not isinstance(normal, list)
            or len(normal) != 2
            or not isinstance(center, list)
            or len(center) != 2
        ):
            raise ValueError("analytic edge geometry is invalid")
        frame, unused_support = _analytic_reference(definition)
        if unused_support is not None:
            raise ValueError("edge fixture unexpectedly declared a binary mask")
        edge = frame.y
        error = edge_location_error(
            edge,
            edge.copy(),
            center=(float(center[0]), float(center[1])),
            normal=(float(normal[0]), float(normal[1])),
            sample_count=int(support["sample_count"]),
        )
        cases.append(
            _case(
                str(definition["fixture_id"]),
                "edge-location",
                0.0,
                error,
                math.isclose(error, 0.0, abs_tol=1e-12),
            )
        )

    translated_reference = step_fixture(64, "vertical", offset=0.0)
    translated_candidate = step_fixture(64, "vertical", offset=1.0)
    translated_error = edge_location_error(
        translated_reference,
        translated_candidate,
        center=(31.5, 31.5),
        normal=(1.0, 0.0),
        sample_count=31,
    )
    cases.append(
        _case(
            "known-one-pixel-translation",
            "edge-location",
            1.0,
            translated_error,
            math.isclose(translated_error, 1.0, abs_tol=1e-12),
        )
    )

    ringing_definitions = [
        definition
        for definition in fixture_definitions
        if isinstance(definition, dict) and definition.get("fixture_kind") == "ringing"
    ]
    if len(ringing_definitions) != 2:
        raise ValueError("analytic fixture manifest must contain two route ringing fixtures")
    for ringing_definition in ringing_definitions:
        frame, impulse_support = _analytic_reference(ringing_definition)
        if impulse_support is None:
            raise ValueError("analytic ringing fixture has no transition support")
        declared_support = ringing_definition["measurement_support"]
        if _packed_mask_sha256(impulse_support) != declared_support["packed_sha256"]:
            raise ValueError("analytic ringing support hash mismatch")
        impulse = frame.y
        ringing_candidate = impulse.copy()
        impulse_row, impulse_column = declared_support["true_coordinates"][0]
        ringing_candidate[int(impulse_row), int(impulse_column) + 2] = 1.1
        ringing_candidate[int(impulse_row), int(impulse_column) - 2] = -0.05
        ringing_value = ringing(impulse, ringing_candidate, impulse_support)
        cases.append(
            _case(
                str(ringing_definition["fixture_id"]),
                "ringing",
                {"overshoot": 0.1, "undershoot": 0.05},
                ringing_value,
                math.isclose(ringing_value["overshoot"], 0.1, abs_tol=1e-12)
                and math.isclose(ringing_value["undershoot"], 0.05, abs_tol=1e-12),
            )
        )

    line_definitions = [
        definition
        for definition in fixture_definitions
        if isinstance(definition, dict) and definition.get("fixture_kind") == "thin_line"
    ]
    if len(line_definitions) != 2:
        raise ValueError("analytic fixture manifest must contain two route thin-line fixtures")
    for line_definition in line_definitions:
        frame, line_support = _analytic_reference(line_definition)
        if line_support is None:
            raise ValueError("analytic thin-line fixture has no support")
        declared_support = line_definition["measurement_support"]
        if _packed_mask_sha256(line_support) != declared_support["packed_sha256"]:
            raise ValueError("analytic thin-line support hash mismatch")
        line_value = thin_line_retention(frame.y, frame.y.copy(), line_support)
        cases.append(
            _case(
                str(line_definition["fixture_id"]),
                "thin-line-retention",
                {"retention_ratio": 1.0, "false_side_lobe_energy": 0.0},
                line_value,
                math.isclose(line_value["retention_ratio"], 1.0, abs_tol=1e-12)
                and math.isclose(line_value["false_side_lobe_energy"], 0.0, abs_tol=1e-12),
            )
        )

    luma_profile = np.asarray([0.0, 0.0, 0.0, 1.0, 1.0, 1.0])
    chroma_profile = np.asarray([-0.5, -0.5, -0.5, 0.5, 0.5, 0.5])
    shifted_chroma = np.asarray([-0.5, -0.5, -0.5, -0.5, 0.5, 0.5])
    displacement = chroma_edge_displacement(
        luma_profile,
        chroma_profile,
        shifted_chroma,
    )
    cases.append(
        _case(
            "cb-cr-edge-displacement",
            "chroma-edge-displacement",
            {"Cb": 0.0, "Cr": 1.0},
            displacement,
            math.isclose(displacement["Cb"], 0.0, abs_tol=1e-12)
            and math.isclose(displacement["Cr"], 1.0, abs_tol=1e-12),
        )
    )

    alias_definitions = [
        definition
        for definition in fixture_definitions
        if isinstance(definition, dict) and definition.get("fixture_kind") == "alias"
    ]
    if len(alias_definitions) != 2:
        raise ValueError("analytic fixture manifest must contain two route alias masks")
    for alias_definition in alias_definitions:
        frame, forbidden = _analytic_reference(alias_definition)
        if forbidden is None:
            raise ValueError("analytic alias fixture has no forbidden mask")
        declared_support = alias_definition["measurement_support"]
        if _packed_mask_sha256(forbidden) != declared_support["packed_sha256"]:
            raise ValueError("analytic alias fixture packed-mask SHA-256 mismatch")
        alias = alias_energy(frame.y, forbidden)
        cases.append(
            _case(
                str(alias_definition["fixture_id"]),
                "alias-energy",
                0.5,
                alias["ratio"],
                math.isclose(alias["ratio"], 0.5, abs_tol=1e-12),
            )
        )

    luma_endpoints = normalize_code_plane(np.asarray([[16.0, 235.0]]), 16.0, 235.0)
    chroma_endpoints = normalize_code_plane(
        np.asarray([[16.0, 240.0]]),
        16.0,
        240.0,
        centered=True,
    )
    endpoint_actual = {
        "Y": [float(value) for value in luma_endpoints[0]],
        "C": [float(value) for value in chroma_endpoints[0]],
    }
    cases.append(
        _case(
            "legal-range-endpoints",
            "normalization",
            {"Y": [0.0, 1.0], "C": [-0.5, 0.5]},
            endpoint_actual,
            endpoint_actual == {"Y": [0.0, 1.0], "C": [-0.5, 0.5]},
        )
    )

    chroma_definitions = [
        definition
        for definition in fixture_definitions
        if isinstance(definition, dict)
        and definition.get("fixture_kind") == "chroma_displacement"
    ]
    if len(chroma_definitions) != 2:
        raise ValueError("analytic fixture manifest must contain two route chroma edges")
    for edge_definition in chroma_definitions:
        frame, unused_support = _analytic_reference(edge_definition)
        if unused_support is not None:
            raise ValueError("analytic chroma fixture unexpectedly declared a mask")
        support = edge_definition["measurement_support"]
        luma_columns = support["luma_sample_columns"]
        chroma_columns = support["chroma_sample_columns"]
        coordinate_rule = support["coordinates_luma_pixels"]
        y_indices = np.arange(
            int(luma_columns["start"]),
            int(luma_columns["start"])
            + int(luma_columns["step"]) * int(luma_columns["count"]),
            int(luma_columns["step"]),
        )
        c_indices = np.arange(
            int(chroma_columns["start"]),
            int(chroma_columns["start"])
            + int(chroma_columns["step"]) * int(chroma_columns["count"]),
            int(chroma_columns["step"]),
        )
        coordinates = np.arange(
            int(coordinate_rule["count"]),
            dtype=np.float64,
        ) * float(coordinate_rule["step"]) + float(coordinate_rule["start"])
        displacement = chroma_edge_displacement(
            frame.y[int(support["luma_row"]), y_indices],
            frame.cb[int(support["chroma_row"]), c_indices],
            frame.cr[int(support["chroma_row"]), c_indices],
            coordinates=coordinates,
        )
        neutral = np.zeros_like(frame.cb)
        reference_frame = PlanarFrame(y=frame.y, cb=neutral, cr=neutral)
        cb_frame = PlanarFrame(y=frame.y, cb=frame.cb, cr=neutral)
        cr_frame = PlanarFrame(y=frame.y, cb=neutral, cr=frame.cr)
        cb_metrics = channel_psnr(reference_frame, cb_frame)
        cr_metrics = channel_psnr(reference_frame, cr_frame)
        passed = (
            cb_metrics["Y"]["exact_match"]
            and not cb_metrics["Cb"]["exact_match"]
            and cb_metrics["Cr"]["exact_match"]
            and cr_metrics["Y"]["exact_match"]
            and cr_metrics["Cb"]["exact_match"]
            and not cr_metrics["Cr"]["exact_match"]
            and math.isclose(displacement["Cb"], 0.0, abs_tol=1e-12)
            and math.isclose(displacement["Cr"], 0.0, abs_tol=1e-12)
        )
        cases.append(
            _case(
                str(edge_definition["fixture_id"]),
                "chroma-edge-displacement-and-channel-PSNR",
                {"Cb": 0.0, "Cr": 0.0},
                {"displacement": displacement, "Cb-only": cb_metrics, "Cr-only": cr_metrics},
                passed,
            )
        )

    return {
        "schema_version": "1.0.0",
        "metric_policy_sha256": metric_policy_sha256,
        "cases": cases,
        "status": "pass" if all(case["pass"] for case in cases) else "fail",
    }
