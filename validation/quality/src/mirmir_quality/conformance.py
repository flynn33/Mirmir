"""Machine-readable analytic metric conformance suite."""

from __future__ import annotations

import hashlib
import math
from pathlib import Path
from typing import Dict, List

import numpy as np

from .arrays import PlanarFrame, normalize_code_plane
from .fixtures import impulse_fixture, step_fixture, thin_line_fixture
from .json_tools import manifest_sha256, read_json
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
        or binding.get("path") != "reference/analytic-fixtures-v1.json"
    ):
        raise ValueError("metric policy lacks the locked analytic fixture manifest")
    path = quality_root / str(binding["path"])
    payload = path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != binding.get("file_sha256"):
        raise ValueError("analytic fixture file SHA-256 mismatch")
    manifest = read_json(path)
    if (
        manifest.get("schema_version") != "1.0.0"
        or manifest.get("artifact_kind") != "metric_analytic_fixture_manifest"
        or manifest.get("manifest_sha256") != binding.get("manifest_sha256")
        or manifest_sha256(manifest) != binding.get("manifest_sha256")
    ):
        raise ValueError("analytic fixture manifest identity or self-hash mismatch")
    return manifest


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

    for orientation, normal in (
        ("vertical", (1.0, 0.0)),
        ("horizontal", (0.0, 1.0)),
        ("diagonal", (1.0, 1.0)),
    ):
        edge = step_fixture(64, orientation)
        error = edge_location_error(
            edge,
            edge.copy(),
            center=(31.5, 31.5),
            normal=normal,
            sample_count=31,
        )
        cases.append(
            _case(
                f"{orientation}-step",
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

    impulse, impulse_support = impulse_fixture()
    ringing_candidate = impulse.copy()
    center = impulse.shape[0] // 2
    ringing_candidate[center, center + 2] = 1.1
    ringing_candidate[center, center - 2] = -0.05
    ringing_value = ringing(impulse, ringing_candidate, impulse_support)
    cases.append(
        _case(
            "single-impulse-ringing",
            "ringing",
            {"overshoot": 0.1, "undershoot": 0.05},
            ringing_value,
            math.isclose(ringing_value["overshoot"], 0.1, abs_tol=1e-12)
            and math.isclose(ringing_value["undershoot"], 0.05, abs_tol=1e-12),
        )
    )

    line, line_support = thin_line_fixture()
    line_value = thin_line_retention(line, line.copy(), line_support)
    cases.append(
        _case(
            "thin-line-identity",
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

    alias_definitions = analytic_fixtures.get("alias_masks")
    if not isinstance(alias_definitions, list) or len(alias_definitions) != 1:
        raise ValueError("analytic fixture manifest must contain one alias mask")
    alias_definition = alias_definitions[0]
    if (
        not isinstance(alias_definition, dict)
        or alias_definition.get("id") != "near-nyquist-single-bin-v1"
        or alias_definition.get("dimensions") != [32, 32]
        or alias_definition.get("source_pattern") != "(-1)^(row+column)"
        or alias_definition.get("encoding")
        != "true-coordinate-pairs-row-column"
        or alias_definition.get("packed_encoding")
        != "row-major numpy-packbits-big"
    ):
        raise ValueError("analytic alias fixture definition is invalid")
    checker = np.fromfunction(lambda row, column: (-1.0) ** (row + column), (32, 32))
    forbidden = np.zeros_like(checker, dtype=bool)
    coordinates = alias_definition.get("true_coordinates")
    if not isinstance(coordinates, list) or not coordinates:
        raise ValueError("analytic alias fixture has no selected coordinates")
    for coordinate in coordinates:
        if (
            not isinstance(coordinate, list)
            or len(coordinate) != 2
            or not all(isinstance(value, int) for value in coordinate)
            or not 0 <= coordinate[0] < 32
            or not 0 <= coordinate[1] < 32
        ):
            raise ValueError("analytic alias fixture coordinate is invalid")
        forbidden[coordinate[0], coordinate[1]] = True
    packed_mask_sha256 = hashlib.sha256(
        np.packbits(forbidden.reshape(-1), bitorder="big").tobytes()
    ).hexdigest()
    if packed_mask_sha256 != alias_definition.get("packed_mask_sha256"):
        raise ValueError("analytic alias fixture packed-mask SHA-256 mismatch")
    alias = alias_energy(checker, forbidden)
    cases.append(
        _case(
            "near-nyquist-alias-mask",
            "alias-energy",
            1.0,
            alias["ratio"],
            math.isclose(alias["ratio"], 1.0, abs_tol=1e-12),
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

    edge_definitions = analytic_fixtures.get("chroma_edge_fixtures")
    if not isinstance(edge_definitions, list) or len(edge_definitions) != 1:
        raise ValueError("analytic fixture manifest must contain one chroma edge")
    edge_definition = edge_definitions[0]
    if (
        not isinstance(edge_definition, dict)
        or edge_definition.get("id") != "centered-cb-cr-step-v1"
        or edge_definition.get("dimensions") != [32, 32]
        or edge_definition.get("edge_column") != 16
        or edge_definition.get("low_value") != -0.5
        or edge_definition.get("high_value") != 0.5
        or edge_definition.get("neutral_value") != 0.0
    ):
        raise ValueError("analytic chroma-edge fixture definition is invalid")
    neutral = np.full((32, 32), 0.0, dtype=np.float64)
    changed = np.full((32, 32), -0.5, dtype=np.float64)
    changed[:, 16:] = 0.5
    reference_frame = PlanarFrame(y=base[:32, :32], cb=neutral, cr=neutral)
    cb_frame = PlanarFrame(y=base[:32, :32], cb=changed, cr=neutral)
    cr_frame = PlanarFrame(y=base[:32, :32], cb=neutral, cr=changed)
    cb_metrics = channel_psnr(reference_frame, cb_frame)
    cr_metrics = channel_psnr(reference_frame, cr_frame)
    channel_pass = (
        cb_metrics["Y"]["exact_match"]
        and not cb_metrics["Cb"]["exact_match"]
        and cb_metrics["Cr"]["exact_match"]
        and cr_metrics["Y"]["exact_match"]
        and cr_metrics["Cb"]["exact_match"]
        and not cr_metrics["Cr"]["exact_match"]
    )
    cases.append(
        _case(
            "cb-only-and-cr-only",
            "channel-PSNR",
            "only the changed chroma channel is non-exact",
            {
                "fixture_id": edge_definition["id"],
                "edge_values": {
                    "low": edge_definition["low_value"],
                    "high": edge_definition["high_value"],
                    "neutral": edge_definition["neutral_value"],
                },
                "Cb-only": cb_metrics,
                "Cr-only": cr_metrics,
            },
            channel_pass,
        )
    )

    return {
        "schema_version": "1.0.0",
        "metric_policy_sha256": metric_policy_sha256,
        "cases": cases,
        "status": "pass" if all(case["pass"] for case in cases) else "fail",
    }
