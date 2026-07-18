"""Deterministic exhaustive P07 spatial holdout aggregation and G07 decision."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
from typing import Dict, List, Mapping, MutableMapping, Optional, Sequence, Tuple

import numpy as np

from validation.calibration_v2.p07.execution import (
    P07ExecutionError,
    SCHEMAS_ROOT,
    _canonical_bytes,
    _validate_schema,
    _write_json,
)
from validation.calibration_v2.p07.contracts_v2 import (
    IDENTITY_FIELD,
    validate_identity_v2,
    validate_selected_evaluation_projection_v2,
)
from validation.quality.src.mirmir_quality.bootstrap import paired_bootstrap
from validation.quality.src.mirmir_quality.corpus import QUALITY_CATEGORIES
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


DOMAINS = ("engine_raw", "container_decoded")
FIXED_CONTROLS = tuple("fixed_descriptor_{:02d}".format(value) for value in range(16))
CONVENTIONAL_CONTROLS = (
    "conventional_bilinear_separable_v1",
    "conventional_keys_cubic_a_minus_0_5_separable_v1",
    "conventional_lanczos3_separable_v1",
)
SELECTED_AND_ASH_CONTROLS = (
    "nearest_same_writer",
    "current_production_ash",
    "best_fixed",
    "conventional",
    "non_ash_selector",
    "state_only",
    "full_ash",
    "state_plus_branch",
    "h07_direct_3_over_2",
)
CONTROL_ORDER = FIXED_CONTROLS + CONVENTIONAL_CONTROLS + SELECTED_AND_ASH_CONTROLS
MEASUREMENT_SCHEMA = SCHEMAS_ROOT / "p07-spatial-holdout-measurements-v1.schema.json"
EVIDENCE_SCHEMA = SCHEMAS_ROOT / "p07-gate-evidence-v1.schema.json"
PUBLICATION_SCHEMA = SCHEMAS_ROOT / "p07-g07-publication-v1.schema.json"
MEASUREMENT_V2_SCHEMA = SCHEMAS_ROOT / "p07-spatial-holdout-measurements-v2.schema.json"
EVIDENCE_V2_SCHEMA = SCHEMAS_ROOT / "p07-gate-evidence-v2.schema.json"
PUBLICATION_V2_SCHEMA = SCHEMAS_ROOT / "p07-g07-publication-v2.schema.json"
BOOTSTRAP_REPLICATES = 10_000
BOOTSTRAP_SEED = 20_260_710
DEGRADATION_KIND_ORDER = (
    "lowpass_decimate",
    "camera_blur_decimate",
    "codec_quantized_proxy",
)
ROUTE_ORDER = ("direct-2x", "direct-3over2")
CORPUS_METRIC_FIELDS = (
    "y_psnr_db",
    "cb_psnr_db",
    "cr_psnr_db",
    "y_ssim",
    "cb_ssim",
    "cr_ssim",
    "y_ms_ssim",
    "cb_ms_ssim",
    "cr_ms_ssim",
    "writer_y_psnr_contribution_db",
)
ANALYTIC_METRIC_FIELDS_BY_KIND = {
    "edge_profile": frozenset({"edge_location_error_pixels"}),
    "ringing": frozenset({"ringing_overshoot", "ringing_undershoot"}),
    "thin_line": frozenset(
        {"thin_line_retention_ratio", "thin_line_false_side_lobe_energy"}
    ),
    "alias": frozenset({"alias_forbidden_band_ratio"}),
    "chroma_displacement": frozenset({"chroma_displacement_pixels"}),
}
ANALYTIC_METRIC_FIELDS = frozenset().union(
    *ANALYTIC_METRIC_FIELDS_BY_KIND.values()
)


class P07GateError(ValueError):
    """Holdout measurements are incomplete, mixed, stale, or non-finite."""


def _finite(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise P07GateError("{} is not numeric".format(label))
    result = float(value)
    if not math.isfinite(result):
        raise P07GateError("{} is not finite".format(label))
    return result


def _sha(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise P07GateError("{} is not a lowercase SHA-256".format(label))
    return value


def _evidence_document(
    *,
    artifact_kind: str,
    status: str,
    measurements: Mapping[str, object],
    evidence: Mapping[str, object],
) -> Mapping[str, object]:
    is_v2 = measurements.get("schema_version") == "2.0.0"
    identity = (
        validate_identity_v2(measurements.get(IDENTITY_FIELD))
        if is_v2
        else None
    )
    document = {
        "schema_version": "2.0.0" if is_v2 else "1.0.0",
        "artifact_kind": (
            artifact_kind + "_v2" if is_v2 else artifact_kind
        ),
        **(
            {IDENTITY_FIELD: dict(identity)}
            if identity is not None
            else {}
        ),
        "status": status,
        "configuration_sha256": measurements["configuration_sha256"],
        "measurement_sha256": measurements["measurement_sha256"],
        "locked_metric_policy_sha256": measurements["locked_metric_policy_sha256"],
        "holdout_accessed": True,
        "configuration_files_modified_after_holdout": False,
        "evidence": dict(evidence),
    }
    document["manifest_sha256"] = canonical_sha256(document)
    _validate_schema(
        document,
        EVIDENCE_V2_SCHEMA if is_v2 else EVIDENCE_SCHEMA,
        artifact_kind,
    )
    return document


def _validate_psnr_measurement(
    measurement: object,
    *,
    label: str,
    require_nonexact: bool,
) -> Optional[float]:
    if not isinstance(measurement, dict) or set(measurement) != {
        "value",
        "mse",
        "exact_match",
    }:
        raise P07GateError("{} PSNR evidence shape differs".format(label))
    mse = _finite(measurement["mse"], "{} MSE".format(label))
    exact_match = measurement["exact_match"]
    if not isinstance(exact_match, bool):
        raise P07GateError("{} exact-match state is not Boolean".format(label))
    value = measurement["value"]
    if exact_match:
        if value is not None or mse != 0.0:
            raise P07GateError(
                "{} exact PSNR must have null value and zero MSE".format(label)
            )
        if require_nonexact:
            raise P07GateError(
                "{} requires finite non-exact PSNR for aggregation".format(label)
            )
        return None
    if value is None or mse <= 0.0:
        raise P07GateError(
            "{} non-exact PSNR requires finite value and positive MSE".format(label)
        )
    numeric_value = _finite(value, "{} PSNR value".format(label))
    expected_value = 10.0 * math.log10(1.0 / mse)
    if (
        not math.isfinite(expected_value)
        or abs(numeric_value - expected_value) > math.ulp(expected_value)
    ):
        raise P07GateError(
            "{} PSNR value and MSE differ beyond one binary64 ULP".format(label)
        )
    return numeric_value


def _psnr_value(bundle: Mapping[str, object], field: str, label: str) -> float:
    value = _validate_psnr_measurement(
        bundle[field],
        label=label,
        require_nonexact=True,
    )
    if value is None:  # Defensive; require_nonexact rejects this state.
        raise P07GateError("{} PSNR value is absent".format(label))
    return value


def _validate_metric_bundle(
    bundle: object,
    *,
    fixture_kind: Optional[str],
    domain: str,
) -> Mapping[str, object]:
    if not isinstance(bundle, dict):
        raise P07GateError("metric bundle is not an object")
    expected = (
        set(CORPUS_METRIC_FIELDS)
        if fixture_kind is None
        else set(ANALYTIC_METRIC_FIELDS)
    )
    if set(bundle) != expected:
        raise P07GateError("metric bundle field set differs")
    if fixture_kind is None:
        for field, label in (
            ("y_psnr_db", "Y"),
            ("cb_psnr_db", "Cb"),
            ("cr_psnr_db", "Cr"),
        ):
            _validate_psnr_measurement(
                bundle[field],
                label=label,
                require_nonexact=field == "y_psnr_db",
            )
        for field in ("y_ssim", "cb_ssim", "cr_ssim"):
            value = _finite(bundle[field], field)
            if value < -1.0 or value > 1.0:
                raise P07GateError("{} is outside [-1, 1]".format(field))
        for field in ("y_ms_ssim", "cb_ms_ssim", "cr_ms_ssim"):
            value = _finite(bundle[field], field)
            if value < 0.0 or value > 1.0:
                raise P07GateError("{} is outside [0, 1]".format(field))
        writer_value = bundle["writer_y_psnr_contribution_db"]
        if domain == "engine_raw":
            if writer_value is not None:
                raise P07GateError(
                    "engine-raw metric bundle contains writer contribution"
                )
        else:
            _finite(writer_value, "writer Y PSNR contribution")
    else:
        required_nonnull = ANALYTIC_METRIC_FIELDS_BY_KIND.get(fixture_kind)
        if required_nonnull is None:
            raise P07GateError("analytic fixture kind is unsupported")
        populated = set()
        for field in ANALYTIC_METRIC_FIELDS:
            value = bundle[field]
            if value is not None:
                if _finite(value, field) < 0.0:
                    raise P07GateError("{} is negative".format(field))
                populated.add(field)
        if populated != set(required_nonnull):
            raise P07GateError(
                "analytic metric nullability differs from fixture support"
            )
    return bundle


def _validate_control_maps(
    row: Mapping[str, object],
    *,
    domain: str,
    route: str,
    selected_aliases: Mapping[str, object],
    configuration_hashes: Mapping[str, object],
    fixture_kind: Optional[str],
) -> None:
    outputs = row.get("output_sha256_by_control")
    writers = row.get("writer_evidence_sha256_by_control")
    metrics = row.get("metrics_by_control")
    row_configurations = row.get("configuration_sha256_by_control")
    for label, value in (
        ("output hashes", outputs),
        ("writer hashes", writers),
        ("metrics", metrics),
        ("configuration hashes", row_configurations),
    ):
        if not isinstance(value, dict) or tuple(value) != CONTROL_ORDER:
            raise P07GateError("{} control coverage or order differs".format(label))
    if row_configurations != configuration_hashes:
        raise P07GateError("row configuration hashes differ from the locked identities")
    h07_expected = route == "direct-3over2"
    for control in CONTROL_ORDER:
        output = outputs[control]
        writer = writers[control]
        bundle = metrics[control]
        if control == "h07_direct_3_over_2" and not h07_expected:
            if output is not None or writer is not None or bundle is not None:
                raise P07GateError("H07 evidence is populated outside direct-3over2")
            continue
        _sha(output, "{} output".format(control))
        if domain == "engine_raw":
            if writer is not None:
                raise P07GateError("engine-raw row contains writer evidence")
        else:
            _sha(writer, "{} writer evidence".format(control))
        _validate_metric_bundle(
            bundle,
            fixture_kind=fixture_kind,
            domain=domain,
        )
    fixed = str(selected_aliases["best_fixed"])
    conventional = str(selected_aliases["conventional"])
    if (
        outputs["best_fixed"] != outputs[fixed]
        or metrics["best_fixed"] != metrics[fixed]
        or writers["best_fixed"] != writers[fixed]
        or outputs["conventional"] != outputs[conventional]
        or metrics["conventional"] != metrics[conventional]
        or writers["conventional"] != writers[conventional]
        or outputs["full_ash"] != outputs["state_plus_branch"]
        or metrics["full_ash"] != metrics["state_plus_branch"]
        or writers["full_ash"] != writers["state_plus_branch"]
    ):
        raise P07GateError("selected aliases or state-plus-branch identity differs")


def _validate_measurements(
    measurements: Mapping[str, object],
    locked_metric_policy: Mapping[str, object],
) -> Tuple[Sequence[Mapping[str, object]], Sequence[Mapping[str, object]]]:
    is_v2 = measurements.get("schema_version") == "2.0.0"
    _validate_schema(
        measurements,
        MEASUREMENT_V2_SCHEMA if is_v2 else MEASUREMENT_SCHEMA,
        "P07 holdout measurements",
    )
    try:
        p06_identity = (
            validate_identity_v2(measurements.get(IDENTITY_FIELD))
            if is_v2
            else None
        )
    except ValueError as error:
        raise P07GateError("P07 V2 release identity differs") from error
    if measurements.get("measurement_sha256") != canonical_sha256(
        {key: value for key, value in measurements.items() if key != "measurement_sha256"}
    ):
        raise P07GateError("P07 measurement self-hash differs")
    policy_sha256 = locked_metric_policy.get("policy_sha256")
    if (
        policy_sha256 != canonical_sha256(
            {key: value for key, value in locked_metric_policy.items() if key != "policy_sha256"}
        )
        or measurements.get("locked_metric_policy_sha256") != policy_sha256
        or locked_metric_policy.get("comparison_domains") != list(DOMAINS)
        or locked_metric_policy.get("domain_aggregation_forbidden") is not True
    ):
        raise P07GateError("locked metric policy or measurement binding differs")
    analytic_binding = locked_metric_policy.get("analytic_fixture_manifest")
    if (
        not isinstance(analytic_binding, dict)
        or measurements.get("analytic_fixture_manifest_sha256")
        != analytic_binding.get("manifest_sha256")
    ):
        raise P07GateError("P07 analytic fixture manifest binding differs")
    bootstrap = locked_metric_policy.get("bootstrap")
    if (
        not isinstance(bootstrap, dict)
        or bootstrap.get("replicates") != BOOTSTRAP_REPLICATES
        or bootstrap.get("seed") != BOOTSTRAP_SEED
        or bootstrap.get("unit") != "source_asset"
    ):
        raise P07GateError("P07 bootstrap policy differs from the P06 lock")
    aliases = measurements.get("selected_aliases")
    if (
        not isinstance(aliases, dict)
        or aliases.get("best_fixed") not in FIXED_CONTROLS
        or aliases.get("conventional") not in CONVENTIONAL_CONTROLS
    ):
        raise P07GateError("selected control aliases are outside exhaustive controls")
    configuration_hashes = measurements.get("control_configuration_sha256_by_control")
    if not isinstance(configuration_hashes, dict) or tuple(configuration_hashes) != CONTROL_ORDER:
        raise P07GateError("control configuration coverage or order differs")
    for control, digest in configuration_hashes.items():
        _sha(digest, "{} configuration".format(control))
    if (
        configuration_hashes["best_fixed"]
        != configuration_hashes[str(aliases["best_fixed"])]
        or configuration_hashes["conventional"]
        != configuration_hashes[str(aliases["conventional"])]
        or configuration_hashes["full_ash"]
        != configuration_hashes["state_plus_branch"]
    ):
        raise P07GateError("selected alias or full-branch configuration hashes differ")
    if is_v2:
        try:
            validate_selected_evaluation_projection_v2(
                measurements.get("selected_p06_evidence_projection"),
                identity=p06_identity,
            )
        except ValueError as error:
            raise P07GateError(
                "selected P06 V2 objective/check evidence differs"
            ) from error
    else:
        performance = measurements.get("locked_p06_performance_evidence")
        expected_performance_fields = {
            "selected_evaluation_sha256",
            "full_frames_per_second",
            "h07_control_frames_per_second",
            "full_dispatch_cost",
            "h07_control_dispatch_cost",
            "no_worse_frames_per_second",
            "no_worse_dispatch_cost",
        }
        if (
            not isinstance(performance, dict)
            or set(performance) != expected_performance_fields
        ):
            raise P07GateError("locked P06 performance evidence is incomplete")
        _sha(performance["selected_evaluation_sha256"], "selected evaluation")
        full_fps = _finite(performance["full_frames_per_second"], "full FPS")
        control_fps = _finite(
            performance["h07_control_frames_per_second"],
            "H07 control FPS",
        )
        full_cost = _finite(performance["full_dispatch_cost"], "full dispatch cost")
        control_cost = _finite(
            performance["h07_control_dispatch_cost"],
            "H07 control cost",
        )
        if (
            performance["no_worse_frames_per_second"] is not True
            or performance["no_worse_dispatch_cost"] is not True
            or full_fps < control_fps
            or full_cost > control_cost
        ):
            raise P07GateError(
                "locked H07 quality/performance Pareto evidence fails"
            )

    source_order = measurements["source_order"]
    kind_order = measurements["degradation_kind_order"]
    if tuple(kind_order) != DEGRADATION_KIND_ORDER:
        raise P07GateError("degradation kind order differs")
    locked_profiles = measurements.get("locked_degradation_profiles")
    expected_profile_order = [
        (route, kind)
        for route in ROUTE_ORDER
        for kind in DEGRADATION_KIND_ORDER
    ]
    if (
        not isinstance(locked_profiles, list)
        or len(locked_profiles) != 6
        or [
            (row.get("target_route"), row.get("kind"))
            for row in locked_profiles
            if isinstance(row, dict)
        ]
        != expected_profile_order
    ):
        raise P07GateError("locked route-specific degradation profile order differs")
    profiles_by_route_kind = {}
    for row in locked_profiles:
        if not isinstance(row, dict):
            raise P07GateError("locked degradation profile is invalid")
        _sha(row.get("profile_sha256"), "locked degradation profile")
        profiles_by_route_kind[(row["target_route"], row["kind"])] = row
    expected_pairs = [
        (source, kind)
        for source in source_order
        for kind in kind_order
    ]
    rows = measurements.get("corpus_rows")
    if not isinstance(rows, list):
        raise P07GateError("P07 corpus rows are absent")
    source_metadata: Dict[
        str,
        Tuple[str, int, int, int, str, Tuple[str, ...], str],
    ] = {}
    observed_routes = set()
    for domain in DOMAINS:
        domain_rows = [row for row in rows if row.get("comparison_domain") == domain]
        if [
            (row.get("source_asset_id"), row.get("degradation_kind"))
            for row in domain_rows
        ] != expected_pairs:
            raise P07GateError(
                "{} source/degradation-kind matrix or order differs".format(domain)
            )
        for row in domain_rows:
            required_fields = {
                "asset_id", "sampling_ordinal", "selected_presentation_time",
                "source_asset_id", "source_family_id", "categories", "target_route",
                "degradation_kind", "degradation_profile_id",
                "degradation_profile_sha256", "source_crop_nv12_sha256",
                "degraded_input_frame_sha256", "comparison_domain",
                "configuration_sha256_by_control", "output_sha256_by_control",
                "writer_evidence_sha256_by_control", "metrics_by_control",
            }
            if set(row) != required_fields:
                raise P07GateError("P07 corpus row field set differs")
            source = row["source_asset_id"]
            asset = row["asset_id"]
            sampling_ordinal = row["sampling_ordinal"]
            selected_time = row["selected_presentation_time"]
            family = row["source_family_id"]
            categories = row["categories"]
            route = row["target_route"]
            if (
                not isinstance(source, str) or not source
                or not isinstance(asset, str) or not asset
                or not isinstance(sampling_ordinal, int)
                or isinstance(sampling_ordinal, bool)
                or sampling_ordinal != source_order.index(source)
                or not isinstance(selected_time, dict)
                or set(selected_time) != {"value", "timescale"}
                or not isinstance(selected_time.get("value"), int)
                or isinstance(selected_time.get("value"), bool)
                or selected_time["value"] < 0
                or not isinstance(selected_time.get("timescale"), int)
                or isinstance(selected_time.get("timescale"), bool)
                or selected_time["timescale"] <= 0
                or not isinstance(family, str) or not family
                or not isinstance(categories, list) or not categories
                or len(categories) != len(set(categories))
                or any(category not in QUALITY_CATEGORIES for category in categories)
                or route not in {"direct-2x", "direct-3over2"}
            ):
                raise P07GateError("P07 source metadata is invalid")
            identity = (
                asset,
                sampling_ordinal,
                selected_time["value"],
                selected_time["timescale"],
                family,
                tuple(categories),
                route,
            )
            previous = source_metadata.setdefault(source, identity)
            if previous != identity:
                raise P07GateError("P07 source metadata changes between rows")
            observed_routes.add(route)
            expected_profile = profiles_by_route_kind.get(
                (route, row["degradation_kind"])
            )
            if (
                expected_profile is None
                or row["degradation_profile_id"] != expected_profile["profile_id"]
                or row["degradation_profile_sha256"]
                != expected_profile["profile_sha256"]
            ):
                raise P07GateError(
                    "row substitutes a route-specific degradation profile"
                )
            _sha(row["source_crop_nv12_sha256"], "source crop")
            _sha(row["degraded_input_frame_sha256"], "degraded input")
            _validate_control_maps(
                row,
                domain=domain,
                route=route,
                selected_aliases=aliases,
                configuration_hashes=configuration_hashes,
                fixture_kind=None,
            )
    if len(rows) != 2 * len(expected_pairs) or observed_routes != {"direct-2x", "direct-3over2"}:
        raise P07GateError("P07 corpus domain count or route coverage differs")
    if len({identity[0] for identity in source_metadata.values()}) != len(
        source_order
    ):
        raise P07GateError("P07 sampled asset identifiers are duplicated")
    raw_by_case = {
        (row["source_asset_id"], row["degradation_kind"]): row
        for row in rows
        if row["comparison_domain"] == "engine_raw"
    }
    decoded_rows = [
        row for row in rows if row["comparison_domain"] == "container_decoded"
    ]
    cross_domain_identity_fields = (
        "asset_id",
        "sampling_ordinal",
        "selected_presentation_time",
        "source_family_id",
        "categories",
        "target_route",
        "degradation_profile_id",
        "degradation_profile_sha256",
        "source_crop_nv12_sha256",
        "degraded_input_frame_sha256",
        "configuration_sha256_by_control",
    )
    for decoded in decoded_rows:
        key = (decoded["source_asset_id"], decoded["degradation_kind"])
        raw = raw_by_case.get(key)
        if raw is None or any(
            decoded[field] != raw[field] for field in cross_domain_identity_fields
        ):
            raise P07GateError("cross-domain corpus case identity differs")
        for control in CONTROL_ORDER:
            decoded_bundle = decoded["metrics_by_control"][control]
            raw_bundle = raw["metrics_by_control"][control]
            if decoded_bundle is None or raw_bundle is None:
                if decoded_bundle is not raw_bundle:
                    raise P07GateError("cross-domain control coverage differs")
                continue
            expected_contribution = _psnr_value(
                decoded_bundle,
                "y_psnr_db",
                "decoded writer Y",
            ) - _psnr_value(raw_bundle, "y_psnr_db", "raw writer Y")
            actual_contribution = _finite(
                decoded_bundle["writer_y_psnr_contribution_db"],
                "writer Y PSNR contribution",
            )
            if (
                abs(actual_contribution - expected_contribution)
                > math.ulp(expected_contribution)
            ):
                raise P07GateError(
                    "decoded writer Y PSNR contribution differs from decoded-minus-raw"
                )

    fixture_rows = measurements.get("analytic_fixture_rows")
    if not isinstance(fixture_rows, list):
        raise P07GateError("P07 analytic fixture rows are absent")
    locked_fixtures = measurements.get("locked_analytic_fixtures")
    if not isinstance(locked_fixtures, list) or len(locked_fixtures) != 14:
        raise P07GateError("locked analytic fixture definitions are absent")
    expected_fixture_ids = [
        row.get("fixture_id") for row in locked_fixtures if isinstance(row, dict)
    ]
    if (
        len(expected_fixture_ids) != 14
        or len(expected_fixture_ids) != len(set(expected_fixture_ids))
    ):
        raise P07GateError("locked analytic fixture IDs are absent or duplicated")
    for definition in locked_fixtures:
        if not isinstance(definition, dict):
            raise P07GateError("locked analytic fixture definition is invalid")
        _sha(
            definition.get("fixture_definition_sha256"),
            "analytic fixture definition",
        )
    for domain in DOMAINS:
        domain_rows = [row for row in fixture_rows if row.get("comparison_domain") == domain]
        if [row.get("fixture_id") for row in domain_rows] != expected_fixture_ids:
            raise P07GateError(
                "{} analytic fixture order or coverage differs".format(domain)
            )
        for row, definition in zip(domain_rows, locked_fixtures):
            required_fields = {
                "fixture_id", "fixture_kind", "fixture_definition_sha256",
                "target_route", "comparison_domain",
                "configuration_sha256_by_control", "output_sha256_by_control",
                "writer_evidence_sha256_by_control", "metrics_by_control",
            }
            if set(row) != required_fields:
                raise P07GateError("P07 analytic row field set differs")
            if any(
                row[field] != definition[field]
                for field in (
                    "fixture_id",
                    "fixture_kind",
                    "fixture_definition_sha256",
                    "target_route",
                )
            ):
                raise P07GateError(
                    "P07 analytic fixture substitutes its locked definition"
                )
            _validate_control_maps(
                row,
                domain=domain,
                route=str(row["target_route"]),
                selected_aliases=aliases,
                configuration_hashes=configuration_hashes,
                fixture_kind=str(row["fixture_kind"]),
            )
    return rows, fixture_rows


def _bootstrap(
    rows: Sequence[Mapping[str, object]],
    candidate: str,
    baseline: str,
    metric: str,
) -> Mapping[str, object]:
    def metric_value(row: Mapping[str, object], control: str) -> float:
        bundle = row["metrics_by_control"][control]
        if metric in {"y_psnr_db", "cb_psnr_db", "cr_psnr_db"}:
            return _psnr_value(bundle, metric, "{} {}".format(control, metric))
        return _finite(bundle[metric], metric)

    records = [
        {
            "source_asset_id": row["source_asset_id"],
            "categories": row["categories"],
            "candidate": metric_value(row, candidate),
            "baseline": metric_value(row, baseline),
        }
        for row in rows
    ]
    return paired_bootstrap(
        records,
        replicates=BOOTSTRAP_REPLICATES,
        seed=BOOTSTRAP_SEED,
    )


def _domain_summary(
    rows: Sequence[Mapping[str, object]],
    fixtures: Sequence[Mapping[str, object]],
    tolerances: Mapping[str, object],
) -> Mapping[str, object]:
    bootstraps = {
        "y_full_vs_best_fixed": _bootstrap(rows, "full_ash", "best_fixed", "y_psnr_db"),
        "y_full_vs_non_ash": _bootstrap(rows, "full_ash", "non_ash_selector", "y_psnr_db"),
        "y_full_vs_conventional": _bootstrap(rows, "full_ash", "conventional", "y_psnr_db"),
        "ms_ssim_full_vs_conventional": _bootstrap(rows, "full_ash", "conventional", "y_ms_ssim"),
        "y_full_vs_state_only": _bootstrap(rows, "full_ash", "state_only", "y_psnr_db"),
    }
    h07_rows = [row for row in rows if row["target_route"] == "direct-3over2"]
    if not h07_rows:
        raise P07GateError("P07 H07 comparison has no direct-3over2 source")
    bootstraps["y_h07_direct_vs_control"] = _bootstrap(
        h07_rows, "full_ash", "h07_direct_3_over_2", "y_psnr_db"
    )
    bootstraps["ms_ssim_h07_direct_vs_control"] = _bootstrap(
        h07_rows, "full_ash", "h07_direct_3_over_2", "y_ms_ssim"
    )

    per_source: MutableMapping[str, List[float]] = {}
    source_categories: MutableMapping[str, set[str]] = {}
    source_families: Dict[str, str] = {}
    for row in rows:
        source = str(row["source_asset_id"])
        metrics = row["metrics_by_control"]
        delta = _psnr_value(metrics["full_ash"], "y_psnr_db", "full Y") - (
            _psnr_value(
                metrics["conventional"],
                "y_psnr_db",
                "conventional Y",
            )
        )
        per_source.setdefault(source, []).append(delta)
        source_categories.setdefault(source, set()).update(row["categories"])
        previous = source_families.setdefault(source, str(row["source_family_id"]))
        if previous != row["source_family_id"]:
            raise P07GateError("source family changes within domain")
    if any(len(values) != 3 for values in per_source.values()):
        raise P07GateError("each P07 source must have exactly three degradation rows")
    source_delta = {
        source: float(np.mean(values, dtype=np.float64))
        for source, values in sorted(per_source.items())
    }
    category_values: MutableMapping[str, List[float]] = {}
    category_families: MutableMapping[str, set[str]] = {}
    for source, categories in source_categories.items():
        for category in categories:
            category_values.setdefault(category, []).append(source_delta[source])
            category_families.setdefault(category, set()).add(source_families[source])
    category_means = {
        category: float(np.mean(values, dtype=np.float64))
        for category, values in sorted(category_values.items())
    }
    category_counts = {
        category: len(values)
        for category, values in sorted(category_families.items())
    }

    ringing = []
    ringing_increase = []
    alias = []
    alias_increase = []
    chroma = []
    chroma_increase = []
    edge_point_evidence = []
    thin_line_point_evidence = []
    for row in fixtures:
        full = row["metrics_by_control"]["full_ash"]
        conventional = row["metrics_by_control"]["conventional"]
        if row["fixture_kind"] == "edge_profile":
            edge_point_evidence.append(
                {
                    "fixture_id": row["fixture_id"],
                    "full_ash_edge_location_error_pixels": _finite(
                        full["edge_location_error_pixels"],
                        "edge-location error",
                    ),
                    "conventional_edge_location_error_pixels": _finite(
                        conventional["edge_location_error_pixels"],
                        "baseline edge-location error",
                    ),
                }
            )
        elif row["fixture_kind"] == "ringing":
            full_value = max(
                _finite(full["ringing_overshoot"], "ringing overshoot"),
                _finite(full["ringing_undershoot"], "ringing undershoot"),
            )
            conventional_value = max(
                _finite(conventional["ringing_overshoot"], "baseline ringing overshoot"),
                _finite(conventional["ringing_undershoot"], "baseline ringing undershoot"),
            )
            ringing.append(full_value)
            ringing_increase.append(full_value - conventional_value)
        elif row["fixture_kind"] == "alias":
            full_value = _finite(full["alias_forbidden_band_ratio"], "alias ratio")
            conventional_value = _finite(
                conventional["alias_forbidden_band_ratio"], "baseline alias ratio"
            )
            alias.append(full_value)
            alias_increase.append(full_value - conventional_value)
        elif row["fixture_kind"] == "chroma_displacement":
            full_value = _finite(
                full["chroma_displacement_pixels"], "chroma displacement"
            )
            conventional_value = _finite(
                conventional["chroma_displacement_pixels"],
                "baseline chroma displacement",
            )
            chroma.append(full_value)
            chroma_increase.append(full_value - conventional_value)
        elif row["fixture_kind"] == "thin_line":
            thin_line_point_evidence.append(
                {
                    "fixture_id": row["fixture_id"],
                    "full_ash_retention_ratio": _finite(
                        full["thin_line_retention_ratio"],
                        "thin-line retention",
                    ),
                    "full_ash_false_side_lobe_energy": _finite(
                        full["thin_line_false_side_lobe_energy"],
                        "thin-line false-side-lobe energy",
                    ),
                    "conventional_retention_ratio": _finite(
                        conventional["thin_line_retention_ratio"],
                        "baseline thin-line retention",
                    ),
                    "conventional_false_side_lobe_energy": _finite(
                        conventional["thin_line_false_side_lobe_energy"],
                        "baseline thin-line false-side-lobe energy",
                    ),
                }
            )
    if not all(
        (
            edge_point_evidence,
            ringing,
            ringing_increase,
            thin_line_point_evidence,
            alias,
            alias_increase,
            chroma,
            chroma_increase,
        )
    ):
        raise P07GateError("P07 analytic fixture aggregation is incomplete")

    control_y_means = {
        control: float(
            np.mean(
                [
                    _psnr_value(
                        row["metrics_by_control"][control],
                        "y_psnr_db",
                        control,
                    )
                    for row in rows
                ],
                dtype=np.float64,
            )
        )
        for control in CONTROL_ORDER
        if control != "h07_direct_3_over_2"
    }
    control_y_means["h07_direct_3_over_2"] = float(
        np.mean(
            [
                _psnr_value(
                    row["metrics_by_control"]["h07_direct_3_over_2"],
                    "y_psnr_db",
                    "H07",
                )
                for row in h07_rows
            ],
            dtype=np.float64,
        )
    )
    summary = {
        "bootstraps": bootstraps,
        "control_y_psnr_means_db": control_y_means,
        "per_source_y_psnr_delta_vs_conventional_db": source_delta,
        "global_mean_y_psnr_delta_vs_conventional_db": float(
            np.mean(list(source_delta.values()), dtype=np.float64)
        ),
        "severe_regression_source_assets": [],
        "category_mean_y_psnr_delta_vs_conventional_db": category_means,
        "category_source_family_counts": category_counts,
        "maximum_ringing_excursion": max(ringing),
        "maximum_ringing_increase": max(ringing_increase),
        "maximum_alias_ratio": max(alias),
        "maximum_alias_increase": max(alias_increase),
        "maximum_chroma_displacement_pixels": max(chroma),
        "maximum_chroma_displacement_increase_pixels": max(chroma_increase),
        "edge_profile_point_evidence": edge_point_evidence,
        "thin_line_point_evidence": thin_line_point_evidence,
    }

    failures = []
    y_bounds = tolerances["y_psnr_paired_delta_lower_bound_db"]
    for key, threshold_name in (
        ("y_full_vs_best_fixed", "full_spatial_ash_vs_best_fixed_same_bank"),
        ("y_full_vs_non_ash", "full_spatial_ash_vs_non_ash_same_bank_selector"),
        ("y_full_vs_conventional", "full_spatial_ash_vs_best_conventional_baseline"),
    ):
        if not bootstraps[key]["ci_low"] > y_bounds[threshold_name]:
            failures.append(key)
    if bootstraps["y_full_vs_state_only"]["ci_low"] <= 0.0:
        failures.append("y_full_vs_state_only")
    if bootstraps["y_h07_direct_vs_control"]["ci_low"] <= 0.0:
        failures.append("y_h07_direct_vs_control")
    ms_floor = tolerances["ms_ssim_noninferiority_lower_bound_minimum"]
    if bootstraps["ms_ssim_full_vs_conventional"]["ci_low"] < ms_floor:
        failures.append("ms_ssim_full_vs_conventional")
    if bootstraps["ms_ssim_h07_direct_vs_control"]["ci_low"] < ms_floor:
        failures.append("ms_ssim_h07_direct_vs_control")
    if (
        summary["maximum_ringing_excursion"]
        > max(
            tolerances["ringing_overshoot_absolute_maximum"],
            tolerances["ringing_undershoot_magnitude_absolute_maximum"],
        )
        or summary["maximum_ringing_increase"] > tolerances["ringing_increase_maximum"]
    ):
        failures.append("ringing")
    if (
        summary["maximum_alias_ratio"] > tolerances["alias_ratio_maximum"]
        or summary["maximum_alias_increase"] > tolerances["alias_increase_maximum"]
    ):
        failures.append("alias")
    if (
        summary["maximum_chroma_displacement_pixels"]
        > tolerances["chroma_displacement_pixels_maximum"]
        or summary["maximum_chroma_displacement_increase_pixels"]
        > tolerances["chroma_displacement_increase_pixels_maximum"]
    ):
        failures.append("chroma_displacement")
    severe = tolerances["severe_regression"]
    failing_sources = [
        source
        for source, value in source_delta.items()
        if value < severe["per_asset_y_psnr_delta_db_minimum"]
    ]
    summary["severe_regression_source_assets"] = failing_sources
    if len(failing_sources) / len(source_delta) > severe["allowed_asset_failure_fraction"]:
        failures.append("severe_asset_regression")
    if any(
        value < severe["per_category_mean_y_psnr_delta_db_minimum"]
        for value in category_means.values()
    ):
        failures.append("severe_category_regression")
    minimum = tolerances["minimum_source_families_per_category"]["holdout"]
    if set(category_counts) != set(QUALITY_CATEGORIES) or any(
        category_counts.get(category, 0) < minimum for category in QUALITY_CATEGORIES
    ):
        failures.append("category_source_family_coverage")
    return {**summary, "failures": failures, "pass": not failures}


def _cross_domain_summary(
    rows: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    raw = {
        (row["source_asset_id"], row["degradation_profile_id"]): row
        for row in rows
        if row["comparison_domain"] == "engine_raw"
    }
    decoded = {
        (row["source_asset_id"], row["degradation_profile_id"]): row
        for row in rows
        if row["comparison_domain"] == "container_decoded"
    }
    if tuple(raw) != tuple(decoded):
        raise P07GateError("raw/container case order differs for cross-domain deltas")
    y_by_control = {}
    for control in CONTROL_ORDER:
        records = []
        for key, raw_row in raw.items():
            decoded_row = decoded[key]
            raw_metrics = raw_row["metrics_by_control"][control]
            decoded_metrics = decoded_row["metrics_by_control"][control]
            if raw_metrics is None or decoded_metrics is None:
                if control != "h07_direct_3_over_2":
                    raise P07GateError("cross-domain metrics are unexpectedly absent")
                continue
            records.append(
                {
                    "source_asset_id": raw_row["source_asset_id"],
                    "categories": raw_row["categories"],
                    "candidate": _psnr_value(
                        decoded_metrics,
                        "y_psnr_db",
                        "decoded Y",
                    ),
                    "baseline": _psnr_value(
                        raw_metrics,
                        "y_psnr_db",
                        "raw Y",
                    ),
                }
            )
        y_by_control[control] = paired_bootstrap(
            records,
            replicates=BOOTSTRAP_REPLICATES,
            seed=BOOTSTRAP_SEED,
        )
    full_ms_records = [
        {
            "source_asset_id": raw_row["source_asset_id"],
            "categories": raw_row["categories"],
            "candidate": _finite(
                decoded[key]["metrics_by_control"]["full_ash"]["y_ms_ssim"],
                "decoded full MS-SSIM",
            ),
            "baseline": _finite(
                raw_row["metrics_by_control"]["full_ash"]["y_ms_ssim"],
                "raw full MS-SSIM",
            ),
        }
        for key, raw_row in raw.items()
    ]
    return {
        "comparison": "container_decoded_minus_engine_raw_paired_by_exact_source_profile",
        "domains_aggregated": False,
        "y_psnr_by_control": y_by_control,
        "full_ash_y_ms_ssim": paired_bootstrap(
            full_ms_records,
            replicates=BOOTSTRAP_REPLICATES,
            seed=BOOTSTRAP_SEED,
        ),
    }


def build_g07_artifacts(
    *,
    measurements: Mapping[str, object],
    locked_metric_policy: Mapping[str, object],
) -> Mapping[str, Mapping[str, object]]:
    """Validate exhaustive measurements and build deterministic G07 evidence."""

    rows, fixture_rows = _validate_measurements(measurements, locked_metric_policy)
    tolerances = locked_metric_policy["release_tolerances"]
    summaries = {}
    for domain in DOMAINS:
        summaries[domain] = _domain_summary(
            [row for row in rows if row["comparison_domain"] == domain],
            [row for row in fixture_rows if row["comparison_domain"] == domain],
            tolerances,
        )
    failures = [
        "{}:{}".format(domain, failure)
        for domain in DOMAINS
        for failure in summaries[domain]["failures"]
    ]
    cross_domain = _cross_domain_summary(rows)
    status = "pass" if not failures else "fail"
    spatial = _evidence_document(
        artifact_kind="p07_spatial_holdout_results",
        status=status,
        measurements=measurements,
        evidence={
            "domain_aggregation_performed": False,
            "domains": {
                domain: {
                    key: value
                    for key, value in summaries[domain].items()
                    if key not in {"bootstraps", "failures"}
                }
                for domain in DOMAINS
            },
            "cross_domain_writer_delta_point_estimates": {
                control: record["point_delta"]
                for control, record in cross_domain["y_psnr_by_control"].items()
            },
        },
    )
    bootstrap = _evidence_document(
        artifact_kind="p07_paired_bootstrap_results",
        status=status,
        measurements=measurements,
        evidence={
            "resampling_unit": "source_asset",
            "replicates": BOOTSTRAP_REPLICATES,
            "seed": BOOTSTRAP_SEED,
            "domains": {
                domain: summaries[domain]["bootstraps"] for domain in DOMAINS
            },
            "cross_domain_writer_deltas": cross_domain,
        },
    )
    aliases = measurements["selected_aliases"]
    ablation = _evidence_document(
        artifact_kind="p07_ablation_results",
        status=status,
        measurements=measurements,
        evidence={
            "required_control_order": list(CONTROL_ORDER),
            "fixed_operator_count": len(FIXED_CONTROLS),
            "conventional_control_count": len(CONVENTIONAL_CONTROLS),
            "selected_aliases": aliases,
            **(
                {
                    "selected_p06_evidence_projection": measurements[
                        "selected_p06_evidence_projection"
                    ]
                }
                if measurements.get("schema_version") == "2.0.0"
                else {
                    "locked_p06_performance_evidence": measurements[
                        "locked_p06_performance_evidence"
                    ]
                }
            ),
            "domains": {
                domain: {
                    "control_y_psnr_means_db": summaries[domain][
                        "control_y_psnr_means_db"
                    ],
                    "full_vs_state_only": summaries[domain]["bootstraps"][
                        "y_full_vs_state_only"
                    ],
                    "h07_direct_vs_control": summaries[domain]["bootstraps"][
                        "y_h07_direct_vs_control"
                    ],
                }
                for domain in DOMAINS
            },
            "raw_output_hash_coverage": sum(
                value is not None
                for row in rows
                if row["comparison_domain"] == "engine_raw"
                for value in row["output_sha256_by_control"].values()
            ),
            "container_writer_hash_coverage": sum(
                value is not None
                for row in rows
                if row["comparison_domain"] == "container_decoded"
                for value in row["writer_evidence_sha256_by_control"].values()
            ),
        },
    )
    decision = _evidence_document(
        artifact_kind="p07_gate_decision",
        status=status,
        measurements=measurements,
        evidence={
            "gate_id": "G07",
            "pass": not failures,
            "failures": failures,
            "same_version_reuse_permitted": False,
            "failure_rule": (
                "on failure preserve evidence, increment algorithm version, move this "
                "holdout to validation, and lock a new holdout"
            ),
        },
    )
    artifacts: Dict[str, Mapping[str, object]] = {
        "spatial-holdout-results.json": spatial,
        "paired-bootstrap-results.json": bootstrap,
        "ablation-results.json": ablation,
        "g07-decision.json": decision,
    }
    if failures:
        artifacts["failed-version-archive.json"] = _evidence_document(
            artifact_kind="p07_failed_version_archive",
            status="preserved_failure",
            measurements=measurements,
            evidence={
                "gate_id": "G07",
                "failures": failures,
                "measurement_sha256": measurements["measurement_sha256"],
                "same_version_reuse_permitted": False,
            },
        )
    return artifacts


def publish_g07_artifacts(
    *,
    output_directory: Path,
    measurements: Mapping[str, object],
    locked_metric_policy: Mapping[str, object],
) -> Mapping[str, object]:
    """Publish a complete G07 evidence set without replacing any file."""

    artifacts = build_g07_artifacts(
        measurements=measurements,
        locked_metric_policy=locked_metric_policy,
    )
    output_directory.mkdir(parents=False, exist_ok=True)
    bindings = {}
    for name, document in artifacts.items():
        path = output_directory / name
        _write_json(path, document)
        bindings[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    decision = artifacts["g07-decision.json"]
    is_v2 = measurements.get("schema_version") == "2.0.0"
    identity = (
        validate_identity_v2(measurements.get(IDENTITY_FIELD))
        if is_v2
        else None
    )
    document = {
        "schema_version": "2.0.0" if is_v2 else "1.0.0",
        "artifact_kind": (
            "p07_g07_publication_v2"
            if is_v2
            else "p07_g07_publication"
        ),
        **(
            {IDENTITY_FIELD: dict(identity)}
            if identity is not None
            else {}
        ),
        "status": decision["status"],
        "gate_pass": decision["evidence"]["pass"],
        "artifact_file_sha256": bindings,
        "holdout_accessed": True,
        "configuration_files_modified_after_holdout": False,
    }
    document["manifest_sha256"] = canonical_sha256(document)
    _validate_schema(
        document,
        PUBLICATION_V2_SCHEMA if is_v2 else PUBLICATION_SCHEMA,
        "P07 G07 publication",
    )
    return document
