from __future__ import annotations

from contextlib import redirect_stderr
from copy import deepcopy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import validation.calibration_v2.p08.staging as p08_staging
from validation.calibration_v2.p08.evidence import (
    ARTIFACT_SCHEMAS,
    BUNDLED_RELEASE_RESOURCES,
    CHECK_IDS,
    DESCRIPTOR_IDS,
    G08_GATE_FILENAME,
    HASH_SCOPE,
    PERFORMANCE_MODES,
    PERFORMANCE_FIXTURE_SHA256,
    PHASE_COUNTS,
    PLANES,
    PROFILE_TOOLS,
    P08EvidenceError,
    ROUTES,
    _expected_raw_bindings,
    _finalize_promoted_g08,
    _gate_checks,
    _load_tolerances,
    file_binding,
    repository_identity,
    tree_binding,
)
from validation.calibration_v2.p08.staging import (
    CAPTURE_ARCHIVES,
    NATIVE_FILENAME,
    PRE_G07_MANIFEST_FILENAME,
    PROFILE_ARCHIVES,
    XCTEST_ARCHIVES,
    promote_after_g07,
    stage_pre_g07,
    validate_native_measurements,
)
from validation.calibration_v2.tools.finalize_g08 import main as finalize_g08_main
from validation.calibration_v2.tools.stage_p08_native_evidence import (
    main as stage_p08_native_evidence_main,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
SCHEMA_ROOT = ROOT / "validation/calibration_v2/schemas"


def _sha(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _write_canonical(path: Path, document: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json_bytes(document) + b"\n")


def _write_candidate(path: Path, document: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


def _seal(document: dict[str, object]) -> dict[str, object]:
    document["artifact_sha256"] = canonical_sha256(document)
    return document


class P08Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.repository = root / "repository"
        self.repository.mkdir()
        (self.repository / "source.txt").write_text("tracked source\n", encoding="utf-8")
        self._git("init")
        (self.repository / ".git/info/exclude").write_text(
            "Artifacts/ASH/\n",
            encoding="utf-8",
        )
        self._git("config", "user.email", "test@example.invalid")
        self._git("config", "user.name", "P08 Test")
        self._git("add", "source.txt")
        self._git("commit", "-m", "fixture")
        self.source_identity = repository_identity(self.repository)
        artifact_parent = self.repository / "Artifacts" / "ASH"
        artifact_parent.mkdir(parents=True)
        self.output = artifact_parent / "g08-run"
        self.staging = artifact_parent / ".g08-run.partial"
        self.staging.mkdir()
        self._build_raw_trees()
        self._build_release_inputs()
        self.documents = self._documents()
        self.write_documents()

    def _git(self, *arguments: str) -> None:
        subprocess.run(
            ["git", "-C", os.fspath(self.repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"},
        )

    def _raw_tree(self, relative: str, payload: bytes) -> dict[str, object]:
        path = self.staging / relative
        path.mkdir(parents=True)
        (path / "evidence.bin").write_bytes(payload)
        return dict(tree_binding(path, relative_path=relative))

    def _build_raw_trees(self) -> None:
        self.parity_tree = self._raw_tree(
            "raw/metal-parity.xcresult",
            b"generated XCTest parity result",
        )
        self.performance_tree = self._raw_tree(
            "raw/performance.xcresult",
            b"generated benchmark result",
        )
        self.resource_tree = self._raw_tree(
            "raw/resource-ring.xcresult",
            b"generated resource result",
        )
        self.profile_trees: dict[tuple[str, str], dict[str, object]] = {}
        for tool in PROFILE_TOOLS:
            for route in ROUTES:
                relative = f"raw/{tool}-{route}.trace"
                self.profile_trees[(tool, route)] = self._raw_tree(
                    relative,
                    f"{tool}:{route}".encode("utf-8"),
                )
        self.capture_trees = {
            route: self._raw_tree(
                f"raw/{route}.gputrace",
                f"capture:{route}".encode("utf-8"),
            )
            for route in ROUTES
        }

    def _locked_policy(self) -> dict[str, object]:
        seed = json.loads(
            (
                ROOT / "validation/quality/policies/metric-policy.json"
            ).read_text(encoding="utf-8")
        )
        tolerance_payload = (
            ROOT
            / "validation/calibration_v2/contracts/metric-performance-tolerances-v1.json"
        ).read_bytes()
        seed["schema_version"] = "2.0.0"
        seed["status"] = "locked"
        seed["unlocked_release_fields"] = []
        seed["release_tolerances"] = {
            "contract_path": (
                "validation/calibration_v2/contracts/"
                "metric-performance-tolerances-v1.json"
            ),
            "contract_sha256": hashlib.sha256(tolerance_payload).hexdigest(),
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
            "temporal_ghosting": {
                "normalized_error_absolute_maximum": 0.02,
                "increase_over_spatial_maximum": 0.005,
                "scene_cut_reset_latency_frames_maximum": 1,
            },
            "dispatch_overhead_budget": {
                "measured_validation_p95_percent": 12.2,
                "uncertainty_margin_percentage_points": 5.0,
                "derived_budget_percent": 18,
                "measurement_run_ids": ["validation-dispatch-001"],
                "measurement_artifact_sha256_values": [_sha("dispatch-measurement")],
                "derivation_formula": "max(5, ceil(measured_validation_p95_percent + 5))",
                "locked_before_g08": True,
                "post_g08_adjustment_allowed": False,
            },
        }
        seed["dispatch_measurement_evidence"] = {
            "path": "dispatch-measurement.json",
            "sha256": _sha("dispatch-measurement"),
            "size_bytes": 100,
            "measurement_domain": "native_cpu_reference_projection_not_metal",
            "production_metal_constraint_satisfied": False,
            "status": "pass",
        }
        seed["hash_scope"] = (
            "canonical sorted-key compact UTF-8 JSON excluding /policy_sha256"
        )
        seed.pop("policy_sha256", None)
        seed["policy_sha256"] = canonical_sha256(seed)
        return seed

    def _selected_evaluation(self) -> dict[str, object]:
        schema = json.loads(
            (SCHEMA_ROOT / "candidate-evaluation-v2.schema.json").read_text(
                encoding="utf-8"
            )
        )
        physical_items = []
        for ordinal, item_schema in enumerate(
            schema["properties"]["physical_candidate_items"]["prefixItems"]
        ):
            name = item_schema["prefixItems"][0]["const"]
            if (
                name.endswith("_policy_id")
                or name.endswith("_coordinate_policy")
                or name == "boundary_mode"
            ):
                value: object = f"value-{ordinal}"
            else:
                value = ordinal
            physical_items.append([name, value])
        evaluation = {
            "feasible": True,
            "failure_reasons": [],
            "objective": {
                "y_vs_fixed_ci_low": 0.1,
                "y_vs_non_ash_ci_low": 0.1,
                "y_vs_conventional_ci_low": 0.1,
                "mean_ms_ssim_delta_vs_conventional": 0.01,
                "maximum_ringing_excursion": 0.01,
                "maximum_alias_ratio": 0.01,
                "estimated_dispatch_cost": 2.1,
            },
        }
        document: dict[str, object] = {
            "schema_version": "2.0.3",
            "artifact_kind": "p06_candidate_evaluation_v2",
            "authority_bindings": deepcopy(
                schema["$defs"]["authorityBindings"]["const"]
            ),
            "run_id": "p06-generated-validation",
            "candidate_id": "generated-candidate",
            "split": "validation",
            "candidate_vector_sha256": _sha("candidate"),
            "adapter_configuration_sha256": _sha("adapter-configuration"),
            "physical_candidate_items": physical_items,
            "shared_bank_configuration_sha256": _sha("shared-bank"),
            "degradation_policy_sha256": _sha("degradation-policy"),
            "source_profile_matrix_sha256": _sha("validation-profile-matrix"),
            "evaluation_cache_identity": {
                "split": "validation",
                "candidate_vector_sha256": _sha("candidate"),
                "calibration_plan_v2_file_sha256": schema["$defs"][
                    "authorityBindings"
                ]["const"]["calibration_plan_v2"]["file_sha256"],
            },
            "source_evidence_sha256_bindings": [
                {
                    "id": gate,
                    "path": f"gates/{gate.lower()}.json",
                    "sha256": _sha(f"source-{gate}"),
                    "size_bytes": 1,
                }
                for gate in ("G04", "G05", "G06")
            ],
            "compiler_input": {
                "file_sha256": _sha("compiler-file"),
                "payload_sha256": _sha("compiler-payload"),
            },
            "route_lut_bindings": [
                {
                    "route": "direct-2x",
                    "whole_file_sha256": self.lut_bindings["direct_2x"]["sha256"],
                    "payload_sha256": _sha("direct-2x-payload"),
                },
                {
                    "route": "direct-3over2",
                    "whole_file_sha256": self.lut_bindings[
                        "direct_3_over_2"
                    ]["sha256"],
                    "payload_sha256": _sha("direct-3over2-payload"),
                },
            ],
            "runtime_evidence_sha256": _sha("selected-runtime"),
            "control_authorization_bundle": {
                "artifact_kind": "p06_control_authorization_bundle_v2",
                "schema_sha256": (
                    "c5d79fa2b6b8b574532d4a83d95a4e543f6a9dde769bc8c3f3969d5167729582"
                ),
                "path": "controls/generated-authorization.json",
                "sha256": _sha("control-authorization"),
                "size_bytes": 1,
            },
            "evaluation": evaluation,
            "evaluation_semantic_sha256": canonical_sha256(evaluation),
            "checks": [
                {
                    "check_id": "generated-validation-check",
                    "status": "pass",
                    "evidence_sha256": _sha("selected-check"),
                }
            ],
            "evaluation_status": "feasible",
            "data_access": {
                "development_accessed": False,
                "validation_accessed": True,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
        }
        document["evidence_sha256"] = canonical_sha256(document)
        document["artifact_sha256"] = canonical_sha256(document)
        return document

    def _release(self, policy_binding: dict[str, object]) -> dict[str, object]:
        schema = json.loads(
            (SCHEMA_ROOT / "p06-release-bundle-v3.schema.json").read_text(
                encoding="utf-8"
            )
        )
        artifacts = []
        for ordinal, item_schema in enumerate(
            schema["properties"]["artifacts"]["prefixItems"]
        ):
            refinements = item_schema["allOf"][1]["properties"]
            identifier = refinements["id"]["const"]
            path_rule = refinements["path"]
            path = path_rule.get("const", "")
            sha256 = _sha(f"release-artifact-{ordinal}")
            size_bytes = 1
            if identifier == "selected_evaluation":
                sha256 = str(self.selected_evaluation_binding["sha256"])
                size_bytes = int(self.selected_evaluation_binding["size_bytes"])
                path = f"evaluations/{sha256}.json"
            elif identifier == "locked_metric_policy":
                sha256 = str(policy_binding["sha256"])
                size_bytes = int(policy_binding["size_bytes"])
            elif identifier == "direct2x_lut":
                sha256 = str(self.lut_bindings["direct_2x"]["sha256"])
                size_bytes = int(self.lut_bindings["direct_2x"]["size_bytes"])
            elif identifier == "direct3over2_lut":
                sha256 = str(self.lut_bindings["direct_3_over_2"]["sha256"])
                size_bytes = int(self.lut_bindings["direct_3_over_2"]["size_bytes"])
            for resource_key, resource_artifact_id, filename in (
                BUNDLED_RELEASE_RESOURCES
            ):
                if identifier == resource_artifact_id:
                    resource_binding = self.bundled_resource_bindings[resource_key]
                    path = filename
                    sha256 = str(resource_binding["sha256"])
                    size_bytes = int(resource_binding["size_bytes"])
            artifacts.append(
                {
                    "id": identifier,
                    "path": path,
                    "sha256": sha256,
                    "size_bytes": size_bytes,
                    "producer": "generated-test",
                    "command": "generated-only",
                    "platform": "macOS",
                    "gate_bindings": ["G06"],
                }
            )
        document: dict[str, object] = {
            "schema_version": "3.0.1",
            "artifact_kind": "p06_release_bundle_v3",
            "bundle_id": "mirmir-p06-spatial-release-lock-v3",
            "status": "locked_before_p07",
            "configuration_id": "ash-p06-0123456789abcdef01234567",
            "locked_utc": "2026-07-16T12:00:00Z",
            "authority_bindings": deepcopy(
                schema["$defs"]["authorityBindings"]["const"]
            ),
            "shared_bank_configuration_sha256": _sha("shared-bank"),
            "input_bundle_sha256": _sha("input-bundle"),
            "corpus_lock_bundle_sha256": _sha("corpus-lock"),
            "release_fields_complete": True,
            "configuration_files_modified_after_lock": False,
            "holdout_accessed": False,
            "holdout_access_count": 0,
            "artifact_ids": deepcopy(
                schema["properties"]["artifact_ids"]["const"]
            ),
            "artifacts": artifacts,
            "filesystem_closure_rule": "all_entries_except_self_manifest_v1",
            "filesystem_closure": [
                {
                    "path": "calibration-selection-v2.json",
                    "entry_kind": "regular_file",
                    "sha256": _sha("filesystem-entry"),
                    "size_bytes": 1,
                    "executable_mode_bits": 0,
                }
            ],
            "authorized_execution_bindings_sha256": _sha("execution-authority"),
            "p07_authorization_status": "ready_for_single_locked_holdout_execution",
        }
        document["artifact_sha256"] = canonical_sha256(document)
        return document

    def _build_release_inputs(self) -> None:
        inputs = self.staging / "inputs"
        inputs.mkdir()
        app = inputs / "Mirmir.app"
        executable = app / "Contents/MacOS/Mirmir"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"generated native executable")
        resources = app / "Contents/Resources"
        locked_resources = resources / "ASH/LockedV3"
        locked_resources.mkdir(parents=True)
        for resource_key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES:
            (locked_resources / filename).write_bytes(
                f"generated release resource:{resource_key}".encode("utf-8")
            )
        metal = resources / "default.metallib"
        metal.write_bytes(b"generated Metal library")
        self.executable_binding = dict(
            file_binding(
                executable,
                relative_path="inputs/Mirmir.app/Contents/MacOS/Mirmir",
            )
        )
        self.app_binding = dict(
            tree_binding(app, relative_path="inputs/Mirmir.app")
        )
        self.metal_binding = dict(
            file_binding(
                metal,
                relative_path="inputs/Mirmir.app/Contents/Resources/default.metallib",
            )
        )
        locked_relative = "inputs/Mirmir.app/Contents/Resources/ASH/LockedV3"
        self.bundled_resource_root_binding = dict(
            tree_binding(locked_resources, relative_path=locked_relative)
        )
        self.bundled_resource_bindings = {
            resource_key: dict(
                file_binding(
                    locked_resources / filename,
                    relative_path=f"{locked_relative}/{filename}",
                )
            )
            for resource_key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES
        }
        self.lut_bindings = {
            "direct_2x": self.bundled_resource_bindings["direct2x_lut"],
            "direct_3_over_2": self.bundled_resource_bindings["direct3over2_lut"],
        }

        self.selected_evaluation = self._selected_evaluation()
        selected_evaluation_path = inputs / "selected-evaluation.json"
        _write_canonical(selected_evaluation_path, self.selected_evaluation)
        self.selected_evaluation_binding = dict(
            file_binding(
                selected_evaluation_path,
                relative_path="inputs/selected-evaluation.json",
            )
        )
        self.selected_evaluation_artifact_sha256 = self.selected_evaluation[
            "artifact_sha256"
        ]

        self.policy = self._locked_policy()
        policy_path = inputs / "locked-metric-policy.json"
        _write_canonical(policy_path, self.policy)
        self.policy_binding = dict(
            file_binding(
                policy_path,
                relative_path="inputs/locked-metric-policy.json",
            )
        )
        self.release = self._release(self.policy_binding)
        release_path = inputs / "p06-release.json"
        _write_canonical(release_path, self.release)
        self.release_binding = dict(
            file_binding(release_path, relative_path="inputs/p06-release.json")
        )
        selected_file_hash = next(
            row["sha256"]
            for row in self.release["artifacts"]
            if row["id"] == "selected_evaluation"
        )
        self.g07_p06_identity = {
            "calibration_plan_v2_file_sha256": _sha("calibration-plan"),
            "candidate_vector_sha256": _sha("candidate"),
            "shared_bank_configuration_sha256": self.release[
                "shared_bank_configuration_sha256"
            ],
            "input_bundle_sha256": self.release["input_bundle_sha256"],
            "p06_release_bundle_artifact_sha256": self.release["artifact_sha256"],
            "selected_evaluation_file_sha256": selected_file_hash,
            "selected_evaluation_artifact_sha256": (
                self.selected_evaluation_artifact_sha256
            ),
            "selected_evaluation_semantic_sha256": self.selected_evaluation[
                "evaluation_semantic_sha256"
            ],
        }
        g07: dict[str, object] = {
            "schema_version": "2.0.0",
            "artifact_kind": "p07_g07_publication_v2",
            "p06_v2_identity": self.g07_p06_identity,
            "status": "pass",
            "gate_pass": True,
            "artifact_file_sha256": {},
            "holdout_accessed": True,
            "configuration_files_modified_after_holdout": False,
        }
        g07["manifest_sha256"] = canonical_sha256(g07)
        self.g07 = g07
        g07_path = inputs / "g07-publication.json"
        _write_canonical(g07_path, g07)
        self.g07_binding = dict(
            file_binding(g07_path, relative_path="inputs/g07-publication.json")
        )

    def _identity(self) -> dict[str, object]:
        tolerance_payload = (
            ROOT
            / "validation/calibration_v2/contracts/metric-performance-tolerances-v1.json"
        ).read_bytes()
        return {
            "run_id": "g08-run",
            **self.source_identity,
            "configuration_id": self.release["configuration_id"],
            "p06_release_bundle": {
                "file": self.release_binding,
                "artifact_sha256": self.release["artifact_sha256"],
            },
            "selected_evaluation_file": self.selected_evaluation_binding,
            "selected_evaluation_artifact_sha256": (
                self.selected_evaluation_artifact_sha256
            ),
            "g07_publication": {
                "file": self.g07_binding,
                "manifest_sha256": self.g07["manifest_sha256"],
            },
            "metric_tolerances_file_sha256": hashlib.sha256(
                tolerance_payload
            ).hexdigest(),
            "locked_metric_policy": {
                "file": self.policy_binding,
                "policy_sha256": self.policy["policy_sha256"],
                "dispatch_overhead_budget": self.policy["release_tolerances"][
                    "dispatch_overhead_budget"
                ],
            },
            "production_app_bundle": self.app_binding,
            "production_executable": self.executable_binding,
            "metal_library": self.metal_binding,
            "bundled_release_resources": {
                "root": self.bundled_resource_root_binding,
                **self.bundled_resource_bindings,
            },
            "route_lut_files": self.lut_bindings,
            "device": {
                "platform": "macOS",
                "hardware_model": "GeneratedMac1,1",
                "os_version": "15.0",
                "os_build": "24A000",
                "metal_device_name": "Generated Apple GPU",
                "metal_registry_id": "12345",
                "metal_low_power": False,
                "metal_removable": False,
                "metal_unified_memory": True,
            },
            "device_identity_sha256": "pending",
        }

    def _documents(self) -> dict[str, dict[str, object]]:
        identity = self._identity()
        identity["device_identity_sha256"] = canonical_sha256(identity["device"])
        parity_routes = []
        for route in ROUTES:
            rows = []
            for plane in PLANES:
                for phase in range(PHASE_COUNTS[route]):
                    for descriptor in DESCRIPTOR_IDS:
                        label = f"{route}:{plane}:{phase}:{descriptor}"
                        rows.append(
                            {
                                "plane": plane,
                                "phase_ordinal": phase,
                                "descriptor_id": descriptor,
                                "fixture_id": label,
                                "input_sha256": _sha(f"input:{label}"),
                                "cpu_output_sha256": _sha(f"cpu:{label}"),
                                "metal_repeat_output_sha256_values": [
                                    _sha(f"metal:{label}"),
                                    _sha(f"metal:{label}"),
                                ],
                                "maximum_normalized_absolute_error": 0.0,
                                "normalized_rms_error": 0.0,
                                "maximum_output_code_difference": 0,
                                "finite": True,
                                "state_bytes_equal": True,
                                "message_bytes_equal": True,
                                "lut_lookup_bytes_equal": True,
                            }
                        )
            parity_routes.append(
                {
                    "route": route,
                    "phase_count": PHASE_COUNTS[route],
                    "rows": rows,
                }
            )
        parity = _seal(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p08_metal_parity",
                "evidence_identity": deepcopy(identity),
                "xctest_result_bundle": self.parity_tree,
                "same_device_repeat_minimum": 2,
                "pixel_determinism_scope": (
                    "same device, identical locked fixture bytes, decoded plane bytes"
                ),
                "routes": parity_routes,
                "hash_scope": HASH_SCOPE,
            }
        )

        performance_rows = []
        for route in ROUTES:
            for mode in PERFORMANCE_MODES:
                if route == "direct_2x":
                    fixture_id = "img9200_exact_1080p_3f.mp4"
                    source_width, source_height = 1920, 1080
                    destination_width, destination_height = 3840, 2160
                    fixture_frames = 3
                    average_bit_rate = 24_883_200
                else:
                    fixture_id = "img9200_exact_720p_1f.mp4"
                    source_width, source_height = 1280, 720
                    destination_width, destination_height = 1920, 1080
                    fixture_frames = 1
                    average_bit_rate = 6_220_800
                fixture_sha256 = PERFORMANCE_FIXTURE_SHA256[route]
                benchmark_conditions = {
                    "fixture_id": fixture_id,
                    "fixture_file_sha256": fixture_sha256,
                    "source_width": source_width,
                    "source_height": source_height,
                    "destination_width": destination_width,
                    "destination_height": destination_height,
                    "fixture_frame_count": fixture_frames,
                    "ordered_decoded_frames": [
                        {
                            "frame_ordinal": ordinal,
                            "presentation_timestamp_value": ordinal,
                            "presentation_timestamp_timescale": 60,
                            "decoded_nv12_sha256": _sha(
                                f"decoded:{route}:{ordinal}"
                            ),
                            "y_plane_sha256": _sha(f"decoded-y:{route}:{ordinal}"),
                            "cbcr_plane_sha256": _sha(
                                f"decoded-cbcr:{route}:{ordinal}"
                            ),
                        }
                        for ordinal in range(fixture_frames)
                    ],
                    "decoded_pixel_format_fourcc": "420v",
                    "decoded_plane_layout": "NV12",
                    "code_range": "video",
                    "chroma_location": "left",
                    "color_primaries": "ITU_R_709_2",
                    "transfer_function": "ITU_R_709_2",
                    "ycbcr_matrix": "ITU_R_709_2",
                    "frame_repetition": {
                        "rule": (
                            "cyclic in original presentation order with generated "
                            "benchmark timestamps"
                        ),
                        "generated_timestamp_start_value": 0,
                        "generated_timestamp_step_value": 1,
                        "generated_timestamp_timescale": 60,
                        "cpu_reference_frames": 3,
                        "warmup_frames": 30,
                        "measurement_frames": 300,
                    },
                    "measurement_scope": mode,
                    "writer_settings": {
                        "execution_scope": (
                            "not_executed_compute_only"
                            if mode == "compute_only"
                            else "production_end_to_end"
                        ),
                        "framework": "AVFoundation",
                        "container": "mp4",
                        "codec": "hevc",
                        "expected_frame_rate": 30,
                        "average_bit_rate": average_bit_rate,
                        "expects_media_data_in_real_time": False,
                        "pixel_format": "420v",
                        "color_primaries": "ITU_R_709_2",
                        "transfer_function": "ITU_R_709_2",
                        "ycbcr_matrix": "ITU_R_709_2",
                    },
                }
                conditions = canonical_sha256(benchmark_conditions)
                target_luma_pixel_count = (
                    destination_width * destination_height * 300
                )
                performance_rows.append(
                    {
                        "route": route,
                        "mode": mode,
                        "input_sha256": fixture_sha256,
                        "full_ash_conditions_sha256": conditions,
                        "fixed_metal_conditions_sha256": conditions,
                        "benchmark_conditions": benchmark_conditions,
                        "cpu_reference_frames": 3,
                        "cpu_reference_elapsed_seconds": 60.0,
                        "full_ash_metal_warmup_frames": 30,
                        "full_ash_metal_frames": 300,
                        "full_ash_metal_elapsed_seconds": 10.0,
                        "same_bank_fixed_metal_warmup_frames": 30,
                        "same_bank_fixed_metal_frames": 300,
                        "same_bank_fixed_metal_elapsed_seconds": 9.0,
                        "same_machine_speedup": 600.0,
                        "frames_per_second": 30.0,
                        "full_ash_gpu_time_samples_seconds": [0.010] * 300,
                        "same_bank_fixed_gpu_time_samples_seconds": [0.009] * 300,
                        "ash_dispatch_overhead_p95_percent": (
                            (0.010 - 0.009) / 0.009 * 100.0
                        ),
                        "calibration_estimate_source_artifact_sha256": (
                            self.selected_evaluation_artifact_sha256
                        ),
                        "analysis_cell_count": target_luma_pixel_count // 10,
                        "target_luma_pixel_count": target_luma_pixel_count,
                        "candidate_luma_operator_invocation_count": (
                            target_luma_pixel_count * 2
                        ),
                        "luma_numerical_fallback_invocation_count": 0,
                        "actual_luma_operator_invocation_count": (
                            target_luma_pixel_count * 2
                        ),
                        "calibration_estimated_dispatch_cost": 2.1,
                        "measured_luma_dispatch_cost": 2.1,
                        "calibration_estimate_relative_error": 0.0,
                        "repeat_output_sha256_values": [
                            _sha(f"performance-output:{route}:{mode}"),
                            _sha(f"performance-output:{route}:{mode}"),
                        ],
                    }
                )
        performance = _seal(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p08_performance_results",
                "evidence_identity": deepcopy(identity),
                "benchmark_result_bundle": self.performance_tree,
                "measurement_protocol": {
                    "warmup_frames": 30,
                    "measurement_frames": 300,
                    "cpu_reference_frames": 3,
                    "gpu_timing_percentile": (
                        "ascending paired overhead percentages with linear "
                        "interpolation at (n-1)*0.95"
                    ),
                    "calibration_estimate_source": (
                        "exact selected validation candidate-evaluation-v2 "
                        "/evaluation/objective/estimated_dispatch_cost"
                    ),
                    "calibration_estimate_formula": (
                        "binary64 mean in locked row order of "
                        "(analysis_cell_count + maximum_operator_evaluations * "
                        "target_luma_pixel_count) / target_luma_pixel_count"
                    ),
                    "measured_dispatch_cost_formula": (
                        "(analysis_cell_count + "
                        "actual_luma_operator_invocation_count) / "
                        "target_luma_pixel_count"
                    ),
                    "dispatch_cost_count_scope": (
                        "luma only, summed across full_ash_metal_frames after warmup"
                    ),
                    "maximum_operator_evaluations_per_output_cell": 2,
                    "candidate_and_fallback_rule": (
                        "candidate luma operator invocations are bounded at two "
                        "per target pixel; conservative numerical fallback "
                        "invocations are recorded separately and are not "
                        "candidate evaluations"
                    ),
                    "compute_only_and_end_to_end_both_required": True,
                    "fixed_control": (
                        "same-bank fixed-operator Metal under identical "
                        "input/output/writer conditions"
                    ),
                },
                "measurements": performance_rows,
                "hash_scope": HASH_SCOPE,
            }
        )
        compute_conditions = {
            row["route"]: row["full_ash_conditions_sha256"]
            for row in performance_rows
            if row["mode"] == "compute_only"
        }
        end_to_end_conditions = {
            row["route"]: row["full_ash_conditions_sha256"]
            for row in performance_rows
            if row["mode"] == "end_to_end"
        }
        resource = _seal(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p08_resource_ring_results",
                "evidence_identity": deepcopy(identity),
                "xctest_result_bundle": self.resource_tree,
                "measurement_protocol": {
                    "warmup_frames": 30,
                    "measurement_frames": 300,
                },
                "routes": [
                    {
                        "route": route,
                        "benchmark_conditions_sha256": compute_conditions[route],
                        "configured_capacity": 3,
                        "maximum_observed_in_flight": 3,
                        "observed_frames": 300,
                        "in_flight_after_drain": 0,
                        "resource_failure_count": 0,
                        "memory_metric": "physical_footprint",
                        "memory_bytes_after_warmup": 1000,
                        "memory_bytes_after_measurement": 1050,
                        "memory_drift_percent": 5.0,
                        "live_frame_resource_bound": 3,
                        "live_frame_resources_after_drain": 0,
                        "live_frame_resources_returned_to_bound": True,
                        "repeat_output_sha256_values": [
                            _sha(f"resource-output:{route}"),
                            _sha(f"resource-output:{route}"),
                        ],
                    }
                    for route in ROUTES
                ],
                "hash_scope": HASH_SCOPE,
            }
        )
        instruments = _seal(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p08_instruments_manifest",
                "evidence_identity": deepcopy(identity),
                "xctrace_version": "generated-xctrace-1",
                "profiles": [
                    {
                        "tool": tool,
                        "route": route,
                        "archive": self.profile_trees[(tool, route)],
                    }
                    for tool in PROFILE_TOOLS
                    for route in ROUTES
                ],
                "route_observations": [
                    {
                        "route": route,
                        "benchmark_conditions_sha256": end_to_end_conditions[route],
                        "observed_frames": 300,
                        "analysis_gpu_frame_count": 300,
                        "reconstruction_gpu_frame_count": 300,
                        "full_frame_cpu_reconstruction_loop_count": 0,
                        "runtime_leaf_tree_generation_count": 0,
                        "candidate_evaluation_maximum_from_gpu_summary": 2,
                        "command_completion_mode":
                            "asynchronous_completion_handler",
                        "submitted_command_buffer_count": 330,
                        "completed_command_buffer_count": 330,
                        "failed_command_buffer_count": 0,
                        "command_buffer_observation_count": 330,
                        "command_buffer_error_observation_count": 0,
                        "avoidable_full_frame_gpu_readback_count": 0,
                    }
                    for route in ROUTES
                ],
                "hash_scope": HASH_SCOPE,
            }
        )
        captures = _seal(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p08_gpu_capture_manifest",
                "evidence_identity": deepcopy(identity),
                "capture_tool": {
                    "name": "MTLCaptureManager",
                    "version": "generated-1",
                },
                "captures": [
                    {
                        "route": route,
                        "archive": self.capture_trees[route],
                        "capture_scope": (
                            "exhaustive synthetic route-plane-phase-descriptor parity "
                            "fixtures; not a natural-frame coverage claim"
                        ),
                        "capture_succeeded": True,
                        "command_buffer_count": 1,
                        "command_buffer_status": "completed",
                        "command_buffer_error": None,
                        "compute_encoder_count": 4,
                        "kernel_names": [
                            "canonicalizeAndAnalyzeY",
                            "analyzeChroma",
                            "reconstructY",
                            "reconstructCbCr",
                        ],
                        "plane_coverage": [
                            {
                                "plane": plane,
                                "phase_ordinals": list(
                                    range(PHASE_COUNTS[route])
                                ),
                                "descriptor_ids": list(DESCRIPTOR_IDS),
                            }
                            for plane in PLANES
                        ],
                    }
                    for route in ROUTES
                ],
                "hash_scope": HASH_SCOPE,
            }
        )
        return {
            "metal-parity.json": parity,
            "performance-results.json": performance,
            "resource-ring-results.json": resource,
            "instruments-manifest.json": instruments,
            "gpu-capture-manifest.json": captures,
        }

    def write_documents(self) -> None:
        self._refresh_pre_g07_provenance()

    def reseal(self, name: str) -> None:
        if name not in self.documents:
            raise AssertionError(f"unknown P08 fixture document: {name}")
        self._refresh_pre_g07_provenance()

    def _refresh_pre_g07_provenance(self) -> None:
        parity = self.documents["metal-parity.json"]
        performance = self.documents["performance-results.json"]
        resources = self.documents["resource-ring-results.json"]
        instruments = self.documents["instruments-manifest.json"]
        captures = self.documents["gpu-capture-manifest.json"]
        identity = parity["evidence_identity"]
        execution = {
            "source_commit": identity["source_commit"],
            "source_tree_sha256": identity["source_tree_sha256"],
            "configuration_id": identity["configuration_id"],
            "p06_release_bundle_artifact_sha256": identity[
                "p06_release_bundle"
            ]["artifact_sha256"],
            "selected_evaluation_artifact_sha256": identity[
                "selected_evaluation_artifact_sha256"
            ],
            "g07_publication_manifest_sha256": None,
            "holdout_accessed": False,
            "production_app_tree_sha256": identity["production_app_bundle"][
                "tree_sha256"
            ],
            "production_executable_sha256": identity["production_executable"][
                "sha256"
            ],
            "metal_library_sha256": identity["metal_library"]["sha256"],
            "bundled_release_resources": [
                {
                    "filename": filename,
                    "sha256": identity["bundled_release_resources"][key]["sha256"],
                    "size_bytes": identity["bundled_release_resources"][key][
                        "size_bytes"
                    ],
                }
                for key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES
            ],
        }
        native: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p08_native_measurements",
            "run_id": identity["run_id"],
            "execution_identity": execution,
            "device": deepcopy(identity["device"]),
            "device_identity_sha256": identity["device_identity_sha256"],
            "xctest_result_bundles": dict(XCTEST_ARCHIVES),
            "metal_parity": {
                "same_device_repeat_minimum": parity[
                    "same_device_repeat_minimum"
                ],
                "pixel_determinism_scope": parity["pixel_determinism_scope"],
                "routes": deepcopy(parity["routes"]),
            },
            "performance": {
                "measurement_protocol": deepcopy(
                    performance["measurement_protocol"]
                ),
                "measurements": deepcopy(performance["measurements"]),
            },
            "resource_ring": {
                "measurement_protocol": deepcopy(resources["measurement_protocol"]),
                "routes": deepcopy(resources["routes"]),
            },
            "instruments": {
                "xctrace_version": instruments["xctrace_version"],
                "profiles": [
                    {
                        "tool": row["tool"],
                        "route": row["route"],
                        "archive_name": row["archive"]["path"].split("/")[-1],
                    }
                    for row in instruments["profiles"]
                ],
                "route_observations": deepcopy(
                    instruments["route_observations"]
                ),
            },
            "gpu_capture": {
                "capture_tool": deepcopy(captures["capture_tool"]),
                "captures": [
                    {
                        **{
                            key: deepcopy(value)
                            for key, value in row.items()
                            if key != "archive"
                        },
                        "archive_name": row["archive"]["path"].split("/")[-1],
                    }
                    for row in captures["captures"]
                ],
            },
            "hash_scope": HASH_SCOPE,
        }
        native["artifact_sha256"] = canonical_sha256(native)
        native_path = self.staging / NATIVE_FILENAME
        _write_canonical(native_path, native)

        _tolerance_payload, tolerances = _load_tolerances()
        checks = _gate_checks(
            self.documents,
            tolerances,
            self.policy["release_tolerances"]["dispatch_overhead_budget"],
            self.selected_evaluation,
        )
        raw_bindings = _expected_raw_bindings(self.documents)
        seal: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p08_pre_g07_seal",
            "run_id": identity["run_id"],
            "source_identity": {
                "source_commit": identity["source_commit"],
                "source_tree_sha256": identity["source_tree_sha256"],
            },
            "native_measurements": file_binding(
                native_path,
                relative_path=NATIVE_FILENAME,
            ),
            "production_app_bundle": deepcopy(identity["production_app_bundle"]),
            "input_files": [
                {"id": name, **binding}
                for name, binding in sorted(
                    {
                        "locked-metric-policy.json": identity[
                            "locked_metric_policy"
                        ]["file"],
                        "p06-release.json": identity["p06_release_bundle"]["file"],
                        "selected-evaluation.json": identity[
                            "selected_evaluation_file"
                        ],
                    }.items()
                )
            ],
            "raw_archives": [
                {"name": name, **raw_bindings[name]}
                for name in sorted(raw_bindings)
            ],
            "available_checks_all_satisfied": all(
                row["status"] == "pass" for row in checks
            ),
            "checks_sha256": canonical_sha256(checks),
            "g08_claimed": False,
            "g07_publication_manifest_sha256": None,
            "holdout_accessed": False,
            "hash_scope": HASH_SCOPE,
        }
        seal["artifact_sha256"] = canonical_sha256(seal)
        seal_path = self.staging / PRE_G07_MANIFEST_FILENAME
        _write_canonical(seal_path, seal)
        pre_g07_seal = {
            "file": file_binding(
                seal_path,
                relative_path=PRE_G07_MANIFEST_FILENAME,
            ),
            "artifact_sha256": seal["artifact_sha256"],
        }
        pre_g07_native = {
            "file": file_binding(
                native_path,
                relative_path=NATIVE_FILENAME,
            ),
            "artifact_sha256": native["artifact_sha256"],
        }
        for document in self.documents.values():
            document["evidence_identity"]["pre_g07_seal"] = deepcopy(
                pre_g07_seal
            )
            document["evidence_identity"]["pre_g07_native_measurements"] = (
                deepcopy(pre_g07_native)
            )
            document.pop("artifact_sha256", None)
            document["artifact_sha256"] = canonical_sha256(document)
        for filename, document in self.documents.items():
            _write_candidate(self.staging / filename, document)


class P08EvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.fixture = P08Fixture(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _finalize(self) -> dict[str, object]:
        return dict(
            _finalize_promoted_g08(
                repository_root=self.fixture.repository,
                staging_root=self.fixture.staging,
                output_root=self.fixture.output,
            )
        )

    def _checks(self) -> dict[str, dict[str, object]]:
        _payload, tolerances = _load_tolerances()
        checks = _gate_checks(
            self.fixture.documents,
            tolerances,
            self.fixture.policy["release_tolerances"][
                "dispatch_overhead_budget"
            ],
            self.fixture.selected_evaluation,
        )
        return {str(row["check_id"]): dict(row) for row in checks}

    def test_complete_real_artifact_closure_finalizes_pass(self) -> None:
        gate = self._finalize()
        self.assertEqual(gate["status"], "pass")
        self.assertTrue(gate["all_mandatory_checks_passed"])
        self.assertEqual(
            [row["check_id"] for row in gate["checks"]],
            list(CHECK_IDS),
        )
        self.assertFalse(self.fixture.staging.exists())
        self.assertTrue((self.fixture.output / G08_GATE_FILENAME).is_file())
        self.assertTrue((self.fixture.output / "raw/direct_2x.gputrace").is_dir())

    def test_locked_18_percent_budget_rejects_20_percent_not_25(self) -> None:
        document = self.fixture.documents["performance-results.json"]
        for row in document["measurements"]:
            row["full_ash_metal_elapsed_seconds"] = 12.0
            row["same_bank_fixed_metal_elapsed_seconds"] = 10.0
            row["same_machine_speedup"] = 500.0
            row["frames_per_second"] = 25.0
            row["full_ash_gpu_time_samples_seconds"] = [0.012] * 300
            row["same_bank_fixed_gpu_time_samples_seconds"] = [0.010] * 300
            row["ash_dispatch_overhead_p95_percent"] = 20.0
        self.fixture.reseal("performance-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["dispatch_overhead_budget"]["status"], "fail")
        self.assertEqual(
            by_id["dispatch_overhead_budget"]["observed"][
                "locked_budget_percent"
            ],
            18,
        )

    def test_speedup_uses_per_frame_times_for_three_frame_cpu_reference(self) -> None:
        row = self.fixture.documents["performance-results.json"]["measurements"][0]
        self.assertLess(
            row["cpu_reference_elapsed_seconds"]
            / row["full_ash_metal_elapsed_seconds"],
            20.0,
        )
        gate = self._finalize()
        by_id = {item["check_id"]: item for item in gate["checks"]}
        self.assertEqual(by_id["same_machine_speedup"]["status"], "pass")

    def test_unbound_metal_frame_count_is_schema_failure(self) -> None:
        document = self.fixture.documents["performance-results.json"]
        document["measurements"][0]["full_ash_metal_frames"] = 299
        self.fixture.reseal("performance-results.json")
        with self.assertRaisesRegex(P08EvidenceError, "violates schema"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_tiny_frame_benchmark_cannot_satisfy_blocking_throughput(self) -> None:
        document = self.fixture.documents["performance-results.json"]
        row = document["measurements"][1]
        conditions = row["benchmark_conditions"]
        conditions["source_width"] = 16
        conditions["source_height"] = 16
        conditions["destination_width"] = 32
        conditions["destination_height"] = 32
        conditions_sha256 = canonical_sha256(conditions)
        row["full_ash_conditions_sha256"] = conditions_sha256
        row["fixed_metal_conditions_sha256"] = conditions_sha256
        row["target_luma_pixel_count"] = 32 * 32 * 300
        row["analysis_cell_count"] = row["target_luma_pixel_count"] // 10
        row["candidate_luma_operator_invocation_count"] = (
            row["target_luma_pixel_count"] * 2
        )
        row["actual_luma_operator_invocation_count"] = (
            row["candidate_luma_operator_invocation_count"]
        )
        self.fixture.reseal("performance-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["performance_protocol"]["status"], "fail")
        self.assertEqual(by_id["frames_per_second"]["status"], "fail")

    def test_same_geometry_substitute_fixture_cannot_satisfy_protocol(self) -> None:
        document = self.fixture.documents["performance-results.json"]
        substitute = _sha("same-geometry-substitute-fixture")
        for row in document["measurements"]:
            if row["route"] != "direct_2x":
                continue
            row["input_sha256"] = substitute
            row["benchmark_conditions"]["fixture_file_sha256"] = substitute
            conditions_sha256 = canonical_sha256(row["benchmark_conditions"])
            row["full_ash_conditions_sha256"] = conditions_sha256
            row["fixed_metal_conditions_sha256"] = conditions_sha256
        self.fixture.reseal("performance-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["performance_protocol"]["status"], "fail")
        self.assertEqual(by_id["frames_per_second"]["status"], "fail")

    def test_tiny_resource_run_cannot_satisfy_ring_protocol(self) -> None:
        document = self.fixture.documents["resource-ring-results.json"]
        document["routes"][0]["benchmark_conditions_sha256"] = _sha(
            "tiny-resource-run"
        )
        self.fixture.reseal("resource-ring-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["performance_protocol"]["status"], "fail")

    def test_tiny_profile_run_cannot_prove_production_metal(self) -> None:
        document = self.fixture.documents["instruments-manifest.json"]
        document["route_observations"][0][
            "benchmark_conditions_sha256"
        ] = _sha("tiny-instruments-run")
        self.fixture.reseal("instruments-manifest.json")
        by_id = self._checks()
        self.assertEqual(by_id["metal_execution"]["status"], "fail")

    def test_missing_gpu_analysis_frame_fails_metal_execution(self) -> None:
        observation = self.fixture.documents["instruments-manifest.json"][
            "route_observations"
        ][0]
        observation["analysis_gpu_frame_count"] = 299
        self.fixture.reseal("instruments-manifest.json")
        self.assertEqual(self._checks()["metal_execution"]["status"], "fail")

    def test_unverified_completion_mode_fails_no_wait_check(self) -> None:
        observation = self.fixture.documents["instruments-manifest.json"][
            "route_observations"
        ][0]
        observation["command_completion_mode"] = "unverified"
        self.fixture.reseal("instruments-manifest.json")
        self.assertEqual(self._checks()["no_production_wait"]["status"], "fail")

    def test_measured_gpu_readback_fails_no_readback_check(self) -> None:
        observation = self.fixture.documents["instruments-manifest.json"][
            "route_observations"
        ][0]
        observation["avoidable_full_frame_gpu_readback_count"] = 1
        self.fixture.reseal("instruments-manifest.json")
        self.assertEqual(self._checks()["no_avoidable_readback"]["status"], "fail")

    def test_observed_capture_command_error_fails_capture_closure(self) -> None:
        capture = self.fixture.documents["gpu-capture-manifest.json"]["captures"][0]
        capture["command_buffer_status"] = "error"
        capture["command_buffer_error"] = {
            "domain": "MTLCommandBufferErrorDomain",
            "code": 1,
            "message": "measured command failure",
        }
        self.fixture.reseal("gpu-capture-manifest.json")
        checks = self._checks()
        self.assertEqual(checks["metal_execution"]["status"], "fail")
        self.assertEqual(checks["profile_and_capture_closure"]["status"], "fail")

    def test_unmeasured_acquisition_timeout_field_is_rejected(self) -> None:
        resource = self.fixture.documents["resource-ring-results.json"]
        resource["routes"][0]["acquisition_timeout_count"] = 0
        self.fixture.reseal("resource-ring-results.json")
        with self.assertRaisesRegex(P08EvidenceError, "Additional properties"):
            self._finalize()

    def test_dispatch_gate_uses_p95_of_paired_raw_gpu_samples(self) -> None:
        document = self.fixture.documents["performance-results.json"]
        row = document["measurements"][0]
        row["full_ash_gpu_time_samples_seconds"] = [0.010] * 284 + [0.012] * 16
        row["same_bank_fixed_gpu_time_samples_seconds"] = [0.010] * 300
        row["ash_dispatch_overhead_p95_percent"] = 20.0
        self.fixture.reseal("performance-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["dispatch_overhead_budget"]["status"], "fail")

    def test_measured_luma_dispatch_cost_is_recomputed_from_counts(self) -> None:
        document = self.fixture.documents["performance-results.json"]
        row = document["measurements"][0]
        row["measured_luma_dispatch_cost"] = 1.0
        self.fixture.reseal("performance-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["calibration_estimate_error"]["status"], "fail")

    def test_third_fallback_invocation_does_not_fail_candidate_bound(self) -> None:
        document = self.fixture.documents["performance-results.json"]
        row = document["measurements"][0]
        target = row["target_luma_pixel_count"]
        row["luma_numerical_fallback_invocation_count"] = target
        row["actual_luma_operator_invocation_count"] = target * 3
        row["measured_luma_dispatch_cost"] = 3.1
        row["calibration_estimate_relative_error"] = abs(
            row["measured_luma_dispatch_cost"] - 2.1
        ) / 2.1
        self.fixture.reseal("performance-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["performance_protocol"]["status"], "pass")
        self.assertEqual(by_id["no_runtime_tree_or_cpu_loop"]["status"], "pass")
        self.assertEqual(by_id["calibration_estimate_error"]["status"], "fail")

    def test_parity_above_exact_tolerance_reports_failure_without_publish(self) -> None:
        document = self.fixture.documents["metal-parity.json"]
        document["routes"][0]["rows"][0][
            "maximum_normalized_absolute_error"
        ] = 3 / 65535
        self.fixture.reseal("metal-parity.json")
        by_id = self._checks()
        self.assertEqual(by_id["numeric_parity"]["status"], "fail")
        self.assertFalse(self.fixture.output.exists())

    def test_same_device_repeat_difference_is_a_gate_failure(self) -> None:
        document = self.fixture.documents["metal-parity.json"]
        document["routes"][0]["rows"][0][
            "metal_repeat_output_sha256_values"
        ][1] = _sha("different-repeat")
        self.fixture.reseal("metal-parity.json")
        by_id = self._checks()
        self.assertEqual(by_id["same_device_determinism"]["status"], "fail")

    def test_direct_three_over_two_end_to_end_throughput_is_blocking(self) -> None:
        rows = self.fixture.documents["performance-results.json"]["measurements"]
        row = next(
            item
            for item in rows
            if item["route"] == "direct_3_over_2"
            and item["mode"] == "end_to_end"
        )
        row["full_ash_metal_elapsed_seconds"] = 600.0
        row["same_machine_speedup"] = 10.0
        row["frames_per_second"] = 0.5
        self.fixture.reseal("performance-results.json")
        by_id = self._checks()
        self.assertEqual(by_id["performance_protocol"]["status"], "pass")
        self.assertEqual(by_id["same_machine_speedup"]["status"], "fail")
        self.assertEqual(by_id["frames_per_second"]["status"], "fail")

    def test_mutated_raw_trace_aborts_without_gate_or_rename(self) -> None:
        path = self.fixture.staging / "raw/time_profiler-direct_2x.trace/evidence.bin"
        path.write_bytes(b"mutated trace")
        with self.assertRaisesRegex(P08EvidenceError, "tree bytes differ"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse(self.fixture.output.exists())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_mutated_p06_release_bytes_abort_without_gate(self) -> None:
        path = self.fixture.staging / "inputs/p06-release.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(P08EvidenceError, "release bundle file bytes differ"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_mutated_selected_evaluation_bytes_abort_without_gate(self) -> None:
        path = self.fixture.staging / "inputs/selected-evaluation.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(P08EvidenceError, "evaluation file bytes differ"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_mutated_preserved_native_envelope_aborts_without_gate(self) -> None:
        path = self.fixture.staging / NATIVE_FILENAME
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(
            P08EvidenceError,
            "preserved P08 native measurements file bytes differ",
        ):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_mutated_preserved_pre_g07_seal_aborts_without_gate(self) -> None:
        path = self.fixture.staging / PRE_G07_MANIFEST_FILENAME
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(
            P08EvidenceError,
            "preserved P08 pre-G07 seal file bytes differ",
        ):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_dirty_tracked_source_aborts_without_pass_claim(self) -> None:
        (self.fixture.repository / "source.txt").write_text(
            "changed tracked source\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(P08EvidenceError, "tracked source cleanliness"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_untracked_source_outside_artifact_scope_aborts(self) -> None:
        (self.fixture.repository / "untracked.swift").write_text(
            "struct Untracked {}\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(P08EvidenceError, "inventory is not empty"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_extra_measurement_field_is_schema_failure(self) -> None:
        document = self.fixture.documents["resource-ring-results.json"]
        document["routes"][0]["unregistered_measurement"] = 1
        self.fixture.reseal("resource-ring-results.json")
        with self.assertRaisesRegex(P08EvidenceError, "Additional properties"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse(self.fixture.output.exists())

    def test_unbound_staging_input_aborts_without_gate(self) -> None:
        (self.fixture.staging / "inputs/unbound.bin").write_bytes(b"unbound")
        with self.assertRaisesRegex(P08EvidenceError, "inputs closure differs"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_resealed_app_tree_with_hosted_test_plugin_is_rejected(self) -> None:
        app = self.fixture.staging / "inputs/Mirmir.app"
        plugin = app / "Contents/PlugIns/MirmirP08Tests.xctest"
        plugin.mkdir(parents=True)
        (plugin / "test-bundle.bin").write_bytes(b"hosted test bundle")
        app_binding = dict(tree_binding(app, relative_path="inputs/Mirmir.app"))
        for name, document in self.fixture.documents.items():
            document["evidence_identity"]["production_app_bundle"] = app_binding
            self.fixture.reseal(name)
        with self.assertRaisesRegex(P08EvidenceError, "hosted test plug-in"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_output_outside_repository_artifact_scope_is_rejected(self) -> None:
        with self.assertRaisesRegex(P08EvidenceError, "direct Artifacts/ASH"):
            _finalize_promoted_g08(
                repository_root=self.fixture.repository,
                staging_root=self.fixture.staging,
                output_root=self.root / "outside-run",
            )
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_run_id_must_equal_exact_output_directory_name(self) -> None:
        for name, document in self.fixture.documents.items():
            document["evidence_identity"]["run_id"] = "different-run"
            self.fixture.reseal(name)
        with self.assertRaisesRegex(P08EvidenceError, "run ID does not equal"):
            self._finalize()
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_direct_finalization_cli_is_disabled(self) -> None:
        alias = self.root / "staging-alias"
        alias.symlink_to(self.fixture.staging, target_is_directory=True)
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            status = finalize_g08_main(
                [
                    "--repository-root",
                    os.fspath(self.fixture.repository),
                    "--staging-root",
                    os.fspath(alias),
                    "--output-root",
                    os.fspath(self.fixture.output),
                ]
            )
        self.assertEqual(status, 2)
        self.assertIn("Direct G08 finalization is disabled", stderr.getvalue())
        self.assertTrue(self.fixture.staging.is_dir())
        self.assertFalse((self.fixture.staging / G08_GATE_FILENAME).exists())

    def test_all_artifact_schema_files_are_present(self) -> None:
        self.assertEqual(
            set(ARTIFACT_SCHEMAS),
            {
                "metal-parity.json",
                "performance-results.json",
                "resource-ring-results.json",
                "instruments-manifest.json",
                "gpu-capture-manifest.json",
            },
        )
        self.assertTrue(all(path.is_file() for path in ARTIFACT_SCHEMAS.values()))


class P08NativeStagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.fixture = P08Fixture(self.root)
        self.release_root = self.root / "p06-release"
        self.release_root.mkdir()
        _write_canonical(
            self.release_root / "p06-release-bundle.json",
            self.fixture.release,
        )
        artifacts = {row["id"]: row for row in self.fixture.release["artifacts"]}
        for identifier, source in (
            (
                "selected_evaluation",
                self.fixture.staging / "inputs/selected-evaluation.json",
            ),
            (
                "locked_metric_policy",
                self.fixture.staging / "inputs/locked-metric-policy.json",
            ),
        ):
            destination = self.release_root / artifacts[identifier]["path"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
        locked = (
            self.fixture.staging
            / "inputs/Mirmir.app/Contents/Resources/ASH/LockedV3"
        )
        for _key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES:
            (self.release_root / filename).write_bytes((locked / filename).read_bytes())
        self.native_path = self.root / "p08-native-measurements.json"
        self.native = self._native_document()
        _write_canonical(self.native_path, self.native)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _native_document(self) -> dict[str, object]:
        documents = self.fixture.documents
        parity = documents["metal-parity.json"]
        performance = documents["performance-results.json"]
        resource = documents["resource-ring-results.json"]
        instruments = documents["instruments-manifest.json"]
        captures = documents["gpu-capture-manifest.json"]
        execution = {
            **self.fixture.source_identity,
            "configuration_id": self.fixture.release["configuration_id"],
            "p06_release_bundle_artifact_sha256": self.fixture.release[
                "artifact_sha256"
            ],
            "selected_evaluation_artifact_sha256": self.fixture.selected_evaluation[
                "artifact_sha256"
            ],
            "g07_publication_manifest_sha256": None,
            "holdout_accessed": False,
            "production_app_tree_sha256": self.fixture.app_binding["tree_sha256"],
            "production_executable_sha256": self.fixture.executable_binding["sha256"],
            "metal_library_sha256": self.fixture.metal_binding["sha256"],
            "bundled_release_resources": [
                {
                    "filename": filename,
                    "sha256": self.fixture.bundled_resource_bindings[key]["sha256"],
                    "size_bytes": self.fixture.bundled_resource_bindings[key][
                        "size_bytes"
                    ],
                }
                for key, _artifact_id, filename in BUNDLED_RELEASE_RESOURCES
            ],
        }
        document: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p08_native_measurements",
            "run_id": "p08-native-run",
            "execution_identity": execution,
            "device": deepcopy(parity["evidence_identity"]["device"]),
            "device_identity_sha256": parity["evidence_identity"][
                "device_identity_sha256"
            ],
            "xctest_result_bundles": dict(XCTEST_ARCHIVES),
            "metal_parity": {
                "same_device_repeat_minimum": parity["same_device_repeat_minimum"],
                "pixel_determinism_scope": parity["pixel_determinism_scope"],
                "routes": deepcopy(parity["routes"]),
            },
            "performance": {
                "measurement_protocol": deepcopy(performance["measurement_protocol"]),
                "measurements": deepcopy(performance["measurements"]),
            },
            "resource_ring": {
                "measurement_protocol": deepcopy(resource["measurement_protocol"]),
                "routes": deepcopy(resource["routes"]),
            },
            "instruments": {
                "xctrace_version": instruments["xctrace_version"],
                "profiles": [
                    {
                        "tool": row["tool"],
                        "route": row["route"],
                        "archive_name": row["archive"]["path"].split("/")[-1],
                    }
                    for row in instruments["profiles"]
                ],
                "route_observations": deepcopy(instruments["route_observations"]),
            },
            "gpu_capture": {
                "capture_tool": deepcopy(captures["capture_tool"]),
                "captures": [
                    {
                        **{
                            key: deepcopy(value)
                            for key, value in row.items()
                            if key != "archive"
                        },
                        "archive_name": row["archive"]["path"].split("/")[-1],
                    }
                    for row in captures["captures"]
                ],
            },
            "hash_scope": HASH_SCOPE,
        }
        document["artifact_sha256"] = canonical_sha256(document)
        return document

    def _raw_archives(self) -> dict[str, Path]:
        return {
            name: self.fixture.staging / "raw" / name
            for name in (
                *XCTEST_ARCHIVES.values(),
                *[row[2] for row in PROFILE_ARCHIVES],
                *[row[1] for row in CAPTURE_ARCHIVES],
            )
        }

    def _stage_pre_g07(self) -> Path:
        with patch(
            "validation.calibration_v2.p08.staging."
            "validate_p06_release_bundle_manifest",
            return_value=self.fixture.release,
        ):
            result = stage_pre_g07(
                repository_root=self.fixture.repository,
                native_measurements=self.native_path,
                p06_release_root=self.release_root,
                release_app=self.fixture.staging / "inputs/Mirmir.app",
                raw_archives=self._raw_archives(),
            )
        return Path(result["staging_root"])

    def test_pre_g07_fragment_promotes_unchanged_after_g07(self) -> None:
        payload, reopened = validate_native_measurements(self.native_path)
        self.assertEqual(reopened, self.native)
        with patch(
            "validation.calibration_v2.p08.staging."
            "validate_p06_release_bundle_manifest",
            return_value=self.fixture.release,
        ):
            pre = stage_pre_g07(
                repository_root=self.fixture.repository,
                native_measurements=self.native_path,
                p06_release_root=self.release_root,
                release_app=self.fixture.staging / "inputs/Mirmir.app",
                raw_archives=self._raw_archives(),
            )
        self.assertTrue(pre["available_checks_all_satisfied"])
        self.assertFalse(pre["g08_claimed"])
        pre_root = Path(pre["staging_root"])
        self.assertEqual((pre_root / "p08-native-measurements.json").read_bytes(), payload)
        seal = json.loads((pre_root / PRE_G07_MANIFEST_FILENAME).read_bytes())
        self.assertEqual(
            seal["artifact_sha256"],
            pre["pre_g07_seal_artifact_sha256"],
        )
        gate = promote_after_g07(
            repository_root=self.fixture.repository,
            pre_g07_root=pre_root,
            g07_publication=self.fixture.staging / "inputs/g07-publication.json",
        )
        self.assertEqual(gate["status"], "pass")
        self.assertEqual(
            gate["evidence_identity"]["g07_publication"]["manifest_sha256"],
            self.fixture.g07["manifest_sha256"],
        )
        self.assertEqual((pre_root / "p08-native-measurements.json").read_bytes(), payload)
        output = self.fixture.repository / "Artifacts/ASH/p08-native-run"
        self.assertEqual((output / NATIVE_FILENAME).read_bytes(), payload)
        self.assertEqual(
            (output / PRE_G07_MANIFEST_FILENAME).read_bytes(),
            (pre_root / PRE_G07_MANIFEST_FILENAME).read_bytes(),
        )
        self.assertEqual(
            gate["evidence_identity"]["pre_g07_native_measurements"][
                "artifact_sha256"
            ],
            self.native["artifact_sha256"],
        )
        self.assertEqual(
            gate["evidence_identity"]["pre_g07_seal"]["artifact_sha256"],
            seal["artifact_sha256"],
        )
        _, promoted_native = validate_native_measurements(output / NATIVE_FILENAME)
        self.assertEqual(promoted_native, self.native)

    def test_promotion_rejects_app_mutated_after_seal_reopen(self) -> None:
        pre_root = self._stage_pre_g07()
        original_copy_tree = p08_staging._copy_tree
        mutation_applied = False

        def mutate_then_copy(
            source: Path,
            destination: Path,
            relative_path: str,
        ) -> dict[str, object]:
            nonlocal mutation_applied
            if relative_path == "inputs/Mirmir.app" and not mutation_applied:
                mutation_applied = True
                (source / "Contents/MacOS/Mirmir").write_bytes(
                    b"post-reopen app mutation"
                )
            return dict(original_copy_tree(source, destination, relative_path))

        with (
            patch(
                "validation.calibration_v2.p08.staging._copy_tree",
                side_effect=mutate_then_copy,
            ),
            self.assertRaisesRegex(P08EvidenceError, "promoted app differs"),
        ):
            promote_after_g07(
                repository_root=self.fixture.repository,
                pre_g07_root=pre_root,
                g07_publication=self.fixture.staging / "inputs/g07-publication.json",
            )

    def test_promotion_rejects_input_mutated_after_seal_reopen(self) -> None:
        pre_root = self._stage_pre_g07()
        original_copy_file = p08_staging._copy_file
        mutation_applied = False

        def mutate_then_copy(source: Path, destination: Path) -> None:
            nonlocal mutation_applied
            if source.name == "selected-evaluation.json" and not mutation_applied:
                mutation_applied = True
                source.write_bytes(source.read_bytes() + b" ")
            original_copy_file(source, destination)

        with (
            patch(
                "validation.calibration_v2.p08.staging._copy_file",
                side_effect=mutate_then_copy,
            ),
            self.assertRaisesRegex(P08EvidenceError, "promoted input differs"),
        ):
            promote_after_g07(
                repository_root=self.fixture.repository,
                pre_g07_root=pre_root,
                g07_publication=self.fixture.staging / "inputs/g07-publication.json",
            )

    def test_promotion_rejects_raw_tree_mutated_after_seal_reopen(self) -> None:
        pre_root = self._stage_pre_g07()
        original_copy_tree = p08_staging._copy_tree
        mutation_applied = False

        def mutate_then_copy(
            source: Path,
            destination: Path,
            relative_path: str,
        ) -> dict[str, object]:
            nonlocal mutation_applied
            if relative_path.startswith("raw/") and not mutation_applied:
                mutation_applied = True
                (source / "evidence.bin").write_bytes(b"post-reopen raw mutation")
            return dict(original_copy_tree(source, destination, relative_path))

        with (
            patch(
                "validation.calibration_v2.p08.staging._copy_tree",
                side_effect=mutate_then_copy,
            ),
            self.assertRaisesRegex(P08EvidenceError, "promoted raw archive differs"),
        ):
            promote_after_g07(
                repository_root=self.fixture.repository,
                pre_g07_root=pre_root,
                g07_publication=self.fixture.staging / "inputs/g07-publication.json",
            )

    def test_pre_g07_seal_rejects_raw_archive_mutation_before_promotion(self) -> None:
        with patch(
            "validation.calibration_v2.p08.staging."
            "validate_p06_release_bundle_manifest",
            return_value=self.fixture.release,
        ):
            pre = stage_pre_g07(
                repository_root=self.fixture.repository,
                native_measurements=self.native_path,
                p06_release_root=self.release_root,
                release_app=self.fixture.staging / "inputs/Mirmir.app",
                raw_archives=self._raw_archives(),
            )
        pre_root = Path(pre["staging_root"])
        raw_file = pre_root / "raw/metal-parity.xcresult/evidence.bin"
        raw_file.write_bytes(b"changed after pre-G07 sealing")
        with self.assertRaisesRegex(P08EvidenceError, "raw archive changed after sealing"):
            promote_after_g07(
                repository_root=self.fixture.repository,
                pre_g07_root=pre_root,
                g07_publication=self.fixture.staging / "inputs/g07-publication.json",
            )
        self.assertFalse(
            (
                self.fixture.repository
                / "Artifacts/ASH/p08-native-run/g08-gate-manifest.json"
            ).exists()
        )

    def test_native_fragment_rejects_predicted_g07_hash(self) -> None:
        self.native["execution_identity"]["g07_publication_manifest_sha256"] = _sha(
            "future-g07"
        )
        self.native.pop("artifact_sha256")
        self.native["artifact_sha256"] = canonical_sha256(self.native)
        _write_canonical(self.native_path, self.native)
        with self.assertRaisesRegex(P08EvidenceError, "violate schema"):
            validate_native_measurements(self.native_path)

    def test_pre_g07_rejects_app_tree_changed_after_native_measurement(self) -> None:
        app = self.fixture.staging / "inputs/Mirmir.app"
        (app / "Contents/Resources/post-measurement.bin").write_bytes(b"changed")
        with (
            patch(
                "validation.calibration_v2.p08.staging."
                "validate_p06_release_bundle_manifest",
                return_value=self.fixture.release,
            ),
            self.assertRaisesRegex(P08EvidenceError, "native app, executable, or Metal library"),
        ):
            stage_pre_g07(
                repository_root=self.fixture.repository,
                native_measurements=self.native_path,
                p06_release_root=self.release_root,
                release_app=app,
                raw_archives=self._raw_archives(),
            )

    def test_pre_g07_rejects_resealed_app_with_hosted_test_plugin(self) -> None:
        app = self.fixture.staging / "inputs/Mirmir.app"
        plugin = app / "Contents/PlugIns/MirmirP08Tests.xctest"
        plugin.mkdir(parents=True)
        (plugin / "test-bundle.bin").write_bytes(b"hosted test bundle")
        self.native["execution_identity"]["production_app_tree_sha256"] = tree_binding(
            app,
            relative_path="Mirmir.app",
        )["tree_sha256"]
        self.native.pop("artifact_sha256")
        self.native["artifact_sha256"] = canonical_sha256(self.native)
        _write_canonical(self.native_path, self.native)
        with (
            patch(
                "validation.calibration_v2.p08.staging."
                "validate_p06_release_bundle_manifest",
                return_value=self.fixture.release,
            ),
            self.assertRaisesRegex(P08EvidenceError, "hosted test plug-in"),
        ):
            stage_pre_g07(
                repository_root=self.fixture.repository,
                native_measurements=self.native_path,
                p06_release_root=self.release_root,
                release_app=app,
                raw_archives=self._raw_archives(),
            )

    def test_staging_cli_runs_pre_g07_then_promotes_exact_fragment(self) -> None:
        raw = self._raw_archives()
        arguments = [
            "pre-g07",
            "--repository-root",
            os.fspath(self.fixture.repository),
            "--native-measurements",
            os.fspath(self.native_path),
            "--p06-release-root",
            os.fspath(self.release_root),
            "--release-app",
            os.fspath(self.fixture.staging / "inputs/Mirmir.app"),
        ]
        for role, name in XCTEST_ARCHIVES.items():
            arguments.extend(
                [f"--{role.replace('_', '-')}-xcresult", os.fspath(raw[name])]
            )
        for tool, route, name in PROFILE_ARCHIVES:
            arguments.extend(
                [
                    f"--{tool.replace('_', '-')}-{route.replace('_', '-')}-trace",
                    os.fspath(raw[name]),
                ]
            )
        for route, name in CAPTURE_ARCHIVES:
            arguments.extend(
                [f"--{route.replace('_', '-')}-gputrace", os.fspath(raw[name])]
            )
        output = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
        with (
            patch(
                "validation.calibration_v2.p08.staging."
                "validate_p06_release_bundle_manifest",
                return_value=self.fixture.release,
            ),
            patch("sys.stdout", output),
        ):
            self.assertEqual(stage_p08_native_evidence_main(arguments), 0)
        pre_root = (
            self.fixture.repository
            / "Artifacts/ASH/.p08-native-run.p08-pre-g07"
        )
        self.assertTrue(pre_root.is_dir())
        status = stage_p08_native_evidence_main(
            [
                "promote-after-g07",
                "--repository-root",
                os.fspath(self.fixture.repository),
                "--pre-g07-root",
                os.fspath(pre_root),
                "--g07-publication",
                os.fspath(self.fixture.staging / "inputs/g07-publication.json"),
            ]
        )
        self.assertEqual(status, 0)
        self.assertTrue(
            (
                self.fixture.repository
                / "Artifacts/ASH/p08-native-run/g08-gate-manifest.json"
            ).is_file()
        )


if __name__ == "__main__":
    unittest.main()
