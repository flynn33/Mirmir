from __future__ import annotations

import copy
import hashlib
import json
import math
from pathlib import Path
import tempfile
import unittest

import jsonschema

from validation.calibration_v2.p07.gate import (
    BOOTSTRAP_REPLICATES,
    BOOTSTRAP_SEED,
    CONTROL_ORDER,
    CONVENTIONAL_CONTROLS,
    DEGRADATION_KIND_ORDER,
    FIXED_CONTROLS,
    P07GateError,
    build_g07_artifacts,
    publish_g07_artifacts,
)
from validation.quality.src.mirmir_quality.corpus import QUALITY_CATEGORIES
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MEASUREMENT_SCHEMA = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/p07-spatial-holdout-measurements-v1.schema.json"
)


def _digest(value: object) -> str:
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()


def _psnr(value: float) -> dict[str, object]:
    return {
        "value": value,
        "mse": math.pow(10.0, -value / 10.0),
        "exact_match": False,
    }


def _metric(
    value: float,
    *,
    domain: str,
    fixture_kind: str | None,
) -> dict[str, object]:
    if fixture_kind is not None:
        fields = {
            "edge_location_error_pixels": None,
            "ringing_overshoot": None,
            "ringing_undershoot": None,
            "alias_forbidden_band_ratio": None,
            "thin_line_retention_ratio": None,
            "thin_line_false_side_lobe_energy": None,
            "chroma_displacement_pixels": None,
        }
        supported = {
            "edge_profile": {"edge_location_error_pixels": 0.05},
            "ringing": {
                "ringing_overshoot": 0.01,
                "ringing_undershoot": 0.01,
            },
            "thin_line": {
                "thin_line_retention_ratio": 0.95,
                "thin_line_false_side_lobe_energy": 0.01,
            },
            "alias": {"alias_forbidden_band_ratio": 0.01},
            "chroma_displacement": {"chroma_displacement_pixels": 0.05},
        }
        fields.update(supported[fixture_kind])
        return fields
    return {
        "y_psnr_db": _psnr(value),
        "cb_psnr_db": _psnr(value - 1.0),
        "cr_psnr_db": _psnr(value - 1.1),
        "y_ssim": 0.97 + (value - 29.0) * 0.001,
        "cb_ssim": 0.96 + (value - 29.0) * 0.001,
        "cr_ssim": 0.95 + (value - 29.0) * 0.001,
        "y_ms_ssim": 0.98 + (value - 29.0) * 0.001,
        "cb_ms_ssim": 0.97 + (value - 29.0) * 0.001,
        "cr_ms_ssim": 0.96 + (value - 29.0) * 0.001,
        "writer_y_psnr_contribution_db": (
            None if domain == "engine_raw" else value - (value + 0.05)
        ),
    }


def _values() -> dict[str, float]:
    values = {
        control: 29.0 + index * 0.01
        for index, control in enumerate(FIXED_CONTROLS)
    }
    values.update(
        {
            CONVENTIONAL_CONTROLS[0]: 29.0,
            CONVENTIONAL_CONTROLS[1]: 29.1,
            CONVENTIONAL_CONTROLS[2]: 29.2,
            "nearest_same_writer": 28.0,
            "current_production_ash": 29.3,
            "best_fixed": values[FIXED_CONTROLS[-1]],
            "conventional": 29.2,
            "non_ash_selector": 29.4,
            "state_only": 29.5,
            "full_ash": 30.0,
            "state_plus_branch": 30.0,
            "h07_direct_3_over_2": 29.6,
        }
    )
    return values


def _control_maps(
    *,
    domain: str,
    case: str,
    route: str,
    fixture_kind: str | None,
    configurations: dict[str, str],
) -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    values = _values()
    outputs: dict[str, object] = {}
    writers: dict[str, object] = {}
    metrics: dict[str, object] = {}
    for control in CONTROL_ORDER:
        if control == "h07_direct_3_over_2" and route != "direct-3over2":
            outputs[control] = None
            writers[control] = None
            metrics[control] = None
            continue
        source_control = control
        if control == "best_fixed":
            source_control = FIXED_CONTROLS[-1]
        elif control == "conventional":
            source_control = CONVENTIONAL_CONTROLS[-1]
        elif control == "state_plus_branch":
            source_control = "full_ash"
        outputs[control] = _digest((domain, case, source_control, "output"))
        writers[control] = (
            None
            if domain == "engine_raw"
            else _digest((domain, case, source_control, "writer"))
        )
        penalty = 0.0 if domain == "engine_raw" else 0.05
        metrics[control] = _metric(
            values[control] - penalty,
            domain=domain,
            fixture_kind=fixture_kind,
        )
        if control in {"best_fixed", "conventional", "state_plus_branch"}:
            metrics[control] = copy.deepcopy(metrics[source_control])
    return outputs, writers, metrics


def _policy() -> dict[str, object]:
    policy: dict[str, object] = {
        "schema_version": "2.0.0",
        "status": "locked",
        "comparison_domains": ["engine_raw", "container_decoded"],
        "domain_aggregation_forbidden": True,
        "analytic_fixture_manifest": {
            "manifest_sha256": _digest("analytic-fixtures"),
        },
        "bootstrap": {
            "unit": "source_asset",
            "replicates": BOOTSTRAP_REPLICATES,
            "seed": BOOTSTRAP_SEED,
        },
        "release_tolerances": {
            "y_psnr_paired_delta_lower_bound_db": {
                "full_spatial_ash_vs_best_fixed_same_bank": 0.0,
                "full_spatial_ash_vs_non_ash_same_bank_selector": 0.0,
                "full_spatial_ash_vs_best_conventional_baseline": 0.0,
                "comparison": "strictly_greater_than",
            },
            "ms_ssim_noninferiority_lower_bound_minimum": -0.002,
            "ringing_overshoot_absolute_maximum": 0.05,
            "ringing_undershoot_magnitude_absolute_maximum": 0.05,
            "ringing_increase_maximum": 0.01,
            "alias_ratio_maximum": 0.05,
            "alias_increase_maximum": 0.01,
            "chroma_displacement_pixels_maximum": 0.25,
            "chroma_displacement_increase_pixels_maximum": 0.1,
            "severe_regression": {
                "per_asset_y_psnr_delta_db_minimum": -0.25,
                "per_category_mean_y_psnr_delta_db_minimum": -0.1,
                "allowed_asset_failure_fraction": 0.0,
            },
            "minimum_source_families_per_category": {
                "development": 1,
                "validation": 1,
                "holdout": 1,
            },
        },
    }
    policy["policy_sha256"] = canonical_sha256(policy)
    return policy


def _measurement() -> tuple[dict[str, object], dict[str, object]]:
    policy = _policy()
    configurations = {control: _digest((control, "configuration")) for control in CONTROL_ORDER}
    configurations["best_fixed"] = configurations[FIXED_CONTROLS[-1]]
    configurations["conventional"] = configurations[CONVENTIONAL_CONTROLS[-1]]
    configurations["state_plus_branch"] = configurations["full_ash"]
    sources = ["source-a", "source-b", "source-c"]
    routes = {"source-a": "direct-3over2", "source-b": "direct-2x", "source-c": "direct-2x"}
    locked_profiles = [
        {
            "target_route": route,
            "kind": kind,
            "profile_id": "{}-{}".format(route, kind),
            "profile_sha256": _digest((route, kind, "profile")),
        }
        for route in ("direct-2x", "direct-3over2")
        for kind in DEGRADATION_KIND_ORDER
    ]
    profiles_by_route_kind = {
        (row["target_route"], row["kind"]): row for row in locked_profiles
    }
    corpus_rows = []
    for domain in ("engine_raw", "container_decoded"):
        for sampling_ordinal, source in enumerate(sources):
            for kind in DEGRADATION_KIND_ORDER:
                profile = profiles_by_route_kind[(routes[source], kind)]
                case = "{}:{}".format(source, kind)
                outputs, writers, metrics = _control_maps(
                    domain=domain,
                    case=case,
                    route=routes[source],
                    fixture_kind=None,
                    configurations=configurations,
                )
                corpus_rows.append(
                    {
                        "asset_id": "asset-{}".format(source),
                        "sampling_ordinal": sampling_ordinal,
                        "selected_presentation_time": {
                            "value": sampling_ordinal * 100,
                            "timescale": 100,
                        },
                        "source_asset_id": source,
                        "source_family_id": "{}-family".format(source),
                        "categories": list(QUALITY_CATEGORIES),
                        "target_route": routes[source],
                        "degradation_kind": kind,
                        "degradation_profile_id": profile["profile_id"],
                        "degradation_profile_sha256": profile["profile_sha256"],
                        "source_crop_nv12_sha256": _digest((source, "crop")),
                        "degraded_input_frame_sha256": _digest((case, "input")),
                        "comparison_domain": domain,
                        "configuration_sha256_by_control": copy.deepcopy(configurations),
                        "output_sha256_by_control": outputs,
                        "writer_evidence_sha256_by_control": writers,
                        "metrics_by_control": metrics,
                    }
                )
    fixture_rows = []
    kinds = (
        "edge_profile", "ringing", "thin_line", "alias",
        "chroma_displacement", "edge_profile", "ringing",
        "thin_line", "alias", "chroma_displacement", "edge_profile",
        "ringing", "alias", "chroma_displacement",
    )
    locked_fixtures = [
        {
            "fixture_id": "fixture-{:02d}".format(index),
            "fixture_kind": kind,
            "target_route": "direct-3over2" if index in {4, 9, 13} else "direct-2x",
            "fixture_definition_sha256": _digest((index, kind, "definition")),
        }
        for index, kind in enumerate(kinds)
    ]
    for domain in ("engine_raw", "container_decoded"):
        for definition in locked_fixtures:
            fixture_id = definition["fixture_id"]
            kind = definition["fixture_kind"]
            route = definition["target_route"]
            outputs, writers, metrics = _control_maps(
                domain=domain,
                case=fixture_id,
                route=route,
                fixture_kind=kind,
                configurations=configurations,
            )
            fixture_rows.append(
                {
                    "fixture_id": fixture_id,
                    "fixture_kind": kind,
                    "fixture_definition_sha256": definition[
                        "fixture_definition_sha256"
                    ],
                    "target_route": route,
                    "comparison_domain": domain,
                    "configuration_sha256_by_control": copy.deepcopy(configurations),
                    "output_sha256_by_control": outputs,
                    "writer_evidence_sha256_by_control": writers,
                    "metrics_by_control": metrics,
                }
            )
    measurement: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_spatial_holdout_measurements",
        "status": "complete",
        "configuration_sha256": _digest("configuration-lock"),
        "locked_metric_policy_sha256": policy["policy_sha256"],
        "sampling_plan_manifest_sha256": _digest("sampling-plan"),
        "frame_extraction_manifest_sha256": _digest("frame-extraction"),
        "runtime_evidence_manifest_sha256": _digest("runtime-evidence"),
        "analytic_fixture_manifest_sha256": _digest("analytic-fixtures"),
        "comparison_domains": ["engine_raw", "container_decoded"],
        "source_order": sources,
        "degradation_kind_order": list(DEGRADATION_KIND_ORDER),
        "locked_degradation_profiles": locked_profiles,
        "locked_analytic_fixtures": locked_fixtures,
        "selected_aliases": {
            "best_fixed": FIXED_CONTROLS[-1],
            "conventional": CONVENTIONAL_CONTROLS[-1],
        },
        "control_configuration_sha256_by_control": configurations,
        "locked_p06_performance_evidence": {
            "selected_evaluation_sha256": _digest("selected-evaluation"),
            "full_frames_per_second": 2.0,
            "h07_control_frames_per_second": 1.5,
            "full_dispatch_cost": 1.0,
            "h07_control_dispatch_cost": 1.2,
            "no_worse_frames_per_second": True,
            "no_worse_dispatch_cost": True,
        },
        "corpus_rows": corpus_rows,
        "analytic_fixture_rows": fixture_rows,
        "holdout_accessed": True,
        "configuration_files_modified_after_holdout": False,
    }
    measurement["measurement_sha256"] = canonical_sha256(measurement)
    return measurement, policy


def _rehash(measurement: dict[str, object]) -> None:
    measurement["measurement_sha256"] = canonical_sha256(
        {key: value for key, value in measurement.items() if key != "measurement_sha256"}
    )


class P07GateTests(unittest.TestCase):
    def test_complete_exhaustive_evidence_passes_deterministically(self) -> None:
        measurement, policy = _measurement()
        first = build_g07_artifacts(
            measurements=measurement,
            locked_metric_policy=policy,
        )
        second = build_g07_artifacts(
            measurements=copy.deepcopy(measurement),
            locked_metric_policy=copy.deepcopy(policy),
        )

        self.assertEqual(first, second)
        decision = first["g07-decision.json"]
        self.assertTrue(decision["evidence"]["pass"])
        self.assertNotIn("failed-version-archive.json", first)
        bootstrap = first["paired-bootstrap-results.json"]["evidence"]
        self.assertEqual(bootstrap["replicates"], 10_000)
        self.assertEqual(bootstrap["seed"], 20_260_710)
        self.assertFalse(
            bootstrap["cross_domain_writer_deltas"]["domains_aggregated"]
        )
        ablation = first["ablation-results.json"]["evidence"]
        self.assertEqual(ablation["fixed_operator_count"], 16)
        self.assertEqual(ablation["conventional_control_count"], 3)
        self.assertEqual(ablation["raw_output_hash_coverage"], 246)
        self.assertEqual(ablation["container_writer_hash_coverage"], 246)
        spatial = first["spatial-holdout-results.json"]["evidence"]["domains"]
        for domain in ("engine_raw", "container_decoded"):
            self.assertTrue(spatial[domain]["edge_profile_point_evidence"])
            self.assertTrue(spatial[domain]["thin_line_point_evidence"])

    def test_schema_rejects_extraneous_metric_field(self) -> None:
        measurement, _ = _measurement()
        measurement["corpus_rows"][0]["metrics_by_control"]["full_ash"][
            "forged_metric"
        ] = 1.0
        _rehash(measurement)
        schema = json.loads(MEASUREMENT_SCHEMA.read_text(encoding="utf-8"))
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(schema).validate(measurement)

    def test_publication_schema_rejects_extraneous_field(self) -> None:
        measurement, policy = _measurement()
        with tempfile.TemporaryDirectory() as temporary:
            summary = publish_g07_artifacts(
                output_directory=Path(temporary).resolve() / "gate",
                measurements=measurement,
                locked_metric_policy=policy,
            )
        schema = json.loads(
            (
                REPOSITORY_ROOT
                / "validation/calibration_v2/schemas/p07-g07-publication-v1.schema.json"
            ).read_text(encoding="utf-8")
        )
        jsonschema.Draft202012Validator(schema).validate(summary)
        forged = dict(summary)
        forged["extraneous_field"] = True
        forged["manifest_sha256"] = canonical_sha256(
            {
                key: value
                for key, value in forged.items()
                if key != "manifest_sha256"
            }
        )
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(schema).validate(forged)

    def test_schema_rejects_inconsistent_exact_psnr_projection(self) -> None:
        measurement, _ = _measurement()
        measurement["corpus_rows"][0]["metrics_by_control"]["full_ash"][
            "cb_psnr_db"
        ] = {"value": None, "mse": 1.0, "exact_match": True}
        _rehash(measurement)
        schema = json.loads(MEASUREMENT_SCHEMA.read_text(encoding="utf-8"))
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(schema).validate(measurement)

    def test_exact_corpus_psnr_is_preserved_but_not_aggregated(self) -> None:
        measurement, policy = _measurement()
        measurement["corpus_rows"][0]["metrics_by_control"]["full_ash"][
            "y_psnr_db"
        ] = {"value": None, "mse": 0, "exact_match": True}
        _rehash(measurement)
        schema = json.loads(MEASUREMENT_SCHEMA.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(measurement)
        with self.assertRaisesRegex(P07GateError, "finite non-exact"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_exact_unused_corpus_chroma_is_accepted(self) -> None:
        measurement, policy = _measurement()
        for row in measurement["corpus_rows"]:
            for control, bundle in row["metrics_by_control"].items():
                if bundle is not None:
                    bundle["cb_psnr_db"] = {
                        "value": None,
                        "mse": 0,
                        "exact_match": True,
                    }
        _rehash(measurement)
        artifacts = build_g07_artifacts(
            measurements=measurement,
            locked_metric_policy=policy,
        )
        self.assertTrue(artifacts["g07-decision.json"]["evidence"]["pass"])

    def test_tampered_psnr_mse_fails_semantic_validation(self) -> None:
        measurement, policy = _measurement()
        measurement["corpus_rows"][0]["metrics_by_control"]["full_ash"][
            "y_psnr_db"
        ]["mse"] *= 2.0
        _rehash(measurement)
        with self.assertRaisesRegex(P07GateError, "binary64 ULP"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_out_of_range_ssim_fails_semantic_validation(self) -> None:
        measurement, policy = _measurement()
        measurement["corpus_rows"][0]["metrics_by_control"]["full_ash"][
            "y_ms_ssim"
        ] = 1.01
        _rehash(measurement)
        with self.assertRaisesRegex(P07GateError, "outside"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_writer_delta_substitution_fails(self) -> None:
        measurement, policy = _measurement()
        decoded = next(
            row
            for row in measurement["corpus_rows"]
            if row["comparison_domain"] == "container_decoded"
        )
        decoded["metrics_by_control"]["full_ash"][
            "writer_y_psnr_contribution_db"
        ] = 0.0
        decoded["metrics_by_control"]["state_plus_branch"] = copy.deepcopy(
            decoded["metrics_by_control"]["full_ash"]
        )
        _rehash(measurement)
        with self.assertRaisesRegex(P07GateError, "decoded-minus-raw"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_analytic_metric_nullability_is_fixture_kind_exact(self) -> None:
        measurement, policy = _measurement()
        row = next(
            value
            for value in measurement["analytic_fixture_rows"]
            if value["fixture_kind"] == "edge_profile"
        )
        bundle = row["metrics_by_control"]["full_ash"]
        bundle["edge_location_error_pixels"] = None
        bundle["ringing_overshoot"] = 0.01
        row["metrics_by_control"]["state_plus_branch"] = copy.deepcopy(bundle)
        _rehash(measurement)
        schema = json.loads(MEASUREMENT_SCHEMA.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(measurement)
        with self.assertRaisesRegex(P07GateError, "nullability"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_schema_rejects_missing_fixed_control(self) -> None:
        measurement, policy = _measurement()
        for mapping_name in (
            "control_configuration_sha256_by_control",
        ):
            measurement[mapping_name].pop("fixed_descriptor_00")
        for row in measurement["corpus_rows"] + measurement["analytic_fixture_rows"]:
            for mapping_name in (
                "configuration_sha256_by_control",
                "output_sha256_by_control",
                "writer_evidence_sha256_by_control",
                "metrics_by_control",
            ):
                row[mapping_name].pop("fixed_descriptor_00")
        _rehash(measurement)
        schema = json.loads(MEASUREMENT_SCHEMA.read_text(encoding="utf-8"))
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(schema).validate(measurement)

    def test_selected_alias_writer_substitution_fails(self) -> None:
        measurement, policy = _measurement()
        decoded = next(
            row
            for row in measurement["corpus_rows"]
            if row["comparison_domain"] == "container_decoded"
        )
        decoded["writer_evidence_sha256_by_control"]["best_fixed"] = _digest("forged")
        _rehash(measurement)

        with self.assertRaisesRegex(P07GateError, "selected aliases"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_forged_pareto_boolean_with_worse_numeric_evidence_fails(self) -> None:
        measurement, policy = _measurement()
        measurement["locked_p06_performance_evidence"]["full_frames_per_second"] = 1.0
        _rehash(measurement)
        schema = json.loads(MEASUREMENT_SCHEMA.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(measurement)

        with self.assertRaisesRegex(P07GateError, "Pareto"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_gate_failure_is_preserved_and_same_version_is_forbidden(self) -> None:
        measurement, policy = _measurement()
        for row in measurement["corpus_rows"]:
            row["metrics_by_control"]["full_ash"]["y_psnr_db"] = _psnr(28.0)
            row["metrics_by_control"]["full_ash"][
                "writer_y_psnr_contribution_db"
            ] = None if row["comparison_domain"] == "engine_raw" else 0.0
            row["metrics_by_control"]["state_plus_branch"] = copy.deepcopy(
                row["metrics_by_control"]["full_ash"]
            )
        _rehash(measurement)

        artifacts = build_g07_artifacts(
            measurements=measurement,
            locked_metric_policy=policy,
        )

        self.assertFalse(artifacts["g07-decision.json"]["evidence"]["pass"])
        self.assertIn("failed-version-archive.json", artifacts)
        self.assertFalse(
            artifacts["failed-version-archive.json"]["evidence"]
            ["same_version_reuse_permitted"]
        )

    def test_route_specific_profile_substitution_fails(self) -> None:
        measurement, policy = _measurement()
        row = next(
            row
            for row in measurement["corpus_rows"]
            if row["target_route"] == "direct-3over2"
        )
        direct2 = next(
            profile
            for profile in measurement["locked_degradation_profiles"]
            if profile["target_route"] == "direct-2x"
            and profile["kind"] == row["degradation_kind"]
        )
        row["degradation_profile_id"] = direct2["profile_id"]
        row["degradation_profile_sha256"] = direct2["profile_sha256"]
        _rehash(measurement)

        with self.assertRaisesRegex(P07GateError, "route-specific"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_omitted_analytic_fixture_fails(self) -> None:
        measurement, policy = _measurement()
        measurement["analytic_fixture_rows"].pop(0)
        _rehash(measurement)

        with self.assertRaises(Exception):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_reordered_analytic_fixture_fails(self) -> None:
        measurement, policy = _measurement()
        rows = measurement["analytic_fixture_rows"]
        rows[0], rows[1] = rows[1], rows[0]
        _rehash(measurement)

        with self.assertRaisesRegex(P07GateError, "order or coverage"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )

    def test_substituted_analytic_fixture_definition_fails(self) -> None:
        measurement, policy = _measurement()
        measurement["analytic_fixture_rows"][0][
            "fixture_definition_sha256"
        ] = _digest("substituted-definition")
        _rehash(measurement)

        with self.assertRaisesRegex(P07GateError, "substitutes"):
            build_g07_artifacts(
                measurements=measurement,
                locked_metric_policy=policy,
            )


if __name__ == "__main__":
    unittest.main()
