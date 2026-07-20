from __future__ import annotations

import copy
from contextlib import redirect_stderr, redirect_stdout
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

ANALYSIS_MODEL_PAYLOAD = b"model-v1"

import r01_preregistration as r01_module  # noqa: E402

from r01_preregistration import (  # noqa: E402
    ANCHOR_CONTRACTS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    HOST_FACT_KEYS,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    ROADMAP_PATH,
    HostFactCollectionError,
    HostAssignmentError,
    PreregistrationVerifier,
    _fixture_digest,
    build_host_assignment,
    check_materialized_fixtures,
    collect_host_facts,
    freeze_host_assignments,
    main,
    materialize_fixtures,
)


class R01PreregistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        for relative in (
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            ROADMAP_PATH,
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPOSITORY_ROOT / relative, destination)
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.catalog = self.read_json(self.root / FIXTURE_CATALOG_PATH)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def read_json(path: Path) -> dict[str, object]:
        return json.loads(path.read_text(encoding="utf-8"))

    @staticmethod
    def write_json(path: Path, value: dict[str, object]) -> None:
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def write_preregistration(self) -> None:
        self.write_json(self.root / PREREGISTRATION_PATH, self.preregistration)

    def write_catalog(self) -> None:
        self.write_json(self.root / FIXTURE_CATALOG_PATH, self.catalog)

    def freeze_analysis_model(
        self,
        path: str = ".r01-local-assets/probe-model.bin",
        model_identity: str = "r01-core-ai-probe-model-v1",
    ) -> None:
        model = self.catalog["fixtures"][-1]
        model.update(
            {
                "status": "frozen",
                "materialization_path": path,
                "byte_count": len(ANALYSIS_MODEL_PAYLOAD),
                "content_sha256": hashlib.sha256(ANALYSIS_MODEL_PAYLOAD).hexdigest(),
                "model_identity": model_identity,
            }
        )
        self.write_catalog()
        catalog_payload = (self.root / FIXTURE_CATALOG_PATH).read_bytes()
        self.preregistration["fixture_catalog"]["sha256"] = hashlib.sha256(
            catalog_payload
        ).hexdigest()
        self.write_preregistration()

    def verifier(self) -> PreregistrationVerifier:
        return PreregistrationVerifier(self.root)

    def assert_error_contains(self, fragment: str) -> None:
        errors = self.verifier().check()
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected error containing {fragment!r}; found {errors!r}",
        )

    @staticmethod
    def profile(
        hardware_class: str,
        chip: str,
        os_version: str,
        xcode_version: str,
        sdk_version: str,
        suffix: str,
    ) -> dict[str, object]:
        return {
            "host_id": f"r01-host-{int(suffix):02d}",
            "model_identifier": f"Mac{suffix}",
            "hardware_class": hardware_class,
            "chip": chip,
            "memory_bytes": 16 * 1024 * 1024 * 1024,
            "os_version": os_version,
            "os_build": f"OS{suffix}",
            "xcode_version": xcode_version,
            "xcode_build": f"XC{suffix}",
            "sdk_version": sdk_version,
            "sdk_build": f"SDK{suffix}",
        }

    @staticmethod
    def pro_max_host_facts() -> dict[str, object]:
        return {
            "model_identifier": "Mac16,7",
            "chip": "Apple M4 Pro",
            "memory_bytes": 51539607552,
            "os_version": "26.5.2",
            "os_build": "25F84",
            "xcode_version": "26.2",
            "xcode_build": "17C52",
            "sdk_version": "26.2",
            "sdk_build": "25C58",
        }

    def assign_all_anchors(self) -> None:
        candidates = self.assignment_candidates()
        assignments = self.preregistration["anchor_assignments"]
        self.assertIsInstance(assignments, list)
        for assignment, candidate in zip(assignments, candidates):
            assignment["assignment_state"] = "assigned"
            assignment["host_profile"] = candidate["host_profile"]
        self.preregistration["preregistration_state"] = "live_assignments_frozen"
        self.write_preregistration()

    def assignment_candidates(self) -> list[dict[str, object]]:
        profiles = [
            self.profile("apple_silicon", "Apple M1", "15.4", "16.3", "15.4", "1"),
            self.profile("macbook_air", "Apple M3", "26.0", "26.0", "26.0", "2"),
            self.profile("pro_max_tier", "Apple M4 Pro", "26.5", "26.2", "26.2", "3"),
            self.profile("core_ai_capable", "Apple M4 Max", "27.0", "27.0", "27.0", "4"),
        ]
        profiles[1]["model_identifier"] = "Mac15,12"
        return [
            {
                "anchor": anchor,
                "assignment_state": "assigned",
                "contract": contract,
                "host_profile": profile,
            }
            for (anchor, contract, _), profile in zip(ANCHOR_CONTRACTS, profiles)
        ]

    def write_assignment_candidates(
        self, candidates: list[dict[str, object]] | None = None
    ) -> list[Path]:
        values = self.assignment_candidates() if candidates is None else candidates
        directory = self.root.resolve() / "assignment-inputs"
        directory.mkdir(exist_ok=True)
        paths: list[Path] = []
        for index, candidate in enumerate(values, start=1):
            path = directory / f"assignment-{index}.json"
            self.write_json(path, candidate)
            paths.append(path)
        return paths

    def test_repository_preregistration_is_valid(self) -> None:
        self.assertEqual(PreregistrationVerifier(REPOSITORY_ROOT).check(), [])

    def test_capabilities_are_exactly_a01_through_a18(self) -> None:
        capabilities = self.preregistration["capabilities"]
        self.assertEqual(
            [item["id"] for item in capabilities],
            [f"A{index:02d}" for index in range(1, 19)],
        )

    def test_probe_class_assignments_are_closed(self) -> None:
        by_class: dict[str, list[str]] = {}
        for capability in self.preregistration["capabilities"]:
            by_class.setdefault(capability["probe_class"], []).append(capability["id"])
        self.assertEqual(
            by_class,
            {
                "primary_scaler": [
                    "A01",
                    "A02",
                    "A06",
                    "A07",
                    "A08",
                    "A09",
                    "A11",
                    "A12",
                    "A14",
                    "A16",
                ],
                "cadence_transform": ["A03", "A10"],
                "support_filter": ["A04", "A13", "A15", "A17"],
                "temporal_analyzer": ["A05"],
                "analysis_runtime": ["A18"],
            },
        )

    def test_fixture_ids_are_exact_and_ordered(self) -> None:
        self.assertEqual(
            [item["id"] for item in self.catalog["fixtures"]],
            [
                "scaler-720p",
                "scaler-1080p",
                "support-frame",
                "support-guidance",
                "support-history",
                "temporal-frame-0",
                "temporal-frame-1",
                "cadence-frame-0",
                "cadence-frame-1",
                "analysis-proxy",
                "analysis-probe-model",
            ],
        )

    def test_frozen_fixture_hash_matches_generator(self) -> None:
        fixture = self.catalog["fixtures"][0]
        observed_size, observed_hash = _fixture_digest("nv12_frame", 1280, 720, 0)
        self.assertEqual(fixture["byte_count"], observed_size)
        self.assertEqual(fixture["content_sha256"], observed_hash)

    def small_fixture_catalog(self) -> dict[str, object]:
        byte_count, content_sha256 = _fixture_digest("nv12_frame", 4, 2, 0)
        return {
            "fixtures": [
                {
                    "id": "small-fixture",
                    "status": "frozen",
                    "media_kind": "nv12_frame",
                    "dimensions": {"width": 4, "height": 2},
                    "frame_index": 0,
                    "materialization_path": "fixtures/small.bin",
                    "byte_count": byte_count,
                    "content_sha256": content_sha256,
                },
                {
                    "id": "unassigned-model",
                    "status": "unassigned",
                    "materialization_path": None,
                },
            ]
        }

    def test_materialize_and_check_fixture_bytes(self) -> None:
        catalog = self.small_fixture_catalog()
        paths = materialize_fixtures(self.root, catalog)
        self.assertEqual(paths, [self.root.resolve() / "fixtures/small.bin"])
        self.assertEqual(check_materialized_fixtures(self.root, catalog), [])
        self.assertEqual(materialize_fixtures(self.root, catalog), paths)

    def test_materializer_refuses_to_overwrite_drifted_bytes(self) -> None:
        catalog = self.small_fixture_catalog()
        path = self.root / "fixtures/small.bin"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"drift")
        with self.assertRaisesRegex(ValueError, "byte count differs"):
            materialize_fixtures(self.root, catalog)
        self.assertEqual(path.read_bytes(), b"drift")

    def test_materializer_rejects_symbolic_link_components(self) -> None:
        catalog = self.small_fixture_catalog()
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "fixtures").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            materialize_fixtures(self.root, catalog)

    def test_scaler_and_analysis_dimensions_are_frozen(self) -> None:
        fixtures = {item["id"]: item for item in self.catalog["fixtures"]}
        self.assertEqual(
            fixtures["scaler-720p"]["scale_output"],
            {"width": 1920, "height": 1080},
        )
        self.assertEqual(
            fixtures["scaler-1080p"]["scale_output"],
            {"width": 3840, "height": 2160},
        )
        self.assertEqual(
            fixtures["analysis-proxy"]["dimensions"],
            {"width": 512, "height": 288},
        )

    def test_cadence_timing_is_frozen(self) -> None:
        fixtures = {item["id"]: item for item in self.catalog["fixtures"]}
        self.assertEqual(
            fixtures["cadence-frame-0"]["timing"],
            {"pts": 0, "duration": 20, "timescale": 600},
        )
        self.assertEqual(
            fixtures["cadence-frame-1"]["timing"],
            {"pts": 20, "duration": 20, "timescale": 600},
        )

    def test_execution_counts_and_timeout_are_frozen(self) -> None:
        self.assertEqual(
            self.preregistration["execution_controls"],
            {
                "sessions": 3,
                "warm_up_units_per_session": 5,
                "measured_units_per_session": 30,
                "timeout_seconds_per_session": 120,
                "repeatability_observations": 3,
                "clock": "monotonic",
            },
        )

    def test_altered_fixture_fails_closed(self) -> None:
        self.catalog["fixtures"][0]["content_sha256"] = "0" * 64
        self.write_catalog()
        errors = self.verifier().check()
        self.assertTrue(any("catalog SHA-256 differs" in error for error in errors), errors)
        self.assertTrue(any("scaler-720p differs" in error for error in errors), errors)

    def test_altered_capability_class_fails(self) -> None:
        self.preregistration["capabilities"][0]["probe_class"] = "support_filter"
        self.write_preregistration()
        self.assert_error_contains("capability identities/classes")

    def test_altered_execution_control_fails(self) -> None:
        self.preregistration["execution_controls"]["sessions"] = 2
        self.write_preregistration()
        self.assert_error_contains("execution_controls differs")

    def test_altered_stop_rule_fails(self) -> None:
        self.preregistration["stop_rules"].pop()
        self.write_preregistration()
        self.assert_error_contains("stop_rules differs")

    def test_extra_claim_fails_closed_schema(self) -> None:
        self.preregistration["product_qualified"] = True
        self.write_preregistration()
        self.assert_error_contains("field is not allowed")

    def test_duplicate_json_key_is_rejected(self) -> None:
        path = self.root / PREREGISTRATION_PATH
        text = path.read_text(encoding="utf-8")
        text = text.replace(
            '  "phase_id": "R01",',
            '  "phase_id": "R01",\n  "phase_id": "R01",',
            1,
        )
        path.write_text(text, encoding="utf-8")
        self.assert_error_contains("duplicate JSON key: phase_id")

    def test_symbolic_link_catalog_is_rejected(self) -> None:
        catalog_path = self.root / FIXTURE_CATALOG_PATH
        target = self.root / "fixture-catalog-target.json"
        shutil.copy2(catalog_path, target)
        catalog_path.unlink()
        catalog_path.symlink_to(target)
        self.assert_error_contains("symbolic-link component")

    def test_nonregular_catalog_is_rejected(self) -> None:
        catalog_path = self.root / FIXTURE_CATALOG_PATH
        catalog_path.unlink()
        catalog_path.mkdir()
        self.assert_error_contains("must resolve to a regular file")

    def test_source_identity_is_rejected_from_preregistration_profile(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][0]["host_profile"][
            "source_commit"
        ] = "1" * 40
        self.write_preregistration()
        self.assert_error_contains("must match exactly one allowed schema")

    def test_partial_assignment_fails_closed(self) -> None:
        assignment = self.preregistration["anchor_assignments"][0]
        assignment["assignment_state"] = "assigned"
        assignment["host_profile"] = self.profile(
            "apple_silicon", "Apple M1", "15.4", "16.3", "15.4", "1"
        )
        self.write_preregistration()
        self.assert_error_contains("offline preregistration state requires all anchors unassigned")

    def test_private_host_profile_values_fail_closed(self) -> None:
        mutations = (
            ("operator@example.com", "email address"),
            ("/Users/operator/model", "private filesystem path"),
            ("/home/operator/model", "private filesystem path"),
            ("file:///private/model", "private filesystem path"),
            ("serial number: C02PRIVATE", "labeled private identifier"),
            ("hardware UUID=PRIVATE", "labeled private identifier"),
            ("account id: PRIVATE", "labeled private identifier"),
            ("user=operator", "labeled private identifier"),
        )
        for value, fragment in mutations:
            with self.subTest(value=value):
                preregistration = copy.deepcopy(self.preregistration)
                self.preregistration = preregistration
                self.assign_all_anchors()
                self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
                self.preregistration["anchor_assignments"][0]["host_profile"][
                    "model_identifier"
                ] = value
                self.write_preregistration()
                self.assert_error_contains(fragment)

    def test_complete_role_correct_assignments_validate(self) -> None:
        self.assign_all_anchors()
        self.assertEqual(self.verifier().check(), [])

    def test_reused_host_pseudonym_requires_identical_host_facts(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        assignments = self.preregistration["anchor_assignments"]
        assignments[1]["host_profile"]["host_id"] = assignments[0]["host_profile"][
            "host_id"
        ]
        self.write_preregistration()
        self.assert_error_contains("identifies different host/toolchain profiles")

    def test_wrong_m3_chip_fails_role_contract(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][1]["host_profile"]["chip"] = (
            "Apple M3 Pro"
        )
        self.write_preregistration()
        self.assert_error_contains("chip exactly Apple M3")

    def test_m3_air_requires_official_air_model_identifier(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][1]["host_profile"][
            "model_identifier"
        ] = "Mac15,3"
        self.write_preregistration()
        self.assert_error_contains("model identifier Mac15,12 or Mac15,13")

    def test_assigned_host_id_uses_closed_sanitized_identifier(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][0]["host_profile"]["host_id"] = (
            "operator@example.com"
        )
        self.write_preregistration()
        errors = self.verifier().check()
        self.assertTrue(
            any("host_id is not a closed r01-host-NN pseudonym" in error for error in errors)
        )
        self.assertTrue(any("email address" in error for error in errors))

    def test_core_ai_requires_os_xcode_and_sdk_major_27(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        profile = self.preregistration["anchor_assignments"][3]["host_profile"]
        profile["os_version"] = "26.5"
        profile["xcode_version"] = "26.2"
        profile["sdk_version"] = "26.2"
        self.write_preregistration()
        errors = self.verifier().check()
        for name in ("macOS", "Xcode", "SDK"):
            self.assertTrue(any(f"requires {name} major 27" in error for error in errors))

    def test_offline_record_blocks_live_probe(self) -> None:
        errors = self.verifier().check_live_readiness("pro-max", host_facts={})
        self.assertTrue(any("all four assignments" in error for error in errors), errors)
        self.assertTrue(any("pro-max is not assigned" in error for error in errors), errors)

    def test_live_readiness_matches_injected_host_facts(self) -> None:
        self.assign_all_anchors()
        self.freeze_analysis_model()
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        profile = copy.deepcopy(
            preregistration["anchor_assignments"][2]["host_profile"]
        )
        profile.pop("hardware_class")
        self.assertEqual(
            self.verifier().check_live_readiness("pro-max", host_facts=profile), []
        )

    def test_live_readiness_rejects_host_mismatch(self) -> None:
        self.assign_all_anchors()
        self.freeze_analysis_model()
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        profile = copy.deepcopy(
            preregistration["anchor_assignments"][2]["host_profile"]
        )
        profile.pop("hardware_class")
        profile["memory_bytes"] += 1
        errors = self.verifier().check_live_readiness("pro-max", host_facts=profile)
        self.assertTrue(any("memory_bytes differs" in error for error in errors), errors)

    def test_every_anchor_live_readiness_requires_frozen_model(self) -> None:
        self.assign_all_anchors()
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        for assignment in preregistration["anchor_assignments"]:
            with self.subTest(anchor=assignment["anchor"]):
                profile = copy.deepcopy(assignment["host_profile"])
                profile.pop("hardware_class")
                errors = self.verifier().check_live_readiness(
                    assignment["anchor"], host_facts=profile
                )
                self.assertTrue(
                    any("frozen analysis-probe-model" in error for error in errors),
                    errors,
                )

    def test_every_anchor_allows_absent_bytes_for_frozen_model(self) -> None:
        self.assign_all_anchors()
        self.freeze_analysis_model()
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        for assignment in preregistration["anchor_assignments"]:
            with self.subTest(anchor=assignment["anchor"]):
                profile = copy.deepcopy(assignment["host_profile"])
                profile.pop("hardware_class")
                self.assertEqual(
                    self.verifier().check_live_readiness(
                        assignment["anchor"], host_facts=profile
                    ),
                    [],
                )

    def test_every_anchor_accepts_matching_present_model_bytes(self) -> None:
        self.assign_all_anchors()
        self.freeze_analysis_model()
        model_path = self.root / ".r01-local-assets/probe-model.bin"
        model_path.parent.mkdir()
        model_path.write_bytes(ANALYSIS_MODEL_PAYLOAD)
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        for assignment in preregistration["anchor_assignments"]:
            with self.subTest(anchor=assignment["anchor"]):
                profile = copy.deepcopy(assignment["host_profile"])
                profile.pop("hardware_class")
                self.assertEqual(
                    self.verifier().check_live_readiness(
                        assignment["anchor"], host_facts=profile
                    ),
                    [],
                )

    def test_every_anchor_rejects_wrong_size_present_model_bytes(self) -> None:
        self.assign_all_anchors()
        self.freeze_analysis_model()
        model_path = self.root / ".r01-local-assets/probe-model.bin"
        model_path.parent.mkdir()
        model_path.write_bytes(b"drift")
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        for assignment in preregistration["anchor_assignments"]:
            with self.subTest(anchor=assignment["anchor"]):
                profile = copy.deepcopy(assignment["host_profile"])
                profile.pop("hardware_class")
                errors = self.verifier().check_live_readiness(
                    assignment["anchor"], host_facts=profile
                )
                self.assertTrue(
                    any("byte count differs" in error for error in errors), errors
                )

    def test_every_anchor_rejects_same_size_model_hash_drift(self) -> None:
        self.assign_all_anchors()
        self.freeze_analysis_model()
        model_path = self.root / ".r01-local-assets/probe-model.bin"
        model_path.parent.mkdir()
        model_path.write_bytes(b"model-v2")
        self.assertEqual(model_path.stat().st_size, len(ANALYSIS_MODEL_PAYLOAD))
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        for assignment in preregistration["anchor_assignments"]:
            with self.subTest(anchor=assignment["anchor"]):
                profile = copy.deepcopy(assignment["host_profile"])
                profile.pop("hardware_class")
                errors = self.verifier().check_live_readiness(
                    assignment["anchor"], host_facts=profile
                )
                self.assertTrue(
                    any("SHA-256 differs" in error for error in errors), errors
                )

    def test_core_ai_model_path_must_use_ignored_local_asset_directory(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.freeze_analysis_model("project-notes/probe-model.bin")
        self.assert_error_contains("ignored .r01-local-assets directory")

    def test_core_ai_model_path_must_be_normalized_and_contained(self) -> None:
        invalid_paths = (
            ".r01-local-assets/../tracked-model.bin",
            ".r01-local-assets//probe.bin",
            ".r01-local-assets/./probe.bin",
            ".r01-local-assets\\probe.bin",
        )
        base_catalog = copy.deepcopy(self.catalog)
        base_preregistration = copy.deepcopy(self.preregistration)
        for path in invalid_paths:
            with self.subTest(path=path):
                self.catalog = copy.deepcopy(base_catalog)
                self.preregistration = copy.deepcopy(base_preregistration)
                self.freeze_analysis_model(path)
                self.assert_error_contains("normalized within the ignored .r01-local-assets")

    def test_analysis_model_identity_is_privacy_scanned_before_commit(self) -> None:
        mutations = (
            ("operator@example.com", "email address"),
            ("/Users/operator/model", "private filesystem path"),
            ("serial number: SECRET", "labeled private identifier"),
            ("hardware UUID=ABC", "labeled private identifier"),
        )
        base_catalog = copy.deepcopy(self.catalog)
        base_preregistration = copy.deepcopy(self.preregistration)
        for identity, fragment in mutations:
            with self.subTest(identity=identity):
                self.catalog = copy.deepcopy(base_catalog)
                self.preregistration = copy.deepcopy(base_preregistration)
                self.freeze_analysis_model(model_identity=identity)
                self.assert_error_contains(fragment)

    def test_core_ai_model_path_rejects_symbolic_link_components(self) -> None:
        outside = self.root / "outside-model-assets"
        outside.mkdir()
        (self.root / ".r01-local-assets").symlink_to(
            outside, target_is_directory=True
        )
        self.freeze_analysis_model()
        self.assert_error_contains("symbolic-link component")

    def test_frozen_analysis_model_rejects_all_zero_hash(self) -> None:
        self.freeze_analysis_model()
        self.catalog = self.read_json(self.root / FIXTURE_CATALOG_PATH)
        self.catalog["fixtures"][-1]["content_sha256"] = "0" * 64
        self.write_catalog()
        catalog_payload = (self.root / FIXTURE_CATALOG_PATH).read_bytes()
        self.preregistration["fixture_catalog"]["sha256"] = hashlib.sha256(
            catalog_payload
        ).hexdigest()
        self.write_preregistration()
        self.assert_error_contains("SHA-256 is invalid")

    def test_host_fact_collector_uses_only_allowlisted_commands(self) -> None:
        outputs = {
            ("/usr/sbin/sysctl", "-n", "hw.model"): "Mac16,7\n",
            ("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"): "Apple M4 Pro\n",
            ("/usr/sbin/sysctl", "-n", "hw.memsize"): "51539607552\n",
            ("/usr/bin/sw_vers", "-productVersion"): "26.5.2\n",
            ("/usr/bin/sw_vers", "-buildVersion"): "25F84\n",
            ("/usr/bin/xcodebuild", "-version"): "Xcode 26.2\nBuild version 17C52\n",
            ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.2\n",
            ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "25C58\n",
        }
        observed: list[tuple[str, ...]] = []

        def run(command: tuple[str, ...], **_: object) -> subprocess.CompletedProcess[str]:
            observed.append(command)
            return subprocess.CompletedProcess(command, 0, outputs[command], "")

        facts = collect_host_facts(run)
        self.assertEqual(facts["model_identifier"], "Mac16,7")
        self.assertEqual(facts["chip"], "Apple M4 Pro")
        self.assertEqual(facts["memory_bytes"], 51539607552)
        self.assertEqual(set(observed), set(outputs))

    def test_host_assignment_export_is_closed_and_role_bound(self) -> None:
        facts = self.pro_max_host_facts()
        assignment = build_host_assignment("pro-max", "r01-host-03", facts)
        self.assertEqual(
            assignment,
            {
                "anchor": "pro-max",
                "contract": "current Pro/Max performance tier",
                "assignment_state": "assigned",
                "host_profile": {
                    "host_id": "r01-host-03",
                    "hardware_class": "pro_max_tier",
                    **facts,
                },
            },
        )
        self.assertEqual(
            set(assignment["host_profile"]),
            {"host_id", "hardware_class", *HOST_FACT_KEYS},
        )

    def test_host_assignment_export_rejects_ineligible_anchor(self) -> None:
        facts = self.pro_max_host_facts()
        with self.assertRaisesRegex(HostAssignmentError, "chip exactly Apple M3"):
            build_host_assignment("m3-air", "r01-host-02", facts)

    def test_host_assignment_export_rejects_private_or_extra_input(self) -> None:
        facts = self.pro_max_host_facts()
        with self.assertRaisesRegex(HostAssignmentError, "email address"):
            build_host_assignment("pro-max", "operator@example.com", facts)
        with self.assertRaisesRegex(HostAssignmentError, "r01-host-NN pseudonym"):
            build_host_assignment("pro-max", "operator-name", facts)
        facts["serial_number"] = "PRIVATE"
        with self.assertRaisesRegex(HostAssignmentError, "closed R01 host fact fields"):
            build_host_assignment("pro-max", "r01-host-03", facts)

    def test_host_assignment_export_rejects_invalid_allowlisted_fact_shape(self) -> None:
        facts = self.pro_max_host_facts()
        facts["memory_bytes"] = 0
        with self.assertRaisesRegex(HostAssignmentError, "positive integer"):
            build_host_assignment("pro-max", "r01-host-03", facts)

    def test_complete_host_assignment_freeze_uses_canonical_order(self) -> None:
        paths = list(reversed(self.write_assignment_candidates()))
        expected_mode = (self.root / PREREGISTRATION_PATH).stat().st_mode & 0o777

        freeze_host_assignments(self.root, paths)

        frozen = self.read_json(self.root / PREREGISTRATION_PATH)
        self.assertEqual(frozen["preregistration_state"], "live_assignments_frozen")
        self.assertEqual(
            [assignment["anchor"] for assignment in frozen["anchor_assignments"]],
            [anchor for anchor, _, _ in ANCHOR_CONTRACTS],
        )
        self.assertEqual(self.verifier().check(), [])
        self.assertEqual(
            (self.root / PREREGISTRATION_PATH).stat().st_mode & 0o777,
            expected_mode,
        )

    def test_host_assignment_freeze_rejects_partial_set_without_writing(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()

        with self.assertRaisesRegex(HostAssignmentError, "exactly four"):
            freeze_host_assignments(self.root, paths[:3])

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_duplicate_anchor_without_writing(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        candidates = self.assignment_candidates()
        candidates[-1] = copy.deepcopy(candidates[0])
        paths = self.write_assignment_candidates(candidates)

        with self.assertRaisesRegex(
            HostAssignmentError, "duplicate assignment anchors: oldest-supported"
        ):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_private_candidate_without_writing(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        candidates = self.assignment_candidates()
        candidates[0]["host_profile"]["model_identifier"] = "operator@example.com"
        paths = self.write_assignment_candidates(candidates)

        with self.assertRaisesRegex(HostAssignmentError, "email address"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_does_not_echo_private_duplicate_key(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()
        sentinel = "serial number: PRIVATE-SENTINEL"
        paths[0].write_text(
            json.dumps({sentinel: 1})[:-1] + f', "{sentinel}": 2}}',
            encoding="utf-8",
        )

        with self.assertRaises(HostAssignmentError) as context:
            freeze_host_assignments(self.root, paths)

        self.assertIn("invalid JSON or a duplicate JSON key", str(context.exception))
        self.assertNotIn(sentinel, str(context.exception))
        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_inconsistent_pseudonym_reuse(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        candidates = self.assignment_candidates()
        candidates[1]["host_profile"]["host_id"] = candidates[0]["host_profile"][
            "host_id"
        ]
        paths = self.write_assignment_candidates(candidates)

        with self.assertRaisesRegex(HostAssignmentError, "identifies different"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_exact_replay_is_idempotent(self) -> None:
        paths = self.write_assignment_candidates()
        self.assertTrue(freeze_host_assignments(self.root, paths))
        preregistration_path = self.root / PREREGISTRATION_PATH
        frozen = preregistration_path.read_bytes()
        frozen_mtime = preregistration_path.stat().st_mtime_ns

        self.assertFalse(freeze_host_assignments(self.root, paths))

        self.assertEqual(preregistration_path.read_bytes(), frozen)
        self.assertEqual(preregistration_path.stat().st_mtime_ns, frozen_mtime)

    def test_host_assignment_freeze_rejects_candidate_replaced_before_open(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()
        replacement = paths[0].with_name("replacement-assignment.json")
        replacement.write_bytes(paths[1].read_bytes())
        real_open = os.open
        swapped = False

        def replace_before_open(
            path: str | bytes | os.PathLike[str] | os.PathLike[bytes],
            flags: int,
            mode: int = 0o777,
            *,
            dir_fd: int | None = None,
        ) -> int:
            nonlocal swapped
            if Path(path) == paths[0] and not swapped:
                replacement.replace(paths[0])
                swapped = True
            if dir_fd is None:
                return real_open(path, flags, mode)
            return real_open(path, flags, mode, dir_fd=dir_fd)

        with mock.patch("r01_preregistration.os.open", side_effect=replace_before_open):
            with self.assertRaisesRegex(HostAssignmentError, "changed before"):
                freeze_host_assignments(self.root, paths)

        self.assertTrue(swapped)
        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_lock_contention_without_writing(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()
        descriptor = os.open(preregistration_path, os.O_RDONLY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(HostAssignmentError, "holds the preregistration lock"):
                freeze_host_assignments(self.root, paths)
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_drift_after_freeze(self) -> None:
        paths = self.write_assignment_candidates()
        self.assertTrue(freeze_host_assignments(self.root, paths))
        preregistration_path = self.root / PREREGISTRATION_PATH
        frozen = preregistration_path.read_bytes()
        candidates = self.assignment_candidates()
        candidates[2]["host_profile"]["memory_bytes"] += 1
        drifted_paths = self.write_assignment_candidates(candidates)

        with self.assertRaisesRegex(HostAssignmentError, "different frozen"):
            freeze_host_assignments(self.root, drifted_paths)

        self.assertEqual(preregistration_path.read_bytes(), frozen)

    def test_host_assignment_freeze_replace_failure_preserves_original(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()

        with mock.patch(
            "r01_preregistration.os.replace",
            side_effect=OSError("injected replace failure"),
        ), self.assertRaisesRegex(HostAssignmentError, "atomically update"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), original)
        self.assertEqual(
            list(preregistration_path.parent.glob(f".{preregistration_path.name}.*.tmp")),
            [],
        )

    def test_host_assignment_freeze_rejects_symbolic_link_input(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()
        symbolic_path = paths[0].with_name("symbolic-assignment.json")
        symbolic_path.symlink_to(paths[0])
        paths[0] = symbolic_path

        with self.assertRaisesRegex(HostAssignmentError, "symbolic-link components"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_detects_concurrent_canonical_change(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        paths = self.write_assignment_candidates()
        original_atomic_write = r01_module._atomic_write_json
        concurrent_bytes = preregistration_path.read_bytes() + b"\n"

        def change_before_replace(*arguments: object) -> None:
            preregistration_path.write_bytes(concurrent_bytes)
            original_atomic_write(*arguments)

        with mock.patch(
            "r01_preregistration._atomic_write_json",
            side_effect=change_before_replace,
        ), self.assertRaisesRegex(HostAssignmentError, "changed during"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), concurrent_bytes)

    def test_host_assignment_freeze_rejects_canonical_final_symlink(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        paths = self.write_assignment_candidates()
        outside = self.root.resolve() / "outside-preregistration.json"
        outside.write_bytes(preregistration_path.read_bytes())
        outside_original = outside.read_bytes()
        preregistration_path.unlink()
        preregistration_path.symlink_to(outside)

        with self.assertRaisesRegex(HostAssignmentError, "symbolic-link components"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(outside.read_bytes(), outside_original)

    def test_host_assignment_freeze_rejects_canonical_parent_symlink(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        paths = self.write_assignment_candidates()
        records_directory = preregistration_path.parent
        with tempfile.TemporaryDirectory() as outside_name:
            outside_records = Path(outside_name).resolve() / "records"
            shutil.copytree(records_directory, outside_records)
            outside_original = (outside_records / preregistration_path.name).read_bytes()
            shutil.rmtree(records_directory)
            records_directory.symlink_to(outside_records, target_is_directory=True)

            with self.assertRaisesRegex(
                HostAssignmentError, "symbolic-link components"
            ):
                freeze_host_assignments(self.root, paths)

            self.assertEqual(
                (outside_records / preregistration_path.name).read_bytes(),
                outside_original,
            )

    def test_host_assignment_freeze_rejects_input_parent_symlink(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()
        linked_directory = self.root.resolve() / "linked-assignment-inputs"
        linked_directory.symlink_to(paths[0].parent, target_is_directory=True)
        paths[0] = linked_directory / paths[0].name

        with self.assertRaisesRegex(HostAssignmentError, "symbolic-link components"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_malformed_json_without_writing(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()
        paths[0].write_text(
            '{"anchor":"oldest-supported","anchor":"oldest-supported"}\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(HostAssignmentError, "duplicate JSON key"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_closed_shape_and_role_mutations(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        original = preregistration_path.read_bytes()

        def add_extra(candidates: list[dict[str, object]]) -> None:
            candidates[0]["extra"] = True

        def change_contract(candidates: list[dict[str, object]]) -> None:
            candidates[0]["contract"] = "different"

        def change_state(candidates: list[dict[str, object]]) -> None:
            candidates[0]["assignment_state"] = "unassigned"

        def remove_profile(candidates: list[dict[str, object]]) -> None:
            candidates[0]["host_profile"] = None

        def break_role(candidates: list[dict[str, object]]) -> None:
            candidates[2]["host_profile"]["chip"] = "Apple M4"

        cases = (
            ("extra", add_extra, "fields differ"),
            ("contract", change_contract, "contract differs"),
            ("state", change_state, "must be assigned"),
            ("profile", remove_profile, "must be an object"),
            ("role", break_role, "Pro or Max chip"),
        )
        for name, mutation, fragment in cases:
            with self.subTest(name=name):
                candidates = self.assignment_candidates()
                mutation(candidates)
                paths = self.write_assignment_candidates(candidates)
                with self.assertRaisesRegex(HostAssignmentError, fragment):
                    freeze_host_assignments(self.root, paths)
                self.assertEqual(preregistration_path.read_bytes(), original)

    def test_host_assignment_freeze_rejects_invalid_canonical_source(self) -> None:
        preregistration_path = self.root / PREREGISTRATION_PATH
        assignment = self.preregistration["anchor_assignments"][0]
        assignment["assignment_state"] = "assigned"
        assignment["host_profile"] = self.assignment_candidates()[0]["host_profile"]
        self.write_preregistration()
        invalid = preregistration_path.read_bytes()
        paths = self.write_assignment_candidates()

        with self.assertRaisesRegex(HostAssignmentError, "must validate before"):
            freeze_host_assignments(self.root, paths)

        self.assertEqual(preregistration_path.read_bytes(), invalid)

    def test_one_host_can_satisfy_two_independent_anchor_contracts(self) -> None:
        candidates = self.assignment_candidates()
        shared_profile = copy.deepcopy(candidates[3]["host_profile"])
        shared_profile["host_id"] = "r01-host-34"
        pro_max_profile = copy.deepcopy(shared_profile)
        pro_max_profile["hardware_class"] = "pro_max_tier"
        core_ai_profile = copy.deepcopy(shared_profile)
        core_ai_profile["hardware_class"] = "core_ai_capable"
        candidates[2]["host_profile"] = pro_max_profile
        candidates[3]["host_profile"] = core_ai_profile
        paths = self.write_assignment_candidates(candidates)

        self.assertTrue(freeze_host_assignments(self.root, paths))

        self.assertEqual(self.verifier().check(), [])
        frozen = self.read_json(self.root / PREREGISTRATION_PATH)
        self.assertEqual(
            frozen["anchor_assignments"][2]["host_profile"]["host_id"],
            frozen["anchor_assignments"][3]["host_profile"]["host_id"],
        )

    def test_cli_rejects_unused_anchor_and_host_id_arguments(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            result = main(["--check", "--anchor", "pro-max"])
        self.assertEqual(result, 2)
        self.assertIn("--anchor requires", stderr.getvalue())

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            result = main(["--check", "--host-id", "r01-host-03"])
        self.assertEqual(result, 2)
        self.assertIn("--host-id requires", stderr.getvalue())

        assignment_path = self.write_assignment_candidates()[0]
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            result = main(["--check", "--assignment-file", str(assignment_path)])
        self.assertEqual(result, 2)
        self.assertIn("--assignment-file requires", stderr.getvalue())

    def test_cli_requires_complete_host_assignment_arguments(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            result = main(["--emit-host-assignment", "--anchor", "pro-max"])
        self.assertEqual(result, 2)
        self.assertIn("requires --anchor and --host-id", stderr.getvalue())

    def test_cli_requires_exactly_four_assignment_files(self) -> None:
        paths = self.write_assignment_candidates()
        for count, selected_paths in (
            (0, []),
            (3, paths[:3]),
            (5, paths + [paths[0]]),
        ):
            with self.subTest(count=count):
                arguments = ["--freeze-host-assignments"]
                for path in selected_paths:
                    arguments.extend(("--assignment-file", str(path)))
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    result = main(arguments)
                self.assertEqual(result, 2)
                self.assertIn("requires exactly four", stderr.getvalue())

    def test_cli_emits_closed_host_assignment_json(self) -> None:
        stdout = io.StringIO()
        with mock.patch(
            "r01_preregistration.collect_host_facts",
            return_value=self.pro_max_host_facts(),
        ), redirect_stdout(stdout):
            result = main(
                [
                    "--emit-host-assignment",
                    "--anchor",
                    "pro-max",
                    "--host-id",
                    "r01-host-03",
                ]
            )
        self.assertEqual(result, 0)
        assignment = json.loads(stdout.getvalue())
        self.assertEqual(assignment["anchor"], "pro-max")
        self.assertEqual(assignment["host_profile"]["host_id"], "r01-host-03")

    def test_cli_freezes_exactly_four_host_assignments(self) -> None:
        paths = self.write_assignment_candidates()
        arguments = ["--freeze-host-assignments"]
        for path in paths:
            arguments.extend(("--assignment-file", str(path)))
        stdout = io.StringIO()

        with mock.patch("r01_preregistration.REPOSITORY_ROOT", self.root), redirect_stdout(
            stdout
        ):
            result = main(arguments)

        self.assertEqual(result, 0)
        self.assertEqual(stdout.getvalue(), "R01 host assignments: FROZEN\n")
        self.assertEqual(self.verifier().check(), [])

        replay_stdout = io.StringIO()
        with mock.patch("r01_preregistration.REPOSITORY_ROOT", self.root), redirect_stdout(
            replay_stdout
        ):
            replay_result = main(arguments)

        self.assertEqual(replay_result, 0)
        self.assertEqual(
            replay_stdout.getvalue(),
            "R01 host assignments: ALREADY FROZEN\n",
        )

    def test_host_fact_collection_failure_does_not_echo_command_output(self) -> None:
        def run(command: tuple[str, ...], **_: object) -> subprocess.CompletedProcess[str]:
            raise subprocess.CalledProcessError(
                1, command, output="SERIAL-NUMBER", stderr="ACCOUNT-DATA"
            )

        with self.assertRaises(HostFactCollectionError) as context:
            collect_host_facts(run)
        self.assertNotIn("SERIAL-NUMBER", str(context.exception))
        self.assertNotIn("ACCOUNT-DATA", str(context.exception))

    def test_anchor_contract_order_is_exact(self) -> None:
        self.assertEqual(
            [item[0] for item in ANCHOR_CONTRACTS],
            ["oldest-supported", "m3-air", "pro-max", "core-ai"],
        )


if __name__ == "__main__":
    unittest.main()
